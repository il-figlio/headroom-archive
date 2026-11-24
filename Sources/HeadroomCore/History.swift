import Foundation
import CSQLite

public struct ObservedApp: Codable {
    public let key: String
    public let name: String
    public let session: String
    public let bytes: UInt64
    public let partial: Bool
    public init(key: String, name: String, session: String, bytes: UInt64, partial: Bool = false) {
        self.key = key; self.name = name; self.session = session; self.bytes = bytes; self.partial = partial
    }
    public static func from(_ apps: [AppMemory]) -> [ObservedApp] {
        apps.compactMap { row in
            guard let bytes = row.bytes else { return nil }
            return ObservedApp(key: row.app.bundleIdentifier ?? row.app.name, name: row.app.name,
                               session: "\(row.app.pid):\(row.app.launchDate?.timeIntervalSince1970 ?? 0)",
                               bytes: bytes, partial: row.unreadableCount > 0)
        }
    }
}

public struct Recommendation: Identifiable {
    public let title: String
    public let detail: String
    public var id: String { title }
}
public struct TrendPoint: Identifiable {
    public let date: Date
    public let usedGB: Double
    public let swapGB: Double
    public var id: Date { date }
}
public struct AppTrend {
    public let name: String
    public var first: ObservedApp
    public var latest: ObservedApp
    public var firstAt: Date
    public var latestAt: Date
    public var peak: UInt64
    public var count: Int
}
public struct TrendSummary {
    public var sampleCount = 0
    public var observedMinutes: Double = 0
    public var pressuredMinutes: Double = 0
    public var peakSwap: UInt64 = 0
    public var swapChange: Int64 = 0
    public var latestAt: Date?
    public var latestPressure: Pressure = .unknown
    public var latestApps: [ObservedApp] = []
    public var appTrends: [AppTrend] = []
    public var points: [TrendPoint] = []
    public var diskPoints: [DiskPoint] = []
    public var latestDiskFree: UInt64?
    public var latestDiskPurgeable: UInt64?
    public var latestDiskTotal: UInt64?
    public var diskRateGBPerDay: Double?
    public var daysUntilFull: Double?
    public var consumers = ConsumerScan()
    public var recommendations: [Recommendation] = []
    public var pressuredFraction: Double { observedMinutes > 0 ? pressuredMinutes / observedMinutes : 0 }
    public init() {}
}

