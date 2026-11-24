import AppKit
import SwiftUI

enum AppBrand {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    /// "0.8.0 (13)"
    static var fullVersion: String { version + (build.map { " (\($0))" } ?? "") }
    static var versionLine: String { "Version \(fullVersion)" }
    static let tagline = "Memory pressure and disk space at a glance."
    static let repositoryURL = URL(string: "https://github.com/il-figlio/headroom")!
    static let privacyURL = URL(string: "https://github.com/il-figlio/headroom/blob/main/PRIVACY.md")!
    static let licenseURL = URL(string: "https://github.com/il-figlio/headroom/blob/main/LICENSE")!
    static let sparkleURL = URL(string: "https://sparkle-project.org")!
    static let icon: NSImage? = {
        let url = Bundle.main.url(forResource: "Headroom", withExtension: "icns")
            ?? (ScreenshotExport.active ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Headroom.icns") : nil)
        return url.flatMap { NSImage(contentsOf: $0) }
    }()
    static func menuIcon() -> NSImage? {
        let copy = icon?.copy() as? NSImage
        copy?.size = NSSize(width: 18, height: 18)
        copy?.isTemplate = false
        return copy
    }
}

struct BrandIcon: View {
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let icon = AppBrand.icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "memorychip").resizable().scaledToFit() }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
