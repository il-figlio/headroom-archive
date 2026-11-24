import Foundation
import Testing
@testable import HeadroomCore

/// In-memory preferences; the real UserDefaults domain is never touched.
private final class MemoryStore: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private let support = URL(fileURLWithPath: "/nonexistent/Headroom", isDirectory: true)

@Suite struct OnboardingChecks {
    @Test func newInstallStartsWithLimitsOffAndShowsWelcome() {
        let store = MemoryStore()
        let state = Onboarding.migrate(store) { Onboarding.isExistingInstall(store: store, supportDirectory: support, fileExists: { _ in false }) }
        #expect(state == Onboarding.State(limitsEnabled: false, showWelcome: true))
        #expect(store.values[Onboarding.limitsKey] as? Bool == false)
        #expect(store.values[Onboarding.welcomeShownKey] as? Bool == false)
    }

    @Test func everyLegacyKeyMarksAnExistingInstall() {
        for key in Onboarding.legacyKeys {
            let store = MemoryStore()
            store.values[key] = "x"
            let state = Onboarding.migrate(store) { Onboarding.isExistingInstall(store: store, supportDirectory: support, fileExists: { _ in false }) }
            #expect(state == Onboarding.State(limitsEnabled: true, showWelcome: false), "\(key)")
        }
    }

    @Test func legacyFilesMarkAnExistingInstall() {
        for file in Onboarding.legacyFiles {
            let path = support.appendingPathComponent(file).path
            #expect(Onboarding.isExistingInstall(store: MemoryStore(), supportDirectory: support, fileExists: { $0 == path }), "\(file)")
        }
        #expect(!Onboarding.isExistingInstall(store: MemoryStore(), supportDirectory: support,
                                              fileExists: { $0 == support.appendingPathComponent("other.txt").path }))
    }

    @Test func realFilesAreCheckedInTheSupportDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!Onboarding.isExistingInstall(store: MemoryStore(), supportDirectory: dir))
        try Data("[]".utf8).write(to: dir.appendingPathComponent("quota-cache.json"))
        #expect(Onboarding.isExistingInstall(store: MemoryStore(), supportDirectory: dir))
    }

    /// Later launches read the settled keys, even though by then this
    /// launch's own writes (widgets, history) look like an existing install.
    @Test func decisionIsSettledOnFirstLaunch() {
        let store = MemoryStore()
        _ = Onboarding.migrate(store) { false }
        store.values["panelWidgets"] = "disk,memory"
        var evaluated = false
        let next = Onboarding.migrate(store) { evaluated = true; return true }
        #expect(!evaluated)
        #expect(next.limitsEnabled == false)
    }

    @Test func welcomeShowsOnceThenNeverAgain() {
        let store = MemoryStore()
        #expect(Onboarding.migrate(store) { false }.showWelcome)
        // Not yet presented (e.g. quit during launch): still due.
        #expect(Onboarding.migrate(store) { true }.showWelcome)
        Onboarding.welcomeShown(store)
        #expect(!Onboarding.migrate(store) { false }.showWelcome)
        #expect(!Onboarding.migrate(store) { false }.showWelcome)
    }

    @Test func userChoiceSurvivesMigration() {
        let on = MemoryStore()
        on.values[Onboarding.limitsKey] = true
        #expect(Onboarding.migrate(on) { false }.limitsEnabled)
        let off = MemoryStore()
        off.values[Onboarding.limitsKey] = false
        off.values["placement"] = "notch"
        let state = Onboarding.migrate(off) { Onboarding.isExistingInstall(store: off, supportDirectory: support, fileExists: { _ in false }) }
        #expect(!state.limitsEnabled)
        // The welcome key was missing, so it follows the install evidence.
        #expect(!state.showWelcome)
    }
}

/// Throwaway homes only; the real ~/.codex, ~/.claude and ~/.ante are never read.
@Suite struct LimitsDetectionChecks {
    private func home() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("limits-detect-\(UUID().uuidString)") }
    private func touch(_ home: URL, _ relative: String, executable: Bool = false) {
        let file = home.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: file)
        if executable { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
    }

    @Test func namesOnlyNoTokens() {
        let url = home(); defer { try? FileManager.default.removeItem(at: url) }
        #expect(QuotaSources.detectedNames(home: url).isEmpty)
        touch(url, ".codex/auth.json")
        #expect(QuotaSources.detectedNames(home: url) == ["Codex"])
        touch(url, ".claude/.credentials.json")
        #expect(QuotaSources.detectedNames(home: url) == ["Codex", "Claude (Claude Code — file)"])
        touch(url, AnteClaudeQuotaSource.executablePath, executable: true)
        touch(url, AnteClaudeQuotaSource.directory + "/work.json")
        touch(url, AnteClaudeQuotaSource.directory + "/personal.json")
        #expect(QuotaSources.detectedNames(home: url) == ["Codex", "Claude (Ante: personal, work)"])
        #expect(QuotaSources.detect(home: url).claudeCodeHidden)
    }
}
