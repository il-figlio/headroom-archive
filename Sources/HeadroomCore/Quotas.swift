import Foundation

/// One subscription usage window as reported by a provider API
/// ("5-hour", "Weekly", "Monthly"). `usedFraction` is 0...1 of the window's
/// allowance; `resetsAt` is the window's reset instant when reported.
public struct QuotaWindow: Sendable, Codable, Equatable {
    public var label: String
    public var usedFraction: Double
    public var resetsAt: Date?
    /// Free-form extra text a source may attach (e.g. "unlimited", "38% left").
    public var detail: String?
    public init(label: String, usedFraction: Double, resetsAt: Date? = nil, detail: String? = nil) {
        self.label = label
        self.usedFraction = max(0, min(1, usedFraction))
        self.resetsAt = resetsAt
        self.detail = detail
    }
}

/// A provider's subscription/quota state, fetched by reusing local
/// credentials (OAuth tokens the vendor's own app already minted). Distinct
/// from `AgentSession`: transcripts measure local work, quota measures the
/// plan's remaining allowance — the two complement each other.
public struct QuotaReading: Identifiable, Sendable, Codable {
    public var id: String { account.map { "\(provider.rawValue)/\($0)" } ?? provider.rawValue }
    /// Provider family; reuses AgentKind so colors/labels stay consistent.
    public var provider: AgentKind
    /// Plan name when the source exposes one ("Pro", "Max", "Plus").
    public var plan: String?
    /// Usage windows, most-urgent first (session before weekly).
    public var windows: [QuotaWindow] = []
    /// Credit/balance line when the provider exposes one (Codex credits).
    public var balance: String?
    /// Local account label when a provider has multiple named sign-ins.
    public var account: String?
    public var fetchedAt = Date()
    /// Non-nil when the fetch failed; stale readings keep their last values
    /// so a transient error doesn't blank the card.
    public var error: String?
    public init(provider: AgentKind) { self.provider = provider }
}

/// Poll cadence shared by the monitor and the Limits card's staleness label.
public enum QuotaPolicy {
    public static let interval: TimeInterval = 15 * 60
    /// A reading older than this is labeled with its last successful fetch time.
    public static let staleAfter: TimeInterval = 2 * interval
    /// Whether to start a poll. With Limits off nothing quota-related runs:
    /// no credential checks, no CLI, no network. A clock that moved
    /// backwards counts as due.
    public static func shouldPoll(enabled: Bool, inFlight: Bool, lastPollAt: Date, now: Date) -> Bool {
        guard enabled, !inFlight else { return false }
        let elapsed = now.timeIntervalSince(lastPollAt)
        return elapsed < 0 || elapsed >= interval
    }
}

/// A quota source uses existing local sign-ins to obtain subscription
/// readings from a provider API or the CLI that owns the sign-in.
/// Failures are embedded in the returned reading.
public protocol QuotaSource: Sendable {
    var provider: AgentKind { get }
    /// Credential file(s) this source needs; used to skip sources with no
    /// sign-in before any network attempt is made.
    var credentialPaths: [String] { get }
    /// True when at least one credential file exists on disk.
    func hasCredentials(home: URL) -> Bool
    /// Fetch a fresh reading. Implementations must return a reading even on
    /// failure (provider set, `error` describing what went wrong).
    func fetch(home: URL) async -> QuotaReading
}

public extension QuotaSource {
    func hasCredentials(home: URL) -> Bool {
        credentialPaths.contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
    }
}

