import XCTest
@testable import HeadroomCore

final class ReleaseTests: XCTestCase {
    func testNumericVersionComparison() {
        XCTAssertGreaterThan(ReleaseVersion("v0.10.0")!, ReleaseVersion("0.9.9")!)
        XCTAssertEqual(ReleaseVersion("1.2"), ReleaseVersion("1.2.0"))
        for value in ["", "1..2", "1.2.3.4", "1.2-beta", "-1", "١.٢"] {
            XCTAssertNil(ReleaseVersion(value))
        }
    }
    func testSelectsNewestStableReleaseRegardlessOfPublicationOrder() throws {
        let data = Data("""
        [{"tag_name":"v0.8.0","draft":false,"prerelease":false},
         {"tag_name":"v1.0.0","draft":true,"prerelease":false},
         {"tag_name":"v0.9.0","draft":false,"prerelease":true},
         {"tag_name":"v0.7.2","draft":false,"prerelease":false},
         {"tag_name":"nightly","draft":false,"prerelease":false}]
        """.utf8)
        XCTAssertEqual(try GitHubRelease.newest(in: data)?.tag_name, "v0.8.0")
        XCTAssertNil(try GitHubRelease.newest(in: Data("[]".utf8)))
        XCTAssertThrowsError(try GitHubRelease.newest(in: Data("{}".utf8)))
    }
}
