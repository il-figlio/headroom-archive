import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Claude (Anthropic subscription quota via the OAuth usage endpoint)

/// Reads Claude Code's sign-in (its credentials file, or its login-Keychain
/// item read with UI disabled) or Ante's single OAuth file, and calls
/// `api.anthropic.com/api/oauth/usage` with the same request identity
/// Claude Code uses. Never refreshes or writes a token: Claude Code and Ante
/// refresh their own records, and the next poll re-reads them.
public final class ClaudeQuotaSource: QuotaSource, @unchecked Sendable {
    public let provider: AgentKind = .claude
    static let claudeFile = ".claude/.credentials.json"
    static let anteFile = ".ante/auth/credentials/oauth/anthropic.json"
    public let credentialPaths = [claudeFile, anteFile]
    let state = QuotaSourceState()
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static let signInChangedMessage = "Claude Code sign-in changed — refreshing"
    static let keychainPromptMessage =
        "Claude Code's Keychain sign-in can't be read without a prompt. Run `claude` once, or turn off Keychain use in Settings."
    static let missingMessage = "No Claude sign-in found — run `claude` to sign in."
    static func expiredMessage(_ origin: Origin) -> String {
        "Claude sign-in expired — run `\(origin.command)` to sign in again."
    }

    private let keychain: any ClaudeKeychain
    private let keychainAllowed: @Sendable () -> Bool
    private let http: QuotaHTTP.Get
    private let cliVersion: ClaudeCLIVersion

    private let lock = NSLock()
    /// Avoids re-reading the Keychain while the cached token remains valid.
    private var cachedCredentials: Credentials?
    /// Sign-in metadata seen at the last credential failure; nil otherwise.
    private var failureStamp: SignInStamp?
    /// A sign-in change was noticed; the next fetch skips any Retry-After gate.
    private var retryPending = false

    public convenience init() { self.init(keychain: SystemClaudeKeychain()) }

    init(keychain: any ClaudeKeychain,
         keychainAllowed: @escaping @Sendable () -> Bool = { QuotaSettings.useClaudeKeychain },
         http: @escaping QuotaHTTP.Get = { try await QuotaHTTP.get($0, headers: $1) },
         cliVersion: ClaudeCLIVersion = ClaudeCLIVersion()) {
        self.keychain = keychain
        self.keychainAllowed = keychainAllowed
        self.http = http
        self.cliVersion = cliVersion
    }

    enum Origin: Sendable, Equatable {
        case claudeFile, anteFile, keychain
        /// The CLI that renews this sign-in.
        var command: String { self == .anteFile ? "ante" : "claude" }
    }

    struct Credentials: Sendable {
        var accessToken: String
        var scopes: [String]
        var subscriptionType: String?
        var expiresAt: Date?
        var origin: Origin = .claudeFile
        func isExpired(_ now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
    }

    struct CredentialError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The Keychain, or nil while the setting (or Limits) is off. Every
    /// Keychain call goes through here.
    private var allowedKeychain: (any ClaudeKeychain)? { keychainAllowed() ? keychain : nil }

    // MARK: Discovery (existence and metadata only)

    public func hasCredentials(home: URL) -> Bool {
        credentialPaths.contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
            || allowedKeychain?.itemInfo() != nil
    }

    /// Which Claude sign-ins exist, for Settings: Claude Code's file, its
    /// Keychain item, Ante's single file. Nothing is opened or read.
    func detectedOrigins(home: URL) -> [Origin] {
        let exists = { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
        var origins: [Origin] = []
        if exists(Self.claudeFile) { origins.append(.claudeFile) }
        if allowedKeychain?.itemInfo() != nil { origins.append(.keychain) }
        if exists(Self.anteFile) { origins.append(.anteFile) }
        return origins
    }

    func stamp(home: URL) -> SignInStamp {
        func modified(_ path: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(path).path))?[.modificationDate] as? Date
        }
        return SignInStamp(claudeFile: modified(Self.claudeFile), anteFile: modified(Self.anteFile),
                           keychain: allowedKeychain?.itemInfo())
    }

