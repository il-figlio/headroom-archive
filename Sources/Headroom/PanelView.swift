import AppKit
import SwiftUI
import HeadroomCore

/// The popover, notch expansion, and fallback panel share one size. Height
/// follows the visible widgets — hiding a card hands its space to the app
/// list, which is the only flexible region. Card heights are pt estimates
/// measured against the rendered panel; overestimates land in the list
/// (minHeight) instead of clipping the footer.
enum PanelMetrics {
    /// Main-thread mirror of the queue's last sign-in check; see MemoryMonitor.pollQuotas.
    static var quotaSourcesPresent = false
    static let width: CGFloat = 400
    /// Default cap; the panel only grows past it when the visible cards
    /// plus the minimum app list need more and the screen has room.
    static let defaultMaxHeight: CGFloat = 780
    /// Gap kept between the panel and the screen's visible edges.
    static let screenMargin: CGFloat = 24
    /// About three app rows; the search field lives in `appsHeader`.
    static let listMinimum: CGFloat = 150
    /// Hosts call this with their screen before sizing; the limit lives on
    /// `PanelWidgets` so the SwiftUI side re-renders when it changes.
    static func setScreen(_ screen: NSScreen?) {
        PanelWidgets.shared.setScreenLimit(screen.map { $0.visibleFrame.height - screenMargin })
    }
    private static let header: CGFloat = 58
    private static let dock: CGFloat = 48
    /// Memory and disk share one row of half-width tiles — one height.
    private static let tilesRow: CGFloat = 140
    /// Header, up to three live-session rows, compact burn chart.
    private static let agentsCard: CGFloat = 190
    /// Three collapsed accounts (one row each) with padding; expanding an
    /// account scrolls inside the cards region.
    private static let quotaCard: CGFloat = 196
    private static let appsHeader: CGFloat = 80
    private static let footer: CGFloat = 46
    private static let listFloor: CGFloat = 220

    /// Fits the cards plus a comfortable list within 780; past that, grows
    /// toward the screen limit to keep cards + a three-row list visible.
    /// Only beyond the screen limit does the cards area scroll.
    static func size() -> NSSize {
        let cards = widgetsHeight()
        let comfortable = header + appsHeader + footer + listFloor + cards
        if comfortable <= defaultMaxHeight { return NSSize(width: width, height: comfortable) }
        let needed = header + appsHeader + footer + listMinimum + cards
        let limit = max(defaultMaxHeight, PanelWidgets.shared.screenLimit ?? defaultMaxHeight)
        return NSSize(width: width, height: max(defaultMaxHeight, min(needed, limit)))
    }

    private static func widgetsHeight() -> CGFloat {
        let widgets = PanelWidgets.shared
        var height: CGFloat = 0
        if widgets.isVisible(.favorites), !FavoritesStore.shared.items.isEmpty { height += dock }
        if widgets.isVisible(.memory) || widgets.isVisible(.disk) { height += tilesRow }
        if widgets.isVisible(.agents) { height += agentsCard }
        // Only costs height when Limits is on and a sign-in was found. The
        // sampling queue does that check (files and Keychain) and publishes
        // the answer, so sizing never touches the disk or Keychain on main.
        if widgets.isVisible(.quota), AppPreferences.shared.limitsEnabled,
           ScreenshotExport.active || quotaSourcesPresent { height += quotaCard }
        return height
    }
}

