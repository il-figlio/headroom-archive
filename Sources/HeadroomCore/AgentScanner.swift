import Foundation

/// A running process as reported by `ps`: pid plus the full argument string.
public struct AgentProcess: Sendable {
    public var pid: Int32
    public var args: String
    public init(pid: Int32, args: String) {
        self.pid = pid; self.args = args
    }
}

/// Which file a path pointed at when it was read. A different identity at the
/// same path means the transcript was replaced (rotated), so the stored
/// offset no longer describes it.
public struct AgentFileID: Codable, Hashable, Sendable {
    public var device: Int64
    public var inode: UInt64
    public init(device: Int64, inode: UInt64) {
        self.device = device; self.inode = inode
    }
    init(_ info: stat) {
        self.init(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }
    /// Replacement is judged by inode alone. `st_dev` is the volume's BSD
    /// device number, which can be renumbered across boots or remounts
    /// (disk3s5 one boot, disk4s5 the next) without the file changing; a
    /// different file at the same path on another volume with the very same
    /// inode is far less likely. The device is still stored for diagnostics.
    func sameFile(as other: AgentFileID) -> Bool { inode == other.inode }
}

/// Output of one scan: the snapshot the UI publishes plus the state that must
/// survive to the next scan (accumulated sessions, per-file offsets and the
/// file identities those offsets belong to).
public struct AgentScanResult: Sendable {
    public var snapshot: AgentSnapshot
    public var sessions: [AgentSession]
    public var offsets: [String: Int64]
    public var identities: [String: AgentFileID] = [:]
    /// Token/cost burn contributed by lines parsed during *this* scan only,
    /// bucketed by epoch-truncated hour and sorted ascending. Offsets only
    /// advance past complete parsed lines, so merging `usage` across scans
    /// can't double count — provided sessions, offsets and usage are kept or
    /// dropped together (see `HistoryStore.commitAgentScan`).
    public var usage: [HourBurn] = []
}

/// Synchronous transcript scanner; the caller owns the queue. Reads are
/// tail-only: each file resumes at its persisted offset, and any unread tail
/// larger than 2 MB is capped to the last 2 MB (the skipped middle simply
/// contributes nothing — partial stats, honest timestamps). Transcripts are
/// append-only JSONL, so offset resume is safe; a truncated or replaced file
/// restarts from the top, counting only events newer than its session's last.
public final class AgentScanner {
    /// Snapshot keeps the 40 most recent sessions; persistence keeps a bit more
    /// so accumulation survives churn at the boundary.
    public static let sessionLimit = 40
    public static let persistLimit = 200
    static let maxTailRead = 2 * 1024 * 1024
    static let staleAfter: TimeInterval = 600
    static let candidateLimit = 60

    private let providers: [AgentProvider]
    private let fallback: AgentProvider
    private let candidates0: [(kind: AgentKind, path: String)]
    let discovery = TranscriptDiscovery()
    /// `sessionFiles()` of providers that declare no trees, by provider index.
    private var listedClaims: [[String]]?

    public init(providers: [AgentProvider] = AgentProviders.all,
                roots: [(kind: AgentKind, path: String)]? = nil) {
        self.providers = providers
        self.fallback = providers.last(where: { $0 is GenericProvider }) ?? GenericProvider()
        self.candidates0 = roots ?? Self.rootCandidates()
    }

    /// Every installation root Headroom knows how to watch, whether it exists
    /// or not — the UI shows what's installed.
    public static func rootCandidates() -> [(kind: AgentKind, path: String)] {
        [(.claude, "~/.claude"), (.codex, "~/.codex"), (.openclaw, "~/.openclaw"),
         (.devin, "~/.devin"), (.devin, "~/.local/share/devin"),
         (.aider, "~/.aider-desk"), (.gemini, "~/.gemini"),
         (.goose, "~/.config/goose"), (.opencode, "~/.config/opencode"),
         (.amp, "~/.config/amp"), (.continue_, "~/.config/continue"),
         (.cursor, "~/.cursor"), (.windsurf, "~/.windsurf"),
         (.amp, "~/.amp"), (.windsurf, "~/.codeium")]
    }

