import Foundation
import Testing
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
@testable import HeadroomCore

// Claude Code sign-in checks. Every Keychain, HTTP and `claude --version`
// call goes to a fake: the real login Keychain, the network, the real CLI
// and the real ~/.claude are never touched.

private final class FakeKeychain: ClaudeKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var _info: KeychainItemInfo?
    private var _secret: KeychainSecret
    private var _calls = 0

    init(info: KeychainItemInfo? = nil, secret: KeychainSecret = .missing) {
        _info = info; _secret = secret
    }
    var info: KeychainItemInfo? {
        get { lock.lock(); defer { lock.unlock() }; return _info }
        set { lock.lock(); _info = newValue; lock.unlock() }
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    func itemInfo() -> KeychainItemInfo? {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return _info
    }
    func readSecret() -> KeychainSecret {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return _secret
    }
}

private final class FakeHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(URL, [String: String])] = []
    private let respond: @Sendable (URL) -> (Int, String)

    init(respond: @escaping @Sendable (URL) -> (Int, String) = { _ in (200, #"{"five_hour":{"utilization":10}}"#) }) {
        self.respond = respond
    }
    var requests: [(URL, [String: String])] { lock.lock(); defer { lock.unlock() }; return _requests }

    private func record(_ url: URL, _ headers: [String: String]) {
        lock.lock(); _requests.append((url, headers)); lock.unlock()
    }

    var get: QuotaHTTP.Get {
        { url, headers in
            self.record(url, headers)
            let (status, body) = self.respond(url)
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

private struct Home {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-check-\(UUID().uuidString)")

    func write(_ relative: String, _ contents: String, executable: Bool = false, modified: Date? = nil) {
        let file = url.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: file, atomically: true, encoding: .utf8)
        var attributes: [FileAttributeKey: Any] = [:]
        if executable { attributes[.posixPermissions] = 0o700 }
        if let modified { attributes[.modificationDate] = modified }
        if !attributes.isEmpty { try? FileManager.default.setAttributes(attributes, ofItemAtPath: file.path) }
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

private let expiredFile = #"{"claudeAiOauth":{"accessToken":"file-old","expiresAt":1000}}"#
private let validFile = #"{"claudeAiOauth":{"accessToken":"file-new","expiresAt":4102444800000,"subscriptionType":"max"}}"#
private let keychainRecord = Data(#"{"claudeAiOauth":{"accessToken":"kc-token","expiresAt":4102444800000,"subscriptionType":"pro"}}"#.utf8)

/// A version probe that never runs a process.
private func quietVersion(_ runs: Count = Count()) -> ClaudeCLIVersion {
    ClaudeCLIVersion(runner: { _, _, _ in runs.bump(); return .exited(status: 0, output: Data("9.9.9 (Claude Code)\n".utf8)) },
                     candidates: { _ in [] })
}

private func source(_ keychain: FakeKeychain, allowed: Bool = true, http: FakeHTTP = FakeHTTP()) -> ClaudeQuotaSource {
    ClaudeQuotaSource(keychain: keychain, keychainAllowed: { allowed }, http: http.get, cliVersion: quietVersion())
}

// MARK: - Participation and detection

@Test func keychainOnlyUserGetsAClaudeSource() {
    let home = Home(); defer { home.remove() }
    let keychain = FakeKeychain(info: .init(modified: Date(timeIntervalSince1970: 1)))
    let claude = source(keychain)
    let selection = QuotaSources.select(home: home.url, from: [claude], ante: [])
    #expect(selection.sources.count == 1 && selection.sources.first is ClaudeQuotaSource)
    #expect(!selection.claudeCodeHidden)
    let detected = QuotaSources.detect(home: home.url, from: [claude], ante: [])
    #expect(detected == .init(names: ["Claude (Claude Code — Keychain)"], claudeCodeHidden: false))
}

@Test func detectionNamesFileKeychainAndAnteFile() {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, expiredFile)
    home.write(ClaudeQuotaSource.anteFile, "{}")
    let claude = source(FakeKeychain(info: .init(modified: nil)))
    #expect(QuotaSources.detect(home: home.url, from: [claude], ante: []).names
        == ["Claude (Claude Code — file, Keychain)", "Claude (Ante)"])
}

@Test func keychainSettingOffMakesNoKeychainCalls() async {
    let home = Home(); defer { home.remove() }
    let keychain = FakeKeychain(info: .init(modified: Date()), secret: .found(keychainRecord))
    let http = FakeHTTP()
    let claude = source(keychain, allowed: false, http: http)
    #expect(QuotaSources.select(home: home.url, from: [claude], ante: []).sources.isEmpty)
    #expect(QuotaSources.detect(home: home.url, from: [claude], ante: []).names.isEmpty)

    home.write(ClaudeQuotaSource.claudeFile, expiredFile)
    let reading = await claude.fetch(home: home.url)
    #expect(reading.error == "Claude sign-in expired — run `claude` to sign in again.")
    #expect(!claude.noteSignInChange(home: home.url))
    #expect(keychain.calls == 0)
    #expect(http.requests.isEmpty)
}

@Test func namedAnteAccountsSuppressClaudeCodeWithoutTouchingKeychain() {
    let home = Home(); defer { home.remove() }
    home.write(AnteClaudeQuotaSource.executablePath, "#!/bin/sh\nexit 1\n", executable: true)
    home.write(AnteClaudeQuotaSource.directory + "/personal.json", "{}")
    home.write(ClaudeQuotaSource.claudeFile, validFile)
    let keychain = FakeKeychain(info: .init(modified: Date()))
    let claude = source(keychain)
    let selection = QuotaSources.select(home: home.url, from: [claude])
    #expect(selection.claudeCodeHidden)
    #expect(!selection.sources.contains { $0 is ClaudeQuotaSource })
    #expect(selection.sources.compactMap { ($0 as? AnteClaudeQuotaSource)?.account } == ["personal"])
    let detected = QuotaSources.detect(home: home.url, from: [claude])
    #expect(detected == .init(names: ["Claude (Ante: personal)"], claudeCodeHidden: true))
    #expect(keychain.calls == 0)
}

// MARK: - Credential order and copy

@Test func expiredFileFallsBackToKeychain() async throws {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, expiredFile)
    let keychain = FakeKeychain(info: .init(modified: Date()), secret: .found(keychainRecord))
    let creds = try ClaudeQuotaSource.readCredentials(home: home.url, keychain: keychain)
    #expect(creds.accessToken == "kc-token" && creds.origin == .keychain)

    let http = FakeHTTP()
    let reading = await source(keychain, http: http).fetch(home: home.url)
    #expect(reading.error == nil && reading.plan == "Pro")
    #expect(http.requests.first?.1["Authorization"] == "Bearer kc-token")
}

@Test func validFileWinsWithoutReadingKeychain() throws {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, validFile)
    let keychain = FakeKeychain(info: .init(modified: Date()), secret: .found(keychainRecord))
    let creds = try ClaudeQuotaSource.readCredentials(home: home.url, keychain: keychain)
    #expect(creds.accessToken == "file-new" && creds.origin == .claudeFile)
    #expect(keychain.calls == 0)
}

@Test func errorCopyNamesTheRightFix() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.anteFile, #"{"access_token":"a","expires_at":"2000-01-01T00:00:00Z"}"#)
    #expect(await source(FakeKeychain()).fetch(home: home.url).error
        == "Claude sign-in expired — run `ante` to sign in again.")

    let prompt = await source(FakeKeychain(info: .init(modified: nil), secret: .needsPrompt)).fetch(home: home.url)
    #expect(prompt.error
        == "Claude Code's Keychain sign-in can't be read without a prompt. Run `claude` once, or turn off Keychain use in Settings.")

    let expiredKeychain = Data(#"{"claudeAiOauth":{"accessToken":"k","expiresAt":1000}}"#.utf8)
    let stale = await source(FakeKeychain(info: .init(modified: nil), secret: .found(expiredKeychain))).fetch(home: home.url)
    #expect(stale.error == "Claude sign-in expired — run `claude` to sign in again.")

    let empty = Home(); defer { empty.remove() }
    #expect(await source(FakeKeychain()).fetch(home: empty.url).error == "No Claude sign-in found — run `claude` to sign in.")
}

