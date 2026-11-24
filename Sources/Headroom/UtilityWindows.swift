import AppKit
import SwiftUI

/// Titled window for an accessory app: Esc and ⌘W close it (there is no
/// visible menu bar to carry a Close item).
final class UtilityWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// One instance each of Settings, Welcome and About. Headroom is an
/// LSUIElement app, so opening one activates Headroom explicitly, and
/// closing the last one hands focus back to the app the user came from
/// instead of leaving an active app with no windows.
final class UtilityWindows: NSObject, NSWindowDelegate {
    enum Kind { case settings, welcome, about }

    private var windows: [Kind: NSWindow] = [:]
    /// The last other app to be frontmost — also covers arriving from the
    /// panel, which activates Headroom before a window opens.
    private var previousApp = NSWorkspace.shared.frontmostApplication
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self?.previousApp = app
        }
    }
    deinit { observer.map(NSWorkspace.shared.notificationCenter.removeObserver) }

    func close(_ kind: Kind) { windows[kind]?.performClose(nil) }

    func show<Content: View>(_ kind: Kind, title: String, @ViewBuilder content: () -> Content) {
        let window = windows[kind] ?? {
            let host = NSHostingController(rootView: content())
            let window = UtilityWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = title
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(host.view.fittingSize)
            window.center()
            windows[kind] = window
            return window
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Dropped so the next open starts fresh (and the SwiftUI tree is freed).
        if let kind = windows.first(where: { $0.value === closing })?.key { windows[kind] = nil }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stillOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
            guard !stillOpen else { return }
            if NSApp.isActive, let previous = self.previousApp, !previous.isTerminated {
                previous.activate(options: [])
            }
        }
    }
}