    public func roots() -> [AgentRoot] {
        let fm = FileManager.default
        return candidates0.map { kind, path in
            let expanded = NSString(string: path).expandingTildeInPath
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
            return AgentRoot(kind: kind, path: path, exists: exists)
        }
    }

    /// Full scan. `previousSessions`/`offsets`/`identities` carry accumulation
    /// state between scans (persisted via HistoryStore); `processes` defaults
    /// to a live `ps` read but is injectable for tests. Without `identities`
    /// a replaced file is only noticed once it is shorter than its offset.
    public func scan(now: Date = Date(), previousSessions: [AgentSession] = [],
                     offsets: [String: Int64] = [:],
                     identities: [String: AgentFileID] = [:],
                     processes: [AgentProcess]? = nil) -> AgentScanResult {
        var roots = self.roots()
        // One discovery pass covers the generic root walks and every
        // provider-declared tree; the latter can sit deeper than the roots
        // walk (Codex's sessions/YYYY/MM/DD).
        let rootIndices = roots.indices.filter { roots[$0].exists }
        var walks = rootIndices.map { (path: roots[$0].path, depth: 4) }
        var trees: [(provider: Int, tree: AgentSessionTree)] = []
        for (index, provider) in providers.enumerated() where !(provider is GenericProvider) {
            for tree in provider.sessionTrees {
                trees.append((index, tree))
                walks.append((tree.path, tree.depth))
            }
        }
        let found = discovery.discover(walks)
        var treeFiles: [Int: [DiscoveredFile]] = [:]
        for (offset, entry) in trees.enumerated() {
            treeFiles[entry.provider, default: []] += found.files[rootIndices.count + offset].filter { file in
                file.depth >= entry.tree.minDepth
                    && entry.tree.namePrefix.map { (file.path as NSString).lastPathComponent.hasPrefix($0) } ?? true
            }
        }
        // Providers without declared trees list their own files; that only
        // changes when some watched directory's entries did.
        if found.changed || listedClaims == nil {
            listedClaims = providers.map { provider in
                provider is GenericProvider || !provider.sessionTrees.isEmpty ? []
                    : provider.sessionFiles().map(\.standardizedFileURL.path)
            }
        }
        var rootFiles: [String: DiscoveredFile] = [:]
        if listedClaims?.contains(where: { !$0.isEmpty }) == true {
            for offset in rootIndices.indices {
                for file in found.files[offset] { rootFiles[file.path] = file }
            }
        }
        // Later providers win a contested file, as before.
        var claimed: [String: AgentProvider] = [:]
        var declared: [DiscoveredFile] = []
        for (index, provider) in providers.enumerated() where !(provider is GenericProvider) {
            var files = treeFiles[index] ?? []
            for path in listedClaims?[index] ?? [] {
                if let file = rootFiles[path] ?? TranscriptDiscovery.file(at: path) { files.append(file) }
            }
            for file in files {
                claimed[file.path] = provider
                declared.append(file)
            }
        }
        var candidates: [(file: DiscoveredFile, provider: AgentProvider)] = []
        var listed: Set<String> = []
        for (offset, index) in rootIndices.enumerated() {
            roots[index].sessionFiles = found.files[offset].count
            for file in found.files[offset] where listed.insert(file.path).inserted {
                candidates.append((file, claimed[file.path] ?? fallback))
            }
        }
        // Declared files the root walk didn't reach, de-duplicated by path
        // and counted under the root that contains them.
        let bases = rootIndices.map { TranscriptDiscovery.base(roots[$0].path) + "/" }
        for file in declared where listed.insert(file.path).inserted {
            candidates.append((file, claimed[file.path] ?? fallback))
            if let offset = bases.firstIndex(where: { file.path.hasPrefix($0) }) {
                roots[rootIndices[offset]].sessionFiles += 1
            }
        }
        candidates.sort { $0.file.mtime > $1.file.mtime }
        // Known sessions always get re-read when they changed, even past the cap.
        let known = Set(previousSessions.map(\.filePath))
        let picked = candidates.enumerated().filter { index, item in
            index < Self.candidateLimit
                || (known.contains(item.file.path)
                    && (offsets[item.file.path] != item.file.size
                        || identities[item.file.path].map { !$0.sameFile(as: item.file.id) } == true))
        }.map(\.element)

        var sessions = Dictionary(previousSessions.map { ($0.filePath, $0) }, uniquingKeysWith: { a, _ in a })
        var newOffsets = offsets
        var newIdentities = identities
        var grew: Set<String> = []
        var burn: [Date: HourBurn] = [:]
        for (file, provider) in picked {
            let path = file.path
            // A failed open leaves offset and identity alone so the bytes are retried.
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { continue }
            let size = Int64(info.st_size)
            let id = AgentFileID(info)
            let rotated = identities[path].map { !$0.sameFile(as: id) } ?? false
            var start = newOffsets[path] ?? 0
            let restarted = rotated || start > size
            if restarted { start = 0 }
            guard size > start || sessions[path] == nil else {
                newOffsets[path] = start
                newIdentities[path] = id
                continue
            }
            let capped = size - start > Self.maxTailRead
            if capped { start = size - Int64(Self.maxTailRead) }
            let url = URL(fileURLWithPath: path)
            var session = sessions[path] ?? Self.newSession(file: url, provider: provider)
            if session.projectDir.isEmpty, let guess = Self.projectGuess(file: url, provider: provider) {
                session.projectDir = guess
            }
            guard let tail = Self.readTail(handle, from: start, skipPartialLine: capped) else { continue }
            let consumed = Self.consumableLength(tail.data)
            let tracker = provider as? ModelTokenTracking
            // A replaced or truncated file that already fed a session is
            // re-read from the top, but only events strictly newer than what
            // the session has seen count: a copied or restored transcript
            // (Migration Assistant, rsync, backup restore) repeats lines
            // already in the session and in agent_usage. Undated lines can't
            // be placed, so this pass skips them (the offset still advances).
            let cutoff = restarted ? sessions[path]?.lastEventAt : nil
            var modelTokens: [String: TokenUsage] = [:]
            var counted = false
            if cutoff != nil { _ = tracker?.takeModelTokens(file: path) }
            for line in Self.splitLines(tail.data.prefix(consumed)) {
                var event = AgentLineEvent()
                if let cutoff {
                    // Parse into a copy and keep it only for a newer event,
                    // so a skipped line leaves no tokens, tools or models.
                    var candidate = session
                    guard provider.parse(line: line, into: &candidate, event: &event) else { continue }
                    let lineModels = tracker?.takeModelTokens(file: path) ?? [:]
                    guard let at = event.at, at > cutoff else { continue }
                    session = candidate
                    counted = true
                    for (model, usage) in lineModels { modelTokens[model, default: TokenUsage()] += usage }
                    guard event.tokens.total > 0 else { continue }
                } else {
                    guard provider.parse(line: line, into: &session, event: &event),
                          event.tokens.total > 0 else { continue }
                }
                // Undated usage lines fall back to the file's mtime —
                // the closest honest "when" for a just-appended line.
                let hour = Self.hourBucket(event.at ?? file.mtime)
                var bucket = burn[hour] ?? HourBurn(hour: hour)
                bucket.tokens[session.kind, default: 0] += event.tokens.total
                // A line that doesn't name its model borrows the
                // session's when it has settled on exactly one, mirroring
                // the orphan rule in applyPricing.
                if let model = event.model ?? (session.models.count == 1 ? session.models.first : nil),
                   let cost = AgentPricing.cost(event.tokens, model: model) {
                    bucket.cost[session.kind, default: 0] += cost
                }
                burn[hour] = bucket
            }
            if session.lastEventAt == nil { session.lastEventAt = file.mtime }
            if session.startedAt == nil { session.startedAt = file.mtime }
            // Advance only past bytes actually parsed: never into a partial
            // trailing line, never past bytes appended after the size was read.
            let end = tail.base + Int64(consumed)
            newOffsets[path] = end
            newIdentities[path] = id
            // Growth means new complete lines; a stuck partial line isn't
            // activity, nor is a restarted file that only repeated old lines.
            if let old = offsets[path], old > 0,
               cutoff != nil ? counted : (rotated ? end > 0 : end > old) { grew.insert(path) }
            if cutoff == nil { modelTokens = tracker?.takeModelTokens(file: path) ?? [:] }
            applyPricing(modelTokens: tracker == nil ? nil : modelTokens, into: &session)
            sessions[path] = session
        }
        // Sessions whose files vanished stay listed but can no longer grow.
        var all = sessions.values.filter {
            // Generic-fallback files that never yielded a token, model, or
            // tool are index/log noise (history.jsonl, session_index.jsonl),
            // not sessions.
            !($0.kind == .other && $0.tokens.total == 0 && $0.models.isEmpty && $0.tools.isEmpty)
        }
        let live = processes ?? Self.liveProcesses()
        let livePids = Set(live.map(\.pid))
        let names = Self.processNames
        var pidsByKind: [AgentKind: [AgentProcess]] = [:]
        for proc in live {
            for (kind, tokens) in names where tokens.contains(where: { proc.matches($0) }) {
                pidsByKind[kind, default: []].append(proc)
            }
        }
        // Most recent first, so a contested process goes to the session that
        // was active last.
        all.sort { ($0.lastEventAt ?? .distantPast) > ($1.lastEventAt ?? .distantPast) }
        assignProcesses(to: &all, candidates: pidsByKind, now: now)
        for i in all.indices {
            all[i].health = health(of: all[i], kindAlive: pidsByKind[all[i].kind] != nil,
                                   grew: grew.contains(all[i].filePath), now: now, livePids: livePids)
        }
        let persisted = Array(all.prefix(Self.persistLimit))
        var snapshot = AgentSnapshot()
        snapshot.sessions = Array(all.prefix(Self.sessionLimit))
        snapshot.roots = roots
        snapshot.scannedAt = now
        snapshot.processCounts = pidsByKind.mapValues(\.count)
        for session in all where Calendar.current.isDateInToday(session.lastEventAt ?? .distantPast) {
            snapshot.todayTokens += session.tokens
            if let cost = session.costUSD { snapshot.todayCostUSD = (snapshot.todayCostUSD ?? 0) + cost }
            snapshot.unpricedTokensToday += session.unpricedTokens
        }
        // Drop state for files that no longer exist so the dicts stay bounded.
        let alive = Set(candidates.map(\.file.path))
        newOffsets = newOffsets.filter { alive.contains($0.key) || known.contains($0.key) }
        newIdentities = newIdentities.filter { newOffsets[$0.key] != nil }
        return AgentScanResult(snapshot: snapshot, sessions: persisted, offsets: newOffsets,
                               identities: newIdentities, usage: burn.values.sorted { $0.hour < $1.hour })
    }

