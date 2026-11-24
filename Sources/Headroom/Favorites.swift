import AppKit

/// Pinned apps shown in the panel dock for one-click switching.
/// Persisted as a JSON array in UserDefaults so pin order survives launches.
public struct FavoriteApp: Identifiable, Equatable, Codable {
    public var id: String { bundleIdentifier }
    public var bundleIdentifier: String
    public var name: String
    public var bundlePath: String
    public init(bundleIdentifier: String, name: String, bundlePath: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundlePath = bundlePath
    }
}

/// The dock's backing store. Main-thread only; workspace launch/terminate
/// notifications republish so the running dots track app state.
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    @Published private(set) var items: [FavoriteApp] = []
    private let key = "favoriteApps"
    /// Icons are resolved once per app; they don't change while Headroom runs.
    private var iconCache: [String: NSImage?] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([FavoriteApp].self, from: data) {
            // Drop unusable entries and dupes so ForEach IDs stay unique.
            var seen = Set<String>()
            items = decoded.filter { !$0.bundleIdentifier.isEmpty && seen.insert($0.bundleIdentifier).inserted }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    /// Bundle ID-less apps can't be pinned: a favorite's entire identity —
    /// dedup, activation, running state — is its bundle identifier.
    func toggle(bundleIdentifier: String, name: String, bundlePath: String) {
        guard !bundleIdentifier.isEmpty else { return }
        if let index = items.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            items.remove(at: index)
            iconCache.removeValue(forKey: bundleIdentifier)
        } else {
            items.append(FavoriteApp(bundleIdentifier: bundleIdentifier, name: name, bundlePath: bundlePath))
        }
        save()
    }

    func isPinned(_ bundleIdentifier: String) -> Bool {
        !bundleIdentifier.isEmpty && items.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Focus the running instance when possible; launch only as a fallback.
    /// Silently no-ops when the pinned bundle path is empty or no longer exists.
    func activate(_ app: FavoriteApp) {
        if let running = running(app) {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }
        guard !app.bundlePath.isEmpty,
              FileManager.default.fileExists(atPath: app.bundlePath) else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.bundlePath), configuration: .init())
    }

    func icon(for app: FavoriteApp) -> NSImage? {
        if let cached = iconCache[app.bundleIdentifier] { return cached }
        let icon = running(app)?.icon
            ?? (app.bundlePath.isEmpty ? nil : NSWorkspace.shared.icon(forFile: app.bundlePath))
        icon?.size = NSSize(width: 24, height: 24)
        iconCache[app.bundleIdentifier] = icon
        return icon
    }

    func isRunning(_ app: FavoriteApp) -> Bool { running(app) != nil }

    private func running(_ app: FavoriteApp) -> NSRunningApplication? {
        guard !app.bundleIdentifier.isEmpty else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
            .first { !$0.isTerminated }
    }

    @objc private func appsChanged() { objectWillChange.send() }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }
}
