import AppKit
import SwiftUI
import HeadroomCore

/// Shown once, on the first launch of a new install. Every choice here is
/// also in Settings; the optional features start off.
struct WelcomeView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var widgets = PanelWidgets.shared
    @ObservedObject var preferences = AppPreferences.shared
    /// The notch is available on this Mac (decides the "where" sentence).
    var notch: Bool
    var done: () -> Void
    static let width: CGFloat = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                BrandIcon(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Headroom").font(.system(size: 20, weight: .semibold))
                    Text(AppBrand.tagline).foregroundStyle(.secondary)
                }
            }.accessibilityElement(children: .combine)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 13) {
                fact("macbook", "Where it lives",
                     (notch ? "In the notch at the top of this screen." : "In the menu bar.")
                     + " Click it to open the panel. You can switch between the notch and the menu bar in Settings.")
                fact("memorychip", "What it measures",
                     "Memory pressure as the kernel reports it, free disk space, and how much memory each app uses with its helpers.")
                fact("lock", "History stays on this Mac",
                     "Readings are kept for 30 days in a local database and never uploaded. You can turn history off at any time.")
            }

            group("Optional — off until you turn them on") {
                option("Limits",
                       "Shows Codex and Claude plan usage. Headroom reads the sign-ins those tools (and Ante) saved on this Mac and asks the providers' usage endpoints, which are unofficial and may change.",
                       isOn: preferences.limitsBinding)
                Divider()
                option("Agents",
                       "Lists coding-agent sessions and token use by reading local Claude Code and Codex transcripts. Read-only; nothing leaves this Mac.",
                       isOn: widgets.widgetBinding(.agents))
            }

            group("Startup and updates") {
                option("Keep history", nil, isOn: $monitor.historyEnabled)
                Divider()
                option("Open at login", nil, isOn: Binding(get: { monitor.loginEnabled }, set: { _ in monitor.toggleLogin() }))
                Divider()
                option("Check for updates automatically", nil,
                       isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
            }

            HStack {
                Text("All of this is in Settings, from the ··· menu or ⌘,.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).controlSize(.large)
            }.padding(.top, 18)
        }
        .padding(24)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func fact(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Color.accentColor)
                .frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }.padding(.top, 18)
    }

    private func option(_ title: String, _ detail: String?, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? "")
    }
}