struct PanelView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var widgets = PanelWidgets.shared
    @ObservedObject private var preferences = AppPreferences.shared
    var close: () -> Void
    var isNotch = false
    @State private var search = ""
    @State private var memoryHover = false
    /// Natural height of the cards stack; nil until first measured. A
    /// measured 0 (only card visible has nothing to show) is a real height.
    @State private var cardsHeight: CGFloat?
    @State private var diskHover = false

    private var filteredApps: [AppMemory] {
        monitor.apps.filter { search.isEmpty || $0.app.name.localizedCaseInsensitiveContains(search) }
    }
    /// Largest measured footprint; scales the quiet per-row memory bars.
    private var maxAppBytes: UInt64 { monitor.apps.compactMap(\.bytes).max() ?? 0 }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BrandIcon(size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Headroom").font(.system(size: 13, weight: .semibold))
                    Text(AppBrand.version).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("About Headroom") { monitor.showAbout?() }
                    Button("Settings…") { monitor.showSettings?(nil) }.keyboardShortcut(",", modifiers: .command)
                    Divider()
                    Menu("Widgets") {
                        ForEach(PanelWidgets.Widget.allCases) { widget in
                            if widget == .quota && !preferences.limitsEnabled {
                                // Limits is an opt-in that reads sign-ins; turning
                                // it on happens in Settings, with the explanation.
                                Button("Turn On Limits…") { monitor.showSettings?(.limits) }
                            } else {
                                Toggle(widget.title, isOn: widgets.widgetBinding(widget))
                            }
                        }
                    }
                    Picker("Position", selection: $monitor.placement) {
                        ForEach(Placement.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }
                    Button(monitor.loginEnabled ? "Disable launch at login" : "Launch at login") { monitor.toggleLogin() }
                    Divider()
                    Button("Trends & recommendations") { monitor.showHistory?() }
                    Button("Open log.md") { monitor.openLog() }
                    Button(monitor.historyEnabled ? "Pause history" : "Resume history") { monitor.historyEnabled.toggle() }
                    Button("Archive history…") { monitor.archiveHistory() }
                    Divider()
                    UpdatesMenu(updater: monitor.updater, check: { monitor.checkForUpdates?() })
                    Button("Open Activity Monitor") { monitor.openActivityMonitor?() }
                    Button("Quit Headroom") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Headroom settings")
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close panel")
                    .accessibilityLabel("Close panel")
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)

            if widgets.isVisible(.favorites) { FavoritesDock().contextMenu { hideButton(.favorites) } }

            // Memory + disk are compact tiles that always render fully;
            // only the agents card scrolls when the budget runs out.
            HStack(spacing: 8) {
                if widgets.isVisible(.memory) { memoryTile.contextMenu { hideButton(.memory) } }
                if monitor.disk.valid && widgets.isVisible(.disk) { diskTile.contextMenu { hideButton(.disk) } }
            }.padding(.horizontal, 16)

            if widgets.isVisible(.quota) || widgets.isVisible(.agents) {
                ScrollView {
                    VStack(spacing: 0) {
                        if widgets.isVisible(.quota) {
                            QuotaCard(monitor: monitor, isNotch: isNotch).contextMenu { hideButton(.quota) }
                        }
                        if widgets.isVisible(.agents) {
                            AgentsCard(monitor: monitor, isNotch: isNotch).contextMenu { hideButton(.agents) }
                        }
                    }.background(GeometryReader { geo in
                        Color.clear.preference(key: CardsHeightKey.self, value: geo.size.height)
                    })
                }.scrollIndicators(.automatic)
                    // Cards take their natural height first; the app list
                    // (min 200) absorbs the rest, and cards scroll only when
                    // the panel cap leaves too little room. Cards that render
                    // nothing (Limits with no readings) take no space.
                    .frame(maxHeight: cardsHeight ?? .infinity)
                    .layoutPriority(1)
                    .onPreferenceChange(CardsHeightKey.self) { cardsHeight = $0 }
            }

            HStack {
                Text("APPS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Text("Helpers included").font(.system(size: 10)).foregroundStyle(.secondary)
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh and sort by memory")
                    .accessibilityLabel("Refresh and sort by memory")
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an app", text: $search).textFieldStyle(.plain).font(.system(size: 12))
            }.padding(8).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 16).padding(.bottom, 7)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if monitor.loading { ProgressView().controlSize(.small).frame(height: 150) }
                    else if filteredApps.isEmpty { Text(search.isEmpty ? "No apps to show" : "No matching apps").foregroundStyle(.secondary).frame(height: 150) }
                    else { ForEach(filteredApps) { row in AppRow(row: row, maxBytes: maxAppBytes, monitor: monitor) } }
                }.padding(.horizontal, 10)
            }.frame(minHeight: PanelMetrics.listMinimum, maxHeight: .infinity)

            if let message = monitor.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.horizontal, 18).frame(height: 48)
            }
            Divider().padding(.horizontal, 16)
            HStack {
                Text("Quit lets apps ask to save.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Trends & advice") { monitor.showHistory?() }.buttonStyle(.plain).font(.system(size: 10))
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.size().height, alignment: .top)
        .background(isNotch ? Color(red: 0.045, green: 0.045, blue: 0.05) : Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(isNotch ? .dark : nil)
        .onExitCommand(perform: close)
    }
    private func hideButton(_ widget: PanelWidgets.Widget) -> some View {
        Button("Hide \(widget.title)") { widgets.toggle(widget) }
    }

    /// Half-width memory tile: label, state, number, sparkline, meter bar,
    /// swap/compressed footnote — always fully visible in the tiles row.
    private var memoryTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MEMORY").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: monitor.memory.pressure.color)).frame(width: 7, height: 7)
                Text(monitor.memory.pressure.title).font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(nsColor: monitor.memory.pressure.color))
            }
            Text(monitor.memory.valid
                 ? "\(String(format: "%.1f", Double(monitor.memory.used) / 1_073_741_824)) / \(MemoryFormat.compact(monitor.memory.total))"
                 : "—")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            Sparkline(values: monitor.trends.points.map(\.usedGB), color: Color(nsColor: monitor.memory.pressure.color))
                .frame(height: 20)
                .accessibilityLabel("Memory used over the last 24 hours")
            MeterBar(fraction: monitor.memory.fraction,
                     color: Color(nsColor: monitor.memory.pressure.color),
                     accessibilityLabel: "Memory used")
                .accessibilityHint("The shaded end of the bar starts near physical limits, where swap and compression work harder.")
            Text("Swap \(MemoryFormat.string(monitor.memory.swap)) · Comp \(MemoryFormat.string(monitor.memory.compressed))")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                .minimumScaleFactor(0.75)
        }.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(isNotch ? 0.055 + (memoryHover ? 0.03 : 0) : 0.035 + (memoryHover ? 0.025 : 0))))
            .hoverDetail("Memory · \(monitor.memory.pressure.title) pressure", memoryDetail, hovering: $memoryHover)
    }

    var memoryDetail: [String] {
        let memory = monitor.memory
        guard memory.valid else { return ["Memory reading unavailable."] }
        return ["Used \(MemoryFormat.string(memory.used)) of \(MemoryFormat.string(memory.total))",
                "Compressed \(MemoryFormat.string(memory.compressed)) · Swap \(MemoryFormat.string(memory.swap))",
                "Pressure comes from the kernel's pressure state, not the used percentage.",
                "Bar's shaded end: near physical limits. Sparkline: last 24 h."]
    }

    /// Half-width disk tile, mirror of the memory tile.
    private var diskTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DISK").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle().fill(Color(nsColor: monitor.disk.urgency.color)).frame(width: 7, height: 7)
                Text(MemoryFormat.compact(monitor.disk.free)).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                Text("free").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("\(Int(monitor.disk.usedFraction * 100))% of \(MemoryFormat.compact(monitor.disk.total)) used")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            Sparkline(values: monitor.trends.diskPoints.map(\.freeGB), color: Color(nsColor: monitor.disk.urgency.color))
                .frame(height: 20)
                .accessibilityLabel("Free disk space over the last 24 hours")
            MeterBar(fraction: monitor.disk.usedFraction,
                     color: Color(nsColor: monitor.disk.urgency.color),
                     attention: 0.9, ticks: [0.95], accessibilityLabel: "Disk used")
                .accessibilityHint("The shaded zone starts at 90% full; the tick at 95% is critical.")
            Text(diskFootnote)
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
        }.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(isNotch ? 0.055 + (diskHover ? 0.03 : 0) : 0.035 + (diskHover ? 0.025 : 0))))
            .hoverDetail("Disk · \(MemoryFormat.string(monitor.disk.free)) free", diskDetail, hovering: $diskHover)
    }

    var diskDetail: [String] {
        let disk = monitor.disk
        var lines = ["Free \(MemoryFormat.string(disk.free)) of \(MemoryFormat.string(disk.total)) total",
                     disk.purgeable > 0 ? "Purgeable \(MemoryFormat.string(disk.purgeable)) — macOS can reclaim it when needed" : "No purgeable space reported",
                     "\(Int(disk.usedFraction * 100))% used"]
        if let rate = monitor.trends.diskRateGBPerDay, rate > 0.1 {
            lines.append("Filling about \(MemoryFormat.perDay(gb: rate))" + (monitor.trends.daysUntilFull.map { ", full in ~\(Int($0)) days" } ?? ""))
        }
        lines.append("Shaded zone: 90% full (low); tick: 95% (critical).")
        return lines
    }

    /// Compact disk footnote: fill rate when known, else purgeable.
    private var diskFootnote: String {
        if let rate = monitor.trends.diskRateGBPerDay, rate > 0.1 {
            return "−\(MemoryFormat.perDay(gb: rate))" + (monitor.disk.purgeable > 0 ? " · \(MemoryFormat.string(monitor.disk.purgeable)) purgeable" : "")
        }
        return monitor.disk.purgeable > 0 ? "\(MemoryFormat.string(monitor.disk.purgeable)) purgeable" : " "
    }
}