@Test func http401NamesTheSignInsOwnCommand() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.anteFile, #"{"access_token":"a","expires_at":"2099-01-01T00:00:00Z"}"#)
    let reading = await source(FakeKeychain(), http: FakeHTTP { _ in (401, "{}") }).fetch(home: home.url)
    #expect(reading.error == "Claude sign-in expired — run `ante` to sign in again.")
}

// MARK: - Freshness

@Test func fileChangeAfterFailureRetriesAndSaysRefreshing() async {
    let home = Home(); defer { home.remove() }
    let then = Date(timeIntervalSince1970: 1_700_000_000)
    home.write(ClaudeQuotaSource.claudeFile, expiredFile, modified: then)
    let http = FakeHTTP()
    let claude = source(FakeKeychain(), allowed: false, http: http)

    let failed = await claude.fetch(home: home.url)
    #expect(failed.error == "Claude sign-in expired — run `claude` to sign in again.")
    #expect(!claude.noteSignInChange(home: home.url), "nothing changed yet")
    // Still gated: a second fetch replays the cause without a request.
    #expect(await claude.fetch(home: home.url).error?.hasPrefix("Claude sign-in expired") == true)
    #expect(http.requests.isEmpty)

    home.write(ClaudeQuotaSource.claudeFile, validFile, modified: then.addingTimeInterval(60))
    #expect(claude.noteSignInChange(home: home.url))
    #expect(!claude.noteSignInChange(home: home.url), "reported once per change")
    let marked = QuotaSources.markClaudeSignInChanged([failed])
    #expect(marked.first?.error == "Claude Code sign-in changed — refreshing")

    let retried = await claude.fetch(home: home.url)
    #expect(retried.error == nil && retried.windows.map(\.label) == ["5h"])
    #expect(http.requests.count == 1)
}

