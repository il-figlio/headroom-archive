import Foundation
import Testing
@testable import HeadroomCore

/// Offset/rotation/persistence checks for AgentScanner against synthetic
/// generic transcripts in throwaway temp directories.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
/// 7 + 3 tokens per line.
private let usageLine = Data((#"{"type":"assistant","timestamp":"2026-11-24T10:00:00Z","model":"m","usage":{"input_tokens":7,"output_tokens":3}}"# + "\n").utf8)

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-agent-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func append(_ url: URL, _ data: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

private func tokens(_ usage: [HourBurn]) -> Int64 {
    usage.reduce(0) { $0 + $1.tokens.values.reduce(0, +) }
}

private func scanner(_ root: URL) -> AgentScanner {
    AgentScanner(providers: [GenericProvider()], roots: [(.other, root.path)])
}

/// Carries scan state forward the way the monitor does, summing burn.
private struct Chain {
    var sessions: [AgentSession] = []
    var offsets: [String: Int64] = [:]
    var identities: [String: AgentFileID] = [:]
    var burn: Int64 = 0
    var sessionTokens: Int64 { sessions.reduce(0) { $0 + $1.tokens.total } }

    @discardableResult
    mutating func scan(_ scanner: AgentScanner) -> AgentScanResult {
        let result = scanner.scan(now: now, previousSessions: sessions, offsets: offsets,
                                  identities: identities, processes: [])
        sessions = result.sessions; offsets = result.offsets; identities = result.identities
        burn += tokens(result.usage)
        return result
    }
}

@Test(arguments: [1, 48, 112])
func agentScanResumesALineSplitAcrossScans(split: Int) throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("b.jsonl")
    try usageLine.prefix(split).write(to: file)
    let scan = scanner(root)
    var chain = Chain()
    chain.scan(scan)
    try append(file, usageLine.dropFirst(split))
    chain.scan(scan)
    #expect(chain.burn == 10)
    #expect(chain.sessionTokens == 10)
    #expect(chain.offsets[file.path] == Int64(usageLine.count))
}

@Test func agentScanAcceptsUnterminatedCompleteLineOnce() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("c.jsonl")
    try usageLine.dropLast().write(to: file)
    let scan = scanner(root)
    var chain = Chain()
    chain.scan(scan)
    #expect(chain.burn == 10)
    try append(file, Data("\n".utf8) + usageLine)
    chain.scan(scan)
    #expect(chain.burn == 20)
    #expect(chain.sessionTokens == 20)
}

@Test func agentScanResumesPartialLineAcrossRestart() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let history = try tempDirectory(); defer { try? FileManager.default.removeItem(at: history) }
    let file = root.appendingPathComponent("d.jsonl")
    try usageLine.prefix(48).write(to: file)
    let first = scanner(root).scan(now: now, processes: [])
    try HistoryStore(directory: history).commitAgentScan(sessions: first.sessions, offsets: first.offsets,
                                                         identities: first.identities, usage: first.usage)
    try append(file, usageLine.dropFirst(48))

    let store = try HistoryStore(directory: history)
    let second = scanner(root).scan(now: now, previousSessions: try store.loadAgentSessions(),
                                    offsets: try store.loadScanOffsets(),
                                    identities: try store.loadScanIdentities(), processes: [])
    #expect(tokens(first.usage) + tokens(second.usage) == 10)
    #expect(second.sessions.first?.tokens.total == 10)
}

@Test func agentScanRetriesUnreadableFile() throws {
    guard getuid() != 0 else { return } // root ignores permissions
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("e.jsonl")
    try usageLine.write(to: file)
    chmod(file.path, 0o000)
    let scan = scanner(root)
    var chain = Chain()
    chain.scan(scan)
    #expect(chain.offsets[file.path] == nil)
    chmod(file.path, 0o644)
    chain.scan(scan)
    #expect(chain.burn == 10)
    #expect(chain.sessionTokens == 10)
}

