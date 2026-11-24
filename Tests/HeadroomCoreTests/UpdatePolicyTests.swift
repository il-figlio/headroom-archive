import XCTest
@testable import HeadroomCore

final class UpdatePolicyTests: XCTestCase {
    func testFeedIsThePublicRawAppcastOnMain() {
        XCTAssertEqual(UpdatePolicy.feedURL.absoluteString, "https://raw.githubusercontent.com/il-figlio/headroom/main/appcast.xml")
        XCTAssertEqual(UpdatePolicy.repository, "il-figlio/headroom")
    }

    func testAllowsOnlyThisRepositorysPublicReleaseZips() {
        let allowed = "https://github.com/il-figlio/headroom/releases/download/v0.9.0/Headroom-0.9.0-universal.zip"
        XCTAssertTrue(UpdatePolicy.allowsArchive(URL(string: allowed)))
        XCTAssertTrue(UpdatePolicy.allowsArchive(URL(string: "https://github.com/il-figlio/headroom/releases/download/v10.20.30/Headroom.zip")))
        for value in [allowed.replacingOccurrences(of: "https:", with: "http:"),
                      allowed.replacingOccurrences(of: "github.com", with: "github.com.evil.test"),
                      allowed.replacingOccurrences(of: "github.com", with: "user@github.com"),
                      allowed.replacingOccurrences(of: "github.com", with: "github.com:8443"),
                      allowed.replacingOccurrences(of: "il-figlio/headroom", with: "il-figlio/other"),
                      allowed.replacingOccurrences(of: "il-figlio/headroom", with: "someone/headroom"),
                      allowed.replacingOccurrences(of: "/download/", with: "/download/latest/"),
                      allowed.replacingOccurrences(of: "v0.9.0", with: "0.9.0"),
                      allowed.replacingOccurrences(of: "v0.9.0", with: "v0.9.0-beta"),
                      allowed.replacingOccurrences(of: "v0.9.0", with: "v0.9"),
                      allowed.replacingOccurrences(of: ".zip", with: ".dmg"),
                      allowed.replacingOccurrences(of: "Headroom-0.9.0-universal.zip", with: ".zip"),
                      allowed.replacingOccurrences(of: "Headroom-0.9.0-universal.zip", with: "..%2Fevil.zip"),
                      allowed + "?redirect=evil", allowed + "#fragment", allowed + "/extra",
                      "https://github.com/il-figlio/headroom/archive/refs/tags/v0.9.0.zip",
                      "https://raw.githubusercontent.com/il-figlio/headroom/main/Headroom.zip",
                      "https://release-assets.githubusercontent.com/github-production-release-asset/1/Headroom.zip",
                      // The pre-public private path is no longer accepted by public builds.
                      "https://api.github.com/repos/il-figlio/headroom/releases/assets/1234"] {
            XCTAssertFalse(UpdatePolicy.allowsArchive(URL(string: value)), value)
        }
        XCTAssertFalse(UpdatePolicy.allowsArchive(nil))
    }

    func testRecognizesGitHubsReleaseAssetRedirectHosts() {
        XCTAssertTrue(UpdatePolicy.allowsDownloadRedirect(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/abc?sp=r&sig=x")))
        XCTAssertTrue(UpdatePolicy.allowsDownloadRedirect(URL(string: "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1/abc?X-Amz-Signature=x")))
        for value in ["http://release-assets.githubusercontent.com/a", "https://release-assets.githubusercontent.com/",
                      "https://release-assets.githubusercontent.com.evil.test/a", "https://evil.githubusercontent.com/a",
                      "https://raw.githubusercontent.com/il-figlio/headroom/main/appcast.xml"] {
            XCTAssertFalse(UpdatePolicy.allowsDownloadRedirect(URL(string: value)), value)
        }
    }
}