    /// True once per change to the sign-in files' or Keychain item's
    /// modification dates after a credential failure; the next fetch then
    /// retries even inside a Retry-After gate. Free when nothing failed.
    public func noteSignInChange(home: URL) -> Bool {
        lock.lock(); let recorded = failureStamp; lock.unlock()
        guard let recorded else { return false }
        let current = stamp(home: home)
        lock.lock(); defer { lock.unlock() }
        guard failureStamp == recorded, current != recorded else { return false }
        failureStamp = current
        retryPending = true
        cachedCredentials = nil
        return true
    }

    // MARK: Credentials

    /// A usable file token first; else Claude Code's Keychain item, read with
    /// UI disabled; else an error naming the fix. An expired file never
    /// hides a valid Keychain sign-in.
    static func readCredentials(home: URL, keychain: (any ClaudeKeychain)? = nil, now: Date = Date()) throws -> Credentials {
        var expired: Credentials?
        func noteExpired(_ creds: Credentials) {
            // Prefer Claude Code's fix over Ante's when both are expired.
            if expired == nil || expired?.origin == .anteFile && creds.origin != .anteFile { expired = creds }
        }
        for (path, origin) in [(claudeFile, Origin.claudeFile), (anteFile, .anteFile)] {
            guard let data = try? Data(contentsOf: home.appendingPathComponent(path)), var creds = parse(data) else { continue }
            creds.origin = origin
            if !creds.isExpired(now) { return creds }
            noteExpired(creds)
        }
        if let keychain {
            switch keychain.readSecret() {
            case .found(let data):
                guard var creds = parse(data) else {
                    throw CredentialError(message: "Claude Code's Keychain sign-in isn't in a format Headroom reads.")
                }
                creds.origin = .keychain
                if !creds.isExpired(now) { return creds }
                noteExpired(creds)
            case .missing:
                break
            case .needsPrompt:
                throw CredentialError(message: keychainPromptMessage)
            case .failed(let status):
                throw CredentialError(message: "Couldn't read Claude Code's Keychain sign-in (error \(status)).")
            }
        }
        if let expired { throw CredentialError(message: expiredMessage(expired.origin)) }
        throw CredentialError(message: missingMessage)
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let access = json["access_token"] as? String, !access.isEmpty,
           let expiresAt = QuotaDate.parse(json["expires_at"] as? String) {
            // Ante owns this file and token refresh; never write to its store.
            return Credentials(accessToken: access,
                               scopes: json["scopes"] as? [String] ?? [],
                               subscriptionType: nil,
                               expiresAt: expiresAt)
        }
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        var expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double, ms > 0 { expiresAt = Date(timeIntervalSince1970: ms / 1000) }
        return Credentials(accessToken: access,
                           scopes: oauth["scopes"] as? [String] ?? [],
                           subscriptionType: oauth["subscriptionType"] as? String,
                           expiresAt: expiresAt)
    }

    private func validCredentials(home: URL) throws -> Credentials {
        lock.lock(); defer { lock.unlock() }
        // Keychain use was turned off: forget a token that came from it.
        if cachedCredentials?.origin == .keychain, !keychainAllowed() { cachedCredentials = nil }
        if let cached = cachedCredentials,
           cached.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true {
            return cached
        }
        let fresh = try Self.readCredentials(home: home, keychain: allowedKeychain)
        cachedCredentials = fresh
        return fresh
    }

    // MARK: Fetch