    /// Epoch-truncated hour — deterministic across timezones and identical
    /// to the `agent_usage` bucket key in HistoryStore.
    static func hourBucket(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    static func newSession(file: URL, provider: AgentProvider) -> AgentSession {
        let kind = provider is GenericProvider ? .other : provider.kind
        let base = file.deletingPathExtension().lastPathComponent
        let sessionId = kind == .codex ? CodexProvider.sessionID(fromFile: file) : base
        return AgentSession(kind: kind, sessionId: sessionId, projectDir: "", filePath: file.standardizedFileURL.path)
    }

    static func projectGuess(file: URL, provider: AgentProvider) -> String? {
        // Claude stores sessions under projects/<escaped cwd>/ — '/' became '-'.
        if provider is ClaudeCodeProvider {
            let dir = file.deletingLastPathComponent().lastPathComponent
            guard dir.hasPrefix("-") else { return nil }
            return String(dir.dropFirst()).split(separator: "-").isEmpty ? nil
                : "/" + String(dir.dropFirst()).replacingOccurrences(of: "-", with: "/")
        }
        return nil
    }

    /// `modelTokens` is the per-model usage this scan added for providers
    /// that track it (`ModelTokenTracking`), nil for the rest.
    private func applyPricing(modelTokens: [String: TokenUsage]?, into session: inout AgentSession) {
        guard var deltas = modelTokens else {
            // Untracked providers can't attribute tokens to a priced model.
            if session.tokens.total > 0 && session.costUSD == nil {
                if let model = session.models.count == 1 ? session.models.first! : nil,
                   let cost = AgentPricing.cost(session.tokens, model: model) {
                    session.costUSD = cost
                } else {
                    session.unpricedTokens = session.tokens.total
                }
            }
            return
        }
        // Usage recorded before the model was known lands under ""; when the
        // session settled on exactly one model, attribute it there.
        if let orphan = deltas.removeValue(forKey: ""), orphan.total > 0 {
            let key = session.models.count == 1 ? session.models.first! : ""
            deltas[key, default: TokenUsage()] += orphan
        }
        var cost = session.costUSD
        for (model, usage) in deltas {
            if let c = AgentPricing.cost(usage, model: model) {
                cost = (cost ?? 0) + c
            } else {
                session.unpricedTokens += usage.total
            }
        }
        session.costUSD = cost
    }

    /// `ps -eo pid=,args=` — cheap, no shell needed beyond the binary itself.
    public static func liveProcesses() -> [AgentProcess] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ps")
        process.arguments = ["-eo", "pid=,args="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let fields = line.drop(while: { $0 == " " }).split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let pid = Int32(fields[0]) else { return nil }
            return AgentProcess(pid: pid, args: String(fields[1]))
        }
    }

