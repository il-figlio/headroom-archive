import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Quota switches the app layer owns. Core defaults to no Keychain access,
/// so nothing (tests included) reaches the login Keychain unless the app
/// turns it on: Limits on and "Use Claude Code's Keychain sign-in" on.
public enum QuotaSettings {
    /// Persisted "Use Claude Code's Keychain sign-in" preference; on when unset.
    public static let claudeKeychainKey = "limitsUseClaudeKeychain"
    private static let lock = NSLock()
    private static var keychain = false

    public static var useClaudeKeychain: Bool {
        get { lock.lock(); defer { lock.unlock() }; return keychain }
        set { lock.lock(); keychain = newValue; lock.unlock() }
    }
}

/// Metadata about Claude Code's Keychain item. Never carries the secret.
public struct KeychainItemInfo: Equatable, Sendable {
    public var modified: Date?
    public init(modified: Date?) { self.modified = modified }
}

/// Outcome of a non-interactive secret read.
public enum KeychainSecret: Equatable, Sendable {
    case found(Data)
    case missing
    /// The item exists but reading it would need a prompt (or consent was refused).
    case needsPrompt
    case failed(OSStatus)
}

/// Claude Code's "Claude Code-credentials" login-Keychain item, behind a
/// protocol so tests never touch the real Keychain. Neither call may show UI.
public protocol ClaudeKeychain: Sendable {
    /// Attributes only (existence and modification date): no secret, no UI.
    func itemInfo() -> KeychainItemInfo?
    /// The secret, read with UI disabled; fails instead of prompting.
    func readSecret() -> KeychainSecret
}

struct SystemClaudeKeychain: ClaudeKeychain {
    static let service = "Claude Code-credentials"
    typealias CopyMatching = @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var copyMatching: CopyMatching = { SecItemCopyMatching($0, $1) }

    /// Both no-UI switches: `LAContext.interactionNotAllowed` is the modern
    /// one, but alone it doesn't stop the legacy login Keychain's
    /// Allow/Deny sheet, which `kSecUseAuthenticationUIFail` does.
    static func query(returning key: CFString) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            key as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        #endif
        return query
    }

    func itemInfo() -> KeychainItemInfo? {
        var item: CFTypeRef?
        guard copyMatching(Self.query(returning: kSecReturnAttributes) as CFDictionary, &item) == errSecSuccess
        else { return nil }
        let attributes = item as? [String: Any]
        return KeychainItemInfo(modified: attributes?[kSecAttrModificationDate as String] as? Date)
    }

    func readSecret() -> KeychainSecret {
        var item: CFTypeRef?
        let status = copyMatching(Self.query(returning: kSecReturnData) as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failed(status) }
            return .found(data)
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem:
            return .needsPrompt
        default: return .failed(status)
        }
    }
}

/// `claude --version` for the usage request's user agent: run at most once
/// per launch, only the first known path that holds an executable, bounded
/// by a short timeout, with a fixed fallback.
final class ClaudeCLIVersion: @unchecked Sendable {
    static let fallback = "2.1.0"
    typealias Runner = @Sendable (URL, [String], BoundedProcess.Limits) -> BoundedProcess.Outcome

    private let lock = NSLock()
    private var cached: String?
    private let runner: Runner
    private let limits: BoundedProcess.Limits
    private let paths: @Sendable (URL) -> [URL]

    init(runner: @escaping Runner = { BoundedProcess.run($0, arguments: $1, limits: $2) },
         limits: BoundedProcess.Limits = .init(timeout: 3, killGrace: 1, outputLimit: 4096),
         candidates: @escaping @Sendable (URL) -> [URL] = { ClaudeCLIVersion.candidates(home: $0) }) {
        self.runner = runner
        self.limits = limits
        self.paths = candidates
    }

    static func candidates(home: URL) -> [URL] {
        [home.appendingPathComponent(".local/bin/claude"), home.appendingPathComponent(".claude/local/claude"),
         URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
    }

    /// Blocking; call from a utility queue. Worst case `timeout + killGrace`, once.
    func version(home: URL) -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var found: String?
        if let url = paths(home).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
           case .exited(0, let output) = runner(url, ["--version"], limits) {
            found = Self.parse(output)
        }
        let version = found ?? Self.fallback
        cached = version
        return version
    }

    /// "2.1.280 (Claude Code)" → "2.1.280"; anything that isn't a dotted
    /// number is rejected so it can't reach a header.
    static func parse(_ output: Data) -> String? {
        guard let text = String(data: output, encoding: .utf8),
              let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let token = String(first)
        guard token.count <= 32, token.first?.isNumber == true,
              token.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return token
    }
}

/// What a sign-in change looks like from the outside: file modification
/// times and the Keychain item's modification date. Gathered without
/// opening a file or reading a secret.
struct SignInStamp: Equatable, Sendable {
    var claudeFile: Date?
    var anteFile: Date?
    var keychain: KeychainItemInfo?
}
