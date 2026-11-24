import Foundation

/// What one monitor sample does beyond reading memory and disk (which every
/// sample does, and publishes first). Pure so the cadence is testable.
public struct SamplePlan: Equatable, Sendable {
    /// Write a history record (needs the app list).
    public var record: Bool
    /// Enumerate running apps and their processes — a few hundred syscalls,
    /// so only when the panel shows them or a record needs them.
    public var enumerateApps: Bool
    /// Run the agent transcript scan.
    public var scanAgents: Bool
    /// Measure agent process-tree footprints from this sample's process list.
    public var measureFootprints: Bool
    /// Start a Limits poll (credential checks, then CLI/network). Never
    /// while Limits is off.
    public var pollLimits: Bool

    public init(record: Bool, enumerateApps: Bool, scanAgents: Bool, measureFootprints: Bool, pollLimits: Bool = false) {
        self.record = record; self.enumerateApps = enumerateApps
        self.scanAgents = scanAgents; self.measureFootprints = measureFootprints
        self.pollLimits = pollLimits
    }

    public static let recordInterval: TimeInterval = 60
    /// A pressure change records early, but not more often than this.
    public static let pressureRecordInterval: TimeInterval = 15
    public static let agentScanInterval: TimeInterval = 45
    public static let agentScanIntervalDetailed: TimeInterval = 15

    /// A clock that moved backwards counts as due rather than stalling
    /// until it catches up.
    public static func decide(now: Date, lastRecordedAt: Date, recordedPressure: Pressure, freshPressure: Pressure,
                              historyEnabled: Bool, detailed: Bool, agentsVisible: Bool,
                              lastAgentScanAt: Date, limitsEnabled: Bool, lastLimitsPollAt: Date,
                              limitsPollInFlight: Bool) -> SamplePlan {
        let elapsed = now.timeIntervalSince(lastRecordedAt)
        let record = historyEnabled
            && (elapsed < 0 || elapsed >= recordInterval
                || (elapsed >= pressureRecordInterval && freshPressure != recordedPressure))
        let sinceScan = now.timeIntervalSince(lastAgentScanAt)
        let scanInterval = detailed ? agentScanIntervalDetailed : agentScanInterval
        let scan = agentsVisible && (sinceScan < 0 || sinceScan >= scanInterval)
        return SamplePlan(record: record, enumerateApps: detailed || record,
                          scanAgents: scan, measureFootprints: detailed && agentsVisible,
                          pollLimits: QuotaPolicy.shouldPoll(enabled: limitsEnabled, inFlight: limitsPollInFlight,
                                                             lastPollAt: lastLimitsPollAt, now: now))
    }
}

public extension AgentSnapshot {
    /// Sets each session's live footprint from its pid's process tree; sessions
    /// without a pid, or whose process is gone, read as unmeasured.
    func withFootprints(_ processes: [ProcessMemory]) -> AgentSnapshot {
        let readings = AgentFootprint.measure(processes: processes, roots: Set(sessions.compactMap(\.pid)))
        var copy = self
        for index in copy.sessions.indices {
            let reading = copy.sessions[index].pid.flatMap { readings[$0] }
            copy.sessions[index].footprint = reading?.bytes
            copy.sessions[index].footprintPartial = reading?.partial ?? false
        }
        return copy
    }
}