    static let processNames: [AgentKind: Set<String>] = [
        .claude: ["claude"], .codex: ["codex"], .openclaw: ["openclaw"],
        .devin: ["devin"], .gemini: ["gemini"], .aider: ["aider"],
        .goose: ["goose"], .opencode: ["opencode"], .amp: ["amp"],
        .cursor: ["cursor"], .windsurf: ["windsurf"],
    ]

    private func health(of session: AgentSession, kindAlive: Bool, grew: Bool, now: Date, livePids: Set<Int32>) -> SessionHealth {
        let fresh = (session.lastEventAt ?? .distantPast).timeIntervalSince(now) > -Self.staleAfter
        if let pid = session.pid, livePids.contains(pid) {
            return fresh ? .live : .stuck
        }
        // A transcript writing right now implies its process is alive even when
        // the args didn't correlate to a project dir.
        if session.pid == nil && kindAlive && fresh { return .live }
        return grew ? .zombie : .ended
    }

    /// Args containing the project dir is the strong correlation; a sole
    /// candidate is only attributed to sessions that were recently active —
    /// otherwise every stale transcript would borrow whatever process is up.
    /// A process backs at most one session: `sessions` arrive most recent
    /// first, project-dir matches are settled before sole-candidate guesses,
    /// and a session whose process is already taken gets no pid (its health
    /// then follows the pid-less rules). Otherwise two sessions in one
    /// project (e.g. after /clear) would both claim one `claude` process and
    /// its footprint would be counted twice.
    func assignProcesses(to sessions: inout [AgentSession], candidates: [AgentKind: [AgentProcess]], now: Date) {
        var taken: Set<Int32> = []
        var settled: Set<Int> = []
        for i in sessions.indices {
            sessions[i].pid = nil
            let dir = sessions[i].projectDir
            guard !dir.isEmpty,
                  let match = (candidates[sessions[i].kind] ?? []).first(where: { proc in
                      !taken.contains(proc.pid) && proc.args.split(separator: " ").contains {
                          $0 == Substring(dir) || $0.hasPrefix(dir + "/")
                      }
                  }) else { continue }
            sessions[i].pid = match.pid
            taken.insert(match.pid)
            settled.insert(i)
        }
        for i in sessions.indices where !settled.contains(i) {
            let kindCandidates = candidates[sessions[i].kind] ?? []
            let recent = sessions[i].lastEventAt.map { now.timeIntervalSince($0) < Self.staleAfter } ?? false
            guard kindCandidates.count == 1, recent, taken.insert(kindCandidates[0].pid).inserted else { continue }
            sessions[i].pid = kindCandidates[0].pid
        }
    }

