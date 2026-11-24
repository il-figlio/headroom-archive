import Foundation

/// Stable numeric release versions only; prereleases are deliberately excluded.
public struct ReleaseVersion: Comparable, Equatable {
    private let parts: [Int]
    public init?(_ text: String) {
        let raw = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              components.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = components.map { Int($0)! } + Array(repeating: 0, count: 3 - components.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

public struct GitHubRelease: Decodable {
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool

    public static func newest(in data: Data) throws -> GitHubRelease? {
        try JSONDecoder().decode([GitHubRelease].self, from: data)
            .filter { !$0.draft && !$0.prerelease && ReleaseVersion($0.tag_name) != nil }
            .max { ReleaseVersion($0.tag_name)! < ReleaseVersion($1.tag_name)! }
    }
}
