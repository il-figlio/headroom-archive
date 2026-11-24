import AppKit
import SwiftUI

/// Hover tracking + a small detail bubble that work where `.help` doesn't:
/// the notch expands on hover without activating Headroom, and AppKit only
/// shows tooltips for the active app. Each region owns an AppKit tracking
/// area with `.activeAlways` (fires in a non-key, non-activating panel of an
/// inactive app); the bubble is its own borderless, mouse-transparent panel,
/// so the ScrollView and panel edges can't clip it and it never takes focus.
extension View {
    /// Shows `detail` in a bubble after a short hover; `hovering` mirrors the
    /// pointer state for row highlights.
    func hoverDetail<Detail: View>(hovering: Binding<Bool>? = nil,
                                   @ViewBuilder _ detail: @escaping () -> Detail) -> some View {
        background(HoverRegion(onHover: hovering.map { binding in { binding.wrappedValue = $0 } },
                               detail: { AnyView(detail()) }).allowedInScreenshots())
    }

    /// Title plus plain lines — the common bubble shape.
    func hoverDetail(_ title: String?, _ lines: [String], hovering: Binding<Bool>? = nil) -> some View {
        hoverDetail(hovering: hovering) { HoverDetailText(title: title, lines: lines) }
    }

    /// Highlight-only tracking with the same always-active semantics.
    func trackHover(_ hovering: Binding<Bool>) -> some View {
        background(HoverRegion(onHover: { hovering.wrappedValue = $0 }, detail: nil).allowedInScreenshots())
    }
}

/// Standard bubble body: bold title, secondary lines.
struct HoverDetailText: View {
    let title: String?
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title { Text(title).font(.system(size: 11, weight: .semibold)) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Chrome shared by the live bubble and the screenshot sheet.
struct HoverBubbleChrome<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: HoverBubble.maxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.985)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

private extension HoverRegion {
    /// Screenshot export renders with no hover sensors at all, so no row can
    /// carry hover state into a capture.
    @ViewBuilder func allowedInScreenshots() -> some View {
        if !ScreenshotExport.active { self }
    }
}

private struct HoverRegion: NSViewRepresentable {
    var onHover: ((Bool) -> Void)?
    var detail: (() -> AnyView)?

    func makeNSView(context: Context) -> HoverTrackingView { HoverTrackingView() }
    func updateNSView(_ view: HoverTrackingView, context: Context) {
        view.onHover = onHover
        view.detail = detail
        view.colorScheme = context.environment.colorScheme
    }
    static func dismantleNSView(_ view: HoverTrackingView, coordinator: ()) { view.reset() }
}

final class HoverTrackingView: NSView {
    var onHover: ((Bool) -> Void)?
    var detail: (() -> AnyView)?
    var colorScheme: ColorScheme = .light
    private var area: NSTrackingArea?
    private var pending: DispatchWorkItem?
    private(set) var inside = false

    /// Purely a sensor: clicks and scrolls go to the SwiftUI content above.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // SwiftUI's platform-view hosts don't clip, which makes `visibleRect`
        // spill past the row; clip so the sensor is exactly the row.
        if #available(macOS 14, *) { clipsToBounds = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Explicit rect (not `.inVisibleRect`): bounds clipped to what the
    /// enclosing scroll view shows. `.activeAlways` is the point — it fires
    /// while the notch panel isn't key and Headroom isn't the active app.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = nil
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        let tracking = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking); area = tracking
        scheduleSync()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { setInside(true) }
    override func mouseExited(with event: NSEvent) { setInside(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { reset() } else { updateTrackingAreas() }
    }

    func reset() { if inside { setInside(false) } else { pending?.cancel(); HoverBubble.shared.hide(owner: self) } }

    /// A recreated tracking area doesn't report the pointer it was created
    /// under, and content that scrolls or re-lays out from under a still
    /// pointer never gets `mouseExited`. Re-check against the pointer after
    /// the layout pass (not during it: `onHover` writes SwiftUI state).
    private var syncScheduled = false
    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncScheduled = false
            self?.syncWithPointer()
        }
    }
    func syncWithPointer() {
        let pointer = NSEvent.mouseLocation
        guard let window, window.isVisible, let rect = screenRect else {
            if inside { setInside(false) }
            return
        }
        if inside {
            if !rect.insetBy(dx: -1, dy: -1).contains(pointer) { setInside(false) }
        } else if rect.contains(pointer),
                  NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0) == window.windowNumber {
            setInside(true)
        }
    }

    /// Regions currently reporting the pointer inside. While any is, one
    /// shared timer and a scroll monitor keep re-checking them, so a missed
    /// exit can't leave a row highlighted (or its row buttons revealed).
    private static let insideViews = NSHashTable<HoverTrackingView>.weakObjects()
    private static var insideWatch: Timer?
    private static var scrollMonitor: Any?
    private static func watch(_ view: HoverTrackingView, _ inside: Bool) {
        if inside { insideViews.add(view) } else { insideViews.remove(view) }
        if insideViews.allObjects.isEmpty {
            stopWatching()
        } else if insideWatch == nil {
            insideWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in recheckInside() }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                // After the scroll has moved the content.
                DispatchQueue.main.async { recheckInside() }
                return event
            }
        }
    }
    private static func stopWatching() {
        insideWatch?.invalidate(); insideWatch = nil
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        scrollMonitor = nil
    }
    private static func recheckInside() {
        let views = insideViews.allObjects
        if views.isEmpty { stopWatching() }
        for view in views { view.syncWithPointer() }
    }

    /// Screen rect of the region, clipped to what's visible in its scroll view.
    var screenRect: NSRect? {
        guard let window else { return nil }
        let visible = bounds.intersection(visibleRect)
        guard !visible.isEmpty else { return nil }
        return window.convertToScreen(convert(visible, to: nil))
    }

    func setInside(_ value: Bool) {
        guard value != inside else { return }
        inside = value
        Self.watch(self, value)
        onHover?(value)
        pending?.cancel(); pending = nil
        if value, detail != nil {
            let item = DispatchWorkItem { [weak self] in self?.showBubble() }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + HoverBubble.delay, execute: item)
        } else {
            HoverBubble.shared.hide(owner: self)
        }
    }

    private func showBubble() {
        guard inside, let window, window.isVisible, let detail, let anchor = screenRect else { return }
        HoverBubble.shared.show(detail(), anchor: anchor, parent: window, scheme: colorScheme, owner: self)
    }
}

