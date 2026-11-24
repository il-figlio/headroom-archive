import AppKit
import SwiftUI
import HeadroomCore

/// Renders the shipped SwiftUI views in an offscreen window. No screen capture permission,
/// provider requests, history writes, preference changes, or session scans are involved.
enum ScreenshotExport {
    static var active: Bool { CommandLine.arguments.contains("--screenshots") }

    static func run(directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = MemoryMonitor(preview: true)
        // Size as if on a laptop whose visible frame is 900 pt tall.
        PanelWidgets.shared.setScreenLimit(900 - PanelMetrics.screenMargin)
        try render(HistoryView(monitor: monitor), size: NSSize(width: 760, height: 1200),
                   title: "Trends & recommendations", to: directory.appendingPathComponent("trends-v2.png"))
        try ScreenshotScenes.render(directory: directory)
        guard CommandLine.arguments.contains("--screenshot-variants") else { return }
        try renderVariants(monitor: monitor, directory: directory)
    }

    /// Review-only renders (not part of docs): the bare panels, expanded
    /// Limits, light mode, the opt-in Agents card, and the hover bubbles at
    /// their natural size.
    private static func renderVariants(monitor: MemoryMonitor, directory: URL) throws {
        try render(NotchView(monitor: monitor, gap: 180, topHeight: 32, expanded: true, open: {}, close: {}),
                   size: NSSize(width: 400, height: PanelMetrics.size().height + 32),
                   title: "Notch panel", to: directory.appendingPathComponent("notch-panel-v2.png"))
        try render(NotchView(monitor: monitor, gap: 180, topHeight: 32, expanded: false, open: {}, close: {}),
                   size: NSSize(width: 320, height: 32),
                   title: "Collapsed notch", to: directory.appendingPathComponent("notch-indicator-v2.png"))
        try render(PanelView(monitor: monitor, close: {}), size: PanelMetrics.size(),
                   title: "Menu bar panel", to: directory.appendingPathComponent("menubar-panel-v1.png"))
        try render(PanelView(monitor: monitor, close: {}).environment(\.quotaExpandedByDefault, true), size: PanelMetrics.size(),
                   title: "Menu bar panel · Limits expanded", to: directory.appendingPathComponent("menubar-panel-limits-expanded.png"))
        try render(PanelView(monitor: monitor, close: {}), size: PanelMetrics.size(), scheme: .light,
                   title: "Menu bar panel · Light", to: directory.appendingPathComponent("menubar-panel-light.png"))
        PanelWidgets.shared.setForScreenshots([.memory, .disk, .quota, .agents])
        try render(NotchView(monitor: monitor, gap: 180, topHeight: 32, expanded: true, open: {}, close: {}),
                   size: NSSize(width: 400, height: PanelMetrics.size().height + 32),
                   title: "Notch panel · Agents on", to: directory.appendingPathComponent("notch-panel-agents.png"))
        try render(PanelView(monitor: monitor, close: {}), size: PanelMetrics.size(),
                   title: "Menu bar panel · Agents on", to: directory.appendingPathComponent("menubar-panel-agents.png"))
        try render(PanelView(monitor: monitor, close: {}), size: PanelMetrics.size(), scheme: .light,
                   title: "Menu bar panel · Agents on · Light", to: directory.appendingPathComponent("menubar-panel-agents-light.png"))
        // Smaller screen: the panel stops at the default cap and the cards scroll.
        PanelWidgets.shared.setScreenLimit(760)
        try render(PanelView(monitor: monitor, close: {}), size: PanelMetrics.size(),
                   title: "Menu bar panel · Agents on · 784 pt screen", to: directory.appendingPathComponent("menubar-panel-agents-small-screen.png"))
        PanelWidgets.shared.setScreenLimit(900 - PanelMetrics.screenMargin)
        PanelWidgets.shared.setForScreenshots([.memory, .disk, .agents])
        try render(PanelView(monitor: monitor, close: {}), size: PanelMetrics.size(),
                   title: "Menu bar panel · Agents, no Limits", to: directory.appendingPathComponent("menubar-panel-agents-only.png"))
        PanelWidgets.shared.setForScreenshots([.memory, .disk, .quota])
        // Limits visible with no readings yet (Agents off, the default): the
        // empty card must take no height away from the app list.
        let noQuotas = MemoryMonitor(preview: true)
        noQuotas.clearQuotasForScreenshots()
        try render(PanelView(monitor: noQuotas, close: {}), size: PanelMetrics.size(),
                   title: "Menu bar panel · Limits empty", to: directory.appendingPathComponent("menubar-panel-limits-empty.png"))

        try renderWindows(monitor: monitor, directory: directory)

        let now = Date()
        var bubbles: [(String?, [String])] = []
        for reading in monitor.quotas {
            for window in reading.windows.prefix(2) {
                let row = QuotaWindowRow(window: window, reading: reading, now: now,
                                         stale: QuotaDisplay.isStale(reading, now: now), color: .accentColor)
                bubbles.append(("\(QuotaDisplay.accountName(reading)) · \(QuotaDisplay.longLabel(window.label))", row.detailLines))
            }
        }
        let panel = PanelView(monitor: monitor, close: {})
        bubbles.append(("Memory · \(monitor.memory.pressure.title) pressure", panel.memoryDetail))
        bubbles.append(("Disk · \(MemoryFormat.string(monitor.disk.free)) free", panel.diskDetail))
        if let app = monitor.apps.first { bubbles.append((app.app.name, AppRow(row: app, maxBytes: 0, monitor: monitor).detail)) }
        for session in monitor.agents.sessions.prefix(2) {
            let row = AgentSessionRow(session: session, now: now, monitor: monitor)
            bubbles.append(("\(row.project) — \(session.kind.title)", row.detailLines))
        }
        if let bucket = monitor.agentBurn.last(where: { $0.tokens.count > 1 }) {
            let column = BurnColumn(bucket: bucket, kinds: [.claude, .codex], maxTokens: 1)
            bubbles.append((column.title, column.lines))
        }
        for scheme in [ColorScheme.dark, .light] {
            // Each bubble at the size the live HoverBubble would measure, so
            // clipping here means clipping on screen.
            let measured = bubbles.map { bubble -> NSSize in
                HoverBubble.measure(HoverBubbleChrome(content: HoverDetailText(title: bubble.0, lines: bubble.1))
                    .environment(\.colorScheme, scheme))
            }
            let half = (bubbles.count + 1) / 2
            let column = { (range: Range<Int>) in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(range), id: \.self) { index in
                        HoverBubbleChrome(content: HoverDetailText(title: bubbles[index].0, lines: bubbles[index].1))
                            .frame(width: measured[index].width, height: measured[index].height, alignment: .topLeading)
                    }
                }
            }
            let height = { (range: Range<Int>) in range.map { measured[$0].height }.reduce(0, +) + CGFloat(max(0, range.count - 1)) * 10 }
            let sheet = HStack(alignment: .top, spacing: 12) { column(0..<half); column(half..<bubbles.count) }
                .padding(12).environment(\.colorScheme, scheme)
            let size = NSSize(width: HoverBubble.maxWidth * 2 + 36,
                              height: max(height(0..<half), height(half..<bubbles.count)) + 24)
            try render(sheet, size: size, scheme: scheme, title: "Hover details",
                       to: directory.appendingPathComponent("hover-details-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    /// Welcome, Settings tabs and About at their window content size.
    /// Limits off for the welcome render: that's how a new install sees it.
    private static func renderWindows(monitor: MemoryMonitor, directory: URL) throws {
        let preferences = AppPreferences.shared
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            preferences.setLimitsEnabled(false)
            PanelWidgets.shared.setForScreenshots([.memory, .disk, .quota])
            try renderWindow(WelcomeView(monitor: monitor, updater: monitor.updater, notch: true, done: {}), scheme: scheme,
                             title: "Welcome (new install)", to: directory.appendingPathComponent("welcome-\(suffix).png"))
            try renderWindow(AboutView(), scheme: scheme, title: "About", to: directory.appendingPathComponent("about-\(suffix).png"))
            for tab in SettingsTab.allCases {
                let router = SettingsRouter(); router.tab = tab
                try renderWindow(SettingsView(monitor: monitor, router: router), scheme: scheme,
                                 title: "Settings · \(tab.title)" + (tab == .limits ? " · off" : ""),
                                 to: directory.appendingPathComponent("settings-\(tab.rawValue)-\(suffix).png"))
            }
            preferences.setLimitsEnabled(true)
            let router = SettingsRouter(); router.tab = .limits
            try renderWindow(SettingsView(monitor: monitor, router: router), scheme: scheme, title: "Settings · Limits · on",
                             to: directory.appendingPathComponent("settings-limits-on-\(suffix).png"))
        }
        // The panel a new install opens: Limits off, so no card and no checks.
        preferences.setLimitsEnabled(false)
        try render(PanelView(monitor: monitor, close: {}), size: PanelMetrics.size(),
                   title: "Menu bar panel · Limits off", to: directory.appendingPathComponent("menubar-panel-limits-off.png"))
        preferences.setLimitsEnabled(true)
    }

    private static func renderWindow<V: View>(_ content: V, scheme: ColorScheme, title: String, to url: URL) throws {
        let probe = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        let size = probe.fittingSize
        try render(content.background(Color(nsColor: .windowBackgroundColor)), size: size, scheme: scheme, title: title, to: url)
    }

    /// `title` names the render in its caption; nil leaves just "Demo data".
    /// `scale` overrides `--screenshot-scale` for renders that always ship at 2x.
    static func render<V: View>(_ content: V, size: NSSize, scheme: ColorScheme = .dark, title: String?,
                                scale fixedScale: Double? = nil, to url: URL) throws {
        let root = VStack(spacing: 14) {
            content.frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 16))
            Text(title.map { "\($0) · Demo data" } ?? "Demo data").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }.padding(24).background(scheme == .dark ? Color(red: 0.085, green: 0.09, blue: 0.10) : Color(red: 0.86, green: 0.87, blue: 0.89))
            .environment(\.colorScheme, scheme)
        let frame = NSRect(x: -12000, y: -12000, width: size.width + 48, height: size.height + 74)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()
        // `--screenshot-scale 2` renders Retina-density PNGs for review.
        let scaleIndex = CommandLine.arguments.firstIndex(of: "--screenshot-scale")
        let scale = fixedScale ?? scaleIndex.flatMap { CommandLine.arguments.count > $0 + 1 ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 1
        let bitmap: NSBitmapImageRep
        if scale > 1, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale),
                                                  pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = host.bounds.size
            bitmap = rep
        } else if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            bitmap = rep
        } else {
            throw NSError(domain: "Headroom.Screenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate screenshot bitmap."])
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Headroom.Screenshots", code: 2)
        }
        try png.write(to: url, options: .atomic)
        window.orderOut(nil)
        print(url.path)
    }
}