private struct CardsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = max(value ?? 0, next) }
    }
}

struct AppRow: View {
    let row: AppMemory
    var maxBytes: UInt64
    @ObservedObject var monitor: MemoryMonitor
    @State private var hover = false
    private var protected: Bool { row.app.bundleIdentifier == "com.apple.finder" || row.app.launchDate == nil }
    var body: some View {
        HStack(spacing: 10) {
            if let icon = monitor.icon(for: row.app) {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            } else { Image(systemName: "app.fill").resizable().frame(width: 28, height: 28).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(row.processCount == 0 ? "Reading unavailable" : row.processCount > 1 ? "\(row.processCount) processes" : "1 process").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Text((row.unreadableCount > 0 && row.bytes != nil ? "≥ " : "") + (row.bytes.map(MemoryFormat.string) ?? "—"))
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                .accessibilityLabel(row.bytes.map { (row.unreadableCount > 0 ? "at least " : "") + MemoryFormat.string($0) } ?? "Reading unavailable")
                .accessibilityHint(row.unreadableCount > 0 ? "Partial reading: some processes aren't readable." : "App and helper memory footprint. Shared memory can overlap between apps.")
            Button(monitor.pending.contains(row.id) ? "…" : "Quit") { monitor.quit(row) }
                .buttonStyle(.bordered).controlSize(.small).disabled(protected || monitor.pending.contains(row.id))
                .help(protected ? "System app" : "Quit \(row.app.name)").accessibilityLabel("Quit \(row.app.name)")
            Menu {
                Button(FavoritesStore.shared.isPinned(row.app.bundleIdentifier ?? "") ? "Unpin from Dock" : "Pin to Dock") {
                    FavoritesStore.shared.toggle(bundleIdentifier: row.app.bundleIdentifier ?? "",
                                                 name: row.app.name, bundlePath: row.app.bundlePath)
                }
                Divider()
                Button("Force Quit…", role: .destructive) { monitor.quit(row, force: true) }
                    .disabled(protected)
            } label: { Image(systemName: "ellipsis").frame(width: 14, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More actions for \(row.app.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        // Share of the largest app's footprint: a thin meter under the name
        // column, not a row fill, so it can't read as a hover highlight.
        .background(alignment: .bottomLeading) {
            GeometryReader { geo in
                let fraction = maxBytes > 0 ? min(1, Double(row.bytes ?? 0) / Double(maxBytes)) : 0
                let track = max(0, geo.size.width - 58)
                Capsule().fill(Color.accentColor.opacity(0.45))
                    .frame(width: max(2, track * fraction), height: 2)
                    .offset(x: 48, y: geo.size.height - 5)
            }.accessibilityHidden(true)
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(hover ? 0.055 : 0)))
        .hoverDetail(row.app.name, detail, hovering: $hover)
    }

    var detail: [String] {
        var lines: [String] = []
        if let bytes = row.bytes {
            lines.append((row.unreadableCount > 0 ? "At least " : "Footprint ") + MemoryFormat.string(bytes) + " (app + helpers)")
        } else {
            lines.append("Memory reading unavailable")
        }
        lines.append(row.processCount == 1 ? "1 process" : "\(row.processCount) processes")
        if row.unreadableCount > 0 {
            lines.append("Partial reading: \(row.unreadableCount) of \(row.processCount) processes aren't readable.")
        }
        lines.append("Shared memory can overlap between apps.")
        if let launched = row.app.launchDate {
            lines.append("Running since " + launched.formatted(date: .abbreviated, time: .shortened))
        }
        return lines
    }
}
