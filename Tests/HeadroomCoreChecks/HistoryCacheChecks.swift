import Foundation
import Testing
@testable import HeadroomCore

/// The long-lived store caches the summary window and consumers; every check
/// compares it against a freshly opened store reading the same database.
@Suite struct HistoryCacheChecks {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func memory(_ pressure: Pressure = .normal, swap: UInt64 = 0, valid: Bool = true) -> SystemMemory {
        .init(total: 16 * 1_073_741_824, used: 10 * 1_073_741_824 + swap / 3, compressed: 2 * 1_073_741_824,
              swap: swap, pressure: pressure, valid: valid)
    }
    func disk(free: UInt64) -> DiskSpace { .init(total: 500_000_000_000, free: free, purgeable: free / 10, valid: true) }
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("headroom-checks-\(UUID().uuidString)")
    }
    /// A new store's summary over a copy of the database. Opening a store on the
    /// live file would write (schema/user_version) and so invalidate the cached
    /// store under test, hiding its incremental path.
    func fresh(_ dir: URL, _ now: Date) throws -> [String] {
        let copy = directory(); defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for name in ["history.sqlite", "history.sqlite-wal"] where FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            try FileManager.default.copyItem(at: dir.appendingPathComponent(name), to: copy.appendingPathComponent(name))
        }
        return try fingerprint(HistoryStore(directory: copy).summary(now: now))
    }
    func logStamp(_ store: HistoryStore) -> String? {
        guard let text = try? String(contentsOf: store.logURL, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("Updated ") }.map(String.init)
    }
    func stamp(_ date: Date) -> String {
        "Updated \(ISO8601DateFormatter().string(from: date)). Times are UTC unless noted."
    }

    func fingerprint(_ s: TrendSummary) -> [String] {
        func app(_ a: ObservedApp) -> String { "\(a.key)|\(a.name)|\(a.session)|\(a.bytes)|\(a.partial)" }
        func opt<T>(_ value: T?) -> String { value.map { "\($0)" } ?? "nil" }
        var lines = [
            "count \(s.sampleCount) observed \(s.observedMinutes) pressured \(s.pressuredMinutes)",
            "swap peak \(s.peakSwap) change \(s.swapChange) latest \(opt(s.latestAt?.timeIntervalSince1970)) \(s.latestPressure)",
            "disk \(opt(s.latestDiskFree)) \(opt(s.latestDiskPurgeable)) \(opt(s.latestDiskTotal)) rate \(opt(s.diskRateGBPerDay)) full \(opt(s.daysUntilFull))",
            "consumers \(s.consumers.items.map { "\($0.path)=\($0.bytes)/\(opt($0.previousBytes))" }) \(opt(s.consumers.scannedAt?.timeIntervalSince1970)) \(s.consumers.localSnapshots)",
            "trend peaks \(s.appTrends.map(\.peak))",
        ]
        lines += s.latestApps.map { "latest " + app($0) }
        // Equal peaks may come out in either order; the original summary didn't fix it either.
        lines += s.appTrends.map { "trend \($0.name) \(app($0.first)) \(app($0.latest)) \($0.firstAt.timeIntervalSince1970) \($0.latestAt.timeIntervalSince1970) \($0.peak) \($0.count)" }.sorted()
        lines += s.points.map { "point \($0.date.timeIntervalSince1970) \($0.usedGB) \($0.swapGB)" }
        lines += s.diskPoints.map { "disk \($0.date.timeIntervalSince1970) \($0.freeGB) \($0.purgeableGB)" }
        lines += s.recommendations.map { "advice \($0.title): \($0.detail)" }
        return lines
    }

    /// 26 hours of samples with sleep, odd gaps, pressure changes, an app restart,
    /// intermittent apps, low disk, invalid readings, and another writer.
    @Test func cachedSummaryMatchesFreshStore() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        var t = base
        var compared = 0
        var titles = Set<String>()
        var pressuresSeen = Set<String>()
        let special: Set<Int> = [99, 100, 101, 179, 180, 300, 301, 400, 401, 500, 501, 502, 600, 601, 700, 750, 751, 800, 801,
                                 900, 901, 902, 1000, 1001, 1100, 1101, 1200, 1201, 1300, 1301, 1439, 1440, 1441, 1442, 1500]
        for minute in 0..<1560 {
            if (180..<300).contains(minute) { continue }               // two hours asleep
            switch minute {
            case 300: t += 2 * 3600
            case 401: t += 15                                           // pressure-change sample
            case 501: t += 90                                           // longest still-observed gap
            case 502: t += 91                                           // just too long
            default: t += 60
            }
            let pressure: Pressure
            switch minute {
            case 400, 600..<700: pressure = .warning
            case 700..<720: pressure = .critical
            case 750: pressure = .unknown
            default: pressure = .normal
            }
            let swap = UInt64(max(0, minute - 590)) * 4_000_000
            var apps = [
                ObservedApp(key: "com.example.browser", name: minute < 1300 ? "Browser" : "Browser Beta", session: "1:1", bytes: 1_073_741_824 + UInt64(minute) * 25_000_000),
                ObservedApp(key: "com.example.agent", name: "Agent", session: minute < 800 ? "2:1" : "9:2",
                            bytes: (minute < 800 ? 600_000_000 : 300_000_000) + UInt64(minute % 37) * 1_000_003),
                ObservedApp(key: "com.example.sync", name: "Sync | tool", session: "3:1", bytes: 200_000_001, partial: minute % 5 == 0),
            ]
            if (minute / 10) % 2 == 0 { apps.append(ObservedApp(key: "com.example.helper", name: "Helper", session: "4:1", bytes: 90_000_007)) }
            let diskReading: DiskSpace? = minute < 100 ? nil : minute == 900 ? disk(free: 100_000_000)
                : disk(free: 80_000_000_000 - UInt64(minute) * 20_000_000)
            let returned = try store.record(memory: memory(pressure, swap: swap, valid: minute != 901), apps: apps, disk: diskReading, at: t)
            if minute != 900 && minute != 901 {
                // Absolute check: both stores share the decode path, so compare with the input too.
                #expect(returned.latestApps.map { "\($0.key)|\($0.name)|\($0.session)|\($0.bytes)|\($0.partial)" }
                        == apps.map { "\($0.key)|\($0.name)|\($0.session)|\($0.bytes)|\($0.partial)" }, "minute \(minute)")
            }
            titles.formUnion(returned.recommendations.map(\.title))
            pressuresSeen.insert("\(returned.latestPressure)")
            if minute % 25 == 0 || special.contains(minute) || special.contains(minute - 1) {
                #expect(fingerprint(returned) == (try fresh(dir, t)), "minute \(minute)")
                compared += 1
            }
            if minute == 1000 {
                // A second connection (CLI capture, another instance) writes between samples.
                try HistoryStore(directory: dir).record(memory: memory(.warning), apps: apps, disk: diskReading, at: t.addingTimeInterval(30))
            }
            if minute == 1100 {
                try store.saveConsumers([DiskConsumer(path: "/a", name: "A", bytes: 5_000_000_000, previousBytes: nil, scannedAt: nil, partial: false)],
                                        localSnapshots: 1, at: t)
            }
            if minute == 1200 {
                try HistoryStore(directory: dir).saveConsumers([DiskConsumer(path: "/a", name: "A", bytes: 7_000_000_000, previousBytes: nil, scannedAt: nil, partial: true)],
                                                               localSnapshots: 2, at: t)
            }
            if [1000, 1100, 1200].contains(minute) {
                #expect(fingerprint(try store.summary(now: t)) == (try fresh(dir, t)), "after another write at minute \(minute)")
            }
        }
        // Reads at times between, before, and after recorded samples.
        for offset in [-86400.0 - 90, -86400, -3600, -1, 0, 30, 89, 91, 200, 4000] {
            let now = t.addingTimeInterval(offset)
            #expect(fingerprint(try store.summary(now: now)) == (try fresh(dir, now)), "offset \(offset)")
        }
        #expect(fingerprint(try store.summary(now: t)) == (try fresh(dir, t)))
        // Re-recording the timestamp the cache already covers replaces that row.
        let replaced = try store.record(memory: memory(.critical, swap: 1), apps: [ObservedApp(key: "com.example.new", name: "New", session: "5:1", bytes: 1)], at: t)
        #expect(replaced.latestApps.map(\.key) == ["com.example.new"])
        #expect(fingerprint(replaced) == (try fresh(dir, t)))
        #expect(compared > 90)
        // The scenario actually exercised the advice and pressure paths.
        #expect(titles.contains("Watch Browser's growth"))
        #expect(titles.contains("Reduce current memory pressure"))
        #expect(pressuresSeen.isSuperset(of: ["warning", "critical", "normal", "unknown"]))
        #expect(try store.summary(now: t).consumers.items.first?.bytes == 7_000_000_000)
    }

    @Test func lowDiskWritesNothing() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let summary = try store.record(memory: memory(.warning), apps: [], disk: disk(free: 100_000_000), at: base)
        #expect(summary.sampleCount == 0)
        #expect(!FileManager.default.fileExists(atPath: store.logURL.path))
        #expect(try store.record(memory: memory(), apps: [], disk: disk(free: 10_000_000_000), at: base.addingTimeInterval(60)).sampleCount == 1)
    }

    @Test func reportCadence() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        // A new store's first record writes the report (what `--capture` relies on).
        try store.record(memory: memory(), apps: [], at: base)
        #expect(logStamp(store) == stamp(base))
        try store.record(memory: memory(.warning), apps: [], at: base.addingTimeInterval(60))
        try store.record(memory: memory(), apps: [], at: base.addingTimeInterval(HistoryStore.logInterval - 1))
        #expect(logStamp(store) == stamp(base))
        let due = base.addingTimeInterval(HistoryStore.logInterval)
        try store.record(memory: memory(), apps: [], at: due)
        #expect(logStamp(store) == stamp(due))
        let report = try String(contentsOf: store.logURL, encoding: .utf8)
        #expect(report.contains("4 samples"))
        #expect(report.contains("pressure-change"))

        let onDemand = due.addingTimeInterval(61)
        try store.record(memory: memory(), apps: [], at: due.addingTimeInterval(60))
        #expect(logStamp(store) == stamp(due))
        try store.refreshLog(now: onDemand)
        #expect(logStamp(store) == stamp(onDemand))
        #expect(try String(contentsOf: store.logURL, encoding: .utf8).contains("5 samples"))

        // Events are written right away; a consumer scan makes the next record write.
        let quit = onDemand.addingTimeInterval(10)
        try store.event(kind: "quit-requested", app: "Browser", detail: "Accepted", at: quit)
        #expect(logStamp(store) == stamp(quit))
        try store.saveConsumers([], localSnapshots: 0, at: quit)
        let next = quit.addingTimeInterval(50)
        try store.record(memory: memory(), apps: [], at: next)
        #expect(logStamp(store) == stamp(next))
        // A reopened store writes on its first record.
        let reopened = try HistoryStore(directory: dir)
        try reopened.record(memory: memory(), apps: [], at: next.addingTimeInterval(60))
        #expect(logStamp(reopened) == stamp(next.addingTimeInterval(60)))
    }

    @Test func retentionStillPrunes() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        try store.record(memory: memory(), apps: [], at: base)
        try store.record(memory: memory(), apps: [], at: base.addingTimeInterval(60))
        #expect(try store.summary(now: base.addingTimeInterval(60)).sampleCount == 2)
        let later = base.addingTimeInterval(31 * 86400)
        try store.record(memory: memory(), apps: [], at: later)
        #expect(try store.summary(now: base.addingTimeInterval(60)).sampleCount == 0)
        #expect(try fresh(dir, base.addingTimeInterval(60)) == fingerprint(try store.summary(now: base.addingTimeInterval(60))))
        #expect(try store.summary(now: later).sampleCount == 1)
        #expect(try fresh(dir, later) == fingerprint(try store.summary(now: later)))
    }

    @Test func archiveResetsCaches() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(directory: dir)
        let app = ObservedApp(key: "com.example.browser", name: "Browser", session: "1", bytes: 1_000_000_000)
        for i in 0..<5 { try store.record(memory: memory(), apps: [app], disk: disk(free: 9_000_000_000), at: base.addingTimeInterval(Double(i) * 60)) }
        try store.saveConsumers([DiskConsumer(path: "/a", name: "A", bytes: 1, previousBytes: nil, scannedAt: nil, partial: false)], localSnapshots: 0, at: base)
        let now = base.addingTimeInterval(240)
        #expect(try store.summary(now: now).sampleCount == 5)
        #expect(try store.loadConsumers().items.count == 1)
        _ = try store.archive(at: now)
        let after = try store.summary(now: now)
        #expect(after.sampleCount == 0 && after.latestApps.isEmpty && after.consumers.items.isEmpty)
        #expect(try String(contentsOf: store.logURL, encoding: .utf8).contains("- 0 samples"))
        let next = try store.record(memory: memory(), apps: [app], at: now.addingTimeInterval(60))
        #expect(next.sampleCount == 1)
        #expect(fingerprint(next) == (try fresh(dir, now.addingTimeInterval(60))))
    }
}