@Test func agentScanRestartsTruncatedFileAndCountsRegrowth() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("g.jsonl")
    try usageLine.write(to: file)
    let scan = scanner(root)
    var chain = Chain()
    chain.scan(scan)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.close()
    try append(file, usageLine.prefix(30))
    chain.scan(scan)
    try append(file, usageLine.dropFirst(30))
    chain.scan(scan)
    #expect(chain.burn == 20)
    #expect(chain.sessionTokens == 20)
}

/// A generic usage line (7 + 3 tokens) stamped at `stamp`.
private func datedUsageLine(_ stamp: String) -> Data {
    Data((#"{"type":"assistant","timestamp":""# + stamp + #"","model":"m","usage":{"input_tokens":7,"output_tokens":3}}"# + "\n").utf8)
}

@Test func agentScanRereadsRotatedFile() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("f.jsonl")
    try usageLine.write(to: file)
    let scan = scanner(root)
    var chain = Chain()
    chain.scan(scan)
    // Replaced by a larger file of genuinely new events: the old offset fits
    // inside it, only the identity shows it's new.
    let later = datedUsageLine("2026-11-24T11:00:00Z") + datedUsageLine("2026-11-24T11:05:00Z")
    try FileManager.default.removeItem(at: file)
    try later.write(to: file)
    chain.scan(scan)
    #expect(chain.burn == 30)
    #expect(chain.sessionTokens == 30)
    // Replaced atomically by a same-size file: still re-read, and its one
    // event newer than the session counts.
    try (datedUsageLine("2026-11-24T11:05:00Z") + datedUsageLine("2026-11-24T12:00:00Z")).write(to: file, options: .atomic)
    chain.scan(scan)
    #expect(chain.burn == 40)
    #expect(chain.sessionTokens == 40)
    #expect(chain.offsets[file.path] == Int64(later.count))
}

/// A copied or restored transcript (new inode, same bytes) must not count
/// its lines a second time — not in the session, not in hourly usage.
@Test func agentScanReplacedByIdenticalCopyCountsNothing() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("x.jsonl")
    let content = usageLine + datedUsageLine("2026-11-24T10:30:00Z")
    try content.write(to: file)
    let scan = scanner(root)
    var chain = Chain()
    let first = chain.scan(scan)
    try content.write(to: file, options: .atomic)
    let second = chain.scan(scan)
    #expect(first.identities[file.path] != second.identities[file.path])
    #expect(tokens(second.usage) == 0)
    #expect(chain.burn == 20)
    #expect(chain.sessionTokens == 20)
    #expect(chain.offsets[file.path] == Int64(content.count))
    // Nothing new, so the restart isn't growth.
    #expect(second.snapshot.sessions.first?.health == .ended)
}

