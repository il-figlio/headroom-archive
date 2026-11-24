import Foundation
import HeadroomCore
import SwiftUI

/// Opt-ins that gate work, not just visibility. Created first thing at launch
/// so the install check sees preferences as the previous launch left them.
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    /// Off: the monitor reads no sign-ins, runs no CLI, makes no quota requests.
    @Published private(set) var limitsEnabled: Bool
    /// Settled at launch; the welcome window shows at most once per install.
    let showWelcome: Bool
    var changed: (() -> Void)?

    private init() {
        // Screenshot mode never reads or writes preferences.
        if ScreenshotExport.active { limitsEnabled = true; showWelcome = false; return }
        let defaults = UserDefaults.standard
        let state = Onboarding.migrate(defaults) {
            Onboarding.isExistingInstall(store: defaults, supportDirectory: HistoryStore.defaultDirectory)
                // The original local prototype's domain.
                || defaults.persistentDomain(forName: "org.memoryline.app") != nil
        }
        limitsEnabled = state.limitsEnabled
        showWelcome = state.showWelcome
    }

    func setLimitsEnabled(_ enabled: Bool) {
        guard enabled != limitsEnabled else { return }
        limitsEnabled = enabled
        if !ScreenshotExport.active { UserDefaults.standard.set(enabled, forKey: Onboarding.limitsKey) }
        changed?()
    }

    func welcomePresented() {
        guard !ScreenshotExport.active else { return }
        Onboarding.welcomeShown(UserDefaults.standard)
    }

    var limitsBinding: Binding<Bool> {
        Binding(get: { self.limitsEnabled }, set: { self.setLimitsEnabled($0) })
    }
}
