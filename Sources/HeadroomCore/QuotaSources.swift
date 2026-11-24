import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession used by all quota calls: ephemeral with no URL cache so bearer
/// tokens never land in the shared cache, and a hard 30s ceiling so a wedged
/// connection can't stall a refresh cycle.
enum QuotaHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Headroom", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static func postForm(_ url: URL, fields: [(String, String)]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Headroom", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        let encoded = fields.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        request.httpBody = encoded.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Decodes the `exp`/`chatgpt_account_id` claims from a JWT payload without
/// verifying the signature — the token is treated as opaque owner evidence
/// the provider's own CLI already minted, exactly like CodexBar does.
enum QuotaJWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func expiration(_ token: String) -> Date? {
        guard let exp = payload(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// ISO-8601 timestamps with or without fractional seconds / zone offsets.
enum QuotaDate {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// Shared per-source bookkeeping: the last successful reading is replayed
/// on failure so a transient error dims the card instead of blanking it,
/// and `blockedUntil` honors Retry-After so a rate-limited endpoint is left
/// alone instead of hammered every poll.
public final class QuotaSourceState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastGood: QuotaReading?
    private var blockedUntil = Date.distantPast
    private var blockedMessage: String?

    public init() {}

    var blocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < blockedUntil
    }

    /// While gated, report the *cause* ("session expired — run `claude`"),
    /// not a generic rate-limit line.
    func blockedReason(now: Date) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard now < blockedUntil else { return nil }
        let quiet = "next attempt \(blockedUntil.formatted(date: .omitted, time: .shortened))"
        return (blockedMessage.map { "\($0) · " } ?? "") + quiet
    }

    func succeed(_ reading: QuotaReading) -> QuotaReading {
        lock.lock(); defer { lock.unlock() }
        lastGood = reading
        blockedUntil = .distantPast
        blockedMessage = nil
        return reading
    }

    /// Record a failure; when `retryAfter` is supplied the source stays quiet
    /// until then, otherwise failures don't gate retries (the poll cadence
    /// already throttles them).
    func fail(_ message: String, provider: AgentKind, retryAfter: Date? = nil) -> QuotaReading {
        lock.lock(); defer { lock.unlock() }
        if let retryAfter { blockedUntil = retryAfter; blockedMessage = message }
        if var good = lastGood {
            good.error = message
            return good
        }
        var reading = QuotaReading(provider: provider)
        reading.error = message
        return reading
    }
}

// MARK: - Codex (OpenAI subscription quota via the ChatGPT backend)

/// Reads `~/.codex/auth.json` (written by the Codex CLI login) and calls
/// `chatgpt.com/backend-api/wham/usage` — the same endpoint the Codex app
/// and CodexBar use. Never refreshes tokens: rotating a refresh token
/// without writing it back would break the CLI's own session, so an expired
/// token surfaces as a re-auth error and `codex login` heals it.
public final class CodexQuotaSource: QuotaSource, @unchecked Sendable {
    public let provider: AgentKind = .codex
    public let credentialPaths = [".codex/auth.json"]
    let state = QuotaSourceState()

    public init() {}

    struct Credentials: Sendable {
        var accessToken: String
        var accountID: String?
        /// True when auth.json only has an OPENAI_API_KEY — the wham usage
        /// endpoint needs an OAuth session, not an API key.
        var apiKeyOnly = false
    }