/// One shared bubble window. Mouse-transparent and never key, so showing it
/// can't steal focus from the panel or the frontmost app.
final class HoverBubble {
    static let shared = HoverBubble()
    static let delay: TimeInterval = 0.35
    static let maxWidth: CGFloat = 270

    private var panel: NSPanel?
    private weak var owner: HoverTrackingView?
    private var monitors: [Any] = []
    private var watchdog: Timer?

    func show(_ content: AnyView, anchor: NSRect, parent: NSWindow, scheme: ColorScheme, owner: HoverTrackingView) {
        let panel = self.panel ?? makePanel()
        self.panel = panel; self.owner = owner
        panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let root = HoverBubbleChrome(content: content).environment(\.colorScheme, scheme)
        let size = Self.measure(root)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.level = NSWindow.Level(rawValue: max(parent.level.rawValue, NSWindow.Level.popUpMenu.rawValue) + 1)
        panel.setFrame(frame(for: size, anchor: anchor, screen: parent.screen ?? NSScreen.main), display: true)
        panel.orderFrontRegardless()
        installMonitors()
    }

    func hide(owner: HoverTrackingView? = nil) {
        if let owner, owner !== self.owner { return }
        panel?.orderOut(nil)
        self.owner = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        watchdog?.invalidate(); watchdog = nil
    }

    /// `fittingSize` measures text unwrapped and underreports wrapped
    /// height, so measure the single-line width first, then the height at
    /// the capped width.
    static func measure<V: View>(_ view: V) -> NSSize {
        let controller = NSHostingController(rootView: view)
        let unbounded = CGFloat(10_000)
        let ideal = controller.sizeThatFits(in: NSSize(width: unbounded, height: unbounded))
        let width = min(ceil(ideal.width), maxWidth)
        let fitted = controller.sizeThatFits(in: NSSize(width: width, height: unbounded))
        return NSSize(width: width, height: ceil(fitted.height))
    }

    /// Below the region near the pointer; flips above near the screen bottom.
    private func frame(for size: NSSize, anchor: NSRect, screen: NSScreen?) -> NSRect {
        let bounds = screen?.frame ?? anchor.insetBy(dx: -2000, dy: -2000)
        let pointer = NSEvent.mouseLocation.x
        var x = (anchor.minX...anchor.maxX).contains(pointer) ? pointer - 14 : anchor.minX
        x = min(max(x, bounds.minX + 6), bounds.maxX - size.width - 6)
        var y = anchor.minY - 6 - size.height
        if y < bounds.minY + 6 { y = anchor.maxY + 6 }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }

    /// Clicks, keys and scrolls dismiss; the watchdog catches exits AppKit
    /// never reports (panel collapsed or popover closed under the pointer,
    /// content scrolled away).
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.hide(); return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.hide()
        }) { monitors.append(global) }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let owner = self.owner, owner.inside, owner.window?.isVisible == true,
                  let rect = owner.screenRect, rect.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) else {
                self.owner?.setInside(false)
                self.hide(); return
            }
        }
    }
}
