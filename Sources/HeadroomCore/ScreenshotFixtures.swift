import Foundation

/// Invented observations for documentation. Never sourced from a user's history or credentials.
public struct ScreenshotFixtures {
    public let memory: SystemMemory
    public let disk: DiskSpace
    public let apps: [AppMemory]
    public let summary: TrendSummary
    public let quotas: [QuotaReading]
    public let agents: AgentSnapshot
    public let agentBurn: [HourBurn]

    /// The machine a scene shows. `.laptop` is the default for every
    /// single-view render; `.desktop` backs the larger-display scene.
    public enum Machine: Sendable { case laptop, desktop }

    public init(now: Date = Date(), machine: Machine = .laptop) {
        let gb: Double = 1_073_741_824
        let desktop = machine == .desktop
        // Laptop: 16 GB / 512 GB, elevated. Desktop: 64 GB / 2 TB, normal.
        let usedGB = desktop ? 31.4 : 12.8
        let swapGB = desktop ? 0 : 0.8
        let pressure: Pressure = desktop ? .normal : .warning
        let diskTotalGB: Double = desktop ? 2048 : 512
        let diskFreeGB = desktop ? 1286.4 : 98.4
        let purgeableGB = desktop ? 38.6 : 14.2
        memory = SystemMemory(total: UInt64((desktop ? 64 : 16) * gb), used: UInt64(usedGB * gb),
                              compressed: UInt64((desktop ? 1.6 : 2.4) * gb),
                              swap: UInt64(swapGB * gb), pressure: pressure, valid: true)
        disk = DiskSpace(total: UInt64(diskTotalGB * gb), free: UInt64(diskFreeGB * gb), purgeable: UInt64(purgeableGB * gb), valid: true)
        // Apple's own apps, so icons resolve from the system and no
        // third-party brand appears.
        let examples: [(String, String, Double, Int)] = desktop ? [
            ("iMovie", "com.apple.iMovieApp", 9.84, 5), ("GarageBand", "com.apple.garageband10", 4.62, 4),
            ("Safari", "com.apple.Safari", 4.18, 24), ("Photos", "com.apple.Photos", 2.36, 6),
            ("Keynote", "com.apple.Keynote", 1.12, 2)
        ] : [
            ("Safari", "com.apple.Safari", 2.94, 14), ("Terminal", "com.apple.Terminal", 0.62, 3),
            ("Messages", "com.apple.MobileSMS", 0.58, 2), ("Notes", "com.apple.Notes", 0.31, 1),
            ("Music", "com.apple.Music", 0.27, 3)
        ]
        apps = examples.enumerated().map { index, example in
            let identity = AppIdentity(pid: Int32(-1000 - index), name: example.0, bundlePath: "",
                                       bundleIdentifier: example.1, launchDate: now.addingTimeInterval(-7200))
            return AppMemory(app: identity, bytes: UInt64(example.2 * gb), processCount: example.3, unreadableCount: 0)
        }
        var history = TrendSummary()
        history.sampleCount = 361; history.observedMinutes = 360; history.pressuredMinutes = desktop ? 0 : 42
        history.peakSwap = UInt64(swapGB * gb); history.latestAt = now; history.latestPressure = pressure
        history.latestApps = ObservedApp.from(apps)
        let rateGBPerDay = desktop ? 3.8 : 1.6
        for i in 0...72 {
            let date = now.addingTimeInterval(Double(i - 72) * 300)
            let used = desktop ? 26.2 + Double(i) * 0.06 + sin(Double(i) * 0.35) * 0.9
                               : 8.5 + Double(i) * 0.055 + sin(Double(i) * 0.42) * 0.55
            history.points.append(TrendPoint(date: date, usedGB: i == 72 ? usedGB : used,
                                             swapGB: desktop ? 0 : max(0, Double(i - 40) * 0.025)))
            history.diskPoints.append(DiskPoint(date: date, freeGB: diskFreeGB + Double(72 - i) * rateGBPerDay / 288,
                                                purgeableGB: purgeableGB))
        }
        history.latestDiskFree = disk.free; history.latestDiskTotal = disk.total
        history.latestDiskPurgeable = disk.purgeable; history.diskRateGBPerDay = rateGBPerDay
        history.daysUntilFull = diskFreeGB / rateGBPerDay
        history.consumers.scannedAt = now
        history.consumers.items = desktop ? [
            DiskConsumer(path: "/Users/demo/Movies", name: "Movies", bytes: UInt64(412 * gb), previousBytes: nil, scannedAt: now, partial: false),
            DiskConsumer(path: "/Users/demo/Music", name: "Music", bytes: UInt64(186 * gb), previousBytes: nil, scannedAt: now, partial: false),
            DiskConsumer(path: "/Applications", name: "Applications", bytes: UInt64(96 * gb), previousBytes: nil, scannedAt: now, partial: false)
        ] : [
            DiskConsumer(path: "/Applications", name: "Applications", bytes: UInt64(64 * gb), previousBytes: nil, scannedAt: now, partial: false),
            DiskConsumer(path: "/Users/demo/Projects", name: "Projects", bytes: UInt64(42 * gb), previousBytes: nil, scannedAt: now, partial: false)
        ]
        history.recommendations = TrendAdvice.recommend(history)
        summary = history
        // Limits: two Claude accounts (one stale with an error, one with a
        // window whose reset just passed) and Codex — collapses to 3 rows.
        let hour: TimeInterval = 3600
        var personal = QuotaReading(provider: .claude)
        personal.account = "Personal"; personal.plan = "Max"
        personal.fetchedAt = now.addingTimeInterval(-4 * 60)
        personal.windows = [.init(label: "5h", usedFraction: 0.88, resetsAt: now.addingTimeInterval(-6 * 60)),
                            .init(label: "Week", usedFraction: 0.61, resetsAt: now.addingTimeInterval(2 * 24 * hour + 5 * hour)),
                            .init(label: "Sonnet", usedFraction: 0.27, resetsAt: now.addingTimeInterval(2 * 24 * hour + 5 * hour),
                                  detail: "Weekly limit for Sonnet models"),
                            .init(label: "Fable", usedFraction: 0.34, resetsAt: now.addingTimeInterval(4 * 24 * hour))]
        personal.balance = "$12.40 of $50 extra usage"
        var work = QuotaReading(provider: .claude)
        work.account = "acme-team"; work.plan = "Team"
        work.fetchedAt = now.addingTimeInterval(-3 * hour - 20 * 60)
        work.error = "Rate limited by the usage endpoint (HTTP 429). Retrying on the next poll."
        work.windows = [.init(label: "5h", usedFraction: 0.44, resetsAt: now.addingTimeInterval(1.5 * hour)),
                        .init(label: "Week", usedFraction: 0.72, resetsAt: now.addingTimeInterval(3 * 24 * hour)),
                        .init(label: "Fable", usedFraction: 0.18, resetsAt: now.addingTimeInterval(5 * 24 * hour + 2 * hour))]
        var codex = QuotaReading(provider: .codex)
        codex.plan = "Pro"; codex.fetchedAt = now.addingTimeInterval(-2 * 60)
        codex.windows = [.init(label: "5h", usedFraction: 0.18, resetsAt: now.addingTimeInterval(3.2 * hour)),
                         .init(label: "Week", usedFraction: 0.46, resetsAt: now.addingTimeInterval(6 * 24 * hour))]
        quotas = [personal, work, codex]

        // Agents: three sessions with live footprints, one stuck.
        func session(_ kind: AgentKind, _ project: String, pid: Int32, health: SessionHealth, footprintGB: Double?,
                     idle: TimeInterval, started: TimeInterval, tokens: Int64, cost: Double?, model: String,
                     tools: [String: Int]) -> AgentSession {
            var s = AgentSession(kind: kind, sessionId: "demo-\(pid)", projectDir: "/Users/demo/Projects/\(project)",
                                 filePath: "/Users/demo/.demo/\(pid).jsonl")
            s.pid = pid; s.health = health; s.footprint = footprintGB.map { UInt64($0 * gb) }
            s.lastEventAt = now.addingTimeInterval(-idle); s.startedAt = now.addingTimeInterval(-started)
            s.tokens.input = tokens / 10; s.tokens.output = tokens / 20; s.tokens.cacheRead = tokens - tokens / 10 - tokens / 20
            s.costUSD = cost; s.models = [model]; s.tools = tools
            return s
        }
        var snapshot = AgentSnapshot()
        snapshot.sessions = [
            session(.claude, "headroom", pid: 4211, health: .live, footprintGB: 1.84, idle: 35, started: 2.4 * hour,
                    tokens: 3_412_000, cost: 4.12, model: "claude-opus-4-5", tools: ["Read": 63, "Bash": 41, "Edit": 22, "Grep": 9]),
            session(.codex, "website", pid: 5120, health: .live, footprintGB: 0.62, idle: 190, started: 1.1 * hour,
                    tokens: 1_204_000, cost: nil, model: "gpt-5-codex", tools: ["exec_command": 28, "apply_patch": 11]),
            session(.claude, "data-pipeline", pid: 3880, health: .stuck, footprintGB: 2.31, idle: 24 * 60, started: 5 * hour,
                    tokens: 5_870_000, cost: 7.35, model: "claude-sonnet-4-5", tools: ["Bash": 88, "Read": 40]),
            session(.claude, "notes", pid: 2001, health: .ended, footprintGB: nil, idle: 6 * hour, started: 7 * hour,
                    tokens: 640_000, cost: 0.92, model: "claude-haiku-4-5", tools: ["Read": 4]),
        ]
        snapshot.roots = [AgentRoot(kind: .claude, path: "/Users/demo/.claude", exists: true, sessionFiles: 42),
                          AgentRoot(kind: .codex, path: "/Users/demo/.codex", exists: true, sessionFiles: 17)]
        snapshot.todayTokens = snapshot.sessions.reduce(into: TokenUsage()) { $0 += $1.tokens }
        snapshot.todayCostUSD = 12.39; snapshot.unpricedTokensToday = 1_204_000
        snapshot.scannedAt = now
        agents = snapshot
        let thisHour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        agentBurn = (0..<12).map { offset in
            var bucket = HourBurn(hour: thisHour.addingTimeInterval(Double(offset - 11) * hour))
            let claude = Int64([0, 0, 120, 340, 610, 280, 90, 0, 450, 820, 760, 520][offset]) * 1_000
            let codex = Int64([0, 0, 0, 0, 80, 140, 0, 0, 0, 210, 330, 260][offset]) * 1_000
            if claude > 0 { bucket.tokens[.claude] = claude; bucket.cost[.claude] = Double(claude) / 1_000_000 * 1.25 }
            if codex > 0 { bucket.tokens[.codex] = codex }
            return bucket
        }
    }
}
