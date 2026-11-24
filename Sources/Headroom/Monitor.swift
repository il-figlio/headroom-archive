import AppKit
import Combine
import HeadroomCore
import os
import ServiceManagement

extension Pressure {
    var color: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }
}

extension DiskUrgency {
    var color: NSColor {
        switch self {
        case .ample: return .systemGreen
        case .low: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

/// All termination paths revalidate identity so a stale row cannot quit a reused PID.
enum AppTermination {
    static func resolve(_ identity: AppIdentity) -> NSRunningApplication? {
        guard identity.pid != ProcessInfo.processInfo.processIdentifier,
              identity.bundleIdentifier != "com.apple.finder",
              let app = NSRunningApplication(processIdentifier: identity.pid),
              !app.isTerminated, app.activationPolicy == .regular,
              app.bundleURL?.path == identity.bundlePath,
              app.bundleIdentifier == identity.bundleIdentifier,
              let launched = identity.launchDate, app.launchDate == launched else { return nil }
        return app
    }
    static func request(_ identity: AppIdentity, force: Bool) -> Bool {
        guard let app = resolve(identity) else { return false }
        return force ? app.forceTerminate() : app.terminate()
    }
}

/// Signposts (subsystem org.headroom.app, category "sampling") plus one
/// debug-level duration line per interval. Both are near-free unless a
/// signpost/debug consumer is attached (`log stream --signpost --level debug`).
enum SamplingTrace {
    static let signposter = OSSignposter(subsystem: "org.headroom.app", category: "sampling")
    static let logger = Logger(subsystem: "org.headroom.app", category: "sampling")
    struct Interval {
        let name: StaticString
        let state: OSSignpostIntervalState
        let start: UInt64
    }
    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()),
                 start: DispatchTime.now().uptimeNanoseconds)
    }
    static func end(_ interval: Interval) {
        signposter.endInterval(interval.name, interval.state)
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- interval.start) / 1_000_000
        logger.debug("\(interval.name.description, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public) ms")
    }
}

