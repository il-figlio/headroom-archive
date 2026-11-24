import Foundation

/// Ante owns the credentials. Headroom only discovers account names and
/// reads the usage JSON returned by the installed CLI.
struct AnteClaudeQuotaSource: QuotaSource {
    let provider: AgentKind = .claude
    let credentialPaths: [String]
    let account: String
    fileprivate let executable: URL
    fileprivate let credential: URL
    private let poller: AntePoller
    static let directory = ".ante/auth/credentials/oauth/anthropic"
    /// Only Ante's own per-user install is run. System-wide paths
    /// (/opt/homebrew/bin, /usr/local/bin) are deliberately not searched:
    /// finding Ante there would silently swap out the Claude Code source.
    static let executablePath = ".ante/bin/ante"

    private init(home: URL, executable: URL, filename: String, poller: AntePoller) {
        let relativePath = Self.directory + "/" + filename
        credentialPaths = [relativePath]
        credential = home.appendingPathComponent(relativePath)
        account = String(filename.dropLast(".json".count))
        self.executable = executable
        self.poller = poller
    }

    /// One source per regular, non-hidden `*.json` file in Ante's Anthropic
    /// credential directory. Files are listed, never read.
    static func sources(home: URL, poller: AntePoller = .shared) -> [AnteClaudeQuotaSource] {
        let files = FileManager.default
        let executable = home.appendingPathComponent(executablePath)
        guard files.isExecutableFile(atPath: executable.path),
              let entries = try? files.contentsOfDirectory(
                at: home.appendingPathComponent(directory),
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        let names = entries.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), name.hasSuffix(".json"), name.count > ".json".count,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            return name
        }
        return names.sorted().map { Self(home: home, executable: executable, filename: $0, poller: poller) }
    }

    func fetch(home: URL) async -> QuotaReading {
        await poller.fetch(self)
    }

    fileprivate var credentialName: String { "anthropic/" + account }

    /// Blocking; runs on a utility queue.
    fileprivate func request(limits: BoundedProcess.Limits) -> QuotaReading {
        var reading = QuotaReading(provider: .claude)
        reading.account = account
        let name = credentialName
        switch BoundedProcess.run(executable, arguments: ["usage", name, "--json"], limits: limits) {
        case .launchFailed:
            reading.error = "Could not start Ante to read Claude usage"
        case .timedOut:
            reading.error = "Ante timed out reading Claude usage"
        case .outputTooLarge:
            reading.error = "Ante returned too much output for Claude usage"
        case .exited(let status, _) where status != 0:
            reading.error = "Ante could not read Claude usage"
        case .exited(_, let data):
            Self.apply(data, credential: name, to: &reading)
        }
        return reading
    }

    static func apply(_ data: Data, credential name: String, to reading: inout QuotaReading) {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let subscription = response.subscriptions.lazy.compactMap(\.value)
                .first(where: { $0.provider == "anthropic" && $0.credential == name })
        else {
            reading.error = "Ante returned no usage for this Claude sign-in"
            return
        }
        guard subscription.status == "ready" else {
            reading.error = "Claude usage is unavailable in Ante. Check `ante usage \(name)`."
            return
        }
        reading.plan = subscription.plan
        reading.windows = (subscription.windows ?? []).compactMap { entry in
            guard let window = entry.value, let raw = window.label, let percent = window.usedPercent,
                  percent.isFinite else { return nil }
            let label: String
            switch raw.lowercased() {
            case "current session": label = "5h"
            case "weekly limit": label = "Week"
            default: label = raw
            }
            return QuotaWindow(label: label, usedFraction: percent / 100, resetsAt: QuotaDate.parse(window.resetsAt))
        }
        if reading.windows.isEmpty { reading.error = "Ante returned no usage for this Claude sign-in" }
    }

    /// Every field is optional and each list element decodes independently,
    /// so one odd entry is skipped instead of failing the whole response.
    struct Response: Decodable {
        let subscriptions: [Lenient<Subscription>]

        struct Subscription: Decodable {
            let credential: String?
            let provider: String?
            let status: String?
            let plan: String?
            let windows: [Lenient<Window>]?
        }

        struct Window: Decodable {
            let label: String?
            let usedPercent: Double?
            let resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case label
                case usedPercent = "used_percent"
                case resetsAt = "resets_at"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                label = try? c.decodeIfPresent(String.self, forKey: .label)
                usedPercent = try? c.decodeIfPresent(Double.self, forKey: .usedPercent)
                resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
            }
        }

        struct Lenient<T: Decodable>: Decodable {
            let value: T?
            init(from decoder: Decoder) throws { value = try? T(from: decoder) }
        }
    }
}

/// Per-account CLI runs: concurrent callers share one in-flight run, a
/// success is reused only briefly (panel-open bursts), and failures are
/// never cached — a failed run replays the last good reading (with its
/// original `fetchedAt`) carrying the new error.
actor AntePoller {
    static let shared = AntePoller()

    let reuseFloor: TimeInterval
    let limits: BoundedProcess.Limits
    private var inFlight: [URL: Task<QuotaReading, Never>] = [:]
    private var lastGood: [URL: QuotaReading] = [:]

    init(reuseFloor: TimeInterval = 60, limits: BoundedProcess.Limits = .init()) {
        self.reuseFloor = reuseFloor
        self.limits = limits
    }

    func fetch(_ source: AnteClaudeQuotaSource) async -> QuotaReading {
        let key = source.credential
        if let task = inFlight[key] { return await task.value }
        if let good = lastGood[key], Date().timeIntervalSince(good.fetchedAt) < reuseFloor { return good }
        let limits = limits
        let task = Task<QuotaReading, Never> {
            let reading = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: source.request(limits: limits))
                }
            }
            return self.settle(key, reading)
        }
        inFlight[key] = task
        return await task.value
    }

    private func settle(_ key: URL, _ reading: QuotaReading) -> QuotaReading {
        inFlight[key] = nil
        guard let error = reading.error else {
            lastGood[key] = reading
            return reading
        }
        guard var good = lastGood[key] else { return reading }
        good.error = error
        return good
    }
}
