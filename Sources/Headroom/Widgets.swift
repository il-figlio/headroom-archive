import AppKit
import Foundation
import SwiftUI

/// Which metric cards the panel shows. Persisted as comma-joined raw values
/// so the panel survives relaunch exactly as the user left it.
final class PanelWidgets: ObservableObject {
    static let shared = PanelWidgets()

    enum Widget: String, CaseIterable, Identifiable {
        case memory, disk, agents, quota, favorites
        var id: String { rawValue }
        var title: String {
            switch self {
            case .memory: return "Memory"
            case .disk: return "Disk"
            case .agents: return "Agents"
            case .quota: return "Limits"
            case .favorites: return "Favorites dock"
            }
        }
    }

    @Published private(set) var visible: Set<Widget>
    /// Tallest panel the host's screen allows (visibleFrame − margin); set
    /// through `PanelMetrics.setScreen`. nil keeps the default cap.
    @Published private(set) var screenLimit: CGFloat?
    /// Imperative hosts (notch panel, popover, fallback) resize off this;
    /// the SwiftUI side already re-renders via @Published.
    var changed: (() -> Void)?

    /// Agents scanning costs process enumeration and transcript reads, so
    /// the card is opt-in. Existing installs lose it once via this flag;
    /// after that the user's toggle sticks.
    static let defaultVisible = Set(Widget.allCases).subtracting([.agents])
    private static let storeKey = "panelWidgets"
    private static let agentsOptInKey = "panelWidgets.agentsOptInMigrated"

    init(defaults: UserDefaults = .standard) {
        if ScreenshotExport.active {
            visible = [.memory, .disk, .quota]
            return
        }
        if let stored = defaults.string(forKey: Self.storeKey), !stored.isEmpty {
            visible = Set(stored.split(separator: ",").compactMap { Widget(rawValue: String($0)) })
        } else {
            visible = Self.defaultVisible
        }
        if !defaults.bool(forKey: Self.agentsOptInKey) {
            if visible.remove(.agents) != nil { persist(defaults) }
            defaults.set(true, forKey: Self.agentsOptInKey)
        }
    }

    func isVisible(_ widget: Widget) -> Bool { visible.contains(widget) }

    func toggle(_ widget: Widget) {
        if visible.contains(widget) { visible.remove(widget) } else { visible.insert(widget) }
        persist(.standard)
        changed?()
    }

    private func persist(_ defaults: UserDefaults) {
        defaults.set(visible.map(\.rawValue).sorted().joined(separator: ","), forKey: Self.storeKey)
    }

    func setScreenLimit(_ limit: CGFloat?) {
        if limit != screenLimit { screenLimit = limit }
    }

    /// Screenshot export only: sets the rendered set without persisting.
    func setForScreenshots(_ widgets: Set<Widget>) {
        guard ScreenshotExport.active else { return }
        visible = widgets
    }

    func widgetBinding(_ widget: Widget) -> Binding<Bool> {
        Binding(get: { self.isVisible(widget) }, set: { _ in self.toggle(widget) })
    }
}