    static func readCredentials(home: URL) throws -> Credentials {
        let url = home.appendingPathComponent(".codex/auth.json")
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "headroom.quota", code: 1, userInfo: [NSLocalizedDescriptionKey: "auth.json isn't JSON"])
        }
        if let tokens = json["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            var accountID = tokens["account_id"] as? String
            if accountID == nil, let idToken = tokens["id_token"] as? String {
                accountID = accountIDFromJWT(idToken)
            }
            accountID = accountID ?? accountIDFromJWT(access)
            return Credentials(accessToken: access, accountID: accountID)
        }
        if let key = json["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return Credentials(accessToken: "", apiKeyOnly: true)
        }
        throw NSError(domain: "headroom.quota", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "auth.json has no OAuth tokens — run `codex login`"])
    }

    private static func accountIDFromJWT(_ token: String) -> String? {
        guard let payload = QuotaJWT.payload(token) else { return nil }
        if let id = payload["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        if let orgs = payload["organizations"] as? [[String: Any]],
           let id = orgs.compactMap({ $0["id"] as? String }).first { return id }
        return nil
    }

    // The wire shape, decoded leniently — unknown/extra fields are ignored
    // and a malformed window degrades to nil instead of failing the fetch.
    struct Response: Decodable {
        var planType: String?
        var accountId: String?
        var rateLimit: RateLimit?
        var credits: Credits?
        var additionalRateLimits: [Additional]?
        var resetCredits: ResetCredits?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case accountId = "account_id"
            case rateLimit = "rate_limit"
            case credits
            case additionalRateLimits = "additional_rate_limits"
            case resetCredits = "rate_limit_reset_credits"
        }

        struct ResetCredits: Decodable {
            var availableCount: Int?
            enum CodingKeys: String, CodingKey { case availableCount = "available_count" }
        }

        struct RateLimit: Decodable {
            var primaryWindow: Window?
            var secondaryWindow: Window?
            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        struct Window: Decodable {
            var usedPercent: Double
            var resetAt: Double?
            var limitWindowSeconds: Int?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
                case limitWindowSeconds = "limit_window_seconds"
            }
            var quotaWindow: QuotaWindow? {
                QuotaWindow(label: CodexQuotaSource.windowLabel(seconds: limitWindowSeconds),
                            usedFraction: usedPercent / 100,
                            resetsAt: resetAt.map { Date(timeIntervalSince1970: $0) })
            }
        }

        struct Credits: Decodable {
            var hasCredits: Bool?
            var unlimited: Bool?
            var balance: Double?
            enum CodingKeys: String, CodingKey {
                case hasCredits = "has_credits", unlimited, balance
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                hasCredits = try? c.decodeIfPresent(Bool.self, forKey: .hasCredits)
                unlimited = try? c.decodeIfPresent(Bool.self, forKey: .unlimited)
                if let d = try? c.decodeIfPresent(Double.self, forKey: .balance) { balance = d }
                else if let s = try? c.decodeIfPresent(String.self, forKey: .balance) { balance = Double(s) }
            }
        }

        struct Additional: Decodable {
            var limitName: String?
            var meteredFeature: String?
            var rateLimit: RateLimit?
            enum CodingKeys: String, CodingKey {
                case limitName = "limit_name"
                case meteredFeature = "metered_feature"
                case rateLimit = "rate_limit"
            }
        }
    }

    static func windowLabel(seconds: Int?) -> String {
        switch seconds {
        case 18000: return "5h"
        case 86400: return "Day"
        case 604800: return "Week"
        case let s?: return s >= 86400 ? "\(s / 86400)d" : "\(s / 3600)h"
        case nil: return "Window"
        }
    }

    public func fetch(home: URL) async -> QuotaReading {
        if let reason = state.blockedReason(now: Date()) {
            return state.fail(reason, provider: provider)
        }
        let credentials: Credentials
        do { credentials = try Self.readCredentials(home: home) } catch {
            return state.fail(error.localizedDescription, provider: provider)
        }
        guard !credentials.apiKeyOnly else {
            return state.fail("API-key sign-in doesn't expose plan limits", provider: provider)
        }

        do {
            var headers = ["Authorization": "Bearer \(credentials.accessToken)"]
            if let accountID = credentials.accountID { headers["ChatGPT-Account-Id"] = accountID }
            let (data, http) = try await QuotaHTTP.get(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
            switch http.statusCode {
            case 200:
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                return state.succeed(Self.map(decoded))
            case 401, 403:
                return state.fail("Codex session expired — run `codex login`", provider: provider,
                                  retryAfter: Date().addingTimeInterval(3600))
            case 429:
                return state.fail("Codex usage API rate-limited", provider: provider,
                                  retryAfter: Self.retryAfter(http) ?? Date().addingTimeInterval(900))
            default:
                return state.fail("Codex usage API returned HTTP \(http.statusCode)", provider: provider)
            }
        } catch {
            return state.fail("Network error: \(error.localizedDescription)", provider: provider)
        }
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    static func map(_ response: Response) -> QuotaReading {
        var reading = QuotaReading(provider: .codex)
        if let plan = response.planType, !plan.isEmpty {
            reading.plan = plan.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let primary = response.rateLimit?.primaryWindow?.quotaWindow { reading.windows.append(primary) }
        if let secondary = response.rateLimit?.secondaryWindow?.quotaWindow { reading.windows.append(secondary) }
        for extra in (response.additionalRateLimits ?? []).prefix(2) {
            for window in [extra.rateLimit?.primaryWindow, extra.rateLimit?.secondaryWindow].compactMap({ $0?.quotaWindow }) {
                var labeled = window
                labeled.label = "\(extra.limitName ?? extra.meteredFeature ?? "Model") · \(window.label)"
                reading.windows.append(labeled)
            }
        }
        if let credits = response.credits {
            if credits.unlimited == true {
                reading.balance = "unlimited credits"
            } else if credits.hasCredits == true, let balance = credits.balance {
                reading.balance = String(format: "%.0f credits", balance)
            }
        }
        if let count = response.resetCredits?.availableCount, count > 0 {
            reading.balance = (reading.balance.map { $0 + " · " } ?? "") + "\(count) reset\(count == 1 ? "" : "s")"
        }
        return reading
    }
}

// MARK: - Claude (Anthropic subscription quota via the OAuth usage endpoint)

/// Reads Claude Code's or Ante's existing OAuth credential file and
/// calls `api.anthropic.com/api/oauth/usage` with the same request identity
/// Claude Code uses. Never refreshes the OAuth token — Claude Code refreshes
/// the file itself, so the next poll just re-reads it.
public final class ClaudeQuotaSource: QuotaSource, @unchecked Sendable {
    public let provider: AgentKind = .claude
    public let credentialPaths = [".claude/.credentials.json", ".ante/auth/credentials/oauth/anthropic.json"]
    let state = QuotaSourceState()
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private var cachedVersion: String?
    /// Avoid repeated Keychain reads while the cached token remains valid.
    private let credentialLock = NSLock()
    private var cachedCredentials: Credentials?

    public init() {}

    struct Credentials: Sendable {
        var accessToken: String
        var scopes: [String]
        var subscriptionType: String?
        var expiresAt: Date?
    }

    /// `allowKeychain` is a test seam: the keychain is process-global and a
    /// temp `home` can't isolate it.
    static func readCredentials(home: URL, allowKeychain: Bool = true) throws -> Credentials {
        let paths = [".claude/.credentials.json", ".ante/auth/credentials/oauth/anthropic.json"]
        var expired: Credentials?
        for path in paths {
            let url = home.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url), let creds = parse(data) else { continue }
            if creds.expiresAt.map({ $0 <= Date() }) != true { return creds }
            if expired == nil { expired = creds }
        }
        if let expired { return expired }
        // Claude Code may keep the live record in the login keychain.
        // Background usage monitoring must never request interactive consent.
        if allowKeychain, let creds = readKeychain() { return creds }
        throw NSError(domain: "headroom.quota", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Claude usage unavailable — credentials are missing or require Keychain consent"])
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

    private static let keychainService = "Claude Code-credentials"

    static func readKeychain(
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    ) -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // This is the legacy login Keychain, not a biometric item.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        guard copyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return parse(data)
    }

    /// Mirrors the `claude-cli/<version> (external, cli)` identity the
    /// endpoint expects; falls back to a recent version when the CLI isn't
    /// on any known path.
    private func claudeUserAgent(home: URL) -> String {
        if let cachedVersion { return "claude-cli/\(cachedVersion) (external, cli)" }
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        var version = "2.1.0"
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let found = Self.versionString(path: path) { version = found; break }
        }
        cachedVersion = version
        return "claude-cli/\(version) (external, cli)"
    }

    private static func versionString(path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        // "2.1.280 (Claude Code)" → "2.1.280"
        return text.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    struct Response: Decodable {
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var sevenDaySonnet: Window?
        var extraUsage: ExtraUsage?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case extraUsage = "extra_usage"
        }

        struct Window: Decodable {
            var utilization: Double?
            var resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization, resetsAt = "resets_at"
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
        }
    }

    public func fetch(home: URL) async -> QuotaReading {
        if let reason = state.blockedReason(now: Date()) {
            return state.fail(reason, provider: provider)
        }
        let credentials: Credentials
        do { credentials = try validCredentials(home: home) } catch {
            return state.fail(error.localizedDescription, provider: provider)
        }
        if let expiresAt = credentials.expiresAt, expiresAt < Date() {
            return state.fail("Claude session expired — open Claude or Ante to refresh usage credentials",
                              provider: provider, retryAfter: Date().addingTimeInterval(900))
        }

        let headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": claudeUserAgent(home: home),
        ]
        do {
            let url = Self.usageURL.appending(queryItems: [URLQueryItem(name: "cedar_ember", value: "1")])
            var (data, http) = try await QuotaHTTP.get(url, headers: headers)
            if http.statusCode == 400 {
                // Some tokens reject the reset-inventory query; retry bare.
                (data, http) = try await QuotaHTTP.get(Self.usageURL, headers: headers)
            }
            switch http.statusCode {
            case 200:
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                return state.succeed(Self.map(decoded, credentials: credentials))
            case 401:
                clearCachedCredentials()
                return state.fail("Claude session expired — run `claude` to re-authenticate",
                                  provider: provider, retryAfter: Date().addingTimeInterval(900))
            case 403:
                return state.fail("Token lacks usage scope — sign in again via `claude`", provider: provider,
                                  retryAfter: Date().addingTimeInterval(3600))
            case 429:
                return state.fail("Claude usage API rate-limited", provider: provider,
                                  retryAfter: Self.retryAfter(http) ?? Date().addingTimeInterval(900))
            default:
                return state.fail("Claude usage API returned HTTP \(http.statusCode)", provider: provider)
            }
        } catch {
            return state.fail("Network error: \(error.localizedDescription)", provider: provider)
        }
    }

    private func validCredentials(home: URL) throws -> Credentials {
        credentialLock.lock(); defer { credentialLock.unlock() }
        if let cached = cachedCredentials,
           let expiresAt = cached.expiresAt, expiresAt > Date().addingTimeInterval(60) {
            return cached
        }
        if let cached = cachedCredentials, cached.expiresAt == nil { return cached }
        let fresh = try Self.readCredentials(home: home)
        cachedCredentials = fresh
        return fresh
    }

    private func clearCachedCredentials() {
        credentialLock.lock(); defer { credentialLock.unlock() }
        cachedCredentials = nil
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw) else { return nil }
        return Date().addingTimeInterval(seconds)
    }

    static func map(_ response: Response, credentials: Credentials) -> QuotaReading {
        var reading = QuotaReading(provider: .claude)
        reading.plan = credentials.subscriptionType?.capitalized
        for (label, window) in [
            ("5h", response.fiveHour),
            ("Week", response.sevenDay),
            ("Opus wk", response.sevenDayOpus),
            ("Sonnet wk", response.sevenDaySonnet),
        ] {
            guard let utilization = window?.utilization else { continue }
            reading.windows.append(QuotaWindow(label: label, usedFraction: utilization / 100,
                                               resetsAt: QuotaDate.parse(window?.resetsAt)))
        }
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
}
