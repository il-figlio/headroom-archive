import Foundation

/// Public update sources, pinned to this repository. Updates need no GitHub
/// login: the appcast is served from the public main branch and archives are
/// public release assets. Sparkle still requires the feed and every archive to
/// carry Headroom's EdDSA signature, so the URL policy only narrows *where* an
/// update may come from; the signature decides whether it is trusted.
///
/// These constants must match packaging/app.env (a Swift Testing check compares them).
public enum UpdatePolicy {
    public static let repository = "il-figlio/headroom"
    public static let feedURL = URL(string: "https://raw.githubusercontent.com/il-figlio/headroom/main/appcast.xml")!
    public static let releasesPageURL = URL(string: "https://github.com/il-figlio/headroom/releases")!
    /// Anonymous public REST endpoint, used only by `--check-for-updates` diagnostics.
    public static let releasesAPIURL = URL(string: "https://api.github.com/repos/il-figlio/headroom/releases?per_page=100")!

    /// GitHub answers a release download with a 302 to a short-lived signed URL
    /// on one of these hosts (release-assets is current; objects is the older
    /// host). Sparkle follows that redirect inside its downloader and exposes no
    /// delegate hook for it, so this documents the expected hop rather than
    /// gating it; the EdDSA archive signature is what protects the download.
    public static let downloadRedirectHosts: Set<String> = ["release-assets.githubusercontent.com", "objects.githubusercontent.com"]

    /// Accepts only `https://github.com/il-figlio/headroom/releases/download/v<x.y.z>/<name>.zip`.
    public static func allowsArchive(_ url: URL?) -> Bool {
        guard let parts = plainHTTPS(url), parts.host == "github.com" else { return false }
        let segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let prefix = ["", "il-figlio", "headroom", "releases", "download"]
        guard segments.count == prefix.count + 2, Array(segments.prefix(prefix.count)) == prefix else { return false }
        let tag = segments[prefix.count], file = segments[prefix.count + 1]
        return isReleaseTag(tag) && isArchiveName(file)
    }

    /// Whether a URL is GitHub's release-asset storage hop (see `downloadRedirectHosts`).
    public static func allowsDownloadRedirect(_ url: URL?) -> Bool {
        guard let parts = plainHTTPS(url, allowQuery: true), let host = parts.host else { return false }
        return downloadRedirectHosts.contains(host) && parts.percentEncodedPath.count > 1
    }

    private static func plainHTTPS(_ url: URL?, allowQuery: Bool = false) -> URLComponents? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil, parts.user == nil, parts.password == nil,
              allowQuery || parts.query == nil, parts.fragment == nil else { return nil }
        return parts
    }
    private static func isReleaseTag(_ tag: String) -> Bool {
        let numbers = tag.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        return tag.hasPrefix("v") && numbers.count == 3
            && numbers.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
    private static func isArchiveName(_ name: String) -> Bool {
        let stem = name.dropLast(4)
        return name.hasSuffix(".zip") && !stem.isEmpty && !stem.hasPrefix(".")
            && stem.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}
