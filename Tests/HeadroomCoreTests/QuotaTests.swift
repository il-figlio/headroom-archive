import XCTest
import Security
@testable import HeadroomCore

final class QuotaTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("quota-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ relative: String, _ contents: String) {
        let url = home.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Credential reading

    func testCodexCredentialsFromOAuthTokens() throws {
        write(".codex/auth.json", """
        {"OPENAI_API_KEY": null, "auth_mode": "chatgpt", "last_refresh": "2026-10-14T00:00:00Z",
         "tokens": {"access_token": "at-abc", "refresh_token": "rt", "id_token": "it",
                    "account_id": "acct-123"}}
        """)
        let creds = try CodexQuotaSource.readCredentials(home: home)
        XCTAssertEqual(creds.accessToken, "at-abc")
        XCTAssertEqual(creds.accountID, "acct-123")
        XCTAssertFalse(creds.apiKeyOnly)
    }

    func testCodexCredentialsAPIKeyOnly() throws {
        write(".codex/auth.json", #"{"OPENAI_API_KEY": "sk-abc"}"#)
        let creds = try CodexQuotaSource.readCredentials(home: home)
        XCTAssertTrue(creds.apiKeyOnly)
    }

    func testCodexCredentialsMissing() {
        XCTAssertThrowsError(try CodexQuotaSource.readCredentials(home: home))
    }

    func testCodexAccountIDFromJWT() throws {
        // Payload: {"https://api.openai.com/auth": {"chatgpt_account_id": "acct-jwt"}}
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-jwt"}}"#.utf8)
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "header.\(b64).sig"
        write(".codex/auth.json", """
        {"tokens": {"access_token": "at", "id_token": "\(jwt)"}}
        """)
        let creds = try CodexQuotaSource.readCredentials(home: home)
        XCTAssertEqual(creds.accountID, "acct-jwt")
    }

    func testClaudeCredentials() throws {
        write(".claude/.credentials.json", """
        {"claudeAiOauth": {"accessToken": "sk-ant-oat-x", "refreshToken": "rt",
         "expiresAt": 1893456000000, "scopes": ["user:profile", "user:inference"],
         "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"}}
        """)
        let creds = try ClaudeQuotaSource.readCredentials(home: home)
        XCTAssertEqual(creds.accessToken, "sk-ant-oat-x")
        XCTAssertEqual(creds.subscriptionType, "max")
        XCTAssertEqual(creds.scopes, ["user:profile", "user:inference"])
        XCTAssertNotNil(creds.expiresAt)
    }

    func testClaudeCredentialsMissing() {
        // No Keychain passed: the real login Keychain is never consulted.
        XCTAssertThrowsError(try ClaudeQuotaSource.readCredentials(home: home))
    }

    func testAnteOAuthFileNeedsNoKeychain() throws {
        write(".ante/auth/credentials/oauth/anthropic.json", #"{"access_token":"ante-token","refresh_token":"owned-by-ante","expires_at":"2099-01-01T00:00:00Z","scopes":["user:profile"]}"#)
        let creds = try ClaudeQuotaSource.readCredentials(home: home)
        XCTAssertEqual(creds.accessToken, "ante-token")
        XCTAssertNotNil(creds.expiresAt)
        XCTAssertEqual(QuotaSources.credentialed(home: home).map(\.provider), [.claude])
    }

    func testValidAnteCredentialsReplaceExpiredClaudeFile() throws {
        write(".claude/.credentials.json", #"{"claudeAiOauth":{"accessToken":"old","expiresAt":1}}"#)
        write(".ante/auth/credentials/oauth/anthropic.json", #"{"access_token":"fresh","expires_at":"2099-01-01T00:00:00.123456Z"}"#)
        let creds = try ClaudeQuotaSource.readCredentials(home: home)
        XCTAssertEqual(creds.accessToken, "fresh")
        XCTAssertNotNil(creds.expiresAt)
    }

    func testAnteCredentialsWithInvalidExpiryAreRejected() {
        write(".ante/auth/credentials/oauth/anthropic.json", #"{"access_token":"token","expires_at":"not-a-date"}"#)
        XCTAssertThrowsError(try ClaudeQuotaSource.readCredentials(home: home))
    }

    func testExpiredAnteCredentialsRemainUnchanged() async throws {
        let record = #"{"access_token":"expired","refresh_token":"owned-by-ante","expires_at":"2000-01-01T00:00:00Z"}"#
        write(".ante/auth/credentials/oauth/anthropic.json", record)
        let reading = await ClaudeQuotaSource().fetch(home: home)
        XCTAssertTrue(reading.error?.contains("sign-in expired") == true)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".ante/auth/credentials/oauth/anthropic.json")), record)
    }

    func testClaudeKeychainConsentIsNotInteractive() {
        let attempts = Counter()
        let keychain = SystemClaudeKeychain { query, _ in
            attempts.increment()
            let attributes = query as NSDictionary
            XCTAssertEqual(attributes[kSecUseAuthenticationUI] as? String, kSecUseAuthenticationUIFail as String)
            return errSecInteractionNotAllowed
        }
        XCTAssertEqual(keychain.readSecret(), .needsPrompt)
        XCTAssertEqual(attempts.value, 1)
    }

    func testClaudeExpiredCredentialsRemainUnchanged() async throws {
        let record = #"{"claudeAiOauth":{"accessToken":"expired","refreshToken":"must-not-rotate","expiresAt":1}}"#
        write(".claude/.credentials.json", record)
        let reading = await ClaudeQuotaSource().fetch(home: home)
        XCTAssertTrue(reading.error?.contains("sign-in expired") == true)
        let stored = try String(contentsOf: home.appendingPathComponent(".claude/.credentials.json"))
        XCTAssertEqual(stored, record)
    }

    // MARK: - Response mapping

    func testCodexUsageMapping() throws {
        let json = """
        {"account_id": "acct-1", "plan_type": "pro",
         "rate_limit": {
           "primary_window":   {"used_percent": 42, "reset_at": 1760400000, "limit_window_seconds": 18000},
           "secondary_window": {"used_percent": 7,  "reset_at": 1761000000, "limit_window_seconds": 604800}},
         "credits": {"has_credits": true, "unlimited": false, "balance": 150.0},
         "additional_rate_limits": [
           {"limit_name": "GPT-5-Spark", "metered_feature": "codex_spark",
            "rate_limit": {"primary_window": {"used_percent": 3, "reset_at": 1760400000,
                                             "limit_window_seconds": 18000}}}]}
        """
        let response = try JSONDecoder().decode(CodexQuotaSource.Response.self, from: Data(json.utf8))
        let reading = CodexQuotaSource.map(response)
        XCTAssertEqual(reading.provider, .codex)
        XCTAssertEqual(reading.plan, "Pro")
        XCTAssertEqual(reading.windows.count, 3)
        XCTAssertEqual(reading.windows[0].label, "5h")
        XCTAssertEqual(reading.windows[0].usedFraction, 0.42, accuracy: 0.001)
        XCTAssertEqual(reading.windows[1].label, "Week")
        XCTAssertEqual(reading.windows[2].label, "GPT-5-Spark · 5h")
        XCTAssertEqual(reading.balance, "150 credits")
        XCTAssertNotNil(reading.windows[0].resetsAt)
    }

    func testCodexUnlimitedCredits() throws {
        let json = """
        {"plan_type": "team", "credits": {"has_credits": true, "unlimited": true}}
        """
        let response = try JSONDecoder().decode(CodexQuotaSource.Response.self, from: Data(json.utf8))
        let reading = CodexQuotaSource.map(response)
        XCTAssertEqual(reading.balance, "unlimited credits")
        XCTAssertTrue(reading.windows.isEmpty)
    }

    func testClaudeUsageMapping() throws {
        let json = """
        {"five_hour": {"utilization": 55.4, "resets_at": "2026-10-14T20:30:00+00:00"},
         "seven_day": {"utilization": 12.0, "resets_at": "2026-10-20T00:00:00+00:00"},
         "seven_day_opus": {"utilization": 80.0, "resets_at": "2026-10-18T00:00:00+00:00"},
         "extra_usage": {"is_enabled": true, "monthly_limit": 600, "used_credits": 43443,
                         "utilization": 72, "currency": "USD"}}
        """
        let response = try JSONDecoder().decode(ClaudeQuotaSource.Response.self, from: Data(json.utf8))
        let creds = ClaudeQuotaSource.Credentials(accessToken: "x", scopes: [], subscriptionType: "max", expiresAt: nil)
        let reading = ClaudeQuotaSource.map(response, credentials: creds)
        XCTAssertEqual(reading.provider, .claude)
        XCTAssertEqual(reading.plan, "Max")
        XCTAssertEqual(reading.windows.count, 3)
        XCTAssertEqual(reading.windows[0].label, "5h")
        XCTAssertEqual(reading.windows[0].usedFraction, 0.554, accuracy: 0.001)
        XCTAssertNotNil(reading.windows[0].resetsAt)
        XCTAssertEqual(reading.windows[2].label, "Opus")
        XCTAssertEqual(reading.balance, "$434.43 of $600 extra usage")
    }

    func testClaudeUsageMinimal() throws {
        let json = #"{"five_hour": {"utilization": 0, "resets_at": "2026-10-14T20:00:00Z"}}"#
        let response = try JSONDecoder().decode(ClaudeQuotaSource.Response.self, from: Data(json.utf8))
        let reading = ClaudeQuotaSource.map(response, credentials: .init(accessToken: "x", scopes: [], subscriptionType: nil, expiresAt: nil))
        XCTAssertEqual(reading.windows.count, 1)
        XCTAssertNil(reading.plan)
        XCTAssertNil(reading.balance)
    }

    // MARK: - Source gating

    func testCredentialedSourcesFollowDisk() {
        XCTAssertTrue(QuotaSources.credentialed(home: home).isEmpty)
        write(".codex/auth.json", #"{"tokens":{"access_token":"at","refresh_token":"rt"}}"#)
        XCTAssertEqual(QuotaSources.credentialed(home: home).count, 1)
        write(".claude/.credentials.json", #"{"claudeAiOauth":{"accessToken":"at"}}"#)
        XCTAssertEqual(QuotaSources.credentialed(home: home).count, 2)
    }

    func testNamedAnteClaudeAccountsUseTheCLIButKeepCodex() async throws {
        write(".codex/auth.json", "{}")
        write(".claude/.credentials.json", "{}")
        write(".ante/auth/credentials/oauth/anthropic/personal.json", "{}")
        write(".ante/auth/credentials/oauth/anthropic/work.json", "{}")
        write(".ante/bin/ante", """
        #!/bin/sh
        [ "$1" = usage ] && [ "$3" = --json ] || exit 1
        printf '{"subscriptions":[{"credential":"%s","provider":"anthropic","status":"ready","plan":"Max","windows":[{"label":"Current session","used_percent":25,"resets_at":"2026-11-24T10:30:00Z"},{"label":"Fable","used_percent":42}]}]}' "$2"
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: home.appendingPathComponent(".ante/bin/ante").path)
        let sources = QuotaSources.credentialed(home: home)
        XCTAssertEqual(sources.map(\.provider), [.codex, .claude, .claude])

        let readings = await QuotaFetcher.fetchAll(sources: Array(sources.dropFirst()), home: home)
        XCTAssertEqual(readings.map(\.id), ["claude/personal", "claude/work"])
        XCTAssertEqual(readings.map { $0.windows.map(\.label) }, [["5h", "Fable"], ["5h", "Fable"]])
        XCTAssertEqual(readings.first?.windows.first?.usedFraction, 0.25)
        XCTAssertNotNil(readings.first?.windows.first?.resetsAt)
        XCTAssertTrue(readings.allSatisfy { $0.plan == "Max" && $0.error == nil })
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