public enum TrendAdvice {
    public static func recommend(_ summary: TrendSummary) -> [Recommendation] {
        var result: [Recommendation] = []
        let pressured = summary.latestPressure == .warning || summary.latestPressure == .critical
        if pressured {
            let largest = summary.latestApps.filter { !$0.partial && $0.key != "com.apple.finder" }.max { $0.bytes < $1.bytes }
            result.append(.init(title: "Reduce current memory pressure",
                                detail: largest.map { "\($0.name) is the largest measured app at \(MemoryFormat.string($0.bytes)). If you aren't using it, save your work and quit it. Otherwise close unneeded tabs, windows, or active tasks." }
                                ?? "Save your work and close an app or task you no longer need. Pressure is \(summary.latestPressure.title.lowercased())."))
        }
        let growth = summary.appTrends.filter {
            !$0.first.partial && !$0.latest.partial && $0.latest.session == $0.first.session &&
            $0.count >= 4 && $0.latestAt.timeIntervalSince($0.firstAt) >= 15 * 60 &&
            $0.latest.bytes > $0.first.bytes && $0.latest.bytes - $0.first.bytes >= 1_073_741_824 &&
            Double($0.latest.bytes) >= Double($0.first.bytes) * 1.5
        }.sorted { ($0.latest.bytes - $0.first.bytes) > ($1.latest.bytes - $1.first.bytes) }.first
        if let growth {
            result.append(.init(title: "Watch \(growth.name)'s growth",
                                detail: "Its measured footprint grew by \(MemoryFormat.string(growth.latest.bytes - growth.first.bytes)) in \(Int(growth.latestAt.timeIntervalSince(growth.firstAt) / 60)) minutes during the same app session. Check active tasks; if growth continues, save and restart the app. Growth alone doesn't prove a leak."))
        }
        if summary.observedMinutes >= 30 && summary.pressuredFraction >= 0.25 {
            result.append(.init(title: "Reduce the apps running together",
                                detail: "Pressure was elevated or critical for \(Int(summary.pressuredMinutes.rounded())) of \(Int(summary.observedMinutes.rounded())) observed minutes in the last 24 hours. Try fewer simultaneous browser and AI tasks. If this repeats over several days during normal work, more RAM may fit your workload."))
        }
        if pressured && summary.observedMinutes >= 20 && summary.swapChange >= 536_870_912 {
            result.append(.init(title: "Watch the increase in swap",
                                detail: "Swap increased by \(MemoryFormat.string(UInt64(summary.swapChange))) across this observation window. Reduce active memory demand and check whether pressure recovers. Swap can stay allocated after pressure improves."))
        }
        if result.isEmpty && summary.latestDiskFree == nil {
            result.append(.init(title: summary.observedMinutes < 15 ? "Building your baseline" : "No action suggested",
                                detail: summary.observedMinutes < 15 ? "Let Headroom observe your usual workflow for at least 15 minutes. Recommendations will use your measured pressure and app trends." : "The recorded window doesn't show sustained pressure or qualifying app growth. Keep your current workflow and review again if pressure rises."))
        }
        return Array(result.prefix(5))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private enum SQLValue { case text(String), number(Double), integer(Int64), null }
private struct HistoryError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

/// Confined to the monitor's utility queue. No process paths or window titles are stored.
public final class HistoryStore {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Headroom", isDirectory: true)
    }
    public let directory: URL
    public var logURL: URL { directory.appendingPathComponent("log.md") }
    /// record() rewrites log.md at most this often; refreshLog() writes on demand.
    public static let logInterval: TimeInterval = 15 * 60
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// nil until this store writes log.md, so the first record() after opening writes it.
    private var lastLogAt: Date?
    private var sampleCache: SampleCache?
    private var consumerCache: ConsumerScan?
    private var dataVersion: Int64?

    public init(directory: URL = HistoryStore.defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try open()
    }
    deinit { sqlite3_close(db) }
    private func open() throws {
        guard sqlite3_open_v2(directory.appendingPathComponent("history.sqlite").path, &db,
                             SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw HistoryError(detail: "Couldn't open Headroom history.")
        }
        sqlite3_busy_timeout(db, 1000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("CREATE TABLE IF NOT EXISTS samples (ts REAL PRIMARY KEY, used REAL, total REAL, compressed REAL, swap REAL, pressure INTEGER, apps TEXT, disk_free REAL, disk_purgeable REAL, disk_total REAL)")
        try execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, ts REAL, kind TEXT, app TEXT, detail TEXT)")
        try execute("CREATE INDEX IF NOT EXISTS events_time ON events(ts)")
        try migrate()
        try execute("CREATE TABLE IF NOT EXISTS consumer_sizes (path TEXT PRIMARY KEY, name TEXT, bytes REAL, prev_bytes REAL, scanned_at REAL, prev_scanned_at REAL, partial INTEGER)")
        try execute("CREATE TABLE IF NOT EXISTS consumer_meta (key TEXT PRIMARY KEY, value REAL)")
        // Schema 2: agent session tracking, keyed by transcript file.
        try execute("CREATE TABLE IF NOT EXISTS agent_sessions (\(Self.agentSessionColumns))")
        try execute("CREATE TABLE IF NOT EXISTS agent_scan_meta (key TEXT PRIMARY KEY, value TEXT)")
        // Schema 1: hourly token burn per agent family; rows accumulate.
        try execute("CREATE TABLE IF NOT EXISTS agent_usage (hour REAL, kind TEXT, tokens INTEGER, cost_usd REAL, PRIMARY KEY(hour, kind))")
        try migrateAgentSessions()
        try execute("PRAGMA user_version=2")
    }
    /// Databases written before storage tracking lack the disk columns.
    private func migrate() throws {
        let stmt = try statement("PRAGMA table_info(samples)")
        defer { sqlite3_finalize(stmt) }
        var hasDisk = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if text(stmt, 1) == "disk_free" { hasDisk = true }
        }
        if !hasDisk {
            try execute("ALTER TABLE samples ADD COLUMN disk_free REAL")
            try execute("ALTER TABLE samples ADD COLUMN disk_purgeable REAL")
            try execute("ALTER TABLE samples ADD COLUMN disk_total REAL")
        }
    }
    private func statement(_ sql: String, _ values: [SQLValue] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let status: Int32
            switch value {
            case .text(let text): status = sqlite3_bind_text(stmt, index, text, -1, sqliteTransient)
            case .number(let number): status = sqlite3_bind_double(stmt, index, number)
            case .integer(let integer): status = sqlite3_bind_int64(stmt, index, integer)
            case .null: status = sqlite3_bind_null(stmt, index)
            }
            if status != SQLITE_OK { sqlite3_finalize(stmt); throw error() }
        }
        return stmt
    }
    private func error() -> HistoryError { HistoryError(detail: db.map { String(cString: sqlite3_errmsg($0)) } ?? "History is unavailable.") }
    private func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW { status = sqlite3_step(stmt) }
        guard status == SQLITE_DONE else { throw error() }
    }
    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    @discardableResult
    public func record(memory: SystemMemory, apps: [ObservedApp], disk: DiskSpace? = nil, at date: Date = Date()) throws -> TrendSummary {
        guard memory.valid else { return try summary(now: date) }
        // When the disk is nearly full, history itself must not make it worse.
        if Self.diskTooFull(disk) { return try summary(now: date) }
        let previous = try statement("SELECT pressure FROM samples ORDER BY ts DESC LIMIT 1")
        let oldPressure = sqlite3_step(previous) == SQLITE_ROW ? Pressure.fromKernel(Int(sqlite3_column_int(previous, 0))) : .unknown
        sqlite3_finalize(previous)
        let json = String(decoding: try encoder.encode(apps), as: UTF8.self)
        // Rows newer than the cache's range are fetched later; an insert inside it is rare.
        if let cache = sampleCache, date.timeIntervalSince1970 <= cache.hi { sampleCache = nil }
        try execute("INSERT OR REPLACE INTO samples VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [.number(date.timeIntervalSince1970), .number(Double(memory.used)), .number(Double(memory.total)),
                     .number(Double(memory.compressed)), .number(Double(memory.swap)), .number(Double(memory.pressure.rawValue)), .text(json),
                     disk?.valid == true ? .number(Double(disk!.free)) : .null,
                     disk?.valid == true ? .number(Double(disk!.purgeable)) : .null,
                     disk?.valid == true ? .number(Double(disk!.total)) : .null])
        if oldPressure != .unknown && oldPressure != memory.pressure {
            try execute("INSERT INTO events(ts, kind, app, detail) VALUES (?, ?, ?, ?)",
                        [.number(date.timeIntervalSince1970), .text("pressure-change"), .text("System"),
                         .text("\(oldPressure.title) → \(memory.pressure.title)")])
        }
        let cutoff = date.addingTimeInterval(-30 * 86400).timeIntervalSince1970
        try execute("DELETE FROM samples WHERE ts < ?", [.number(cutoff)])
        sampleCache?.rows.removeAll { $0.ts < cutoff }
        try execute("DELETE FROM events WHERE ts < ?", [.number(cutoff)])
        let summary = try self.summary(now: date)
        if logDue(at: date) { try writeLog(summary: summary, now: date) }
        return summary
    }
    /// Events are user actions (quit requests and outcomes); the report shows them right away.
    public func event(kind: String, app: String, detail: String, at date: Date = Date()) throws {
        try execute("INSERT INTO events(ts, kind, app, detail) VALUES (?, ?, ?, ?)",
                    [.number(date.timeIntervalSince1970), .text(kind), .text(app), .text(detail)])
        try writeLog(summary: summary(now: date), now: date)
    }
    /// Rewrites log.md now, e.g. before showing it to the user.
    public func refreshLog(now: Date = Date()) throws {
        try writeLog(summary: summary(now: now), now: now)
    }
    private func logDue(at date: Date) -> Bool {
        guard let lastLogAt else { return true }
        let elapsed = date.timeIntervalSince(lastLogAt)
        return elapsed >= Self.logInterval || elapsed < 0
    }
    public func summary(now: Date = Date()) throws -> TrendSummary {
        var result = TrendSummary()
        let start = now.addingTimeInterval(-86400)
        let rows = try windowRows(from: start.addingTimeInterval(-90).timeIntervalSince1970, through: now.timeIntervalSince1970, start: start)
        var previous: (Date, Pressure)?
        var trends: [String: AppTrend] = [:]
        var firstSwap: UInt64?
        var lastChart = Date.distantPast
        var latestChartPoint: TrendPoint?
        var latestDiskPoint: DiskPoint?
        var firstDisk: (date: Date, free: UInt64)?
        func addDuration(until date: Date) {
            guard let (time, pressure) = previous, pressure != .unknown else { return }
            // Sleep and downtime aren't observed intervals.
            guard date.timeIntervalSince(time) <= 90 else { return }
            let seconds = max(0, date.timeIntervalSince(max(time, start)))
            result.observedMinutes += seconds / 60
            if pressure == .warning || pressure == .critical { result.pressuredMinutes += seconds / 60 }
        }
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ts)
            let pressure = Pressure.fromKernel(Int(row.pressure))
            addDuration(until: date)
            previous = (date, pressure)
            guard date >= start else { continue }
            result.sampleCount += 1; result.latestAt = date; result.latestPressure = pressure
            let swap = UInt64(max(0, row.swap))
            if firstSwap == nil { firstSwap = swap }
            result.swapChange = Int64(swap) - Int64(firstSwap ?? swap)
            result.peakSwap = max(result.peakSwap, swap)
            guard let apps = row.apps else { sampleCache = nil; throw HistoryError(detail: "History cache is inconsistent.") }
            result.latestApps = apps
            let chartPoint = TrendPoint(date: date, usedGB: row.used / 1_073_741_824,
                                        swapGB: Double(swap) / 1_073_741_824)
            latestChartPoint = chartPoint
            var diskPoint: DiskPoint?
            if let rawFree = row.diskFree {
                let free = UInt64(max(0, rawFree))
                let purgeable = UInt64(max(0, row.diskPurgeable))
                diskPoint = DiskPoint(date: date, freeGB: Double(free) / 1_073_741_824,
                                      purgeableGB: Double(purgeable) / 1_073_741_824)
                latestDiskPoint = diskPoint
                result.latestDiskFree = free
                result.latestDiskPurgeable = purgeable
                result.latestDiskTotal = UInt64(max(0, row.diskTotal))
                if firstDisk == nil { firstDisk = (date, free) }
            }
            for app in apps {
                // Updated in place: this loop runs for every app in every sample of the day.
                if let i = trends.index(forKey: app.key) {
                    if trends.values[i].latest.session == app.session, date.timeIntervalSince(trends.values[i].latestAt) <= 120 {
                        trends.values[i].latest = app; trends.values[i].latestAt = date
                        trends.values[i].peak = max(trends.values[i].peak, app.bytes); trends.values[i].count += 1
                    } else {
                        trends.values[i] = AppTrend(name: app.name, first: app, latest: app, firstAt: date, latestAt: date, peak: app.bytes, count: 1)
                    }
                } else {
                    trends[app.key] = AppTrend(name: app.name, first: app, latest: app, firstAt: date, latestAt: date, peak: app.bytes, count: 1)
                }
            }
            // At most 289 chart points for a day, with the final reading included below.
            if date.timeIntervalSince(lastChart) >= 300 {
                result.points.append(chartPoint)
                if let diskPoint { result.diskPoints.append(diskPoint) }
                lastChart = date
            }
        }
        if let latestChartPoint, result.points.last?.date != latestChartPoint.date {
            result.points.append(latestChartPoint)
            if let latestDiskPoint, result.diskPoints.last?.date != latestDiskPoint.date {
                result.diskPoints.append(latestDiskPoint)
            }
        }
        // Free-space shrink rate drives the days-until-full estimate.
        if let firstDisk, let latestDiskPoint, let free = result.latestDiskFree {
            let hours = latestDiskPoint.date.timeIntervalSince(firstDisk.date) / 3600
            if hours >= 1 {
                let shrinkGB = (Double(firstDisk.free) - Double(free)) / 1_073_741_824
                result.diskRateGBPerDay = shrinkGB / hours * 24
                if result.diskRateGBPerDay! > 0.01 {
                    result.daysUntilFull = Double(free) / 1_073_741_824 / result.diskRateGBPerDay!
                }
            }
        }
        // Don't recommend growth for an app absent from the current snapshot.
        let current = Set(result.latestApps.map(\.key))
        result.appTrends = trends.values.filter { current.contains($0.latest.key) }.sorted { $0.peak > $1.peak }
        result.consumers = (try? loadConsumers()) ?? ConsumerScan()
        // Urgent disk advice comes first; routine memory advice follows.
        result.recommendations = Array((DiskAdvice.recommend(result) + TrendAdvice.recommend(result)).prefix(5))
        if let latest = result.latestAt, now.timeIntervalSince(latest) > 180 {
            result.recommendations = [.init(title: "History hasn't updated recently", detail: "The latest recorded sample is more than three minutes old. Resume history or reopen Headroom to get recommendations for your current workload.")]
        }
        return result
    }

    public func loadConsumers() throws -> ConsumerScan {
        try syncWithOtherWriters()
        if let consumerCache { return consumerCache }
        var scan = ConsumerScan()
        let stmt = try statement("SELECT path, name, bytes, prev_bytes, scanned_at, partial FROM consumer_sizes ORDER BY bytes DESC")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let previous = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : UInt64(max(0, sqlite3_column_double(stmt, 3)))
            let scannedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            scan.items.append(DiskConsumer(path: text(stmt, 0), name: text(stmt, 1),
                                           bytes: UInt64(max(0, sqlite3_column_double(stmt, 2))),
                                           previousBytes: previous, scannedAt: scannedAt,
                                           partial: sqlite3_column_int(stmt, 5) != 0))
        }
        let meta = try statement("SELECT key, value FROM consumer_meta")
        defer { sqlite3_finalize(meta) }
        while sqlite3_step(meta) == SQLITE_ROW {
            switch text(meta, 0) {
            case "last_scan_at": scan.scannedAt = Date(timeIntervalSince1970: sqlite3_column_double(meta, 1))
            case "local_snapshots": scan.localSnapshots = Int(sqlite3_column_double(meta, 1))
            default: break
            }
        }
        consumerCache = scan
        return scan
    }

    /// Replaces the consumer table, keeping the previous scan's sizes for growth deltas.
    public func saveConsumers(_ items: [DiskConsumer], localSnapshots: Int, at date: Date = Date()) throws {
        let previous = Dictionary(try loadConsumers().items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // Reload after the swap (or a failed one); the next record() also rewrites the report.
        defer { consumerCache = nil; lastLogAt = nil }
        try execute("BEGIN")
        do {
            try execute("DELETE FROM consumer_sizes")
            for item in items {
                let prev = previous[item.path]
                try execute("INSERT INTO consumer_sizes VALUES (?, ?, ?, ?, ?, ?, ?)",
                            [.text(item.path), .text(item.name), .number(Double(item.bytes)),
                             prev.map { .number(Double($0.bytes)) } ?? .null,
                             .number(date.timeIntervalSince1970),
                             prev?.scannedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                             .number(item.partial ? 1 : 0)])
            }
            try execute("INSERT OR REPLACE INTO consumer_meta VALUES ('last_scan_at', ?)", [.number(date.timeIntervalSince1970)])
            try execute("INSERT OR REPLACE INTO consumer_meta VALUES ('local_snapshots', ?)", [.number(Double(localSnapshots))])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Same columns, in the same order, as schema 1 so older builds' positional
    /// INSERTs still fit; only the key moved from `id` (kind:sessionId, which
    /// two transcripts can share) to the transcript path the scanner keys by.
    private static let agentSessionColumns = "id TEXT, kind TEXT, session_id TEXT, project_dir TEXT, pid INTEGER, started_at REAL, last_event_at REAL, file_path TEXT PRIMARY KEY, file_offset INTEGER, models_json TEXT, tokens_json TEXT, tools_json TEXT, cost_usd REAL, unpriced_tokens INTEGER, health TEXT"

    /// Schema 1 → 2: rebuild agent_sessions keyed by file_path, keeping the
    /// most recently active row per file. Checks the live key rather than
    /// user_version, because older builds reset user_version to 1.
    private func migrateAgentSessions() throws {
        let info = try statement("PRAGMA table_info(agent_sessions)")
        var keyedByPath = false
        while sqlite3_step(info) == SQLITE_ROW {
            if text(info, 1) == "file_path" && sqlite3_column_int(info, 5) > 0 { keyedByPath = true }
        }
        sqlite3_finalize(info)
        guard !keyedByPath else { return }
        let columns = "id, kind, session_id, project_dir, pid, started_at, last_event_at, file_path, file_offset, models_json, tokens_json, tools_json, cost_usd, unpriced_tokens, health"
        try agentTransaction {
            try execute("DROP TABLE IF EXISTS agent_sessions_v2")
            try execute("CREATE TABLE agent_sessions_v2 (\(Self.agentSessionColumns))")
            // NULLs sort last descending, so a dated row wins its file_path.
            try execute("INSERT OR IGNORE INTO agent_sessions_v2 (\(columns)) SELECT \(columns) FROM agent_sessions ORDER BY last_event_at DESC")
            try execute("DROP TABLE agent_sessions")
            try execute("ALTER TABLE agent_sessions_v2 RENAME TO agent_sessions")
        }
    }

    private func agentTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Replaces the agent session table wholesale — scans own the full list.
    public func saveAgentSessions(_ sessions: [AgentSession], offsets: [String: Int64] = [:]) throws {
        try agentTransaction { try writeAgentSessions(sessions, offsets: offsets) }
    }

    /// History stops writing below this much free space (512 MB).
    public static let minimumFreeBytes: UInt64 = 536_870_912
    static func diskTooFull(_ disk: DiskSpace?) -> Bool {
        guard let disk, disk.valid else { return false }
        return disk.free < minimumFreeBytes
    }

    /// Persists one scan's sessions, offsets/identities and newly parsed
    /// usage in a single transaction. On throw nothing changed: the caller
    /// must keep its previous sessions/offsets/identities and not merge the
    /// usage, so the next scan re-reads the same bytes and counts them once.
    /// A nearly full disk (`disk` below `minimumFreeBytes`) throws without
    /// writing, exactly like a failed commit — the bytes are re-read and
    /// counted once space returns, rather than parsed now and never saved.
    public func commitAgentScan(sessions: [AgentSession], offsets: [String: Int64],
                                identities: [String: AgentFileID], usage: [HourBurn],
                                disk: DiskSpace? = nil) throws {
        if Self.diskTooFull(disk) {
            throw HistoryError(detail: "Less than 512 MB free on disk; agent usage will be saved once space frees up.")
        }
        try agentTransaction {
            try writeAgentSessions(sessions, offsets: offsets)
            try writeScanOffsets(offsets, identities: identities)
            try writeAgentUsage(usage)
        }
    }

    private func writeAgentSessions(_ sessions: [AgentSession], offsets: [String: Int64]) throws {
        try execute("DELETE FROM agent_sessions")
        for session in sessions {
            let models = String(decoding: try encoder.encode(session.models.sorted()), as: UTF8.self)
            let tokens = String(decoding: try encoder.encode(session.tokens), as: UTF8.self)
            let tools = String(decoding: try encoder.encode(session.tools), as: UTF8.self)
            try execute("INSERT OR REPLACE INTO agent_sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        [.text(session.id), .text(session.kind.rawValue), .text(session.sessionId),
                         .text(session.projectDir),
                         session.pid.map { .number(Double($0)) } ?? .null,
                         session.startedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                         session.lastEventAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                         .text(session.filePath), .number(Double(offsets[session.filePath] ?? 0)),
                         .text(models), .text(tokens), .text(tools),
                         session.costUSD.map { .number($0) } ?? .null,
                         .number(Double(session.unpricedTokens)), .text(session.health.rawValue)])
        }
    }

    public func loadAgentSessions() throws -> [AgentSession] {
        let stmt = try statement("SELECT kind, session_id, project_dir, pid, started_at, last_event_at, file_path, models_json, tokens_json, tools_json, cost_usd, unpriced_tokens, health FROM agent_sessions")
        defer { sqlite3_finalize(stmt) }
        var sessions: [AgentSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kind = AgentKind(rawValue: text(stmt, 0)) else { continue }
            var session = AgentSession(kind: kind, sessionId: text(stmt, 1),
                                       projectDir: text(stmt, 2), filePath: text(stmt, 6))
            session.pid = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int32(sqlite3_column_int(stmt, 3))
            session.startedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            session.lastEventAt = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            session.models = Set((try? decoder.decode([String].self, from: Data(text(stmt, 7).utf8))) ?? [])
            session.tokens = (try? decoder.decode(TokenUsage.self, from: Data(text(stmt, 8).utf8))) ?? TokenUsage()
            session.tools = (try? decoder.decode([String: Int].self, from: Data(text(stmt, 9).utf8))) ?? [:]
            session.costUSD = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 10)
            session.unpricedTokens = sqlite3_column_int64(stmt, 11)
            session.health = SessionHealth(rawValue: text(stmt, 12)) ?? .ended
            sessions.append(session)
        }
        return sessions
    }

    /// File offsets for incremental transcript reads, stored as one JSON blob;
    /// identities (when given) go in a sibling row older builds ignore.
    public func saveScanOffsets(_ offsets: [String: Int64], identities: [String: AgentFileID]? = nil) throws {
        try writeScanOffsets(offsets, identities: identities)
    }

    private func writeScanOffsets(_ offsets: [String: Int64], identities: [String: AgentFileID]?) throws {
        let json = String(decoding: try encoder.encode(offsets), as: UTF8.self)
        try execute("INSERT OR REPLACE INTO agent_scan_meta VALUES ('offsets', ?)", [.text(json)])
        if let identities {
            let ids = String(decoding: try encoder.encode(identities), as: UTF8.self)
            try execute("INSERT OR REPLACE INTO agent_scan_meta VALUES ('identities', ?)", [.text(ids)])
        }
    }

    public func loadScanOffsets() throws -> [String: Int64] {
        try loadScanMeta("offsets", as: [String: Int64].self) ?? [:]
    }

    /// Empty for databases written before identities were tracked; the
    /// scanner then only detects replacement once a file is shorter.
    public func loadScanIdentities() throws -> [String: AgentFileID] {
        try loadScanMeta("identities", as: [String: AgentFileID].self) ?? [:]
    }

    private func loadScanMeta<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        let stmt = try statement("SELECT value FROM agent_scan_meta WHERE key = ?", [.text(key)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return try? decoder.decode(T.self, from: Data(text(stmt, 0).utf8))
    }

    /// Accumulates a scan's partial hourly buckets — each scan only carries
    /// newly parsed usage, so same-(hour, kind) rows add rather than replace.
    public func recordAgentUsage(_ burn: [HourBurn]) throws {
        guard !burn.isEmpty else { return }
        try agentTransaction { try writeAgentUsage(burn) }
    }

    private func writeAgentUsage(_ burn: [HourBurn]) throws {
        guard !burn.isEmpty else { return }
        for bucket in burn {
            for kind in Set(bucket.tokens.keys).union(bucket.cost.keys) {
                try execute("""
                    INSERT INTO agent_usage (hour, kind, tokens, cost_usd) VALUES (?, ?, ?, ?)
                    ON CONFLICT (hour, kind) DO UPDATE SET tokens = tokens + excluded.tokens, cost_usd = cost_usd + excluded.cost_usd
                    """,
                    [.number(bucket.hour.timeIntervalSince1970), .text(kind.rawValue),
                     .integer(bucket.tokens[kind] ?? 0), .number(bucket.cost[kind] ?? 0)])
            }
        }
        // Retention matches the samples window; readers only need 48h.
        try execute("DELETE FROM agent_usage WHERE hour < ?", [.number(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970)])
    }

    /// Raw SQL for tests (fault injection, legacy-schema fixtures); returns
    /// any result rows as text.
    @discardableResult
    func executeForTesting(_ sql: String) throws -> [[String]] {
        let stmt = try statement(sql); defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(stmt)).map { text(stmt, $0) })
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw error() }
        return rows
    }

    /// Hourly burn at or after `since`, ascending. `since` is truncated to
    /// its containing hour so a partially-elapsed boundary bucket is kept.
    /// Hours without usage are absent; kinds with no priced cost don't
    /// appear in `cost`.
    public func loadAgentUsage(since: Date) throws -> [HourBurn] {
        let cutoff = (since.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        let stmt = try statement("SELECT hour, kind, tokens, cost_usd FROM agent_usage WHERE hour >= ? ORDER BY hour",
                                 [.number(cutoff)])
        defer { sqlite3_finalize(stmt) }
        var burn: [HourBurn] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hour = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            guard let kind = AgentKind(rawValue: text(stmt, 1)) else { continue }
            // ORDER BY hour keeps one bucket's rows contiguous.
            if burn.last?.hour != hour { burn.append(HourBurn(hour: hour)) }
            let tokens = sqlite3_column_int64(stmt, 2)
            if tokens > 0 { burn[burn.count - 1].tokens[kind] = tokens }
            let cost = sqlite3_column_double(stmt, 3)
            if cost > 0 { burn[burn.count - 1].cost[kind] = cost }
        }
        return burn
    }

    public func writeLog(summary: TrendSummary, now: Date = Date()) throws {
        let dateFormatter = ISO8601DateFormatter()
        var lines = ["# Headroom observations", "", "Updated \(dateFormatter.string(from: now)). Times are UTC unless noted.", "",
                     "Local history, retained for 30 days. Samples are normally one minute apart; pressure changes may add a sample. App readings include helpers and can overlap in shared memory.", "",
                     "## Last 24 hours", "",
                     "- \(summary.sampleCount) samples; \(Int(summary.observedMinutes.rounded())) minutes actually observed.",
                     "- Elevated or critical pressure for \(Int(summary.pressuredMinutes.rounded())) observed minutes.",
                     "- Peak swap: \(MemoryFormat.string(summary.peakSwap)).",
                     "- Latest pressure: \(summary.latestPressure.title).", "", "## Recommendations", ""]
        for advice in summary.recommendations { lines += ["### \(advice.title)", "", advice.detail, ""] }
        if let free = summary.latestDiskFree, let total = summary.latestDiskTotal, total > 0 {
            lines += ["## Storage", ""]
            let used = total > free ? total - free : 0
            let purgeText = (summary.latestDiskPurgeable ?? 0) > 0 ? " · \(MemoryFormat.string(summary.latestDiskPurgeable!)) purgeable" : ""
            lines.append("- \(MemoryFormat.string(free)) free of \(MemoryFormat.string(total)) · \(Int(Double(used) / Double(total) * 100))% full\(purgeText).")
            if let rate = summary.diskRateGBPerDay, rate > 0.1 {
                var trend = "- Free space shrank by about \(MemoryFormat.perDay(gb: rate)) across the recorded window."
                if let days = summary.daysUntilFull { trend += " At that pace it runs out in about \(Int(days.rounded(.up))) day(s)." }
                lines.append(trend)
            } else if summary.diskRateGBPerDay != nil {
                lines.append("- Free space was flat or grew across the recorded window.")
            }
            let scan = summary.consumers
            if !scan.items.isEmpty {
                lines += ["", "### Largest consumers\(scan.scannedAt.map { " — scanned \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")", "",
                          "| Location | Size | Change |", "| --- | ---: | ---: |"]
                for item in scan.items.prefix(12) {
                    let change = item.delta.map { $0 > 0 ? "+\(MemoryFormat.string(UInt64($0)))" : ($0 < 0 ? "-\(MemoryFormat.string(UInt64(-$0)))" : "—") } ?? "first scan"
                    lines.append("| \(escape(item.name)) | \(MemoryFormat.string(item.bytes))\(item.partial ? " · partial" : "") | \(change) |")
                }
                let other = used > scan.totalBytes ? used - scan.totalBytes : 0
                if other > 0 { lines.append("| System & other volumes | \(MemoryFormat.string(other)) | — |") }
                if scan.localSnapshots > 0 { lines.append("| Time Machine local snapshots | system-managed | \(scan.localSnapshots) |") }
            } else {
                lines += ["", "No consumer scan yet — use the storage view's Scan button for a sized breakdown.", ""]
            }
            lines.append("")
        }
        lines += ["## Apps in the latest sample", "", "| App | Footprint | Reading |", "| --- | ---: | --- |"]
        for app in summary.latestApps.sorted(by: { $0.bytes > $1.bytes }) {
            lines.append("| \(escape(app.name)) | \(MemoryFormat.string(app.bytes)) | \(app.partial ? "Partial" : "Measured") |")
        }
        lines += ["", "## Daily readings", "", "Local calendar dates. Pressure percentages count samples, not elapsed time.", "",
                  "| Date | Samples | Elevated/critical samples | Peak swap |", "| --- | ---: | ---: | ---: |"]
        let daily = try statement("SELECT date(ts, 'unixepoch', 'localtime'), count(*), sum(CASE WHEN pressure IN (2,4) THEN 1 ELSE 0 END), max(swap) FROM samples GROUP BY date(ts, 'unixepoch', 'localtime') ORDER BY 1 DESC")
        defer { sqlite3_finalize(daily) }
        while sqlite3_step(daily) == SQLITE_ROW {
            let count = sqlite3_column_int(daily, 1)
            let high = sqlite3_column_int(daily, 2)
            let percent = count > 0 ? Int(Double(high) / Double(count) * 100) : 0
            lines.append("| \(text(daily, 0)) | \(count) | \(high) / \(count) · \(percent)% | \(MemoryFormat.string(UInt64(max(0, sqlite3_column_double(daily, 3))))) |")
        }
        lines += ["", "## Recent events", "", "Quit requests and observed outcomes are logged separately. Memory changes after a quit don't prove causation.", ""]
        let events = try statement("SELECT ts, kind, app, detail FROM events ORDER BY ts DESC LIMIT 20")
        defer { sqlite3_finalize(events) }
        while sqlite3_step(events) == SQLITE_ROW {
            let time = dateFormatter.string(from: Date(timeIntervalSince1970: sqlite3_column_double(events, 0)))
            lines.append("- \(time) · \(escape(text(events, 1))) · \(escape(text(events, 2))) · \(escape(text(events, 3)))")
        }
        lines += ["", "Reports are generated from measured values, without an external AI service. Gaps longer than 90 seconds are excluded from observed-time estimates.", ""]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        lastLogAt = now
    }
    private func escape(_ value: String) -> String { value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }

    /// Keeps the old database and report intact; starts a new history without deleting data.
    public func archive(at date: Date = Date()) throws -> URL {
        let archive = directory.appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent("\(Int(date.timeIntervalSince1970))-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        sqlite3_close(db); db = nil
        sampleCache = nil; consumerCache = nil; dataVersion = nil
        do {
            for name in ["history.sqlite", "log.md"] {
                let source = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: archive.appendingPathComponent(name))
                }
            }
        } catch { try open(); throw error }
        try open()
        try writeLog(summary: TrendSummary(), now: date)
        return archive
    }

    // MARK: Summary window cache
    //
    // The store is long-lived and queue-confined, so summary() keeps the decoded
    // samples of its trailing window and only reads rows newer than the last call.

    /// A samples row as summary() reads it. `apps` is nil for boundary pre-roll
    /// rows, which summary() never decodes.
    private struct SampleRow {
        let ts: Double
        let used: Double
        let swap: Double
        let pressure: Int32
        let apps: [ObservedApp]?
        let diskFree: Double?
        let diskPurgeable: Double
        let diskTotal: Double
    }
    /// Holds exactly the samples rows with `lo <= ts <= hi`, ascending.
    private struct SampleCache {
        var lo: Double
        var hi: Double
        var rows: [SampleRow]
    }

    /// Another connection (a CLI run, a second instance) changed the database.
    private func syncWithOtherWriters() throws {
        let stmt = try statement("PRAGMA data_version"); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw error() }
        let version = sqlite3_column_int64(stmt, 0)
        if version != dataVersion { sampleCache = nil; consumerCache = nil; dataVersion = version }
    }

    /// Rows with `lo <= ts <= hi`, ascending, apps decoded for every row at or after `start`.
    private func windowRows(from lo: Double, through hi: Double, start: Date) throws -> ArraySlice<SampleRow> {
        try syncWithOtherWriters()
        if var cache = sampleCache, lo >= cache.lo {
            sampleCache = nil
            if let first = cache.rows.firstIndex(where: { $0.ts >= lo }) { cache.rows.removeFirst(first) } else { cache.rows.removeAll() }
            cache.lo = lo
            if hi > cache.hi {
                try fetchSamples("ts > ? AND ts <= ?", [.number(cache.hi), .number(hi)], start: start, into: &cache.rows)
                cache.hi = hi
            }
            let end = (cache.rows.lastIndex { $0.ts <= hi } ?? -1) + 1
            // A row that was pre-roll for an earlier call can't be inside this window
            // while time only moves forward; fall back to a full read if it is.
            if cache.rows[..<end].allSatisfy({ $0.apps != nil || Date(timeIntervalSince1970: $0.ts) < start }) {
                sampleCache = cache
                return cache.rows[..<end]
            }
        }
        sampleCache = nil
        var rows: [SampleRow] = []
        try fetchSamples("ts >= ? AND ts <= ?", [.number(lo), .number(hi)], start: start, into: &rows)
        sampleCache = SampleCache(lo: lo, hi: hi, rows: rows)
        return rows[...]
    }

    private func fetchSamples(_ condition: String, _ values: [SQLValue], start: Date, into rows: inout [SampleRow]) throws {
        let stmt = try statement("SELECT ts, used, swap, pressure, apps, disk_free, disk_purgeable, disk_total FROM samples WHERE \(condition) ORDER BY ts", values)
        defer { sqlite3_finalize(stmt) }
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error() }
            let ts = sqlite3_column_double(stmt, 0)
            var apps: [ObservedApp]?
            if Date(timeIntervalSince1970: ts) >= start {
                apps = try decoder.decode([ObservedApp].self, from: Data(text(stmt, 4).utf8))
                if let previous = rows.last?.apps { apps = Self.sharingStrings(apps!, with: previous) }
            }
            rows.append(SampleRow(ts: ts, used: sqlite3_column_double(stmt, 1), swap: sqlite3_column_double(stmt, 2),
                                  pressure: sqlite3_column_int(stmt, 3), apps: apps,
                                  diskFree: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5),
                                  diskPurgeable: sqlite3_column_double(stmt, 6), diskTotal: sqlite3_column_double(stmt, 7)))
        }
    }

    /// Consecutive samples repeat the same keys, names, and sessions; reuse the
    /// previous row's string storage so a day of rows stays small in memory.
    private static func sharingStrings(_ apps: [ObservedApp], with previous: [ObservedApp]) -> [ObservedApp] {
        let index = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        return apps.map { app in
            guard let old = index[app.key], same(old.key, app.key) else { return app }
            return ObservedApp(key: old.key, name: same(old.name, app.name) ? old.name : app.name,
                               session: same(old.session, app.session) ? old.session : app.session,
                               bytes: app.bytes, partial: app.partial)
        }
    }
}
