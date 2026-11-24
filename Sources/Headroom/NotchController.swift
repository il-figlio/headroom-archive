import AppKit
import SwiftUI
import HeadroomCore

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class HoverContainer: NSView {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
}

private struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 18
        path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - r), control: CGPoint(x: 0, y: rect.maxY))
        path.closeSubpath(); return path
    }
}

struct NotchView: View {
    @ObservedObject var monitor: MemoryMonitor
    let gap: CGFloat
    let topHeight: CGFloat
    let expanded: Bool
    var open: () -> Void
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: open) {
                    HStack(spacing: 4) {
                        BrandIcon(size: 14)
                        Text(String(format: "%.0fG", Double(monitor.memory.used) / 1_073_741_824))
                            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.leading, 10)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open Headroom")
                    .accessibilityLabel("Open Headroom")
                Color.clear.frame(width: gap)
                Button(action: open) {
                    HStack(spacing: 4) {
                        if monitor.disk.valid && monitor.disk.urgency != .ample {
                            Image(systemName: "internaldrive.fill").font(.system(size: 8))
                                .foregroundStyle(Color(nsColor: monitor.disk.urgency.color))
                        }
                        Circle().fill(Color(nsColor: monitor.memory.pressure.color)).frame(width: 6, height: 6)
                        Text(monitor.memory.pressure.title).font(.system(size: 10, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.trailing, 10)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("Headroom: \(monitor.memory.pressure.title) memory pressure, \(MemoryFormat.string(monitor.disk.free)) disk free")
                    .accessibilityLabel("Open memory pressure panel")
            }.foregroundStyle(.white).frame(height: topHeight)
            if expanded { PanelView(monitor: monitor, close: close, isNotch: true) }
        }
        .background(Color.black).clipShape(NotchShape())
        .preferredColorScheme(.dark)
        .onExitCommand(perform: close)
    }
}

final class NotchController {
    let screen: NSScreen
    private let monitor: MemoryMonitor
    private let panel: NotchPanel
    private let container = HoverContainer()
    private var hosted: NSHostingView<NotchView>?
    private var work: DispatchWorkItem?
    private(set) var expanded = false
    private var pinned = false
    private var gap: CGFloat {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return 180 }
        return max(120, right.minX - left.maxX)
    }
    private var center: CGFloat {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return screen.frame.midX }
        return screen.frame.minX + (left.maxX + right.minX) / 2
    }
    private var topHeight: CGFloat { max(30, screen.safeAreaInsets.top) }

    init(screen: NSScreen, monitor: MemoryMonitor) {
        self.screen = screen; self.monitor = monitor
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentView = container
        container.entered = { [weak self] in self?.hover(true) }
        container.exited = { [weak self] in self?.hover(false) }
        render()
        panel.orderFrontRegardless()
    }
    func contains(_ point: NSPoint) -> Bool { panel.frame.contains(point) }
    private func hover(_ inside: Bool) {
        work?.cancel()
        if !inside && (pinned || monitor.alertVisible || monitor.menuTracking) { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, inside || (!self.pinned && !self.monitor.alertVisible && !self.monitor.menuTracking) else { return }
            self.setExpanded(inside)
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.18 : 0.4), execute: item)
    }
    func setExpanded(_ value: Bool) {
        work?.cancel()
        guard expanded != value else { return }
        expanded = value
        monitor.setDetailed(value)
        render()
    }
    func openPinned() { pinned = true; setExpanded(true); panel.makeKey(); NSApp.activate(ignoringOtherApps: true) }
    func close() { pinned = false; setExpanded(false) }
    func dispose() { work?.cancel(); panel.orderOut(nil); monitor.setDetailed(false) }
    /// Recomputes the panel frame — used when the visible widget set changes
    /// while the panel is already expanded.
    func refresh() { render() }
    private func render() {
        PanelMetrics.setScreen(screen)
        let width = expanded ? max(PanelMetrics.width, gap + 140) : gap + 140
        let content = NotchView(monitor: monitor, gap: gap, topHeight: topHeight, expanded: expanded,
                                open: { [weak self] in self?.openPinned() }, close: { [weak self] in self?.close() })
        if let hosted { hosted.rootView = content }
        else {
            let host = NSHostingView(rootView: content)
            container.addSubview(host); hosted = host
        }
        let height = topHeight + (expanded ? PanelMetrics.size().height : 0)
        panel.setFrame(NSRect(x: center - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
        hosted?.frame = container.bounds
        hosted?.autoresizingMask = [.width, .height]
        panel.hasShadow = expanded
    }
}
