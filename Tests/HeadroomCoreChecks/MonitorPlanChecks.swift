import Foundation
import Testing
@testable import HeadroomCore

/// Sample cadence: what each tick does beyond reading memory and disk.
@Suite struct MonitorPlanChecks {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func plan(at offset: TimeInterval, recordedAt: TimeInterval = 0, recorded: Pressure = .normal,
              fresh: Pressure = .normal, history: Bool = true, detailed: Bool = false,
              agents: Bool = false, scannedAt: Date? = nil, limits: Bool = false,
              polledAt: Date = .distantPast, polling: Bool = false) -> SamplePlan {
        SamplePlan.decide(now: base.addingTimeInterval(offset), lastRecordedAt: base.addingTimeInterval(recordedAt),
                          recordedPressure: recorded, freshPressure: fresh, historyEnabled: history,
                          detailed: detailed, agentsVisible: agents,
                          lastAgentScanAt: scannedAt ?? base, limitsEnabled: limits,
                          lastLimitsPollAt: polledAt, limitsPollInFlight: polling)
    }

    @Test func idleTicksBetweenRecordsSkipApps() {
        for offset in [15.0, 30, 45] {
            let p = plan(at: offset)
            #expect(!p.record, "tick \(offset)")
            #expect(!p.enumerateApps, "tick \(offset)")
        }
    }

    @Test func minuteTickRecordsWithApps() {
        let p = plan(at: 60)
        #expect(p.record)
        #expect(p.enumerateApps)
        #expect(plan(at: 0, recordedAt: 0, history: true).record == false)
        #expect(SamplePlan.decide(now: base, lastRecordedAt: .distantPast, recordedPressure: .unknown,
                                  freshPressure: .normal, historyEnabled: true, detailed: false,
                                  agentsVisible: false, lastAgentScanAt: base, limitsEnabled: false,
                                  lastLimitsPollAt: .distantPast, limitsPollInFlight: false).record)
    }

    @Test func pressureChangeRecordsEarlyButNotBefore15s() {
        #expect(plan(at: 15, fresh: .warning).record)
        #expect(plan(at: 15, fresh: .warning).enumerateApps)
        #expect(!plan(at: 14, fresh: .warning).record)
        #expect(!plan(at: 30, recorded: .warning, fresh: .warning).record)
    }

    @Test func detailedAlwaysEnumerates() {
        for offset in [0.0, 2, 15, 59] {
            let p = plan(at: offset, detailed: true)
            #expect(p.enumerateApps, "tick \(offset)")
            #expect(!p.record, "tick \(offset)")
        }
        #expect(plan(at: 4, history: false, detailed: true).enumerateApps)
    }

    @Test func historyDisabledNeverRecords() {
        for offset in [15.0, 60, 3600] {
            let p = plan(at: offset, fresh: .critical, history: false)
            #expect(!p.record)
            #expect(!p.enumerateApps)
        }
        #expect(!SamplePlan.decide(now: base, lastRecordedAt: .distantPast, recordedPressure: .unknown,
                                   freshPressure: .normal, historyEnabled: false, detailed: false,
                                   agentsVisible: false, lastAgentScanAt: .distantPast, limitsEnabled: false,
                                   lastLimitsPollAt: .distantPast, limitsPollInFlight: false).record)
    }

    @Test func agentsHiddenNeverScanOrMeasure() {
        for detailed in [false, true] {
            for offset in [0.0, 15, 45, 3600] {
                let p = plan(at: offset, detailed: detailed, agents: false, scannedAt: .distantPast)
                #expect(!p.scanAgents)
                #expect(!p.measureFootprints)
            }
        }
    }

    @Test func agentsVisibleRespectThrottles() {
        // Collapsed: 45 s.
        #expect(!plan(at: 15, agents: true).scanAgents)
        #expect(!plan(at: 44, agents: true).scanAgents)
        #expect(plan(at: 45, agents: true).scanAgents)
        // Panel open: 15 s.
        #expect(!plan(at: 14, detailed: true, agents: true).scanAgents)
        #expect(plan(at: 15, detailed: true, agents: true).scanAgents)
        // Never scanned (or just turned on): due immediately.
        #expect(plan(at: 0, agents: true, scannedAt: .distantPast).scanAgents)
        // Agent scans don't need history or app enumeration.
        let p = plan(at: 45, history: false, agents: true)
        #expect(p.scanAgents && !p.enumerateApps)
    }

    @Test func footprintsOnlyWithPanelOpenAndAgentsVisible() {
        #expect(plan(at: 2, detailed: true, agents: true).measureFootprints)
        #expect(plan(at: 2, detailed: true, agents: true).enumerateApps)
        #expect(!plan(at: 2, detailed: false, agents: true).measureFootprints)
        #expect(!plan(at: 2, detailed: true, agents: false).measureFootprints)
    }

    /// Limits off: no credential checks, CLI or network on any tick,
    /// whatever else the sample does.
    @Test func limitsOffNeverPolls() {
        for detailed in [false, true] {
            for history in [false, true] {
                for offset in [0.0, 15, 60, 3600, -30] {
                    let p = plan(at: offset, history: history, detailed: detailed, agents: true, limits: false)
                    #expect(!p.pollLimits)
                }
            }
        }
        #expect(!QuotaPolicy.shouldPoll(enabled: false, inFlight: false, lastPollAt: .distantPast, now: base))
    }

    @Test func limitsOnPollsOncePerInterval() {
        #expect(plan(at: 0, limits: true).pollLimits)
        let last = base.addingTimeInterval(-QuotaPolicy.interval + 1)
        #expect(!plan(at: 0, limits: true, polledAt: last).pollLimits)
        #expect(plan(at: 1, limits: true, polledAt: last).pollLimits)
        #expect(!plan(at: 0, limits: true, polling: true).pollLimits)
        // A clock that moved backwards counts as due.
        #expect(plan(at: 0, limits: true, polledAt: base.addingTimeInterval(60)).pollLimits)
    }

    @Test func clockMovingBackwardsCountsAsDue() {
        #expect(plan(at: -30).record)
        #expect(plan(at: -30, agents: true).scanAgents)
    }

    @Test func footprintsAttachBySessionPid() {
        var snapshot = AgentSnapshot()
        var withPid = AgentSession(kind: .claude, sessionId: "a", projectDir: "/p", filePath: "/a.jsonl")
        withPid.pid = 100
        var gone = AgentSession(kind: .claude, sessionId: "a", projectDir: "/p", filePath: "/b.jsonl")
        gone.pid = 300
        gone.footprint = 1
        let noPid = AgentSession(kind: .codex, sessionId: "c", projectDir: "/p", filePath: "/c.jsonl")
        snapshot.sessions = [withPid, gone, noPid]
        let processes = [ProcessMemory(pid: 100, parent: 1, path: "/bin/node", footprint: 1_000),
                         ProcessMemory(pid: 101, parent: 100, path: "/bin/tool", footprint: nil),
                         ProcessMemory(pid: 200, parent: 1, path: "/bin/other", footprint: 5_000)]
        let measured = snapshot.withFootprints(processes)
        #expect(measured.sessions[0].footprint == 1_000)
        #expect(measured.sessions[0].footprintPartial)
        #expect(measured.sessions[1].footprint == nil)
        #expect(!measured.sessions[1].footprintPartial)
        #expect(measured.sessions[2].footprint == nil)
    }
}