    /// `base` is the file offset of `data`'s first byte; nil when the read
    /// failed. A capped read starts one byte early so a line beginning exactly
    /// at the cap boundary isn't mistaken for a partial one and skipped.
    static func readTail(_ handle: FileHandle, from offset: Int64, skipPartialLine: Bool) -> (data: Data, base: Int64)? {
        let from = skipPartialLine ? max(0, offset - 1) : offset
        do { try handle.seek(toOffset: UInt64(from)) } catch { return nil }
        guard var data = try? handle.readToEnd() ?? Data() else { return nil }
        var base = from
        if skipPartialLine, let newline = data.firstIndex(of: 0x0A) {
            base += Int64(newline - data.startIndex + 1)
            data = data.subdata(in: data.index(after: newline)..<data.endIndex)
        }
        return (data, base)
    }

    /// Bytes through the last newline; an unterminated tail counts only when
    /// it is already a complete JSON object (a prefix of an object never is).
    static func consumableLength(_ data: Data) -> Int {
        let tail = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
        let rest = data[tail...]
        if !rest.isEmpty, (try? JSONSerialization.jsonObject(with: rest)) is [String: Any] { return data.count }
        return tail - data.startIndex
    }

    static func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            if newline > start { lines.append(data.subdata(in: start..<newline)) }
            start = data.index(after: newline)
        }
        if start < data.endIndex { lines.append(data.subdata(in: start..<data.endIndex)) }
        return lines
    }
}