/// Replaced by the old content plus one later line: only that line counts.
/// Undated lines in the recovery pass can't be placed and are skipped.
@Test func agentScanReplacedFileCountsOnlyNewerLines() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("x.jsonl")
    try usageLine.write(to: file)
    let scan = AgentScanner(providers: [GenericProvider()], roots: [(.other, root.path)])
    let first = scan.scan(processes: [])
    let undated = Data((#"{"type":"assistant","model":"m","usage":{"input_tokens":50,"output_tokens":50}}"# + "\n").utf8)
    try (usageLine + undated + datedUsageLine("2026-11-24T10:00:01Z")).write(to: file, options: .atomic)
    let second = scan.scan(previousSessions: first.sessions, offsets: first.offsets, identities: first.identities, processes: [])
    #expect(tokens(first.usage) + tokens(second.usage) == 20)
    #expect(second.sessions.first?.tokens.total == 20)
    #expect(second.sessions.first?.lastEventAt == ISO8601DateFormatter().date(from: "2026-11-24T10:00:01Z"))
}

/// Same recovery for a model-tracking provider: cost and per-model pricing
/// see only the newer line, and the restart doesn't double the cost.
@Test func claudeTranscriptRestoredFromCopyKeepsCostOnce() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("projects/-Users-me-app")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = project.appendingPathComponent("s.jsonl")
    func line(_ stamp: String) -> Data {
        Data((#"{"timestamp":""# + stamp + #"","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":1000000,"output_tokens":0},"content":[{"type":"tool_use","name":"Read"}]}}"# + "\n").utf8)
    }
    try line("2026-11-24T10:00:00Z").write(to: file)
    let scan = AgentScanner(providers: [ClaudeCodeProvider(root: root.path), GenericProvider()], roots: [(.claude, root.path)])
    let first = scan.scan(now: now, processes: [])
    #expect(first.sessions.first?.costUSD == 3)
    try line("2026-11-24T10:00:00Z").write(to: file, options: .atomic)
    let copied = scan.scan(now: now, previousSessions: first.sessions, offsets: first.offsets, identities: first.identities, processes: [])
    #expect(copied.sessions.first?.costUSD == 3)
    #expect(copied.sessions.first?.tools["Read"] == 1)
    #expect(copied.usage.isEmpty)
    try (line("2026-11-24T10:00:00Z") + line("2026-11-24T10:01:00Z")).write(to: file, options: .atomic)
    let grown = scan.scan(now: now, previousSessions: copied.sessions, offsets: copied.offsets, identities: copied.identities, processes: [])
    #expect(grown.sessions.first?.costUSD == 6)
    #expect(grown.sessions.first?.tokens.total == 2_000_000)
    #expect(grown.sessions.first?.tools["Read"] == 2)
    #expect(grown.usage.reduce(0) { $0 + ($1.cost[.claude] ?? 0) } == 3)
}

/// Device numbers can change across boots or remounts; the same inode at
/// the same path is the same file.
@Test func agentFileIdentityIgnoresDeviceRenumbering() {
    #expect(AgentFileID(device: 16777234, inode: 42).sameFile(as: AgentFileID(device: 16777235, inode: 42)))
    #expect(!AgentFileID(device: 1, inode: 42).sameFile(as: AgentFileID(device: 1, inode: 43)))
}

/// Two recent sessions in one project (e.g. after /clear) and one `claude`
/// process: the process backs one session only, and its footprint is
/// counted once.
@Test func sharedAgentProcessIsAssignedOnceAndCountedOnce() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("projects/-Users-me-app")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    func line(_ ago: TimeInterval) -> Data {
        Data((#"{"timestamp":""# + formatter.string(from: now.addingTimeInterval(-ago)) + #"","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":5,"output_tokens":5}}}"# + "\n").utf8)
    }
    try line(120).write(to: project.appendingPathComponent("old.jsonl"))
    try line(30).write(to: project.appendingPathComponent("new.jsonl"))
    let scanner = AgentScanner(providers: [ClaudeCodeProvider(root: root.path), GenericProvider()], roots: [(.claude, root.path)])
    let result = scanner.scan(now: now, processes: [AgentProcess(pid: 4242, args: "/usr/local/bin/claude")])
    let byName = Dictionary(uniqueKeysWithValues: result.snapshot.sessions.map { (URL(fileURLWithPath: $0.filePath).lastPathComponent, $0) })
    #expect(byName["new.jsonl"]?.pid == 4242)
    #expect(byName["old.jsonl"]?.pid == nil)
    #expect(result.snapshot.processCounts[.claude] == 1)
    let measured = result.snapshot.withFootprints([ProcessMemory(pid: 4242, parent: 1, path: "", footprint: 1_000_000_000)])
    let summary = measured.runningSummary
    #expect(summary.processes == 1)
    #expect(summary.footprint == 1_000_000_000)
    #expect(summary.measured == 1)
}

/// The card's totals stay per process even if sessions do share a pid
/// (fixtures, older state), and pid-less live sessions count only up to the
/// processes no session holds.
@Test func runningSummaryCountsDistinctProcesses() {
    func session(_ name: String, pid: Int32?, footprint: UInt64?) -> AgentSession {
        var s = AgentSession(kind: .claude, sessionId: name, projectDir: "/p", filePath: "/\(name).jsonl")
        s.pid = pid; s.footprint = footprint; s.health = .live
        return s
    }
    var snapshot = AgentSnapshot()
    snapshot.sessions = [session("a", pid: 7, footprint: 500), session("b", pid: 7, footprint: 500), session("c", pid: nil, footprint: nil)]
    snapshot.processCounts = [.claude: 1]
    #expect(snapshot.runningSummary.processes == 1)
    #expect(snapshot.runningSummary.footprint == 500)
    snapshot.processCounts = [.claude: 2]
    #expect(snapshot.runningSummary.processes == 2)
    #expect(snapshot.runningSummary.measured == 1)
}

/// Agent commits honor history's low-disk guard: nothing is written and the
/// caller keeps its previous state, so the bytes count once space returns.
@Test func agentCommitSkipsWritesOnLowDisk() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let history = try tempDirectory(); defer { try? FileManager.default.removeItem(at: history) }
    let file = root.appendingPathComponent("d.jsonl")
    try usageLine.write(to: file)
    let store = try HistoryStore(directory: history)
    let scan = scanner(root)
    let first = scan.scan(now: now, processes: [])
    let low = DiskSpace(total: 500_000_000_000, free: 100_000_000, purgeable: 0, valid: true)
    #expect(throws: (any Error).self) {
        try store.commitAgentScan(sessions: first.sessions, offsets: first.offsets,
                                  identities: first.identities, usage: first.usage, disk: low)
    }
    #expect(try store.loadAgentSessions().isEmpty)
    #expect(try store.loadScanOffsets().isEmpty)
    #expect(try store.loadAgentUsage(since: .distantPast).isEmpty)
    let retry = scan.scan(now: now, processes: [])
    let roomy = DiskSpace(total: 500_000_000_000, free: 10_000_000_000, purgeable: 0, valid: true)
    try store.commitAgentScan(sessions: retry.sessions, offsets: retry.offsets,
                              identities: retry.identities, usage: retry.usage, disk: roomy)
    #expect(tokens(try store.loadAgentUsage(since: .distantPast)) == 10)
}

@Test func agentScanCapsLargeTailAndResumesItsPartialLine() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("h.jsonl")
    let count = AgentScanner.maxTailRead / usageLine.count + 50
    var big = Data()
    for _ in 0..<count { big.append(usageLine) }
    big.append(usageLine.prefix(48))
    try big.write(to: file)
    let scan = scanner(root)
    var chain = Chain()
    chain.scan(scan)
    // Only lines starting inside the last 2 MB are read.
    let window = big.count - AgentScanner.maxTailRead
    let inWindow = (0..<count).filter { $0 * usageLine.count >= window }.count
    #expect(chain.burn == Int64(inWindow) * 10)
    #expect(chain.offsets[file.path] == Int64(big.count - 48))
    try append(file, usageLine.dropFirst(48))
    let before = chain.burn
    chain.scan(scan)
    #expect(chain.burn - before == 10)
}

