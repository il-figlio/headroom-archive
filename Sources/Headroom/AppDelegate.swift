import AppKit
import SwiftUI
import HeadroomCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var monitor: MemoryMonitor!
    private var status: NSStatusItem!
    private let popover = NSPopover()
    private var notch: NotchController?
    private var fallback: NotchPanel?
    private var historyWindow: NSWindow?
    private let windows = UtilityWindows()
    private let settingsRouter = SettingsRouter()
    private var eventMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only, including launching a copied build.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        // Settles first-launch state before anything this launch writes preferences.
        let preferences = AppPreferences.shared
        monitor = MemoryMonitor()
        if let icon = AppBrand.icon { NSApp.applicationIconImage = icon }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self; status.button?.action = #selector(togglePanel)
        status.button?.image = StatusIndicator.image()
        status.button?.imagePosition = .imageLeading
        popover.behavior = .applicationDefined; popover.animates = false; popover.delegate = self
        popover.contentSize = PanelMetrics.size()
        PanelWidgets.shared.changed = { [weak self] in self?.resizePanels(); self?.monitor.widgetsChanged() }
        preferences.changed = { [weak self] in self?.resizePanels(); self?.monitor.limitsChanged() }
        popover.contentViewController = NSHostingController(rootView: PanelView(monitor: monitor, close: { [weak self] in self?.closePanel() }))
        monitor.changed = { [weak self] in self?.updateIndicator() }
        monitor.placementChanged = { [weak self] in self?.place() }
        monitor.openActivityMonitor = {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
        monitor.checkForUpdates = { [weak self] in
            self?.closePanel()
            self?.monitor.updater.check()
        }
        monitor.showHistory = { [weak self] in self?.showHistory() }
        monitor.showSettings = { [weak self] tab in self?.showSettings(tab) }
        monitor.showAbout = { [weak self] in self?.showAbout() }
        installMainMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(place), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, !self.monitor.alertVisible, !self.monitor.menuTracking else { return }
            if self.notch?.contains(NSEvent.mouseLocation) != true { self.closePanel() }
        }) { eventMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self, !self.monitor.alertVisible, !self.monitor.menuTracking else { return event }
            // Esc in Settings, Welcome, About or Trends closes that window instead.
            if event.type == .keyDown && event.keyCode == 53 && !(event.window is UtilityWindow) { self.closePanel(); return nil }
            if event.type != .keyDown, event.window !== self.popover.contentViewController?.view.window,
               event.window !== self.fallback,
               self.notch?.contains(NSEvent.mouseLocation) != true,
               event.window !== self.status.button?.window { self.closePanel() }
            return event
        }) { eventMonitors.append(local) }
        place(); updateIndicator()
        monitor.updater.start()
        if preferences.showWelcome {
            preferences.welcomePresented()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showWelcome() }
        }
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.togglePanel() }
        }
        if CommandLine.arguments.contains("--show-trends") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showHistory() }
        }
    }
    @objc private func place() {
        closePanel(); notch?.dispose(); notch = nil
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }
        if monitor.placement.usesNotch(available: screen != nil), let screen {
            notch = NotchController(screen: screen, monitor: monitor)
            status.isVisible = false
        } else { status.isVisible = true }
    }
    private func updateIndicator() {
        status.button?.attributedTitle = StatusIndicator.title(for: monitor)
        status.button?.toolTip = "Headroom · \(monitor.memory.pressure.title) pressure · \(MemoryFormat.string(monitor.memory.swap)) swap · \(MemoryFormat.string(monitor.disk.free)) disk free"
        status.button?.setAccessibilityLabel("Headroom, \(monitor.memory.pressure.title) memory pressure")
    }
    @objc private func togglePanel() {
        if let notch { notch.openPinned(); return }
        if popover.isShown || fallback?.isVisible == true { closePanel(); return }
        guard let button = status.button else { return }
        monitor.setDetailed(true)
        if let window = button.window, window.isVisible,
           NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            PanelMetrics.setScreen(window.screen ?? NSScreen.main)
            popover.contentSize = PanelMetrics.size()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        } else {
            // macOS can hide menu extras when the menu bar runs out of room.
            // Opening the app from Finder must still give access to its controls.
            let screen = NSScreen.main ?? NSScreen.screens[0]
            PanelMetrics.setScreen(screen)
            let size = PanelMetrics.size()
            let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 16,
                               y: screen.visibleFrame.maxY - size.height - 16,
                               width: size.width, height: size.height)
            let panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
            panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: PanelView(monitor: monitor, close: { [weak self] in self?.closePanel() }).clipShape(RoundedRectangle(cornerRadius: 16)))
            fallback = panel
            panel.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { togglePanel() }
        return true
    }
    private func showHistory() {
        closePanel()
        if historyWindow == nil {
            let window = UtilityWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Headroom · Trends"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(monitor: monitor))
            window.center()
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func showSettings(_ tab: SettingsTab? = nil) {
        closePanel()
        if let tab { settingsRouter.tab = tab }
        windows.show(.settings, title: "Headroom Settings") {
            SettingsView(monitor: monitor, router: settingsRouter, showAbout: { [weak self] in self?.showAbout() })
        }
    }
    func showAbout() {
        closePanel()
        windows.show(.about, title: "About Headroom") { AboutView() }
    }
    private func showWelcome() {
        closePanel()
        let notch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
        windows.show(.welcome, title: "Welcome to Headroom") {
            WelcomeView(monitor: monitor, updater: monitor.updater, notch: notch, done: { [weak self] in self?.windows.close(.welcome) })
        }
    }
    @objc private func openSettingsFromMenu(_ sender: Any?) { showSettings() }
    @objc private func openAboutFromMenu(_ sender: Any?) { showAbout() }
    /// Never shown (accessory apps have no menu bar), but its key equivalents
    /// still work while Headroom is active: ⌘, ⌘Q, and editing in text fields.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(title: "Headroom")
        appMenu.addItem(withTitle: "About Headroom", action: #selector(openAboutFromMenu(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Headroom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
    private func closePanel() {
        guard monitor != nil, !monitor.alertVisible else { return }
        popover.performClose(nil); fallback?.orderOut(nil); fallback = nil; notch?.close(); monitor.setDetailed(false)
    }
    func popoverDidClose(_ notification: Notification) { monitor.setDetailed(false) }
    /// Re-fit every host when the widget set changes — the popover resizes
    /// live, the fallback re-anchors to the top-right, the notch re-renders.
    private func resizePanels() {
        if notch == nil { PanelMetrics.setScreen(fallback?.screen ?? status.button?.window?.screen ?? NSScreen.main) }
        popover.contentSize = PanelMetrics.size()
        if let fallback, let screen = fallback.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let size = PanelMetrics.size()
            fallback.setFrame(NSRect(x: screen.visibleFrame.maxX - size.width - 16,
                                     y: screen.visibleFrame.maxY - size.height - 16,
                                     width: size.width, height: size.height), display: true)
        }
        notch?.refresh()
    }
    func applicationWillTerminate(_ notification: Notification) {
        eventMonitors.forEach(NSEvent.removeMonitor)
        notch?.dispose()
        monitor?.refreshLogBeforeQuit()
    }
}

/// The menu-bar status item's title, shared with the screenshot scenes.
enum StatusIndicator {
    static func image() -> NSImage? {
        AppBrand.menuIcon() ?? NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Headroom")
    }
    static func title(for monitor: MemoryMonitor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "  ● ", attributes: [.foregroundColor: monitor.memory.pressure.color, .font: NSFont.systemFont(ofSize: 10)])
        text.append(NSAttributedString(string: monitor.memory.valid ? MemoryFormat.compact(monitor.memory.used) : "—",
                                       attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]))
        // Disk only earns menu-bar space when it's genuinely getting tight.
        if monitor.disk.valid && monitor.disk.urgency != .ample {
            text.append(NSAttributedString(string: "  ● ", attributes: [.foregroundColor: monitor.disk.urgency.color, .font: NSFont.systemFont(ofSize: 10)]))
            text.append(NSAttributedString(string: MemoryFormat.compact(monitor.disk.free),
                                           attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]))
        }
        return text
    }
}
