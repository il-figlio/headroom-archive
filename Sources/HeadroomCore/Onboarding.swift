import Foundation

/// The slice of `UserDefaults` the launch migration needs, so tests can use
/// an in-memory store instead of real preferences.
public protocol PreferenceStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// First-launch decisions. Limits reads other apps' sign-ins and calls
/// unofficial endpoints, so a new install starts with it off; installs from
/// before it became opt-in keep it on and never see the welcome window.
public enum Onboarding {
    public static let limitsKey = "limitsEnabled"
    /// false: welcome window still due; true: shown (or not needed).
    public static let welcomeShownKey = "welcomeShown"
    /// Keys earlier builds write on launch or on the first change.
    public static let legacyKeys = ["placement", "panelWidgets", "panelWidgets.agentsOptInMigrated",
                                    "historyEnabled", "favoriteApps"]
    /// Files earlier builds create in Headroom's Application Support folder.
    public static let legacyFiles = ["history.sqlite", "quota-cache.json", "log.md"]

    public struct State: Equatable, Sendable {
        public var limitsEnabled: Bool
        public var showWelcome: Bool
        public init(limitsEnabled: Bool, showWelcome: Bool) {
            self.limitsEnabled = limitsEnabled; self.showWelcome = showWelcome
        }
    }

    /// Evidence that Headroom ran here before this launch. Call before
    /// anything this launch writes preferences or history.
    public static func isExistingInstall(store: PreferenceStore, supportDirectory: URL,
                                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        legacyKeys.contains { store.object(forKey: $0) != nil }
            || legacyFiles.contains { fileExists(supportDirectory.appendingPathComponent($0).path) }
    }

    /// Settles both keys once, then reads them. `existingInstall` is only
    /// evaluated when a key is still missing.
    public static func migrate(_ store: PreferenceStore, existingInstall: () -> Bool) -> State {
        if store.object(forKey: limitsKey) == nil || store.object(forKey: welcomeShownKey) == nil {
            let existing = existingInstall()
            if store.object(forKey: limitsKey) == nil { store.set(existing, forKey: limitsKey) }
            if store.object(forKey: welcomeShownKey) == nil { store.set(existing, forKey: welcomeShownKey) }
        }
        return State(limitsEnabled: store.object(forKey: limitsKey) as? Bool ?? false,
                     showWelcome: !(store.object(forKey: welcomeShownKey) as? Bool ?? true))
    }

    /// Marked when the window appears, so quitting from it doesn't bring it back.
    public static func welcomeShown(_ store: PreferenceStore) { store.set(true, forKey: welcomeShownKey) }
}
