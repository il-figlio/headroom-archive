import XCTest
import CSQLite
@testable import HeadroomCore

final class DiskTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func memory() -> SystemMemory {
        .init(total: 16 << 30, used: 10 << 30, compressed: 2 << 30, swap: 0, pressure: .normal, valid: true)
    }
    func disk(free: UInt64, total: UInt64 = 228 << 30, purgeable: UInt64 = 0) -> DiskSpace {
        .init(total: total, free: free, purgeable: purgeable, valid: true)
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testLiveDiskRead() {
        let disk = DiskSpace.read()
        XCTAssertTrue(disk.valid)
        XCTAssertGreaterThan(disk.total, 0)
        XCTAssertLessThanOrEqual(disk.free, disk.total)
        XCTAssertEqual(disk.used + disk.free, disk.total)
    }
    func testDiskUrgencyThresholds() {
        XCTAssertEqual(disk(free: 2 << 30).urgency, .critical)   // <1% free
        XCTAssertEqual(disk(free: 20 << 30).urgency, .low)       // ~9% free
        XCTAssertEqual(disk(free: 60 << 30).urgency, .ample)     // ~26% free
        XCTAssertEqual(DiskSpace(total: 100, free: 50, purgeable: 0, valid: false).urgency, .ample)
    }
    func testRecordStoresDiskAndLowSpaceSkipsWrites() throws {
        let store = try HistoryStore(directory: directory())
        _ = try store.record(memory: memory(), apps: [], disk: disk(free: 10 << 30), at: base)
        var summary = try store.summary(now: base)
        XCTAssertEqual(summary.latestDiskFree, 10 << 30)
        XCTAssertEqual(summary.latestDiskTotal, 228 << 30)
        // Below the guard threshold, history drops the sample instead of writing.
        _ = try store.record(memory: memory(), apps: [], disk: disk(free: 100_000_000), at: base.addingTimeInterval(60))
        summary = try store.summary(now: base.addingTimeInterval(60))
        XCTAssertEqual(summary.sampleCount, 1)
    }
    func testMigrationAddsDiskColumnsToLegacyDatabase() throws {
        let dir = try directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("history.sqlite").path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE samples (ts REAL PRIMARY KEY, used REAL, total REAL, compressed REAL, swap REAL, pressure INTEGER, apps TEXT)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO samples VALUES (1800000000, 1, 16, 2, 0, 1, '[]')", nil, nil, nil)
        sqlite3_close(db)
        let store = try HistoryStore(directory: dir)
        let summary = try store.record(memory: memory(), apps: [], disk: disk(free: 9 << 30), at: base.addingTimeInterval(60))
        XCTAssertEqual(summary.sampleCount, 2)
        XCTAssertEqual(summary.latestDiskFree, 9 << 30)
    }
    func testDiskRateAndDaysUntilFull() throws {
        let store = try HistoryStore(directory: directory())
        // Free space drops 2 GB/hour across three hours: 48 GB/day, ~0.2 days left at 10 GB.
        for i in 0...3 {
            _ = try store.record(memory: memory(), apps: [], disk: disk(free: UInt64(16 << 30) - UInt64(i) * (2 << 30)), at: base.addingTimeInterval(Double(i) * 3600))
        }
        let summary = try store.summary(now: base.addingTimeInterval(3 * 3600))
        XCTAssertEqual(summary.diskRateGBPerDay ?? 0, 48, accuracy: 2)
        XCTAssertEqual(summary.daysUntilFull ?? 0, 10.0 / 48.0, accuracy: 0.1)
    }
    func testConsumerRoundTripKeepsPreviousScan() throws {
        let store = try HistoryStore(directory: directory())
        try store.saveConsumers([.init(path: "/a", name: "~/a", bytes: 5 << 30, previousBytes: nil, scannedAt: nil, partial: false)],
                                localSnapshots: 0, at: base)
        var scan = try store.loadConsumers()
        XCTAssertEqual(scan.items.first?.bytes, 5 << 30)
        XCTAssertNil(scan.items.first?.previousBytes)
        try store.saveConsumers([.init(path: "/a", name: "~/a", bytes: 6 << 30, previousBytes: nil, scannedAt: nil, partial: false)],
                                localSnapshots: 2, at: base.addingTimeInterval(3600))
        scan = try store.loadConsumers()
        XCTAssertEqual(scan.items.first?.bytes, 6 << 30)
        XCTAssertEqual(scan.items.first?.previousBytes, 5 << 30)
        XCTAssertEqual(scan.items.first?.delta, Int64(1 << 30))
        XCTAssertEqual(scan.localSnapshots, 2)
        // Locations absent from a new scan disappear.
        try store.saveConsumers([], localSnapshots: 0, at: base.addingTimeInterval(7200))
        XCTAssertTrue(try store.loadConsumers().items.isEmpty)
    }
    func testDiskAdviceFiresOnLowSpaceAndConsumerGrowth() throws {
        let store = try HistoryStore(directory: directory())
        _ = try store.record(memory: memory(), apps: [], disk: disk(free: 8 << 30), at: base)
        try store.saveConsumers([.init(path: "/x", name: "~/x", bytes: 10 << 30, previousBytes: nil, scannedAt: nil, partial: false)],
                                localSnapshots: 0, at: base)
        try store.saveConsumers([.init(path: "/x", name: "~/x", bytes: 12 << 30, previousBytes: nil, scannedAt: nil, partial: false)],
                                localSnapshots: 0, at: base.addingTimeInterval(3600))
        let titles = try store.summary(now: base).recommendations.map(\.title)
        XCTAssertTrue(titles.contains("Free up disk space soon"))
        XCTAssertTrue(titles.contains { $0.hasPrefix("~/x grew") })
    }
    func testScannerSizesDirectoryAndHonorsCancellation() throws {
        let dir = try directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 12345).write(to: dir.appendingPathComponent("blob.bin"))
        let result = ConsumerScanner().scan(roots: [dir])
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.consumers.first?.bytes ?? 0, 12345, accuracy: 8192)
        let cancelled = ConsumerScanner()
        cancelled.cancel()
        XCTAssertTrue(cancelled.scan(roots: [dir]).cancelled)
    }
}