@Test func agentScanCountsConcurrentAppendsExactly() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("race.jsonl")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    // Short enough that the whole run stays under the 2 MB tail cap.
    let line = Data((#"{"type":"a","ts":1,"usage":{"input":7,"output":3}}"# + "\n").utf8)
    let lines = 20_000
    let scan = scanner(root)
    var chain = Chain()
    chain.scan(scan)
    let done = DispatchSemaphore(value: 0)
    let path = file.path
    Thread.detachNewThread {
        let fd = open(path, O_WRONLY | O_APPEND)
        line.withUnsafeBytes { bytes in for _ in 0..<lines { _ = write(fd, bytes.baseAddress, line.count) } }
        close(fd)
        done.signal()
    }
    var finished = false
    while !finished {
        finished = done.wait(timeout: .now()) == .success
        chain.scan(scan)
    }
    #expect(chain.burn == Int64(lines) * 10)
    #expect(chain.sessionTokens == Int64(lines) * 10)
}

@Test func agentCommitRollsBackAndRetryCountsOnce() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let history = try tempDirectory(); defer { try? FileManager.default.removeItem(at: history) }
    let file = root.appendingPathComponent("s.jsonl")
    try usageLine.write(to: file)
    let store = try HistoryStore(directory: history)
    let scan = scanner(root)
    let first = scan.scan(now: now, processes: [])
    try store.commitAgentScan(sessions: first.sessions, offsets: first.offsets, identities: first.identities, usage: first.usage)

    try append(file, usageLine)
    let second = scan.scan(now: now, previousSessions: first.sessions, offsets: first.offsets,
                           identities: first.identities, processes: [])
    #expect(tokens(second.usage) == 10)
    // The usage write is the last step, so sessions and offsets were already
    // written inside the transaction when it fails.
    try store.executeForTesting("CREATE TRIGGER fail_insert BEFORE INSERT ON agent_usage BEGIN SELECT RAISE(ABORT, 'injected'); END")
    try store.executeForTesting("CREATE TRIGGER fail_update BEFORE UPDATE ON agent_usage BEGIN SELECT RAISE(ABORT, 'injected'); END")
    #expect(throws: (any Error).self) {
        try store.commitAgentScan(sessions: second.sessions, offsets: second.offsets,
                                  identities: second.identities, usage: second.usage)
    }
    #expect(try store.loadScanOffsets() == first.offsets)
    #expect(try store.loadScanIdentities() == first.identities)
    #expect(try store.loadAgentSessions().map(\.tokens.total) == [10])
    #expect(tokens(try store.loadAgentUsage(since: .distantPast)) == 10)

    // The caller kept its previous state; the retry re-reads the same bytes.
    try store.executeForTesting("DROP TRIGGER fail_insert")
    try store.executeForTesting("DROP TRIGGER fail_update")
    let retry = scan.scan(now: now, previousSessions: try store.loadAgentSessions(), offsets: try store.loadScanOffsets(),
                          identities: try store.loadScanIdentities(), processes: [])
    try store.commitAgentScan(sessions: retry.sessions, offsets: retry.offsets, identities: retry.identities, usage: retry.usage)
    #expect(tokens(try store.loadAgentUsage(since: .distantPast)) == 20)
    #expect(try store.loadAgentSessions().map(\.tokens.total) == [20])
    #expect(try store.loadScanOffsets()[file.path] == Int64(usageLine.count * 2))
}

