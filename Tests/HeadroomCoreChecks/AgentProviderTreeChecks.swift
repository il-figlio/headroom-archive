import Foundation
import Testing
@testable import HeadroomCore

/// Provider-declared trees against a synthetic home — never the real
/// ~/.codex or ~/.claude.
private func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-agent-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
}

/// A minimal rollout: session meta plus one cumulative token count (110 tokens).
private func rollout(_ uuid: String) -> [String] {
    [#"{"timestamp":"2026-11-24T10:00:00Z","type":"session_meta","payload":{"id":"\#(uuid)","cwd":"/tmp/proj"}}"#,
     #"{"timestamp":"2026-11-24T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10}}}}"#]
}

private func tokens(_ usage: [HourBurn]) -> Int64 {
    usage.reduce(0) { $0 + $1.tokens.values.reduce(0, +) }
}

private func codexScanner(_ codex: URL) -> AgentScanner {
    AgentScanner(providers: [CodexProvider(root: codex.path), GenericProvider()], roots: [(.codex, codex.path)])
}

@Test func codexDatedRolloutsAreDiscoveredAndCounted() throws {
    let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
    let codex = home.appendingPathComponent(".codex")
    let uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    // Five levels below the root: out of the generic walk's reach.
    let live = codex.appendingPathComponent("sessions/2026/11/24/rollout-2026-11-24T10-00-00-\(uuid).jsonl")
    try write(rollout(uuid), to: live)
    // Unclaimed .jsonl under the root still falls to the generic provider.
    try write([#"{"type":"assistant","timestamp":"2026-11-24T10:00:00Z","usage":{"input_tokens":7,"output_tokens":3}}"#],
              to: codex.appendingPathComponent("log/other.jsonl"))

    let scanner = codexScanner(codex)
    let result = scanner.scan(processes: [])
    let session = try #require(result.sessions.first { $0.filePath == live.path })
    #expect(session.kind == .codex)
    #expect(session.sessionId == uuid)
    #expect(session.tokens.total == 110)
    #expect(result.sessions.first { $0.filePath.hasSuffix("/log/other.jsonl") }?.kind == .other)
    #expect(tokens(result.usage) == 120)
    #expect(result.snapshot.roots.first?.sessionFiles == 2)

    // A rescan with nothing new counts nothing.
    let again = scanner.scan(previousSessions: result.sessions, offsets: result.offsets,
                             identities: result.identities, processes: [])
    #expect(again.usage.isEmpty)
}

@Test func codexRolloutInANewDayDirectoryIsPickedUp() throws {
    let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
    let codex = home.appendingPathComponent(".codex")
    try write(rollout("11111111-2222-3333-4444-555555555555"),
              to: codex.appendingPathComponent("sessions/2026/11/24/rollout-2026-11-24T10-00-00-11111111-2222-3333-4444-555555555555.jsonl"))
    // Backdate so every listing is trusted and only real changes re-list.
    let past = Date().addingTimeInterval(-600)
    for dir in [".", "sessions", "sessions/2026", "sessions/2026/11", "sessions/2026/11/24"] {
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: codex.appendingPathComponent(dir).path)
    }
    let scanner = codexScanner(codex)
    var result = scanner.scan(processes: [])
    #expect(result.sessions.count == 1)
    let listed = scanner.discovery.listings

    let next = codex.appendingPathComponent("sessions/2026/11/25/rollout-2026-11-25T09-00-00-66666666-7777-8888-9999-000000000000.jsonl")
    try write(rollout("66666666-7777-8888-9999-000000000000"), to: next)
    result = scanner.scan(previousSessions: result.sessions, offsets: result.offsets,
                          identities: result.identities, processes: [])
    let session = try #require(result.sessions.first { $0.filePath == next.path })
    #expect(session.kind == .codex)
    #expect(session.tokens.total == 110)
    #expect(tokens(result.usage) == 110)
    // Only the month directory (new entry) and the new day were read again.
    #expect(scanner.discovery.listings == listed + 2)
}

@Test func filesSeenByBothTheWalkAndAProviderCountOnce() throws {
    let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
    let codex = home.appendingPathComponent(".codex")
    let uuid = "abababab-cdcd-efef-0101-232323232323"
    // archived_sessions/<file> is two levels down: both the root walk and
    // Codex's archived tree list it.
    let archived = codex.appendingPathComponent("archived_sessions/rollout-2026-11-20T08-00-00-\(uuid).jsonl")
    try write(rollout(uuid), to: archived)
    let result = codexScanner(codex).scan(processes: [])
    #expect(result.sessions.filter { $0.filePath == archived.path }.count == 1)
    #expect(result.sessions.first?.kind == .codex)
    #expect(tokens(result.usage) == 110)
    #expect(result.snapshot.roots.first?.sessionFiles == 1)
}

@Test func claudeProjectFilesAreClaimedThroughTheirTree() throws {
    let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
    let claude = home.appendingPathComponent(".claude")
    let file = claude.appendingPathComponent("projects/-tmp-proj/s1.jsonl")
    try write([#"{"type":"assistant","sessionId":"s1","timestamp":"2026-11-24T10:00:00Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":10,"output_tokens":5}}}"#], to: file)
    // Directly under projects/ isn't a session file (minDepth 2).
    try write([#"{"type":"assistant","timestamp":"2026-11-24T10:00:00Z","usage":{"input_tokens":1}}"#],
              to: claude.appendingPathComponent("projects/stray.jsonl"))
    let scanner = AgentScanner(providers: [ClaudeCodeProvider(root: claude.path), GenericProvider()],
                               roots: [(.claude, claude.path)])
    let result = scanner.scan(processes: [])
    #expect(result.sessions.first { $0.filePath == file.path }?.kind == .claude)
    #expect(result.sessions.first { $0.filePath.hasSuffix("/stray.jsonl") }?.kind == .other)
    #expect(result.snapshot.roots.first?.sessionFiles == 2)
}