private extension AgentProcess {
    /// True when any argument token's basename equals the agent's binary name —
    /// covers `node /opt/bin/claude` style launches as well as direct execs.
    func matches(_ name: String) -> Bool {
        args.split(separator: " ").contains { token in
            var t = token
            while t.hasPrefix("\"") || t.hasPrefix("'") { t = t.dropFirst() }
            while t.hasSuffix("\"") || t.hasSuffix("'") { t = t.dropLast() }
            return t.split(separator: "/").last == Substring(name)
        }
    }
}

struct DiscoveredFile {
    /// Standardized path — the key for sessions, offsets and identities.
    var path: String
    var mtime: Date
    var size: Int64
    var id: AgentFileID
    /// Levels below the walk's base (1 = directly inside it).
    var depth = 0
}

/// Finds .jsonl transcripts under the watched roots and provider trees
/// without re-listing quiet directories: a directory is re-read only when its
/// mtime moved (adding, removing or renaming an entry updates it), plus a
/// full re-listing every few minutes as a safety net. Every listed file is
/// still stat'ed each pass, so growth anywhere is seen immediately. Same depth
/// and hidden-file rules as `jsonlFiles(under:depth:)`. Confined to the
/// scanner's queue.
final class TranscriptDiscovery {
    var rediscoverEvery: TimeInterval = 300
    /// A listing taken within this window of the directory's own mtime isn't
    /// trusted: a change in the same timestamp tick would be invisible.
    static let racyWindow: TimeInterval = 2
    /// Directories read from disk so far; tests use it to observe the cache.
    private(set) var listings = 0

    private struct Listing {
        var mtime: timespec
        var trusted: Bool
        var files: [String]
        var dirs: [String]
    }
    private var cache: [String: Listing] = [:]
    private var lastFull: TimeInterval?

    /// Standardized form of a watched path, the prefix of every key under it.
    static func base(_ path: String) -> String {
        URL(fileURLWithPath: expandAgentPath(path), isDirectory: true).standardizedFileURL.path
    }