final class MemoryMonitor: ObservableObject {
    let isPreview: Bool
    @Published private(set) var memory = SystemMemory.read()
    @Published private(set) var disk = DiskSpace.read()
    @Published private(set) var apps: [AppMemory] = []
    @Published private(set) var loading = true
    @Published private(set) var pending = Set<Int32>()
    @Published var message: String?
    @Published var placement: Placement {
        didSet { UserDefaults.standard.set(placement.rawValue, forKey: "placement"); placementChanged?() }
    }
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var alertVisible = false
    @Published private(set) var trends = TrendSummary()
    @Published private(set) var consumers = ConsumerScan()
    /// Detected coding-agent sessions and today's token totals.
    @Published private(set) var agents = AgentSnapshot()
    /// Hourly token/cost burn per agent family over the trailing 48h,
    /// ascending by hour. Hours with no usage are omitted — the chart
    /// renders the sparse buckets as-is rather than zero-filling gaps.
    @Published private(set) var agentBurn: [HourBurn] = []
    /// Subscription quota windows per provider, fetched by reusing the local
    /// OAuth credentials the CLIs already minted (Codex ~/.codex/auth.json,
    /// Claude ~/.claude/.credentials.json). Read-only — tokens are never
    /// refreshed or written back; the owning CLI does that itself. Empty, and
    /// never fetched, while `AppPreferences.limitsEnabled` is off.
    @Published private(set) var quotas: [QuotaReading] = []
    /// Non-nil while a consumer scan runs; shows progress for the storage view.
    @Published private(set) var consumerScanText: String?
    @Published private(set) var historyError: String?
    /// Main-owned. The latest record() and agent load/commit outcomes behind
    /// `historyError`, tracked apart so a successful agent commit clears only
    /// its own error and a successful record() doesn't hide a failing commit.
    private var recordError: String?
    private var agentSaveError: String?
    @Published var historyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(historyEnabled, forKey: "historyEnabled")
            if historyEnabled { queue.async { [weak self] in self?.lastRecordedAt = .distantPast }; sample() }
        }
    }
    var menuTracking = false
    var placementChanged: (() -> Void)?
    var changed: (() -> Void)?
    var openActivityMonitor: (() -> Void)?
    var showHistory: (() -> Void)?
    /// nil keeps whichever tab Settings last showed.
    var showSettings: ((SettingsTab?) -> Void)?
    var showAbout: (() -> Void)?
    var checkForUpdates: (() -> Void)?
    let updater = UpdateChecker()
    /// Main-owned, like `historyEnabled`; each sample snapshots both.
    private(set) var detailed = false
    private let queue = DispatchQueue(label: "org.headroom.sampling", qos: .utility)
    private let scanQueue = DispatchQueue(label: "org.headroom.consumerscan", qos: .utility)
    private var scanner: ConsumerScanner?
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Main-owned. A sample requested while one is in flight sets
    /// `samplePending`, and exactly one more runs when the current one lands.
    private var busy = false
    private var samplePending = false
    private var sleeping = false
    /// Main-owned mirror of the Agents widget, to notice it being turned on.
    private var agentsVisible = false
    private var panelOpenTrace: SamplingTrace.Interval?
    private var order: [Int32] = []
    // Everything below is confined to `queue`.
    private var historyStore: HistoryStore?
    private let agentScanner = AgentScanner()
    private var lastAgentScanAt = Date.distantPast
    private var agentSessions: [AgentSession] = []
    private var agentOffsets: [String: Int64] = [:]
    private var agentIdentities: [String: AgentFileID] = [:]
    /// Latest scan's snapshot, re-measured for footprints between scans.
    private var lastAgentSnapshot: AgentSnapshot?
    /// Burn accumulation mirrored into the published `agentBurn`; seeded from
    /// `agent_usage` when agent state first loads.
    private var agentBurnBuckets: [HourBurn] = []
    private var agentStateLoaded = false
    /// Quota polls follow `QuotaPolicy.interval` — Anthropic's usage endpoint
    /// rate-limits hard, and these windows move slowly anyway.
    private var lastQuotaFetchAt = Date.distantPast
    private var quotaFetchInFlight = false
    /// Claude Code sign-in change checks (metadata only) run at most this often.
    private var lastSignInCheckAt = Date.distantPast
    /// Instant display after relaunch; lives in our own Application Support dir.
    private static let quotaCacheURL = HistoryStore.defaultDirectory.appendingPathComponent("quota-cache.json")
    /// Burn window shown by the panel chart.
    private static let burnWindow: TimeInterval = 48 * 3600
    /// Authoritative record state, compared against the *fresh* pressure reading.
    private var lastRecordedAt = Date.distantPast
    private var recordedPressure: Pressure = .unknown
    private var iconCache: [String: NSImage?] = [:]

    init(preview: Bool = false, machine: ScreenshotFixtures.Machine = .laptop) {
        isPreview = preview
        if preview {
            placement = .automatic; historyEnabled = true
            let demo = ScreenshotFixtures(machine: machine)
            memory = demo.memory; disk = demo.disk; apps = demo.apps
            trends = demo.summary; consumers = demo.summary.consumers; quotas = demo.quotas
            agents = demo.agents; agentBurn = demo.agentBurn // UI-STUB: preview-only demo agents for screenshots
            loading = false
            return
        }
        // Keep the placement preference from the original local prototype.
        if UserDefaults.standard.string(forKey: "placement") == nil,
           let old = UserDefaults.standard.persistentDomain(forName: "org.memoryline.app")?["placement"] as? String {
            UserDefaults.standard.set(old, forKey: "placement")
        }
        placement = Placement(rawValue: UserDefaults.standard.string(forKey: "placement") ?? "") ?? .automatic
        historyEnabled = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true
        agentsVisible = PanelWidgets.shared.isVisible(.agents)
        pressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressureSource?.setEventHandler { [weak self] in
            self?.sample()
        }
        pressureSource?.resume()
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        notifications.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        notifications.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuStarted), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        // Enqueued before the first timer sample: the quota cache is on screen
        // (and is the merge base) before any fetch can land; agent state loads
        // lazily on the first scan, and only if Agents is visible.
        let limitsEnabled = AppPreferences.shared.limitsEnabled
        queue.async { [weak self] in
            guard let self else { return }
            if limitsEnabled { self.loadQuotaCache() }
            do {
                let store = try HistoryStore()
                self.historyStore = store
                let summary = try store.summary()
                DispatchQueue.main.async {
                    self.trends = summary
                    self.consumers = summary.consumers
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self.historyError = message }
            }
            let now = Date()
            if QuotaPolicy.shouldPoll(enabled: limitsEnabled, inFlight: self.quotaFetchInFlight,
                                      lastPollAt: self.lastQuotaFetchAt, now: now) {
                self.pollQuotas(now: now)
            }
        }
        schedule()
    }

    static func identities() -> [AppIdentity] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.map {
            AppIdentity(pid: $0.processIdentifier, name: $0.localizedName ?? "Application",
                        bundlePath: $0.bundleURL?.path ?? "", bundleIdentifier: $0.bundleIdentifier, launchDate: $0.launchDate)
        }
    }

    func setDetailed(_ value: Bool) {
        guard !isPreview else { return }
        guard detailed != value else { return }
        detailed = value
        if value {
            order = []; loading = apps.isEmpty
            panelOpenTrace = SamplingTrace.begin("panel.open")
            // Opening the panel wants fresh limits, not a 15-minute-old cache.
            queue.async { [weak self] in self?.lastQuotaFetchAt = .distantPast }
        } else {
            panelOpenTrace = nil
        }
        schedule()
    }
    func refresh() { order = []; sample() }
    /// PanelWidgets changed. Turning Agents on scans on the very next sample;
    /// turning it off stops all agent work from the next sample on.
    func widgetsChanged() {
        guard !isPreview else { return }
        let visible = PanelWidgets.shared.isVisible(.agents)
        let turnedOn = visible && !agentsVisible
        agentsVisible = visible
        guard turnedOn else { return }
        queue.async { [weak self] in self?.lastAgentScanAt = .distantPast }
        sample()
    }
    /// Limits turned on: show the cache and poll on the next sample. Off:
    /// clear the card; an in-flight poll's result is discarded on landing.
    func limitsChanged() {
        guard !isPreview else { return }
        guard AppPreferences.shared.limitsEnabled else { quotas = []; return }
        queue.async { [weak self] in
            self?.lastQuotaFetchAt = .distantPast
            self?.loadQuotaCache()
        }
        sample()
    }
    private func schedule() {
        timer?.cancel(); timer = nil
        guard !sleeping else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: detailed ? 2 : 15, leeway: .milliseconds(detailed ? 250 : 1500))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
    }
    /// Main thread. Memory and disk publish as soon as they're read; app
    /// enumeration, history, agents and quotas follow on the same queue pass.
    private func sample() {
        guard !isPreview, !sleeping else { return }
        if busy { samplePending = true; return }
        busy = true
        let date = Date()
        let detailed = detailed, historyEnabled = historyEnabled
        let agentsVisible = PanelWidgets.shared.isVisible(.agents)
        let limitsEnabled = AppPreferences.shared.limitsEnabled
        let fullTrace = SamplingTrace.begin("sample")
        let freshTrace = SamplingTrace.begin("sample.fresh")
        queue.async { [weak self] in
            guard let self else { return }
            let memory = SystemMemory.read()
            let disk = DiskSpace.read()
            DispatchQueue.main.async {
                self.memory = memory
                self.disk = disk
                self.changed?()
                SamplingTrace.end(freshTrace)
            }
            if limitsEnabled { self.checkClaudeSignIn(now: date) }
            let plan = SamplePlan.decide(now: date, lastRecordedAt: self.lastRecordedAt,
                                         recordedPressure: self.recordedPressure, freshPressure: memory.pressure,
                                         historyEnabled: historyEnabled, detailed: detailed,
                                         agentsVisible: agentsVisible, lastAgentScanAt: self.lastAgentScanAt,
                                         limitsEnabled: limitsEnabled, lastLimitsPollAt: self.lastQuotaFetchAt,
                                         limitsPollInFlight: self.quotaFetchInFlight)
            var processes: [ProcessMemory] = []
            var apps: [AppMemory] = []
            if plan.enumerateApps {
                let identities = Self.identities()
                processes = ProcessMemory.read()
                apps = AppGrouping.group(apps: identities, processes: processes)
            }
            var trends: TrendSummary?
            var historyError: String?
            if plan.record {
                let recordTrace = SamplingTrace.begin("history.record")
                self.lastRecordedAt = date
                self.recordedPressure = memory.pressure
                do {
                    if self.historyStore == nil { self.historyStore = try HistoryStore() }
                    trends = try self.historyStore?.record(memory: memory, apps: ObservedApp.from(apps), disk: disk, at: date)
                } catch { historyError = error.localizedDescription }
                SamplingTrace.end(recordTrace)
            }
            var agentSnapshot: AgentSnapshot?
            var agentBurn: [HourBurn]?
            var agentError: String?
            if plan.scanAgents {
                let result = self.scanAgents(now: date, historyEnabled: historyEnabled, disk: disk)
                agentSnapshot = result.snapshot; agentBurn = result.burn; agentError = result.error
            }
            if plan.measureFootprints, let latest = agentSnapshot ?? self.lastAgentSnapshot {
                agentSnapshot = latest.withFootprints(processes)
            }
            if plan.pollLimits { self.pollQuotas(now: date) }
            DispatchQueue.main.async {
                self.busy = false
                if plan.record {
                    self.recordError = historyError
                    if let trends { self.trends = trends }
                }
                let agentErrorChanged = plan.scanAgents && agentError != self.agentSaveError
                if plan.scanAgents { self.agentSaveError = agentError }
                if plan.record || agentErrorChanged { self.historyError = self.recordError ?? self.agentSaveError }
                if plan.enumerateApps && self.detailed {
                    // Keep controls still while users interact with the panel.
                    let oldOrder = self.order
                    self.order = oldOrder.filter { id in apps.contains { $0.id == id } }
                    self.order.append(contentsOf: apps.map(\.id).filter { !self.order.contains($0) })
                    let ranks = Dictionary(self.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                    self.apps = apps.sorted { ranks[$0.id, default: 0] < ranks[$1.id, default: 0] }
                    self.loading = false
                    self.pending.formIntersection(Set(apps.map(\.id)))
                    if let trace = self.panelOpenTrace { SamplingTrace.end(trace); self.panelOpenTrace = nil }
                }
                if let agentSnapshot { self.agents = agentSnapshot }
                if let agentBurn { self.agentBurn = agentBurn }
                SamplingTrace.end(fullTrace)
                if self.samplePending {
                    self.samplePending = false
                    self.sample()
                }
            }
        }
    }
    /// Screenshot-only: the demo monitor with no quota readings yet.
    func clearQuotasForScreenshots() {
        guard isPreview else { return }
        quotas = []
    }
    @objc private func sleep() { sleeping = true; samplePending = false; timer?.cancel(); timer = nil }
    @objc private func wake() { sleeping = false; schedule() }
    @objc private func appsChanged() { if detailed { sample() } }
    @objc private func menuStarted() { menuTracking = true }
    @objc private func menuEnded() { menuTracking = false }

    func quit(_ row: AppMemory, force: Bool = false) {
        guard !isPreview else { return }
        if force {
            alertVisible = true
            let alert = NSAlert()
            alert.messageText = "Force quit \(row.app.name)?"
            alert.informativeText = "Unsaved changes may be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Force Quit")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            alertVisible = false
            guard response == .alertSecondButtonReturn else { return }
        }
        guard AppTermination.request(row.app, force: force) else {
            recordEvent("quit-rejected", app: row.app.name, detail: "Application closed, refused, or identity changed.")
            message = "Couldn't quit \(row.app.name). It may have already closed or refused the request."
            refresh()
            return
        }
        pending.insert(row.id)
        recordEvent(force ? "force-quit-requested" : "quit-requested", app: row.app.name, detail: "macOS accepted the request.")
        message = "\(force ? "Force quitting" : "Quitting") \(row.app.name)…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.pending.remove(row.id)
            if AppTermination.resolve(row.app) != nil {
                self.recordEvent("still-open", app: row.app.name, detail: "Still running five seconds after the quit request.")
                self.message = "\(row.app.name) is still open. Check for a save dialog, or use Force Quit in its menu."
            } else {
                self.recordEvent("exit-observed", app: row.app.name, detail: "Original application instance is no longer running.")
                self.message = nil
            }
            self.sample()
        }
    }

    /// Queue-confined; the caller (`SamplePlan`) owns the throttle. With
    /// history on, sessions/offsets/identities/usage advance only if they
    /// commit together — on failure (or a nearly full disk) the previous
    /// state stays, burn isn't merged, and the next scan re-reads the same
    /// bytes. Nothing commits until persisted state has loaded: committing
    /// state rebuilt from zero offsets would replace the saved sessions and
    /// add their tails to agent_usage a second time.
    private func scanAgents(now: Date, historyEnabled: Bool, disk: DiskSpace) -> (snapshot: AgentSnapshot, burn: [HourBurn], error: String?) {
        let trace = SamplingTrace.begin("agent.scan")
        defer { SamplingTrace.end(trace) }
        lastAgentScanAt = now
        let loadError = loadAgentStateIfNeeded(now: now)
        let scan = agentScanner.scan(now: now, previousSessions: agentSessions, offsets: agentOffsets, identities: agentIdentities)
        lastAgentSnapshot = scan.snapshot
        if historyEnabled, loadError == nil, let store = historyStore {
            do {
                try store.commitAgentScan(sessions: scan.sessions, offsets: scan.offsets,
                                          identities: scan.identities, usage: scan.usage, disk: disk)
            } catch {
                return (scan.snapshot, agentBurnBuckets, "Couldn't save agent sessions: \(error.localizedDescription)")
            }
        }
        // Unloaded state advances in memory only, as with history off, for
        // display; the next successful load replaces all of it.
        agentSessions = scan.sessions
        agentOffsets = scan.offsets
        agentIdentities = scan.identities
        mergeAgentBurn(scan.usage, now: now)
        let error = historyEnabled ? loadError.map { "Couldn't load saved agent sessions, so they aren't being saved: \($0)" } : nil
        return (scan.snapshot, agentBurnBuckets, error)
    }

    /// Queue-confined. Loads persisted agent state once; nil on success (or
    /// already loaded), else the error. Marked loaded only when the store
    /// opened and every load succeeded, so a busy or unreadable database is
    /// retried on the next scan instead of being taken as empty.
    private func loadAgentStateIfNeeded(now: Date) -> String? {
        guard !agentStateLoaded else { return nil }
        do {
            if historyStore == nil { historyStore = try HistoryStore() }
            guard let store = historyStore else { return "History is unavailable." }
            let sessions = try store.loadAgentSessions()
            let offsets = try store.loadScanOffsets()
            let identities = try store.loadScanIdentities()
            let burn = try store.loadAgentUsage(since: now.addingTimeInterval(-Self.burnWindow))
            agentSessions = sessions
            agentOffsets = offsets
            agentIdentities = identities
            agentBurnBuckets = burn
            agentStateLoaded = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Queue-confined. Folds one scan's partial buckets into the 48h window:
    /// same-hour buckets sum per kind, expired hours drop, order stays
    /// ascending. Burn merges whether or not history persists it — the chart
    /// shows live usage either way.
    private func mergeAgentBurn(_ usage: [HourBurn], now: Date) {
        // Truncate like loadAgentUsage so the boundary bucket is kept.
        let cutoff = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - Self.burnWindow) / 3600).rounded(.down) * 3600)
        for bucket in usage {
            if let index = agentBurnBuckets.firstIndex(where: { $0.hour == bucket.hour }) {
                for (kind, tokens) in bucket.tokens { agentBurnBuckets[index].tokens[kind, default: 0] += tokens }
                for (kind, cost) in bucket.cost { agentBurnBuckets[index].cost[kind, default: 0] += cost }
            } else {
                agentBurnBuckets.append(bucket)
            }
        }
        agentBurnBuckets = agentBurnBuckets.filter { $0.hour >= cutoff }.sorted { $0.hour < $1.hour }
    }

    /// Queue-confined. Show the cached readings until a poll lands.
    private func loadQuotaCache() {
        let cached = QuotaCache.load(Self.quotaCacheURL)
        guard !cached.isEmpty else { return }
        DispatchQueue.main.async {
            if self.quotas.isEmpty && AppPreferences.shared.limitsEnabled { self.quotas = cached }
        }
    }

    /// Queue-confined; callers gate on `QuotaPolicy.shouldPoll` (Limits on,
    /// once per interval). Spawns the poll only when a provider's credentials
    /// exist on disk — a machine with no agent CLIs signs in to nothing and
    /// calls nothing. Results merge over what's shown on main (a failed source
    /// keeps its last good windows) and the merged set is cached for instant
    /// display after relaunch.
    private func pollQuotas(now: Date) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let present = !QuotaSources.credentialed(home: home).isEmpty
        DispatchQueue.main.async {
            guard PanelMetrics.quotaSourcesPresent != present else { return }
            PanelMetrics.quotaSourcesPresent = present
            PanelWidgets.shared.changed?()  // hosts resize to fit (or drop) the Limits card
        }
        guard present else { return }
        quotaFetchInFlight = true
        lastQuotaFetchAt = now
        Task.detached { [weak self] in
            let readings = await QuotaFetcher.fetchAll(home: home)
            let merged: [QuotaReading]? = await MainActor.run { [weak self] in
                // Limits was turned off while this poll ran: drop it.
                guard let self, AppPreferences.shared.limitsEnabled else { return nil }
                let merged = QuotaMerge.merge(previous: self.quotas, fresh: readings)
                self.quotas = merged
                return merged
            }
            self?.quotaFetchFinished(merged)
        }
    }
    /// Queue-confined. After a Claude credential failure, a changed sign-in
    /// file or Keychain item (modification dates only, never the secret)
    /// replaces the stale error with "refreshing" and polls right away.
    private func checkClaudeSignIn(now: Date) {
        guard !quotaFetchInFlight else { return }
        let elapsed = now.timeIntervalSince(lastSignInCheckAt)
        guard elapsed < 0 || elapsed >= 60 else { return }
        lastSignInCheckAt = now
        guard QuotaSources.claudeSignInChanged() else { return }
        lastQuotaFetchAt = .distantPast
        DispatchQueue.main.async {
            guard AppPreferences.shared.limitsEnabled else { return }
            self.quotas = QuotaSources.markClaudeSignInChanged(self.quotas)
        }
    }
    /// Back on `queue`: cache the merged set, then allow the next poll.
    private func quotaFetchFinished(_ merged: [QuotaReading]?) {
        queue.async { [weak self] in
            if let merged { QuotaCache.save(merged, to: Self.quotaCacheURL) }
            self?.quotaFetchInFlight = false
        }
    }

    private func recordEvent(_ kind: String, app: String, detail: String) {
        guard historyEnabled else { return }
        queue.async { [weak self] in
            do {
                guard let self else { return }
                if self.historyStore == nil { self.historyStore = try HistoryStore() }
                try self.historyStore?.event(kind: kind, app: app, detail: detail)
            } catch { DispatchQueue.main.async { self?.historyError = error.localizedDescription } }
        }
    }
    /// log.md is otherwise rewritten at most every 15 minutes; bring it
    /// current before showing it.
    func openLog() {
        let url = HistoryStore.defaultDirectory.appendingPathComponent("log.md")
        queue.async { [weak self] in
            if let self {
                if self.historyStore == nil { self.historyStore = try? HistoryStore() }
                try? self.historyStore?.refreshLog(now: Date())
            }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }
    /// App quit: bring log.md current, waiting at most `timeout` (the queue
    /// may be mid-scan; the write is atomic either way).
    func refreshLogBeforeQuit(timeout: TimeInterval = 1) {
        guard !isPreview, historyEnabled else { return }
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            try? self?.historyStore?.refreshLog(now: Date())
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }
    func revealHistory() { NSWorkspace.shared.open(HistoryStore.defaultDirectory) }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
    /// App icons don't change during a launch; resolve once per bundle path.
    func icon(for app: AppIdentity) -> NSImage? {
        let key = app.bundlePath.isEmpty ? "name:\(app.name)" : app.bundlePath
        if let cached = iconCache[key] { return cached }
        let icon: NSImage?
        if isPreview, let identifier = app.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSRunningApplication(processIdentifier: app.pid)?.icon
        }
        iconCache[key] = icon
        return icon
    }

    /// Sizes are cached and only stale past a day, so opening the storage view
    /// doesn't cost I/O unless it wants to.
    var consumersStale: Bool { !isPreview && (consumers.scannedAt.map { Date().timeIntervalSince($0) > 86400 } ?? true) }

    func rescanConsumers() {
        guard !isPreview else { return }
        guard consumerScanText == nil else { return }
        consumerScanText = "Starting…"
        let scanner = ConsumerScanner()
        self.scanner = scanner
        scanQueue.async { [weak self] in
            let result = scanner.scan { done, total in
                DispatchQueue.main.async { self?.consumerScanText = "Scanning \(done) of \(total) locations…" }
            }
            guard let self else { return }
            if result.cancelled {
                DispatchQueue.main.async { self.consumerScanText = nil }
                return
            }
            self.queue.async {
                do {
                    if self.historyStore == nil { self.historyStore = try HistoryStore() }
                    try self.historyStore?.saveConsumers(result.consumers, localSnapshots: result.localSnapshots)
                    let scan = (try? self.historyStore?.loadConsumers()) ?? ConsumerScan()
                    let summary = try? self.historyStore?.summary()
                    DispatchQueue.main.async {
                        self.consumers = scan
                        if let summary { self.trends = summary }
                        self.consumerScanText = nil
                    }
                } catch {
                    DispatchQueue.main.async { self.consumerScanText = nil; self.historyError = error.localizedDescription }
                }
            }
        }
    }
    func cancelConsumerScan() { scanner?.cancel() }

    func archiveHistory() {
        alertVisible = true
        let alert = NSAlert()
        alert.messageText = "Archive current history?"
        alert.informativeText = "The database and log will be kept in an Archives folder. Headroom will start a fresh baseline."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Archive")
        let result = alert.runModal()
        alertVisible = false
        guard result == .alertSecondButtonReturn else { return }
        queue.async { [weak self] in
            do {
                guard let self else { return }
                if self.historyStore == nil { self.historyStore = try HistoryStore() }
                _ = try self.historyStore?.archive()
                self.lastRecordedAt = .distantPast
                DispatchQueue.main.async { self.trends = TrendSummary(); self.sample() }
            } catch { DispatchQueue.main.async { self?.historyError = error.localizedDescription } }
        }
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                message = "Allow Headroom in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { message = "Couldn't change launch at login: \(error.localizedDescription)" }
    }
}