@Test func agentSessionsSharingAnIdBothPersist() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let history = try tempDirectory(); defer { try? FileManager.default.removeItem(at: history) }
    for dir in ["a", "b"] {
        let sub = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try usageLine.write(to: sub.appendingPathComponent("same.jsonl"))
    }
    let result = scanner(root).scan(now: now, processes: [])
    #expect(Set(result.sessions.map(\.id)) == ["other:same"])
    #expect(result.sessions.count == 2)
    let store = try HistoryStore(directory: history)
    try store.commitAgentScan(sessions: result.sessions, offsets: result.offsets, identities: result.identities, usage: result.usage)
    let loaded = try HistoryStore(directory: history).loadAgentSessions()
    #expect(Set(loaded.map(\.filePath)) == Set(result.sessions.map(\.filePath)))
}

@Test func agentSessionsTableMigratesFromIdKey() throws {
    let history = try tempDirectory(); defer { try? FileManager.default.removeItem(at: history) }
    func row(_ id: String, _ path: String, _ last: String, input: Int) -> String {
        "('\(id)', 'other', '\(id)', '/p', NULL, \(last), \(last), '\(path)', 10, '[\"m\"]', '{\"input\":\(input),\"output\":0,\"cacheRead\":0,\"cacheWrite\":0}', '{}', NULL, 0, 'ended')"
    }
    do {
        // Rebuild the schema-1 table exactly as older builds created it.
        let store = try HistoryStore(directory: history)
        try store.executeForTesting("DROP TABLE agent_sessions")
        try store.executeForTesting("CREATE TABLE agent_sessions (id TEXT PRIMARY KEY, kind TEXT, session_id TEXT, project_dir TEXT, pid INTEGER, started_at REAL, last_event_at REAL, file_path TEXT, file_offset INTEGER, models_json TEXT, tokens_json TEXT, tools_json TEXT, cost_usd REAL, unpriced_tokens INTEGER, health TEXT)")
        try store.executeForTesting("INSERT INTO agent_sessions VALUES \(row("a1", "/x/a.jsonl", "100", input: 1)), \(row("a2", "/x/a.jsonl", "200", input: 2)), \(row("b1", "/x/b.jsonl", "NULL", input: 3)), \(row("b2", "/x/b.jsonl", "50", input: 4)), \(row("c", "/x/c.jsonl", "300", input: 5))")
        try store.executeForTesting("PRAGMA user_version=1")
    }
    let store = try HistoryStore(directory: history)
    #expect(try store.executeForTesting("PRAGMA user_version") == [["2"]])
    #expect(try store.executeForTesting("SELECT name FROM pragma_table_info('agent_sessions') WHERE pk > 0") == [["file_path"]])
    let loaded = Dictionary(uniqueKeysWithValues: try store.loadAgentSessions().map { ($0.filePath, $0) })
    #expect(loaded.count == 3)
    #expect(loaded["/x/a.jsonl"]?.tokens.input == 2) // most recent row wins
    #expect(loaded["/x/b.jsonl"]?.tokens.input == 4) // dated beats undated
    #expect(loaded["/x/c.jsonl"]?.models == ["m"])
    // Older builds insert positionally and may repeat an id; both still fit.
    try store.executeForTesting("INSERT INTO agent_sessions VALUES \(row("a2", "/y/a.jsonl", "400", input: 6))")
    // Reopening (as after an older build reset user_version) is a no-op.
    try store.executeForTesting("PRAGMA user_version=1")
    let reopened = try HistoryStore(directory: history)
    #expect(try reopened.loadAgentSessions().count == 4)
    #expect(try reopened.executeForTesting("PRAGMA user_version") == [["2"]])
}