@Test func keychainChangeAfterFailureIsNoticedWithoutReadingTheSecret() async {
    let home = Home(); defer { home.remove() }
    let keychain = FakeKeychain(info: .init(modified: Date(timeIntervalSince1970: 1)), secret: .needsPrompt)
    let claude = source(keychain)
    #expect(await claude.fetch(home: home.url).error?.contains("can't be read without a prompt") == true)
    #expect(!claude.noteSignInChange(home: home.url))
    keychain.info = .init(modified: Date(timeIntervalSince1970: 2))
    #expect(claude.noteSignInChange(home: home.url))
}

@Test func markingOnlyTouchesTheFailedClaudeCodeReading() {
    var claudeCode = QuotaReading(provider: .claude); claudeCode.error = "old"
    var ante = QuotaReading(provider: .claude); ante.account = "work"; ante.error = "old"
    let healthy = QuotaReading(provider: .codex)
    let marked = QuotaSources.markClaudeSignInChanged([claudeCode, ante, healthy])
    #expect(marked.map(\.error) == [ClaudeQuotaSource.signInChangedMessage, "old", nil])
}

// MARK: - Request

@Test func usageRequestAsksForModelWindows() async throws {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, validFile)
    let runs = Count()
    let http = FakeHTTP()
    let claude = ClaudeQuotaSource(keychain: FakeKeychain(), keychainAllowed: { false }, http: http.get,
                                   cliVersion: ClaudeCLIVersion(
                                       runner: { _, _, _ in runs.bump(); return .exited(status: 0, output: Data("9.9.9 (Claude Code)".utf8)) },
                                       candidates: { [$0.appendingPathComponent("bin/claude")] }))
    home.write("bin/claude", "#!/bin/sh\nexit 1\n", executable: true)
    _ = await claude.fetch(home: home.url)
    _ = await claude.fetch(home: home.url)
    let (url, headers) = try #require(http.requests.first)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "api.anthropic.com" && components.path == "/api/oauth/usage")
    #expect(components.queryItems == [URLQueryItem(name: "cedar_ember", value: "1")])
    #expect(headers["User-Agent"] == "claude-cli/9.9.9 (external, cli)")
    #expect(runs.value == 1, "version probed once per launch")
}