/// All quota sources, in display order. A source only participates when its
/// credentials exist on disk — nothing is fetched for providers the user
/// doesn't use. `shared` returns the same instances every call so per-source
/// last-good and rate-limit state survive between polls.
public enum QuotaSources {
    public static let shared: [any QuotaSource] = [
        CodexQuotaSource(), ClaudeQuotaSource(),
    ]
    /// Providers with usable credential files on this machine.
    public static func credentialed(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [any QuotaSource] {
        let sources = shared.filter { $0.hasCredentials(home: home) }
        // Named Ante accounts replace the Claude Code sign-in (product decision).
        let ante = AnteClaudeQuotaSource.sources(home: home)
        return ante.isEmpty ? sources : sources.filter { $0.provider != .claude } + ante
    }
    /// Display names for Settings, e.g. ["Codex", "Claude (Ante: personal, work)"].
    /// Built from file existence and file names only; nothing is opened.
    public static func detectedNames(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let sources = credentialed(home: home)
        var names: [String] = []
        for kind in [AgentKind.codex, .claude] {
            let matching = sources.filter { $0.provider == kind }
            guard !matching.isEmpty else { continue }
            let accounts = matching.compactMap { ($0 as? AnteClaudeQuotaSource)?.account }
            names.append(accounts.isEmpty ? kind.title : "\(kind.title) (Ante: \(accounts.joined(separator: ", ")))")
        }
        return names
    }
}

/// Fetches all credentialed sources concurrently, preserving the
/// `QuotaSources.shared` display order. Runs entirely off-main; each source
/// is responsible for its own timeout and error embedding.
public enum QuotaFetcher {
    public static func fetchAll(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> [QuotaReading] {
        await fetchAll(sources: QuotaSources.credentialed(home: home), home: home)
    }

    public static func fetchAll(sources: [any QuotaSource], home: URL) async -> [QuotaReading] {
        guard !sources.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, QuotaReading).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { (index, await source.fetch(home: home)) }
            }
            var out = Array(repeating: QuotaReading?.none, count: sources.count)
            for await (index, reading) in group { out[index] = reading }
            return out.compactMap { $0 }
        }
    }
}

public extension QuotaWindow {
    /// Remaining share of the window's allowance, 0...1.
    var leftFraction: Double { 1 - usedFraction }
    /// True once the reported reset instant has passed; the stored
    /// `usedFraction` then describes an expired window.
    func hasReset(now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }
}

public extension QuotaReading {
    /// The last fetch failed, or the values are older than `QuotaPolicy.staleAfter`.
    func isStale(now: Date = Date()) -> Bool {
        error != nil || now.timeIntervalSince(fetchedAt) > QuotaPolicy.staleAfter
    }
    /// Highest-usage window that hasn't reset yet; nil when none qualifies.
    func mostConstrained(now: Date = Date()) -> QuotaWindow? {
        windows.filter { !$0.hasReset(now: now) }.max { $0.usedFraction < $1.usedFraction }
    }
    /// Something worth showing besides an error line.
    internal var hasUsage: Bool { !windows.isEmpty || balance != nil }
}

/// Combines a new poll with what is already displayed so a failed fetch
/// dims the last good values instead of blanking them.
public enum QuotaMerge {
    /// Order and membership follow `fresh` (sources that disappeared are
    /// dropped). A fresh reading that only carries an error keeps the
    /// previous reading's windows/plan/balance/fetchedAt and takes the new error.
    public static func merge(previous: [QuotaReading], fresh: [QuotaReading]) -> [QuotaReading] {
        let byID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fresh.map { reading in
            guard let error = reading.error, !reading.hasUsage,
                  var kept = byID[reading.id], kept.hasUsage else { return reading }
            kept.error = error
            return kept
        }
    }
}

/// On-disk copy of the last readings (Monitor keeps it in Application Support)
/// for instant display after relaunch.
public enum QuotaCache {
    public static func load(_ url: URL) -> [QuotaReading] {
        guard let data = try? Data(contentsOf: url),
              let readings = try? JSONDecoder().decode([QuotaReading].self, from: data) else { return [] }
        return readings
    }

    /// Writes `readings` merged over what is already on disk, so an entry
    /// with usage is never replaced by an error-only one.
    public static func save(_ readings: [QuotaReading], to url: URL) {
        let merged = QuotaMerge.merge(previous: load(url), fresh: readings)
        guard let data = try? JSONEncoder().encode(merged) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
