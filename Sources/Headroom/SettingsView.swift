import AppKit
import SwiftUI
import HeadroomCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, limits, history, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .limits: return "Limits"
        case .history: return "History"
        case .updates: return "Updates"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .limits: return "speedometer"
        case .history: return "clock.arrow.circlepath"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// Which tab Settings shows; the panel can open it straight to Limits.
final class SettingsRouter: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var router: SettingsRouter
    var showAbout: () -> Void = {}
    static let size = CGSize(width: 520, height: 540)

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar-style tabs, like the system's own settings windows.
            HStack(spacing: 4) {
                ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element) { index, tab in
                    TabButton(tab: tab, selected: router.tab == tab) { router.tab = tab }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }.padding(.top, 10).padding(.bottom, 6)
            Divider()
            Group {
                switch router.tab {
                case .general: GeneralSettings(monitor: monitor, showAbout: showAbout)
                case .limits: LimitsSettings()
                case .history: HistorySettings(monitor: monitor)
                case .updates: UpdateSettings(monitor: monitor, updater: monitor.updater)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

private struct TabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol).font(.system(size: 18)).frame(height: 22)
                Text(tab.title).font(.system(size: 11))
            }
            .frame(width: 72, height: 50)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(selected ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(tab.title)
    }
}

/// Small grey explanation under a control.
private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var widgets = PanelWidgets.shared
    @ObservedObject var preferences = AppPreferences.shared
    var showAbout: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Show Headroom in", selection: $monitor.placement) {
                    ForEach(Placement.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
                Toggle("Open at login", isOn: Binding(get: { monitor.loginEnabled }, set: { _ in monitor.toggleLogin() }))
            } footer: {
                Caption("Automatic uses the notch on screens that have one, and the menu bar otherwise.")
            }
            Section {
                Toggle("Memory", isOn: widgets.widgetBinding(.memory))
                Toggle("Disk", isOn: widgets.widgetBinding(.disk))
                Toggle("Favorites dock", isOn: widgets.widgetBinding(.favorites))
                Toggle(isOn: widgets.widgetBinding(.agents)) {
                    Text("Agents")
                    Text("Reads local Claude Code and Codex transcripts, read-only.")
                }
                // Reads as off while Limits itself is off, whatever the card setting.
                Toggle(isOn: preferences.limitsEnabled ? widgets.widgetBinding(.quota) : .constant(false)) {
                    Text("Limits")
                    Text(preferences.limitsEnabled ? "Plan usage for your signed-in tools." : "Turn on Limits in the Limits tab first.")
                }.disabled(!preferences.limitsEnabled)
            } header: { Text("Panel cards") }
            Section {
                HStack {
                    Text("Headroom \(AppBrand.fullVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Button("About Headroom", action: showAbout)
                }
            }
        }.formStyle(.grouped)
    }
}

private struct LimitsSettings: View {
    @ObservedObject var preferences = AppPreferences.shared
    @State private var detected: [String]?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: preferences.limitsBinding) {
                    Text("Show plan limits")
                    Text("Codex and Claude usage windows, checked every \(Int(QuotaPolicy.interval / 60)) minutes.")
                }
            } footer: {
                Caption("When on, Headroom reads the sign-ins these tools saved on this Mac and asks the providers how much of your plan is used. These usage endpoints are unofficial and may change or stop working. Headroom never shows, copies, refreshes or writes your tokens.")
            }
            Section {
                if let detected {
                    if detected.isEmpty {
                        Text("No supported sign-ins found").foregroundStyle(.secondary)
                    } else {
                        ForEach(detected, id: \.self) { name in
                            Label(name, systemImage: "person.crop.circle").accessibilityLabel("Sign-in found: \(name)")
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text("Sign-ins on this Mac")
            } footer: {
                Caption("Found by checking which sign-in files exist. They're only opened while Limits is on.")
            }
            Section {
                Link("How Headroom handles your data", destination: AppBrand.privacyURL)
            }
        }.formStyle(.grouped)
            .task { await detect() }
    }

    private func detect() async {
        if ScreenshotExport.active { detected = ["Codex", "Claude (Ante: personal, work)"]; return }
        detected = await Task.detached(priority: .utility) { QuotaSources.detectedNames() }.value
    }
}

private struct HistorySettings: View {
    @ObservedObject var monitor: MemoryMonitor

    var body: some View {
        Form {
            Section {
                Toggle("Keep history", isOn: $monitor.historyEnabled)
            } footer: {
                Caption("About one reading a minute, kept for 30 days in ~/Library/Application Support/Headroom. It stays on this Mac. With history off, the live readings still work.")
            }
            if let error = monitor.historyError {
                Section {
                    Label("History couldn't be saved: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section {
                row("Trends & recommendations", button: "Open") { monitor.showHistory?() }
                row("Plain-text log (log.md)", button: "Open") { monitor.openLog() }
                row("History folder", button: "Show in Finder") { monitor.revealHistory() }
                row("Start a fresh baseline", button: "Archive…") { monitor.archiveHistory() }
            }
        }.formStyle(.grouped)
    }

    private func row(_ title: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(button, action: action).accessibilityLabel("\(button) \(title)")
        }
    }
}

private struct UpdateSettings: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
                Toggle("Download and install updates automatically", isOn: Binding(get: { updater.automaticInstalls }, set: updater.setAutomaticInstalls))
                    .disabled(!updater.automaticChecks)
            } footer: {
                Caption("Updates are signed and verified before they're installed. Headroom may quit and relaunch itself to finish an update.")
            }
            Section {
                HStack {
                    Text(AppBrand.versionLine).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { monitor.checkForUpdates?() }.disabled(!updater.canCheck)
                }
            }
        }.formStyle(.grouped)
    }
}