@Test func badRequestRetriesWithoutTheQuery() async {
    let home = Home(); defer { home.remove() }
    home.write(ClaudeQuotaSource.claudeFile, validFile)
    let http = FakeHTTP { url in url.query == nil ? (200, #"{"seven_day":{"utilization":5}}"#) : (400, "{}") }
    let reading = await source(FakeKeychain(), allowed: false, http: http).fetch(home: home.url)
    #expect(http.requests.map { $0.0.query } == ["cedar_ember=1", nil])
    #expect(reading.windows.map(\.label) == ["Week"])
}

// MARK: - Version probe

@Test func versionProbeTimesOutToTheFallbackQuickly() throws {
    let home = Home(); defer { home.remove() }
    home.write("bin/claude", "#!/bin/sh\nsleep 10\n", executable: true)
    let probe = ClaudeCLIVersion(limits: .init(timeout: 0.3, killGrace: 0.2, outputLimit: 4096),
                                 candidates: { [$0.appendingPathComponent("bin/claude")] })
    let start = Date()
    #expect(probe.version(home: home.url) == ClaudeCLIVersion.fallback)
    #expect(Date().timeIntervalSince(start) < 3)
    // Cached for the launch: no second run.
    let again = Date()
    #expect(probe.version(home: home.url) == ClaudeCLIVersion.fallback)
    #expect(Date().timeIntervalSince(again) < 0.1)
}

@Test func versionProbeSkipsMissingPathsAndRejectsOddOutput() {
    let runs = Count()
    let missing = ClaudeCLIVersion(runner: { _, _, _ in runs.bump(); return .timedOut },
                                   candidates: { _ in [URL(fileURLWithPath: "/nonexistent/claude-\(UUID().uuidString)")] })
    #expect(missing.version(home: URL(fileURLWithPath: "/nonexistent")) == ClaudeCLIVersion.fallback)
    #expect(runs.value == 0)
    #expect(ClaudeCLIVersion.parse(Data("2.1.280 (Claude Code)\n".utf8)) == "2.1.280")
    #expect(ClaudeCLIVersion.parse(Data("evil\r\nX-Header: 1".utf8)) == nil)
    #expect(ClaudeCLIVersion.parse(Data()) == nil)
}

// MARK: - Keychain query shape (fake SecItemCopyMatching)

@Test func keychainQueriesNeverAllowUI() {
    let queries = QueryLog()
    let keychain = SystemClaudeKeychain { query, result in
        queries.add(query as NSDictionary)
        let dict = query as NSDictionary
        if dict[kSecReturnAttributes] as? Bool == true {
            result?.pointee = [kSecAttrModificationDate as String: Date(timeIntervalSince1970: 5)] as CFDictionary
            return errSecSuccess
        }
        return errSecInteractionNotAllowed
    }
    #expect(keychain.itemInfo() == KeychainItemInfo(modified: Date(timeIntervalSince1970: 5)))
    #expect(keychain.readSecret() == .needsPrompt)
    let logged = queries.all
    #expect(logged.count == 2)
    for query in logged {
        #expect(query[kSecAttrService] as? String == "Claude Code-credentials")
        #expect(query[kSecUseAuthenticationUI] as? String == kSecUseAuthenticationUIFail as String)
        #if canImport(LocalAuthentication)
        #expect((query[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed == true)
        #endif
    }
    #expect(logged[0][kSecReturnData] == nil, "existence check never asks for the secret")
    #expect(logged[1][kSecReturnData] as? Bool == true)
}

@Test func keychainStatusMapping() {
    func secret(_ status: OSStatus) -> KeychainSecret { SystemClaudeKeychain { _, _ in status }.readSecret() }
    #expect(secret(errSecItemNotFound) == .missing)
    #expect(secret(errSecAuthFailed) == .needsPrompt)
    #expect(secret(errSecUserCanceled) == .needsPrompt)
    #expect(secret(errSecParam) == .failed(errSecParam))
    #expect(SystemClaudeKeychain { _, _ in errSecItemNotFound }.itemInfo() == nil)
}

private final class QueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [NSDictionary] = []
    var all: [NSDictionary] { lock.lock(); defer { lock.unlock() }; return queries }
    func add(_ query: NSDictionary) { lock.lock(); queries.append(query); lock.unlock() }
}

// MARK: - Per-model windows (fixtures)

private func decode(_ json: String) throws -> QuotaReading {
    let response = try JSONDecoder().decode(ClaudeQuotaSource.Response.self, from: Data(json.utf8))
    return ClaudeQuotaSource.map(response, credentials: .init(accessToken: "x", scopes: [], subscriptionType: "max", expiresAt: nil))
}

@Test func usageWithoutModelFieldsKeepsFiveHourAndWeek() throws {
    let reading = try decode("""
    {"five_hour": {"utilization": 31, "resets_at": "2026-11-24T20:30:00+00:00"},
     "seven_day": {"utilization": 12.5, "resets_at": "2026-11-28T00:00:00Z"},
     "seven_day_opus": null, "unknown_field": {"nested": [1, 2]}}
    """)
    #expect(reading.windows.map(\.label) == ["5h", "Week"])
    #expect(reading.windows[1].usedFraction == 0.125)
    #expect(reading.windows.allSatisfy { $0.resetsAt != nil && $0.detail == nil })
}

@Test func usageWithModelWindowsOrdersThemAfterWeek() throws {
    let reading = try decode("""
    {"five_hour": {"utilization": 31},
     "seven_day": {"utilization": 40, "resets_at": "2026-11-28T00:00:00Z"},
     "seven_day_opus": {"utilization": 80, "resets_at": "2026-11-27T00:00:00Z"},
     "seven_day_sonnet": {"utilization": 22, "resets_at": "2026-11-27T00:00:00Z"},
     "limits": [
       {"weekly_scoped": {"model": "claude-haiku-4-5", "utilization": 5, "resets_at": "2026-11-27T00:00:00Z"}},
       {"type": "weekly_scoped", "scope": "All models", "utilization": 41},
       {"weekly_scoped": [{"display_name": "Sonnet", "utilization": 99}, {"name": "Experimental-Long-Name", "used_percent": "7"}]},
       {"something_else": true}, "garbage", 3]}
    """)
    #expect(reading.windows.map(\.label) == ["5h", "Week", "Sonnet", "Opus", "Haiku", "Experim"])
    #expect(reading.windows[1].usedFraction == 0.40, "seven_day wins over the generic scope")
    #expect(reading.windows[2].usedFraction == 0.22, "seven_day_sonnet wins over a scoped Sonnet")
    #expect(reading.windows[3].detail == "Weekly limit for Opus models")
    #expect(reading.windows[5].usedFraction == 0.07)
    #expect(reading.windows.allSatisfy { $0.label.count <= 7 })
}

@Test func genericScopeFillsMissingWeek() throws {
    let reading = try decode("""
    {"five_hour": {"utilization": "bad"},
     "limits": [{"kind": "weekly_scoped", "scope": {"name": "all_models"}, "utilization": 64, "resets_at": 1795000000},
                {"weekly_scoped": {"scope_name": "fable", "utilization": 12}}]}
    """)
    #expect(reading.windows.map(\.label) == ["Week", "Fable"])
    #expect(reading.windows[0].usedFraction == 0.64 && reading.windows[0].resetsAt != nil)
}

@Test func scopeLabelsFitTheColumn() {
    #expect(ClaudeQuotaSource.scope("claude-opus-4-1") == .model("Opus"))
    #expect(ClaudeQuotaSource.scope("Sonnet 4.5") == .model("Sonnet"))
    #expect(ClaudeQuotaSource.scope("All models") == .generic)
    #expect(ClaudeQuotaSource.scope("claude") == nil)
    #expect(ClaudeQuotaSource.scope("research_preview") == .model("Researc"))
}
