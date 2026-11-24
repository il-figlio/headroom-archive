import Foundation
import Testing
@testable import HeadroomCore

/// Fake `ante` scripts in throwaway homes; the real CLI and real
/// credentials are never touched.
private struct FakeHome {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ante-check-\(UUID().uuidString)")
    var counter: URL { url.appendingPathComponent("invocations") }

    func write(_ relative: String, _ contents: String, executable: Bool = false) {
        let file = url.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: file, atomically: true, encoding: .utf8)
        if executable { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
    }

    func account(_ name: String) { write(AnteClaudeQuotaSource.directory + "/\(name).json", "{}") }

    /// Every script counts its invocations before doing `body`.
    func ante(_ body: String) {
        write(AnteClaudeQuotaSource.executablePath, "#!/bin/sh\necho x >> '\(counter.path)'\n\(body)\n", executable: true)
    }

    var invocations: Int {
        ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private let okScript = #"""
printf '{"subscriptions":[{"credential":"%s","provider":"anthropic","status":"ready","plan":"Max","windows":[{"label":"Current session","used_percent":25,"resets_at":"2026-11-24T10:30:00Z"},{"label":"Weekly limit","used_percent":61},{"label":"Fable","used_percent":42}]}]}' "$2"
"""#
private let failScript = "exit 1"
private let fast = BoundedProcess.Limits(timeout: 0.5, killGrace: 0.3)

private func fetch(_ home: FakeHome, _ poller: AntePoller) async -> [QuotaReading] {
    await QuotaFetcher.fetchAll(sources: AnteClaudeQuotaSource.sources(home: home.url, poller: poller), home: home.url)
}

@Test func anteTwoAccountsMapWindows() async {
    let home = FakeHome(); defer { home.remove() }
    home.account("personal"); home.account("work"); home.ante(okScript)
    let readings = await fetch(home, AntePoller())
    #expect(readings.map(\.id) == ["claude/personal", "claude/work"])
    #expect(readings.allSatisfy { $0.windows.map(\.label) == ["5h", "Week", "Fable"] && $0.plan == "Max" && $0.error == nil })
    #expect(readings.first?.windows.first?.usedFraction == 0.25)
    #expect(readings.first?.windows.first?.resetsAt != nil)
    #expect(readings.first?.windows[1].resetsAt == nil)
}

@Test func anteLaunchFailureMergedWithCacheKeepsWindowsAndFetchTime() async {
    let home = FakeHome(); defer { home.remove() }
    home.account("personal"); home.ante(failScript)
    var cached = QuotaReading(provider: .claude)
    cached.account = "personal"; cached.plan = "Max"
    cached.windows = [QuotaWindow(label: "5h", usedFraction: 0.3)]
    cached.fetchedAt = Date(timeIntervalSince1970: 1_000_000)

    let fresh = await fetch(home, AntePoller())
    #expect(fresh.count == 1 && fresh[0].windows.isEmpty && fresh[0].error == "Ante could not read Claude usage")
    let merged = QuotaMerge.merge(previous: [cached], fresh: fresh)
    #expect(merged.count == 1)
    #expect(merged[0].windows == cached.windows && merged[0].plan == "Max")
    #expect(merged[0].fetchedAt == cached.fetchedAt)
    #expect(merged[0].error == "Ante could not read Claude usage")
}

@Test func anteFailureIsNotCachedAndLastGoodKeepsItsFetchTime() async throws {
    let home = FakeHome(); defer { home.remove() }
    home.account("personal"); home.ante(failScript)
    let poller = AntePoller(reuseFloor: 0.05, limits: .init(timeout: 5))
    #expect(await fetch(home, poller).first?.error != nil)

    home.ante(okScript)  // CLI fixed: the very next fetch must see it.
    let good = try #require(await fetch(home, poller).first)
    #expect(good.error == nil && good.windows.count == 3)

    try await Task.sleep(nanoseconds: 100_000_000)
    home.ante(failScript)
    let replayed = try #require(await fetch(home, poller).first)
    #expect(replayed.error == "Ante could not read Claude usage")
    #expect(replayed.windows == good.windows && replayed.fetchedAt == good.fetchedAt)
    #expect(home.invocations == 3)
}

@Test func anteSuccessIsReusedWithinTheFloor() async {
    let home = FakeHome(); defer { home.remove() }
    home.account("personal"); home.ante(okScript)
    let poller = AntePoller(reuseFloor: 60, limits: .init(timeout: 5))
    let first = await fetch(home, poller)
    let second = await fetch(home, poller)
    #expect(home.invocations == 1)
    #expect(first.first?.fetchedAt == second.first?.fetchedAt)
}

@Test func anteConcurrentFetchesShareOneRun() async {
    let home = FakeHome(); defer { home.remove() }
    home.account("personal"); home.ante("sleep 0.3\n" + okScript)
    let poller = AntePoller(reuseFloor: 0, limits: .init(timeout: 5))
    let source = AnteClaudeQuotaSource.sources(home: home.url, poller: poller)[0]
    let readings = await withTaskGroup(of: QuotaReading.self) { group in
        for _ in 0..<6 { group.addTask { await source.fetch(home: home.url) } }
        return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(home.invocations == 1)
    #expect(readings.count == 6 && readings.allSatisfy { $0.error == nil && $0.windows.count == 3 })
}

@Test func anteNullAndMalformedEntriesAreSkipped() async {
    let home = FakeHome(); defer { home.remove() }
    home.account("personal")
    home.ante(#"""
    printf '{"subscriptions":[42,{"credential":7},{"credential":"anthropic/other","provider":"anthropic","status":"ready","windows":[]},{"credential":"%s","provider":"anthropic","status":"ready","plan":"Max","windows":[{"label":"Current session","used_percent":25},{"label":"Fable","used_percent":null},{"label":"Weekly limit"},"junk",{"used_percent":5}]}]}' "$2"
    """#)
    let reading = await fetch(home, AntePoller()).first
    #expect(reading?.error == nil)
    #expect(reading?.windows.map(\.label) == ["5h"])
    #expect(reading?.plan == "Max")
}

@Test func anteAllWindowsUnusableIsAnError() {
    var reading = QuotaReading(provider: .claude)
    let json = #"{"subscriptions":[{"credential":"anthropic/a","provider":"anthropic","status":"ready","windows":[{"label":"Fable","used_percent":null}]}]}"#
    AnteClaudeQuotaSource.apply(Data(json.utf8), credential: "anthropic/a", to: &reading)
    #expect(reading.windows.isEmpty && reading.error == "Ante returned no usage for this Claude sign-in")
}

@Test func anteStatusNotReady() async {
    let home = FakeHome(); defer { home.remove() }
    home.account("personal")
    home.ante(#"printf '{"subscriptions":[{"credential":"%s","provider":"anthropic","status":"reauth_required"}]}' "$2""#)
    let reading = await fetch(home, AntePoller()).first
    #expect(reading?.windows.isEmpty == true)
    #expect(reading?.error == "Claude usage is unavailable in Ante. Check `ante usage anthropic/personal`.")
}

private struct InstantSource: QuotaSource {
    let provider: AgentKind = .codex
    let credentialPaths: [String] = []
    func fetch(home: URL) async -> QuotaReading { QuotaReading(provider: .codex) }
}

@Test func anteIgnoringSIGTERMIsKilledAndDoesNotBlockOtherSources() async {
    let home = FakeHome(); defer { home.remove() }
    home.account("personal")
    // The orphaned `sleep` keeps the pipe open after the shell is killed.
    home.ante("trap '' TERM\nsleep 5 &\nwait\nwait")
    let poller = AntePoller(limits: fast)
    let started = Date()
    let sources: [any QuotaSource] = [InstantSource()] + AnteClaudeQuotaSource.sources(home: home.url, poller: poller)
    let readings = await QuotaFetcher.fetchAll(sources: sources, home: home.url)
    let ended = Date()
    let elapsed = ended.timeIntervalSince(started)
    #expect(elapsed < 0.5 + 0.3 + 1.5, "took \(elapsed)s")
    #expect(readings.map(\.id) == ["codex", "claude/personal"])
    // Relative, not absolute: slow CI runners take a while to start the task
    // group, but the quick source must still finish long before the hung one
    // is killed (timeout 0.5 s + grace 0.3 s).
    #expect(ended.timeIntervalSince(readings[0].fetchedAt) > 0.4,
            "quick source finished \(ended.timeIntervalSince(readings[0].fetchedAt))s before the hung one")
    #expect(readings[1].error == "Ante timed out reading Claude usage")
}

@Test func anteOutputIsBounded() async {
    let home = FakeHome(); defer { home.remove() }
    home.account("personal"); home.ante("head -c 200000 /dev/zero")
    let poller = AntePoller(limits: .init(timeout: 5, killGrace: 0.3, outputLimit: 1000))
    #expect(await fetch(home, poller).first?.error == "Ante returned too much output for Claude usage")
}

@Test func anteDiscoveryOnlyRegularVisibleJSON() throws {
    let home = FakeHome(); defer { home.remove() }
    let dir = AnteClaudeQuotaSource.directory
    #expect(AnteClaudeQuotaSource.sources(home: home.url).isEmpty)
    home.account("personal"); home.account("Work Account")
    home.write(dir + "/.hidden.json", "{}")
    home.write(dir + "/notes.txt", "")
    home.write(dir + "/backup.json.bak", "")
    try FileManager.default.createDirectory(at: home.url.appendingPathComponent(dir + "/folder.json"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: home.url.appendingPathComponent(dir + "/link.json"),
                                               withDestinationURL: home.url.appendingPathComponent(dir + "/personal.json"))
    #expect(AnteClaudeQuotaSource.sources(home: home.url).isEmpty, "no executable, no sources")
    home.ante(okScript)
    #expect(AnteClaudeQuotaSource.sources(home: home.url).map(\.account) == ["Work Account", "personal"])
    #expect(QuotaSources.credentialed(home: home.url).map(\.provider) == [.claude, .claude])
}
