import Foundation
import Testing
@testable import HeadroomCore

/// The desktop scene's demo machine: bigger, healthy, and a different app mix
/// from the laptop's, so the two README scenes never show the same numbers.
@Test func desktopFixturesDescribeABiggerHealthyMachine() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let laptop = ScreenshotFixtures(now: now)
    let demo = ScreenshotFixtures(now: now, machine: .desktop)
    #expect(demo.apps.allSatisfy { $0.id < 0 && $0.app.bundlePath.isEmpty })
    #expect(demo.memory.total == 64 * 1_073_741_824)
    #expect(demo.memory.pressure == .normal && demo.summary.latestPressure == .normal)
    #expect(demo.memory.swap == 0)
    #expect(demo.disk.free == demo.summary.latestDiskFree)
    #expect(demo.disk.urgency == .ample)
    #expect(abs(demo.summary.diskPoints.last!.freeGB - Double(demo.disk.free) / 1_073_741_824) < 0.001)
    #expect(abs(demo.summary.points.last!.usedGB - Double(demo.memory.used) / 1_073_741_824) < 0.001)
    #expect(demo.memory.total > laptop.memory.total && demo.disk.total > laptop.disk.total)
    #expect(demo.apps.first?.app.name != laptop.apps.first?.app.name)
    #expect(Set(demo.apps.map(\.app.name)).intersection(laptop.apps.map(\.app.name)).count <= 1)
    #expect(demo.summary.consumers.items.allSatisfy { !$0.path.hasPrefix("/Users/") || $0.path.hasPrefix("/Users/demo/") })
}

/// The laptop machine keeps the shape the XCTest suite and README rely on.
@Test func laptopFixturesStayElevatedOnSixteenGigabytes() {
    let demo = ScreenshotFixtures(now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(demo.memory.total == 16 * 1_073_741_824)
    #expect(demo.memory.pressure == .warning && demo.summary.latestPressure == .warning)
    #expect(demo.disk.total == 512 * 1_073_741_824)
    #expect(abs(demo.summary.diskPoints.last!.freeGB - Double(demo.disk.free) / 1_073_741_824) < 0.001)
    #expect(!demo.summary.recommendations.isEmpty)
}