    public func fetch(home: URL) async -> QuotaReading {
        _ = noteSignInChange(home: home)
        if takeRetry() { state.unblock() }
        if let reason = state.blockedReason(now: Date()) {
            return state.fail(reason, provider: provider)
        }
        let credentials: Credentials
        do { credentials = try validCredentials(home: home) } catch {
            let message = error.localizedDescription
            let retry = message == Self.missingMessage ? nil : Date().addingTimeInterval(900)
            return failSignIn(message, home: home, retryAfter: retry)
        }

        let headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": await userAgent(home: home),
        ]
        do {
            // cedar_ember=1 asks for the per-model weekly windows too.
            let url = Self.usageURL.appending(queryItems: [URLQueryItem(name: "cedar_ember", value: "1")])
            var (data, response) = try await http(url, headers)
            if response.statusCode == 400 {
                // Some tokens reject the extended query; retry bare.
                (data, response) = try await http(Self.usageURL, headers)
            }
            switch response.statusCode {
            case 200:
                guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
                    return failOther("Claude usage API returned an unexpected response")
                }
                clearFailure()
                return state.succeed(Self.map(decoded, credentials: credentials))
            case 401:
                clearCachedCredentials()
                return failSignIn(Self.expiredMessage(credentials.origin), home: home,
                                  retryAfter: Date().addingTimeInterval(900))
            case 403:
                return failSignIn("Claude sign-in lacks the usage scope — run `\(credentials.origin.command)` to sign in again.",
                                  home: home, retryAfter: Date().addingTimeInterval(3600))
            case 429:
                return failOther("Claude usage API rate-limited",
                                 retryAfter: Self.retryAfter(response) ?? Date().addingTimeInterval(900))
            default:
                return failOther("Claude usage API returned HTTP \(response.statusCode)")
            }
        } catch {
            return failOther("Network error: \(error.localizedDescription)")
        }
    }

    private func userAgent(home: URL) async -> String {
        let probe = cliVersion
        let version = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: probe.version(home: home)) }
        }
        return "claude-cli/\(version) (external, cli)"
    }

    private func takeRetry() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { retryPending = false }
        return retryPending
    }

    /// A credential problem: remember what the sign-in looked like so a
    /// change to it can trigger an early retry.
    private func failSignIn(_ message: String, home: URL, retryAfter: Date?) -> QuotaReading {
        let current = stamp(home: home)
        lock.lock(); failureStamp = current; lock.unlock()
        return state.fail(message, provider: provider, retryAfter: retryAfter)
    }

    private func failOther(_ message: String, retryAfter: Date? = nil) -> QuotaReading {
        clearFailure()
        return state.fail(message, provider: provider, retryAfter: retryAfter)
    }

    private func clearFailure() {
        lock.lock(); failureStamp = nil; lock.unlock()
    }

    private func clearCachedCredentials() {
        lock.lock(); cachedCredentials = nil; lock.unlock()
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    // MARK: Response

    /// Decoded leniently: a missing, null, or oddly typed field drops only
    /// that window, never the whole reading.
    struct Response: Decodable {
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var sevenDaySonnet: Window?
        var extraUsage: ExtraUsage?
        /// Shape not pinned down; scanned for `weekly_scoped` entries.
        var limits: JSONValue?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case extraUsage = "extra_usage"
            case limits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
            sevenDayOpus = try? c.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
            sevenDaySonnet = try? c.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
            extraUsage = try? c.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
            limits = try? c.decodeIfPresent(JSONValue.self, forKey: .limits)
        }

        struct Window: Decodable {
            var utilization: Double?
            var resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization, resetsAt = "resets_at"
            }
            init(utilization: Double?, resetsAt: String?) {
                self.utilization = utilization; self.resetsAt = resetsAt
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                utilization = (try? c.decodeIfPresent(Double.self, forKey: .utilization))
                    ?? (try? c.decodeIfPresent(String.self, forKey: .utilization)).flatMap { $0.flatMap(Double.init) }
                resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
            }
        }

        struct ExtraUsage: Decodable {
            var isEnabled: Bool?
            var monthlyLimit: Double?
            var usedCredits: Double?
            var utilization: Double?
            var currency: String?
            enum CodingKeys: String, CodingKey {
                case isEnabled = "is_enabled"
                case monthlyLimit = "monthly_limit"
                case usedCredits = "used_credits"
                case utilization, currency
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                isEnabled = try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)
                monthlyLimit = try? c.decodeIfPresent(Double.self, forKey: .monthlyLimit)
                usedCredits = try? c.decodeIfPresent(Double.self, forKey: .usedCredits)
                utilization = try? c.decodeIfPresent(Double.self, forKey: .utilization)
                currency = try? c.decodeIfPresent(String.self, forKey: .currency)
            }
        }
    }

    /// Order: 5h, Week, then per-model weekly windows.
    static func map(_ response: Response, credentials: Credentials) -> QuotaReading {
        var reading = QuotaReading(provider: .claude)
        reading.plan = credentials.subscriptionType?.capitalized
        func window(_ label: String, _ raw: Response.Window?, model: Bool = false) -> QuotaWindow? {
            guard let utilization = raw?.utilization, utilization.isFinite else { return nil }
            return QuotaWindow(label: label, usedFraction: utilization / 100, resetsAt: QuotaDate.parse(raw?.resetsAt),
                               detail: model ? "Weekly limit for \(label) models" : nil)
        }
        let scoped = scopedWindows(response.limits)
        var models = [window("Sonnet", response.sevenDaySonnet, model: true),
                      window("Opus", response.sevenDayOpus, model: true)].compactMap { $0 }
        for (scope, raw) in scoped {
            guard case .model(let label) = scope, !models.contains(where: { $0.label == label }),
                  let w = window(label, raw, model: true) else { continue }
            models.append(w)
        }
        // A generic "All models" scope is the Week window under another name.
        let generic = scoped.first { $0.0 == .generic }?.1
        reading.windows = [window("5h", response.fiveHour), window("Week", response.sevenDay) ?? window("Week", generic)]
            .compactMap { $0 } + models
        if let extra = response.extraUsage, extra.isEnabled == true {
            if let used = extra.usedCredits, let limit = extra.monthlyLimit, limit > 0 {
                // used_credits arrives in minor units; monthly_limit is dollars.
                reading.balance = String(format: "$%.2f of $%.0f extra usage", used / 100, limit)
            } else if let utilization = extra.utilization {
                reading.balance = String(format: "Extra usage %.0f%%", utilization)
            }
        }
        return reading
    }

    enum Scope: Equatable {
        case generic
        case model(String)
    }

    private static let nameKeys = ["display_name", "model_display_name", "scope_display_name", "model", "model_name",
                                   "scope", "scope_name", "name", "label"]
    private static let percentKeys = ["utilization", "used_percent", "percent_used", "usage_percent"]

    /// `limits[].weekly_scoped` entries, accepting either an element that
    /// carries a `weekly_scoped` object/array or one typed "weekly_scoped".
    static func scopedWindows(_ limits: JSONValue?) -> [(Scope, Response.Window)] {
        var elements: [JSONValue] = []
        switch limits {
        case .array(let items)?: elements = items
        case .object?: elements = [limits!]
        default: return []
        }
        var out: [(Scope, Response.Window)] = []
        for element in elements {
            var entries: [JSONValue] = []
            switch element["weekly_scoped"] {
            case .array(let items)?: entries = items
            case .object?: entries = [element["weekly_scoped"]!]
            default:
                let kind = (element["type"] ?? element["kind"] ?? element["window"])?.string?.lowercased()
                if kind == "weekly_scoped" { entries = [element] }
            }
            for entry in entries {
                guard let percent = percentKeys.lazy.compactMap({ entry[$0]?.number }).first,
                      let name = name(in: entry) ?? name(in: element),
                      let scope = scope(name) else { continue }
                var resets = entry["resets_at"]?.string ?? entry["reset_at"]?.string
                if resets == nil, let epoch = (entry["resets_at"] ?? entry["reset_at"])?.number {
                    resets = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch))
                }
                out.append((scope, Response.Window(utilization: percent, resetsAt: resets)))
            }
        }
        return out
    }

    private static func name(in value: JSONValue) -> String? {
        for key in nameKeys {
            if let text = value[key]?.string, !text.isEmpty { return text }
            if case .object? = value[key], let nested = name(in: value[key]!) { return nested }
        }
        return nil
    }

    /// "claude-sonnet-4-5" → Sonnet; "All models" → generic; anything else
    /// becomes its first meaningful word, cut to fit the 44 pt label column.
    static func scope(_ raw: String) -> Scope? {
        let words = raw.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains("all") || words.contains("any") { return .generic }
        for family in ["opus", "sonnet", "haiku", "fable"] where words.contains(where: { $0.hasPrefix(family) }) {
            return .model(family.capitalized)
        }
        let filler: Set = ["claude", "model", "models", "weekly", "week", "scoped", "limit", "seven", "day", "7"]
        guard let word = words.first(where: { !filler.contains($0) && $0.first?.isLetter == true }) else { return nil }
        return .model(String(word.capitalized.prefix(7)))
    }
}

/// Minimal JSON tree for response fields whose shape isn't fixed.
enum JSONValue: Decodable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? c.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }
    var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }
    var number: Double? {
        switch self {
        case .number(let value): return value.isFinite ? value : nil
        case .string(let text): return Double(text).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }
}