    static func file(at path: String) -> DiscoveredFile? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let mtime = info.st_mtimespec
        return DiscoveredFile(path: path, mtime: Date(timeIntervalSince1970: Double(mtime.tv_sec) + Double(mtime.tv_nsec) / 1e9),
                              size: Int64(info.st_size), id: AgentFileID(info))
    }

    /// One file list per walk, in order. Walks may overlap: listings and
    /// stats are shared within a pass. `changed` is true when any
    /// directory's entries differ from the last pass (or on the periodic full
    /// re-listing).
    func discover(_ walks: [(path: String, depth: Int)]) -> (files: [[DiscoveredFile]], changed: Bool) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let full = lastFull.map { uptime - $0 >= rediscoverEvery } ?? true
        if full { lastFull = uptime }
        var pass = Pass(full: full, changed: full)
        let result = walks.map { walk -> [DiscoveredFile] in
            var files: [DiscoveredFile] = []
            var visited: Set<String> = []
            if walk.depth > 0 {
                self.walk(Self.base(walk.path), level: 0, depth: walk.depth, pass: &pass, visited: &visited, files: &files)
            }
            return files
        }
        let before = cache.count
        cache = cache.filter { pass.seen.contains($0.key) }
        if cache.count != before { pass.changed = true }
        return (result, pass.changed)
    }

    private struct Pass {
        var full: Bool
        var changed: Bool
        var seen: Set<String> = []
        var relisted: Set<String> = []
        /// Stat results per directory, for walks that overlap.
        var statted: [String: [DiscoveredFile]] = [:]
    }

    private func walk(_ dir: String, level: Int, depth: Int, pass: inout Pass,
                      visited: inout Set<String>, files: inout [DiscoveredFile]) {
        guard visited.insert(dir).inserted else { return }
        pass.seen.insert(dir)
        var info = stat()
        // Stat before listing: an entry added after the stat moves the mtime
        // again, so the next pass re-lists.
        guard stat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        let listing: Listing
        if let cached = cache[dir], pass.relisted.contains(dir)
            || (!pass.full && cached.trusted
                && cached.mtime.tv_sec == info.st_mtimespec.tv_sec && cached.mtime.tv_nsec == info.st_mtimespec.tv_nsec) {
            listing = cached
        } else {
            guard let fresh = list(dir, mtime: info.st_mtimespec) else { cache[dir] = nil; return }
            if cache[dir]?.files != fresh.files || cache[dir]?.dirs != fresh.dirs { pass.changed = true }
            cache[dir] = fresh
            pass.relisted.insert(dir)
            listing = fresh
        }
        let entries = pass.statted[dir] ?? listing.files.compactMap(Self.file(at:))
        pass.statted[dir] = entries
        for var file in entries {
            file.depth = level + 1
            files.append(file)
        }
        // Entries of a directory at `level` sit at level + 1; like the
        // enumerator, files count up to `depth` and directories at `depth`
        // aren't descended.
        guard level + 1 < depth else { return }
        for sub in listing.dirs {
            walk(sub, level: level + 1, depth: depth, pass: &pass, visited: &visited, files: &files)
        }
    }
    /// Full paths of visible .jsonl entries and subdirectories. Symlinked
    /// directories aren't followed (enumerator parity).
    private func list(_ dir: String, mtime: timespec) -> Listing? {
        guard let handle = opendir(dir) else { return nil }
        defer { closedir(handle) }
        listings += 1
        var files: [String] = [], dirs: [String] = []
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard !name.hasPrefix(".") else { continue }
            let path = prefix + name
            var isDir = Int32(entry.pointee.d_type) == DT_DIR
            if Int32(entry.pointee.d_type) == DT_UNKNOWN {
                var info = stat()
                isDir = lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            }
            if isDir { dirs.append(path) } else if name.hasSuffix(".jsonl") { files.append(path) }
        }
        files.sort(); dirs.sort()
        let age = Date().timeIntervalSince1970 - (Double(mtime.tv_sec) + Double(mtime.tv_nsec) / 1e9)
        return Listing(mtime: mtime, trusted: age > Self.racyWindow, files: files, dirs: dirs)
    }
}