@Test func agentScanIdentitiesSurviveOldStyleSave() throws {
    let history = try tempDirectory(); defer { try? FileManager.default.removeItem(at: history) }
    let store = try HistoryStore(directory: history)
    // A database that only ever stored offsets loads with no identities.
    try store.saveScanOffsets(["/f.jsonl": 5])
    #expect(try store.loadScanIdentities().isEmpty)
    try store.saveScanOffsets(["/f.jsonl": 6], identities: ["/f.jsonl": AgentFileID(device: 1, inode: 2)])
    #expect(try store.loadScanOffsets() == ["/f.jsonl": 6])
    #expect(try store.loadScanIdentities() == ["/f.jsonl": AgentFileID(device: 1, inode: 2)])
}

@Test func agentScanDoesNotTreatAStuckPartialLineAsGrowth() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("z.jsonl")
    try usageLine.write(to: file)
    let scan = scanner(root)
    var chain = Chain()
    chain.scan(scan)
    try append(file, usageLine.prefix(20))
    chain.scan(scan)
    let result = chain.scan(scan)
    #expect(result.snapshot.sessions.first?.health == .ended)
    try append(file, usageLine.dropFirst(20))
    #expect(chain.scan(scan).snapshot.sessions.first?.health == .zombie)
    #expect(chain.burn == 20)
}
