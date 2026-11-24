import XCTest
@testable import HeadroomCore

final class MemoryTests: XCTestCase {
    func app(_ pid: Int32, _ path: String, name: String = "App") -> AppIdentity {
        .init(pid: pid, name: name, bundlePath: path, bundleIdentifier: nil, launchDate: nil)
    }
    func testGroupsDescendantsAndReparentedHelpersWithoutDoubleCounting() {
        let apps = [app(10, "/Applications/Browser.app"), app(20, "/Applications/Editor.app")]
        let processes = [
            ProcessMemory(pid: 10, parent: 1, path: "/Applications/Browser.app/Contents/MacOS/browser", footprint: 100),
            ProcessMemory(pid: 11, parent: 10, path: "/usr/bin/worker", footprint: 200),
            ProcessMemory(pid: 12, parent: 1, path: "/Applications/Browser.app/Contents/Helper.app/helper", footprint: 300),
            ProcessMemory(pid: 20, parent: 10, path: "/Applications/Editor.app/editor", footprint: 50),
            ProcessMemory(pid: 21, parent: 20, path: "/usr/bin/worker", footprint: 25),
            ProcessMemory(pid: 30, parent: 1, path: "/Applications/Browser.app.fake/worker", footprint: 999)
        ]
        let result = AppGrouping.group(apps: apps, processes: processes)
        XCTAssertEqual(result.map(\.bytes), [600, 75])
        XCTAssertEqual(result.map(\.processCount), [3, 2])
    }
    func testUnreadableProcessesAndParentCycles() {
        let result = AppGrouping.group(apps: [app(10, "/A.app"), app(20, "/B.app")], processes: [
            .init(pid: 10, parent: 1, path: "/A.app/main", footprint: 10),
            .init(pid: 11, parent: 10, path: "/worker", footprint: nil),
            .init(pid: 20, parent: 1, path: "/B.app/main", footprint: nil),
            .init(pid: 30, parent: 31, path: "/worker", footprint: 1000),
            .init(pid: 31, parent: 30, path: "/worker", footprint: 1000)
        ])
        XCTAssertEqual(result[0].bytes, 10)
        XCTAssertEqual(result[0].unreadableCount, 1)
        XCTAssertNil(result[1].bytes)
    }
    func testLongestBundlePathOwnsReparentedNestedHelper() {
        let result = AppGrouping.group(apps: [app(10, "/A.app"), app(20, "/A.app/Nested.app")], processes: [
            .init(pid: 21, parent: 1, path: "/A.app/Nested.app/helper", footprint: 50)
        ])
        XCTAssertEqual(result.first?.id, 20)
        XCTAssertEqual(result.first?.bytes, 50)
    }
    func testKernelPressureIsNotDerivedFromUsagePercent() {
        XCTAssertEqual(Pressure.fromKernel(1), .normal)
        XCTAssertEqual(Pressure.fromKernel(2), .warning)
        XCTAssertEqual(Pressure.fromKernel(4), .critical)
        XCTAssertEqual(Pressure.fromKernel(6), .critical)
        XCTAssertEqual(Pressure.fromKernel(0), .unknown)
    }
    func testPlacementFallsBackWithoutNotch() {
        for placement in Placement.allCases { XCTAssertFalse(placement.usesNotch(available: false)) }
        XCTAssertTrue(Placement.automatic.usesNotch(available: true))
        XCTAssertTrue(Placement.notch.usesNotch(available: true))
        XCTAssertFalse(Placement.menuBar.usesNotch(available: true))
    }
    func testLiveKernelReadAndOwnFootprint() {
        let memory = SystemMemory.read()
        XCTAssertTrue(memory.valid)
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        let own = ProcessMemory.read().first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        XCTAssertNotNil(own)
        XCTAssertGreaterThan(own?.footprint ?? 0, 0)
    }
}
