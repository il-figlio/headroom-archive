import XCTest
@testable import HeadroomCore

final class ScreenshotTests: XCTestCase {
    func testFixturesAreInventedAndInternallyConsistent() {
        let demo = ScreenshotFixtures(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(demo.apps.allSatisfy { $0.id < 0 && $0.app.bundlePath.isEmpty })
        XCTAssertEqual(demo.memory.pressure, demo.summary.latestPressure)
        XCTAssertEqual(demo.disk.free, demo.summary.latestDiskFree)
        XCTAssertEqual(demo.summary.diskPoints.last!.freeGB, Double(demo.disk.free) / 1_073_741_824, accuracy: 0.001)
        XCTAssertEqual(demo.summary.points.last!.usedGB, Double(demo.memory.used) / 1_073_741_824, accuracy: 0.001)
        XCTAssertEqual(demo.quotas.filter { $0.provider == .claude }.count, 2)
        XCTAssertEqual(demo.quotas.filter { $0.error != nil }.count, 1)
        XCTAssertTrue(demo.agents.sessions.allSatisfy { $0.projectDir.hasPrefix("/Users/demo/") })
        XCTAssertFalse(demo.agents.live.isEmpty)
        XCTAssertFalse(demo.summary.recommendations.isEmpty)
    }
}
