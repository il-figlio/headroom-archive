import XCTest
@testable import HeadroomCore

/// Points a real provider's parser at fixture files the test owns.
private final class FixtureProvider: AgentProvider, ModelTokenTracking {
    let kind: AgentKind
    var files: [URL]
    let wrapped: AgentProvider
    init(kind: AgentKind, files: [URL], wrapped: AgentProvider) {
        self.kind = kind; self.files = files; self.wrapped = wrapped
    }
    var roots: [String] { [] }
    func sessionFiles() -> [URL] { files }
    func parse(line: Data, into session: inout AgentSession, event: inout AgentLineEvent) -> Bool {
        wrapped.parse(line: line, into: &session, event: &event)
    }
    func takeModelTokens(file: String) -> [String: TokenUsage] {
        (wrapped as? ModelTokenTracking)?.takeModelTokens(file: file) ?? [:]
    }
}

final class AgentTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func line(_ json: String) -> Data { Data(json.utf8) }
    func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-agent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func write(_ name: String, _ lines: [String], in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func claudeAssistant(id: String = "s1", model: String = "claude-opus-4-6", input: Int = 10, output: Int = 5,
                         cacheRead: Int = 3, cacheWrite: Int = 2, tools: [String] = [],
                         sidechain: Bool = false, at date: Date) -> String {
        let toolBlocks = tools.map { #"{"type":"tool_use","name":"\#($0)"}"# }.joined(separator: ",")
        return #"{"type":"assistant","sessionId":"\#(id)","cwd":"/tmp/proj","isSidechain":\#(sidechain),"timestamp":"\#(iso(date))","message":{"model":"\#(model)","role":"assistant","content":[\#(toolBlocks)],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheWrite)}}}"#
    }

    func testClaudeParseAccumulatesUsageAndSkipsSidechainTools() {
        let provider = ClaudeCodeProvider()
        var session = AgentSession(kind: .claude, sessionId: "s1", projectDir: "", filePath: "/tmp/x/s1.jsonl")
        XCTAssertTrue(provider.parse(line: line(#"{"type":"user","sessionId":"s1","cwd":"/tmp/proj","timestamp":"\#(iso(now))"}"#), into: &session))
        _ = provider.parse(line: line(claudeAssistant(tools: ["Bash", "mcp__fs__read"], at: now)), into: &session)
        _ = provider.parse(line: line(claudeAssistant(input: 4, output: 2, cacheRead: 0, cacheWrite: 0, tools: ["Bash"], sidechain: true, at: now)), into: &session)
        XCTAssertEqual(session.projectDir, "/tmp/proj")
        XCTAssertEqual(session.tokens.input, 14)
        XCTAssertEqual(session.tokens.output, 7)
        XCTAssertEqual(session.tokens.cacheRead, 3)
        XCTAssertEqual(session.tokens.cacheWrite, 2)
        XCTAssertEqual(session.tools, ["Bash": 1, "mcp__fs__read": 1])
        XCTAssertEqual(session.models, ["claude-opus-4-6"])
        XCTAssertEqual(session.lastEventAt, now)
        XCTAssertFalse(provider.parse(line: line("not json"), into: &session))
    }

    func testCodexRolloutParsesMetaToolsAndCumulativeUsage() {
        let provider = CodexProvider()
        var session = AgentSession(kind: .codex, sessionId: "", projectDir: "", filePath: "/tmp/x/rollout-2026-01-01T00-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl")
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/proj"}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"turn_context","payload":{"cwd":"/tmp/proj","model":"gpt-9-turbo"}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"response_item","payload":{"type":"local_shell_call"}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"token_usage_record","payload":{"usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":5,"reasoning_output_tokens":2}}}"#), into: &session)
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":12,"cached_input_tokens":5}}}}"#), into: &session)
        XCTAssertEqual(session.sessionId, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(session.projectDir, "/tmp/proj")
        XCTAssertEqual(session.models, ["gpt-9-turbo"])
        XCTAssertEqual(session.tools, ["exec_command": 1, "local_shell": 1])
        // Per-response delta and the cumulative counter agree; tokens stay 100/12, not doubled.
        XCTAssertEqual(session.tokens.input, 100)
        XCTAssertEqual(session.tokens.output, 12)
        XCTAssertEqual(session.tokens.cacheRead, 5)
        // A later delta resumes accumulating over the cumulative value.
        _ = provider.parse(line: line(#"{"timestamp":"\#(iso(now))","type":"token_usage_record","payload":{"usage":{"input_tokens":50,"output_tokens":4}}}"#), into: &session)
        XCTAssertEqual(session.tokens.input, 150)
        XCTAssertEqual(session.tokens.output, 16)
    }

    func testGenericFallbackAcceptsShapedLinesOnly() {
        let provider = GenericProvider()
        var session = AgentSession(kind: .other, sessionId: "g1", projectDir: "", filePath: "/tmp/x/g1.jsonl")
        XCTAssertTrue(provider.parse(line: line(#"{"type":"message","role":"assistant","timestamp":"\#(iso(now))","model":"m1","usage":{"prompt_tokens":7,"completion_tokens":3}}"#), into: &session))
        XCTAssertEqual(session.tokens.input, 7)
        XCTAssertEqual(session.tokens.output, 3)
        XCTAssertEqual(session.models, ["m1"])
        XCTAssertEqual(session.lastEventAt, now)
        XCTAssertFalse(provider.parse(line: line(#"{"type":"message"}"#), into: &session))
        XCTAssertFalse(provider.parse(line: line(#"{"timestamp":"\#(iso(now))"}"#), into: &session))
        XCTAssertFalse(provider.parse(line: line("hello"), into: &session))
    }

    func testToolTaxonomyAndPricing() {
        XCTAssertEqual(ToolTaxonomy.categorize("Bash"), .shell)
        XCTAssertEqual(ToolTaxonomy.categorize("mcp__github__list"), .mcp)
        XCTAssertEqual(ToolTaxonomy.categorize("send_message"), .message)
        XCTAssertNotNil(AgentPricing.rate(for: "claude-opus-4-6"))
        XCTAssertNotNil(AgentPricing.cost(TokenUsage(), model: "claude-sonnet-4-7"))
        XCTAssertNil(AgentPricing.rate(for: "gpt-9-turbo"))
        XCTAssertNil(AgentPricing.cost(TokenUsage(), model: "gpt-9-turbo"))
    }

    private func makeScanner(for provider: FixtureProvider, in dir: URL) -> AgentScanner {
        AgentScanner(providers: [provider], roots: [(kind: provider.kind, path: dir.path)])
    }

    func testHealthTransitions() throws {
        let dir = try directory()
        let fresh = try write("a.jsonl", [#"{"type":"user","sessionId":"a","cwd":"/tmp/p","timestamp":"\#(iso(now))"}"#,
                                          claudeAssistant(id: "a", at: now)], in: dir)
        let stale = try write("b.jsonl", [#"{"type":"user","sessionId":"b","cwd":"/tmp/q","timestamp":"\#(iso(now.addingTimeInterval(-3600)))"}"#], in: dir)
        let provider = FixtureProvider(kind: .claude, files: [fresh, stale], wrapped: ClaudeCodeProvider())
        let scanner = makeScanner(for: provider, in: dir)
        let alive = [AgentProcess(pid: 4242, args: "/usr/local/bin/claude")]

        var result = scanner.scan(now: now, processes: alive)
        let byID = Dictionary(result.snapshot.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        // Single candidate process: the fresh session gets it and goes live.
        XCTAssertEqual(byID["a"]?.health, .live)
        XCTAssertEqual(byID["a"]?.pid, 4242)
        XCTAssertEqual(byID["b"]?.health, .ended)

        // Args correlating to the stale session's project dir → pid, stale → stuck.
        let staleProvider = FixtureProvider(kind: .claude, files: [stale], wrapped: ClaudeCodeProvider())
        let correlated = [AgentProcess(pid: 4343, args: "claude --cwd /tmp/q")]
        result = makeScanner(for: staleProvider, in: dir).scan(now: now, processes: correlated)
        let staleSession = result.snapshot.sessions.first { $0.sessionId == "b" }
        XCTAssertEqual(staleSession?.pid, 4343)
        XCTAssertEqual(staleSession?.health, .stuck)

        // No process + growth between scans → zombie; no growth → ended.
        var result2 = scanner.scan(now: now, processes: [])
        let handle = try FileHandle(forWritingTo: fresh)
        try handle.seekToEnd()
        handle.write(Data((#"{"type":"user","sessionId":"a","timestamp":"\#(iso(now.addingTimeInterval(-1200)))"}"# + "\n").utf8))
        try handle.close()
        result2 = scanner.scan(now: now, previousSessions: result2.sessions, offsets: result2.offsets, processes: [])
        XCTAssertEqual(result2.snapshot.sessions.first { $0.sessionId == "a" }?.health, .zombie)
        XCTAssertEqual(result2.snapshot.sessions.first { $0.sessionId == "b" }?.health, .ended)
    }

    func testOffsetResumeReadsOnlyNewLines() throws {
        let dir = try directory()
        let file = try write("s.jsonl", [claudeAssistant(input: 10, output: 5, tools: ["Bash"], at: now)], in: dir)
        let provider = FixtureProvider(kind: .claude, files: [file], wrapped: ClaudeCodeProvider())
        let scanner = makeScanner(for: provider, in: dir)

        let first = scanner.scan(now: now, processes: [])
        XCTAssertEqual(first.snapshot.sessions.first?.tokens.input, 10)
        let size = Int64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        XCTAssertEqual(first.offsets[file.path], size)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data((claudeAssistant(input: 20, output: 8, tools: ["Read"], at: now) + "\n").utf8))
        try handle.close()

        let second = scanner.scan(now: now, previousSessions: first.sessions, offsets: first.offsets, processes: [])
        let session = try XCTUnwrap(second.snapshot.sessions.first)
        XCTAssertEqual(session.tokens.input, 30)
        XCTAssertEqual(session.tokens.output, 13)
        XCTAssertEqual(session.tools, ["Bash": 1, "Read": 1])
        XCTAssertEqual(second.offsets[file.path] ?? 0, size + Int64(claudeAssistant(input: 20, output: 8, tools: ["Read"], at: now).utf8.count + 1))
        // claude-opus-4-6 is priced, so cost accumulates and nothing is unpriced.
        XCTAssertEqual(session.unpricedTokens, 0)
        XCTAssertEqual((session.costUSD ?? 0) > 0, true)
    }

    func testScanUsageCountsEachLineOnce() throws {
        let dir = try directory()
        let file = try write("s.jsonl", [claudeAssistant(input: 10, output: 5, at: now)], in: dir)
        let provider = FixtureProvider(kind: .claude, files: [file], wrapped: ClaudeCodeProvider())
        let scanner = makeScanner(for: provider, in: dir)

        // 10 + 5 + 3 + 2 = 20 tokens; `now` is already hour-aligned.
        let first = scanner.scan(now: now, processes: [])
        XCTAssertEqual(first.usage.count, 1)
        XCTAssertEqual(first.usage.first?.hour, now)
        XCTAssertEqual(first.usage.first?.tokens[.claude], 20)
        // claude-opus-4-6 is priced: (10*5 + 5*25 + 3*0.5 + 2*6.25)/1e6.
        XCTAssertEqual(first.usage.first?.cost[.claude] ?? -1, 0.000189, accuracy: 1e-9)

        // Rescanning the same bytes contributes nothing — offsets dedupe.
        let second = scanner.scan(now: now, previousSessions: first.sessions, offsets: first.offsets, processes: [])
        XCTAssertTrue(second.usage.isEmpty)

        // An appended line adds exactly its own usage to the same bucket.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data((claudeAssistant(input: 4, output: 2, cacheRead: 0, cacheWrite: 0, at: now.addingTimeInterval(120)) + "\n").utf8))
        try handle.close()
        let third = scanner.scan(now: now, previousSessions: second.sessions, offsets: second.offsets, processes: [])
        XCTAssertEqual(third.usage.count, 1)
        XCTAssertEqual(third.usage.first?.hour, now)
        XCTAssertEqual(third.usage.first?.tokens[.claude], 6)
        XCTAssertEqual(third.usage.first?.cost[.claude] ?? -1, 0.00007, accuracy: 1e-9)
    }

    func testScanUsageSplitsEventsAcrossHours() throws {
        let dir = try directory()
        // `now` is hour-aligned, so one minute either side lands in
        // adjacent buckets — this also exercises truncation.
        let file = try write("s.jsonl", [
            claudeAssistant(input: 10, output: 0, cacheRead: 0, cacheWrite: 0, at: now.addingTimeInterval(-60)),
            claudeAssistant(input: 0, output: 7, cacheRead: 0, cacheWrite: 0, at: now.addingTimeInterval(60)),
        ], in: dir)
        let provider = FixtureProvider(kind: .claude, files: [file], wrapped: ClaudeCodeProvider())
        let result = makeScanner(for: provider, in: dir).scan(now: now, processes: [])
        XCTAssertEqual(result.usage.count, 2)
        XCTAssertEqual(result.usage[0].hour, now.addingTimeInterval(-3600))
        XCTAssertEqual(result.usage[0].tokens[.claude], 10)
        XCTAssertEqual(result.usage[1].hour, now)
        XCTAssertEqual(result.usage[1].tokens[.claude], 7)
    }

    func testAgentUsageRecordAndLoadAccumulates() throws {
        let store = try HistoryStore(directory: directory())
        var first = HourBurn(hour: now)
        first.tokens[.claude] = 20
        first.cost[.claude] = 0.010
        first.tokens[.codex] = 5 // unpriced — no cost entry expected
        try store.recordAgentUsage([first])
        var second = HourBurn(hour: now)
        second.tokens[.claude] = 6
        second.cost[.claude] = 0.004
        var later = HourBurn(hour: now.addingTimeInterval(3600))
        later.tokens[.claude] = 1
        try store.recordAgentUsage([second, later])

        let loaded = try store.loadAgentUsage(since: now.addingTimeInterval(-1800))
        XCTAssertEqual(loaded.map(\.hour), [now, now.addingTimeInterval(3600)])
        XCTAssertEqual(loaded[0].tokens[.claude], 26)
        XCTAssertEqual(loaded[0].tokens[.codex], 5)
        XCTAssertEqual(loaded[0].cost[.claude] ?? -1, 0.014, accuracy: 1e-9)
        XCTAssertNil(loaded[0].cost[.codex])
        XCTAssertEqual(loaded[1].tokens[.claude], 1)
        XCTAssertNil(loaded[1].cost[.claude])

        // A `since` inside a bucket still returns that bucket; past it drops.
        let mid = try store.loadAgentUsage(since: now.addingTimeInterval(600))
        XCTAssertEqual(mid.map(\.hour), [now, now.addingTimeInterval(3600)])
        let tail = try store.loadAgentUsage(since: now.addingTimeInterval(3600 + 600))
        XCTAssertEqual(tail.map(\.hour), [now.addingTimeInterval(3600)])
    }

    func testHistoryStoresSessionsAndOffsets() throws {
        let store = try HistoryStore(directory: directory())
        var session = AgentSession(kind: .claude, sessionId: "s1", projectDir: "/tmp/p", filePath: "/tmp/f.jsonl")
        session.pid = 99
        session.startedAt = now.addingTimeInterval(-100)
        session.lastEventAt = now
        session.models = ["claude-opus-4-6"]
        session.tokens.input = 42
        session.tools = ["Bash": 3]
        session.costUSD = 0.5
        session.health = .live
        try store.saveAgentSessions([session], offsets: ["/tmp/f.jsonl": 1234])
        try store.saveScanOffsets(["/tmp/f.jsonl": 1234])
        let loaded = try XCTUnwrap(store.loadAgentSessions().first)
        XCTAssertEqual(loaded.id, "claude:s1")
        XCTAssertEqual(loaded.pid, 99)
        XCTAssertEqual(loaded.tokens.input, 42)
        XCTAssertEqual(loaded.tools, ["Bash": 3])
        XCTAssertEqual(loaded.costUSD, 0.5)
        XCTAssertEqual(loaded.health, .live)
        XCTAssertEqual(try store.loadScanOffsets(), ["/tmp/f.jsonl": 1234])
    }
}
