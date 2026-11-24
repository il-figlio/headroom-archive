import XCTest
@testable import HeadroomCore

final class HistoryTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func memory(_ pressure: Pressure = .normal, swap: UInt64 = 0) -> SystemMemory {
        .init(total: 16 * 1_073_741_824, used: 10 * 1_073_741_824, compressed: 2 * 1_073_741_824,
              swap: swap, pressure: pressure, valid: true)
    }
    func app(_ bytes: UInt64, session: String = "one", partial: Bool = false, name: String = "Browser") -> ObservedApp {
        .init(key: "com.example.browser", name: name, session: session, bytes: bytes, partial: partial)
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testObservedTimeExcludesSleepAndUnknownPressure() throws {
        let store = try HistoryStore(directory: directory())
        _ = try store.record(memory: memory(.warning), apps: [], at: base)
        _ = try store.record(memory: memory(.normal), apps: [], at: base.addingTimeInterval(60))
        _ = try store.record(memory: memory(.unknown), apps: [], at: base.addingTimeInterval(3660))
        let summary = try store.record(memory: memory(), apps: [], at: base.addingTimeInterval(3720))
        XCTAssertEqual(summary.observedMinutes, 1, accuracy: 0.001)
        XCTAssertEqual(summary.pressuredMinutes, 1, accuracy: 0.001)
    }
    func testGrowthRequiresContinuousSameSessionAndEnoughEvidence() throws {
        let store = try HistoryStore(directory: directory())
        for i in 0...20 {
            _ = try store.record(memory: memory(), apps: [app(UInt64(1_073_741_824 + i * 60_000_000))], at: base.addingTimeInterval(Double(i * 60)))
        }
        var summary = try store.summary(now: base.addingTimeInterval(1200))
        XCTAssertTrue(summary.recommendations.contains { $0.title == "Watch Browser's growth" })
        summary = try store.record(memory: memory(), apps: [app(3_500_000_000, session: "restarted")], at: base.addingTimeInterval(1260))
        XCTAssertFalse(summary.recommendations.contains { $0.title.contains("growth") })
    }
    func testPartialReadingsAndLongGapsDoNotGenerateGrowthAdvice() throws {
        let store = try HistoryStore(directory: directory())
        for i in 0...20 {
            _ = try store.record(memory: memory(), apps: [app(UInt64(1_073_741_824 + i * 60_000_000), partial: true)], at: base.addingTimeInterval(Double(i * 60)))
        }
        var summary = try store.summary(now: base.addingTimeInterval(1200))
        XCTAssertFalse(summary.recommendations.contains { $0.title.contains("growth") })
        summary = try store.record(memory: memory(), apps: [app(8_000_000_000)], at: base.addingTimeInterval(7200))
        XCTAssertFalse(summary.recommendations.contains { $0.title.contains("growth") })
    }
    func testRetentionAndArchivePreserveOldReportAndResetBaseline() throws {
        let store = try HistoryStore(directory: directory())
        _ = try store.record(memory: memory(), apps: [app(1_000_000_000)], at: base.addingTimeInterval(-31 * 86400))
        _ = try store.record(memory: memory(.warning), apps: [app(2_000_000_000)], at: base)
        XCTAssertEqual(try store.summary(now: base.addingTimeInterval(-31 * 86400)).sampleCount, 0)
        try store.event(kind: "quit-requested", app: "Browser", detail: "Accepted", at: base)
        let report = try String(contentsOf: store.logURL)
        XCTAssertFalse(report.contains("\(ISO8601DateFormatter().string(from: base.addingTimeInterval(-31 * 86400)))"))
        XCTAssertTrue(report.contains("quit-requested"))
        let archive = try store.archive(at: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("history.sqlite").path))
        XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("log.md")), report)
        XCTAssertEqual(try store.summary(now: base).sampleCount, 0)
        XCTAssertFalse(try String(contentsOf: store.logURL).contains("quit-requested"))
    }
    func testReopenPersistsDataAndEscapesAppNames() throws {
        let dir = try directory()
        do {
            let store = try HistoryStore(directory: dir)
            _ = try store.record(memory: memory(.critical), apps: [app(2_000_000_000, name: "Browser | test\nline")], at: base)
        }
        let store = try HistoryStore(directory: dir)
        XCTAssertEqual(try store.summary(now: base).sampleCount, 1)
        XCTAssertTrue(try String(contentsOf: store.logURL).contains("Browser \\| test line"))
        XCTAssertEqual(try store.summary(now: base.addingTimeInterval(300)).recommendations.first?.title, "History hasn't updated recently")
    }
    func testSustainedPressureAdviceUsesTimeRatherThanSampleCount() throws {
        let store = try HistoryStore(directory: directory())
        for i in 0...30 {
            _ = try store.record(memory: memory(.warning, swap: UInt64(i * 30_000_000)), apps: [app(4_000_000_000)], at: base.addingTimeInterval(Double(i * 60)))
        }
        let summary = try store.summary(now: base.addingTimeInterval(1800))
        XCTAssertEqual(summary.observedMinutes, 30, accuracy: 0.001)
        XCTAssertEqual(summary.pressuredFraction, 1, accuracy: 0.001)
        XCTAssertTrue(summary.recommendations.contains { $0.title == "Reduce the apps running together" })
        XCTAssertTrue(summary.recommendations.contains { $0.title == "Watch the increase in swap" })
    }
}
