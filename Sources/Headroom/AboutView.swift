import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            BrandIcon(size: 96)
            Text("Headroom").font(.system(size: 22, weight: .semibold)).padding(.top, 10)
            Text(AppBrand.versionLine).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.top, 2)
            Text(AppBrand.tagline).multilineTextAlignment(.center).padding(.top, 12)

            HStack(spacing: 16) {
                Link("GitHub", destination: AppBrand.repositoryURL)
                Link("Privacy", destination: AppBrand.privacyURL)
                Link("MIT License", destination: AppBrand.licenseURL)
            }.padding(.top, 14)

            Divider().padding(.vertical, 16)

            VStack(spacing: 4) {
                Text("Acknowledgements").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Link("Sparkle", destination: AppBrand.sparkleURL).font(.callout)
                Text("Software updates. MIT License, with BSD-licensed components.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let license = Self.sparkleLicense {
                    Button("View Sparkle License") { Self.open(license) }
                        .buttonStyle(.link).font(.callout)
                }
            }
            Text("© 2026 Headroom contributors").font(.caption).foregroundStyle(.tertiary).padding(.top, 16)
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Bundled by build.sh next to the icon.
    static var sparkleLicense: URL? { Bundle.main.url(forResource: "Sparkle-LICENSE", withExtension: nil) }
    /// The file has no extension, so name the app that shows it.
    private static func open(_ file: URL) {
        guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSWorkspace.shared.open(file); return
        }
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
