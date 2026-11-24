import Foundation
import Testing
@testable import HeadroomCore

private let line = Data((#"{"type":"assistant","timestamp":"2026-11-24T10:00:00Z","usage":{"input_tokens":7,"output_tokens":3}}"# + "\n").utf8)

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-agent-discovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func backdate(_ url: URL, by seconds: TimeInterval) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
}

@Test func agentDiscoveryMatchesEnumeratorRules() throws {
    // Resolved: under the /var symlink the enumerator walks /private/var and
    // its relative depth comes out one short.
    // (realpath, since resolvingSymlinksInPath hands back the /var spelling).
    let temp = try tempDirectory()
    let root = URL(fileURLWithPath: realpath(temp.path, nil).map { String(cString: $0) } ?? temp.path, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let paths = ["a.jsonl", "x/b.jsonl", "x/y/c.jsonl", "x/y/z/d.jsonl", "x/y/z/w/too-deep.jsonl",
                 ".hidden.jsonl", ".dot/e.jsonl", "x/notes.txt", "x/f.jsonl.bak", "q.r.jsonl"]
    for path in paths {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try line.write(to: url)
    }
    let expected = Set(jsonlFiles(under: root.path, depth: 4).map(\.standardizedFileURL.path))
    let found = TranscriptDiscovery().discover([(root.path, 4)])
    #expect(Set(found.files[0].map(\.path)) == expected)
    #expect(expected.count == 5)
}

@Test func agentDiscoveryReusesQuietListingsAndSeesNewFilesAndGrowth() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("proj")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // More files than the candidate cap, oldest last.
    let count = AgentScanner.candidateLimit + 10
    var files: [URL] = []
    for index in 0..<count {
        let url = dir.appendingPathComponent("s\(index).jsonl")
        try line.write(to: url)
        try backdate(url, by: 1000 + Double(index))
        files.append(url)
    }
    try backdate(dir, by: 600)
    try backdate(root, by: 600)

    let scanner = AgentScanner(providers: [GenericProvider()], roots: [(.other, root.path)])
    var result = scanner.scan(processes: [])
    #expect(result.sessions.count == AgentScanner.candidateLimit)
    let listed = scanner.discovery.listings
    #expect(listed == 2)
    func rescan() {
        result = scanner.scan(previousSessions: result.sessions, offsets: result.offsets,
                              identities: result.identities, processes: [])
    }

    // Nothing changed: no directory is re-read.
    rescan()
    #expect(scanner.discovery.listings == listed)
    #expect(result.usage.isEmpty)

    // Growth of a file that was never picked (not known, beyond the cap)
    // doesn't touch the directory, yet the next scan reads it.
    let oldest = files[count - 1]
    #expect(!result.sessions.contains { $0.filePath == oldest.path })
    let handle = try FileHandle(forWritingTo: oldest)
    try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.close()
    rescan()
    #expect(scanner.discovery.listings == listed)
    #expect(result.sessions.first { $0.filePath == oldest.path }?.tokens.total == 20)

    // A new file changes the directory's mtime, so only that directory is re-read.
    let fresh = dir.appendingPathComponent("new.jsonl")
    try line.write(to: fresh)
    rescan()
    #expect(scanner.discovery.listings == listed + 1)
    #expect(result.sessions.first { $0.filePath == fresh.path }?.tokens.total == 10)
    #expect(result.snapshot.roots.first?.sessionFiles == count + 1)
}

@Test func agentDiscoveryFullRelistingIsASafetyNet() throws {
    let root = try tempDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    try line.write(to: root.appendingPathComponent("a.jsonl"))
    try backdate(root, by: 600)
    let discovery = TranscriptDiscovery()
    _ = discovery.discover([(root.path, 4)])
    _ = discovery.discover([(root.path, 4)])
    #expect(discovery.listings == 1)
    discovery.rediscoverEvery = 0
    let again = discovery.discover([(root.path, 4)])
    #expect(discovery.listings == 2)
    #expect(again.changed)
}

@Test func agentFootprintSumsProcessTrees() {
    let processes = [
        ProcessMemory(pid: 100, parent: 1, path: "/bin/claude", footprint: 10),
        ProcessMemory(pid: 101, parent: 100, path: "/bin/node", footprint: 20),
        ProcessMemory(pid: 102, parent: 101, path: "/bin/sh", footprint: nil),
        ProcessMemory(pid: 103, parent: 102, path: "/bin/rg", footprint: 5),
        ProcessMemory(pid: 200, parent: 1, path: "/bin/codex", footprint: 7),
        ProcessMemory(pid: 300, parent: 1, path: "/bin/other", footprint: 1000),
        // A parent cycle (pid reuse) must terminate.
        ProcessMemory(pid: 400, parent: 401, path: "/bin/a", footprint: 1),
        ProcessMemory(pid: 401, parent: 400, path: "/bin/b", footprint: 2),
    ]
    let readings = AgentFootprint.measure(processes: processes, roots: [100, 200, 400, 999, 1])
    #expect(readings[100] == AgentFootprintReading(bytes: 35, processCount: 4, partial: true))
    #expect(readings[200] == AgentFootprintReading(bytes: 7, processCount: 1, partial: false))
    #expect(readings[400] == AgentFootprintReading(bytes: 3, processCount: 2, partial: false))
    #expect(readings[999] == nil)
    #expect(readings[1] == nil)
    // A nested root reports its own subtree.
    let nested = AgentFootprint.measure(processes: processes, roots: [100, 102])
    #expect(nested[102] == AgentFootprintReading(bytes: 5, processCount: 2, partial: true))
    #expect(nested[100]?.bytes == 35)
}

@Test func codexTakesSessionIdOnlyFromSessionMeta() {
    let provider = CodexProvider()
    var session = AgentSession(kind: .codex, sessionId: "from-file", projectDir: "", filePath: "/tmp/x/rollout-a.jsonl")
    _ = provider.parse(line: Data(#"{"timestamp":"2026-01-01T00:00:00Z","type":"response_item","payload":{"type":"message","id":"msg_1","role":"assistant"}}"#.utf8), into: &session)
    _ = provider.parse(line: Data(#"{"timestamp":"2026-01-01T00:00:00Z","type":"event_msg","payload":{"type":"agent_message","id":"evt_2","thread_id":"t"}}"#.utf8), into: &session)
    #expect(session.sessionId == "from-file")
    _ = provider.parse(line: Data(#"{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","cwd":"/tmp/proj"}}"#.utf8), into: &session)
    #expect(session.sessionId == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    _ = provider.parse(line: Data(#"{"timestamp":"2026-01-01T00:00:00Z","type":"response_item","payload":{"type":"function_call","id":"fc_3","name":"exec_command"}}"#.utf8), into: &session)
    #expect(session.sessionId == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    #expect(session.tools == ["exec_command": 1])
}

@Test func openClawTakesBareIdOnlyFromSessionHeader() {
    let provider = OpenClawProvider()
    var session = AgentSession(kind: .openclaw, sessionId: "from-file", projectDir: "", filePath: "/tmp/x/o.jsonl")
    _ = provider.parse(line: Data(#"{"type":"session","id":"sess-1","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp/p"}"#.utf8), into: &session)
    #expect(session.sessionId == "sess-1")
    _ = provider.parse(line: Data(#"{"type":"message","id":"msg-9","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","model":"m","usage":{"input_tokens":4}}}"#.utf8), into: &session)
    #expect(session.sessionId == "sess-1")
    #expect(session.tokens.input == 4)
    _ = provider.parse(line: Data(#"{"sessionId":"sess-2","timestamp":"2026-01-01T00:00:02Z"}"#.utf8), into: &session)
    #expect(session.sessionId == "sess-2")
}
