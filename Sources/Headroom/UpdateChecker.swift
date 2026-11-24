import AppKit
import HeadroomCore
import Sparkle
import SwiftUI

/// Reads the public GitHub releases list anonymously. Only the
/// `--check-for-updates` command-line diagnostic uses this; Sparkle reads the appcast.
enum GitHubUpdates {
    static func fetch() throws -> GitHubRelease? {
        var request = URLRequest(url: UpdatePolicy.releasesAPIURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        var outcome: Result<Data, Error> = .failure(Failure("GitHub did not respond."))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { outcome = .failure(error); return }
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200, let data else {
                outcome = .failure(Failure("GitHub returned an unexpected response for \(UpdatePolicy.repository) releases.")); return
            }
            outcome = .success(data)
        }.resume()
        done.wait()
        return try GitHubRelease.newest(in: outcome.get())
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Sparkle owns checking, verification, installation and relaunch. Updates are
/// public: no GitHub login or token is involved. The feed must be EdDSA-signed
/// (SURequireSignedFeed) and archives must carry Headroom's EdDSA signature.
final class UpdateChecker: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = true
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticInstalls = false
    private var started = false
    private var observations: [NSKeyValueObservation] = []
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    /// Bundles without a Sparkle key (e.g. `swift run`) never start the updater.
    func start() {
        guard !started, Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        started = true
        controller.startUpdater()
        observeSettings()
    }
    func check() {
        start()
        guard started else { return }
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled; automaticChecks = enabled }
    func setAutomaticInstalls(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled; automaticInstalls = enabled }

    private func observeSettings() {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in self?.canCheck = updater.canCheckForUpdates },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in self?.automaticChecks = updater.automaticallyChecksForUpdates },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in self?.automaticInstalls = updater.automaticallyDownloadsUpdates }
        ]
    }
    func feedURLString(for updater: SPUUpdater) -> String? { UpdatePolicy.feedURL.absoluteString }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard UpdatePolicy.allowsArchive(item.fileURL), item.installationType == "application" else {
            throw GitHubUpdates.Failure("The update does not point to a Headroom release download.")
        }
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    func standardUserDriverWillShowModalAlert() { NSApp.activate(ignoringOtherApps: true) }
}

struct UpdatesMenu: View {
    @ObservedObject var updater: UpdateChecker
    var check: () -> Void
    var body: some View {
        Button("Check for Updates…", action: check).disabled(!updater.canCheck)
        Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
        Toggle("Download and install updates automatically", isOn: Binding(get: { updater.automaticInstalls }, set: updater.setAutomaticInstalls))
    }
}
