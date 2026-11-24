import AppKit
import SwiftUI
import HeadroomCore

/// Compact token/cost formatting shared by the agents views.
enum TokenFormat {
    static func compact(_ tokens: Int64) -> String {
        switch tokens {
        case ..<1_000: return "\(tokens)"
        case ..<1_000_000: return String(format: "%.1fK", Double(tokens) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(tokens) / 1_000_000)
        default: return String(format: "%.1fB", Double(tokens) / 1_000_000_000)
        }
    }
    static func usd(_ value: Double) -> String {
        if value <= 0 { return "$0.00" }
        if value < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }
}

/// Bar colors for the hourly burn chart. Agent families that match nothing
/// specific fall back to gray so the legend stays quiet.
extension AgentKind {
    var color: NSColor {
        switch self {
        case .claude: return .systemPurple
        case .codex: return .systemBlue
        case .openclaw: return .systemTeal
        case .devin: return .systemGreen
        case .gemini: return .systemIndigo
        default: return .systemGray
        }
    }
}

/// AGENTS card, capacity first: one row per session that's running (or
/// needs attention) with its live memory footprint, then a compact 12-hour
/// burn chart. Opt-in widget — scanning only matters while it's visible.
struct AgentsCard: View {
    @ObservedObject var monitor: MemoryMonitor
    var isNotch = false
    private static let maxRows = 4

    private var agents: AgentSnapshot { monitor.agents }
    /// The trailing twelve hourly burn buckets, oldest → newest.
    private var burn: [HourBurn] { Array(monitor.agentBurn.suffix(12)) }
    private var burnMax: Double { Double(burn.map { $0.tokens.values.reduce(0, +) }.max() ?? 0) }
    private var burnCost: Double { burn.reduce(0) { $0 + $1.cost.values.reduce(0, +) } }
    /// Kinds with any tokens in the window, in stable declaration order so
    /// the stack and legend never reshuffle between samples.
    private var burnKinds: [AgentKind] {
        AgentKind.allCases.filter { kind in burn.contains { ($0.tokens[kind] ?? 0) > 0 } }
    }
    /// Live, then stuck, then zombie; most recent activity first within each.
    private var nowRows: [AgentSession] {
        let rank: [SessionHealth: Int] = [.live: 0, .stuck: 1, .zombie: 2]
        return agents.sessions.filter { $0.health != .ended }.sorted {
            let (a, b) = (rank[$0.health] ?? 3, rank[$1.health] ?? 3)
            return a != b ? a < b : ($0.lastEventAt ?? .distantPast) > ($1.lastEventAt ?? .distantPast)
        }
    }
    private var running: [AgentSession] { agents.live }
    private var lastActivity: Date? { agents.sessions.compactMap(\.lastEventAt).max() }
    private var costToday: String {
        agents.todayCostUSD.map { "~" + TokenFormat.usd($0) + " today" } ?? "\(TokenFormat.compact(agents.todayTokens.total)) tokens today"
    }
    /// Summed process-tree footprint over distinct processes (sessions
    /// sharing a pid count once); "≥" when some aren't measured yet.
    private var footprintText: String? {
        let summary = agents.runningSummary
        guard summary.measured > 0 else { return nil }
        return (summary.measured < summary.processes ? "≥ " : "") + MemoryFormat.compact(summary.footprint)
    }
    private var summary: String {
        let processes = agents.runningSummary.processes
        return [running.isEmpty ? "Idle" : "\(max(processes, 1)) running", footprintText, costToday].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                header
                content(now: context.date)
            }
        }.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(isNotch ? 0.055 : 0.035)))
            .padding(.horizontal, 16).padding(.top, 8)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("AGENTS").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
            if !agents.roots.isEmpty {
                Text(summary).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(running.isEmpty ? .secondary : .primary)
                    .hoverDetail("Today", todayLines)
            }
            Spacer(minLength: 4)
            Button { monitor.showHistory?() } label: {
                HStack(spacing: 2) { Text("Details"); Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)) }
            }
            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            .help("Open the agents breakdown").accessibilityLabel("Open the agents breakdown")
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if agents.scannedAt == nil {
            quietLine("Looking for coding-agent sessions…")
        } else if agents.roots.isEmpty {
            quietLine("No coding agents found on this Mac.")
        } else {
            if nowRows.isEmpty {
                quietLine(idleLine(now: now))
            } else {
                VStack(spacing: 1) {
                    ForEach(nowRows.prefix(Self.maxRows), id: \.filePath) { session in
                        AgentSessionRow(session: session, now: now, monitor: monitor)
                    }
                    if nowRows.count > Self.maxRows {
                        Button { monitor.showHistory?() } label: {
                            Text("+\(nowRows.count - Self.maxRows) more").font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, -6)
            }
            if burnMax > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    BurnChart(burn: burn, kinds: burnKinds, maxTokens: burnMax)
                    HStack(spacing: 8) {
                        Text("12h")
                        ForEach(burnKinds, id: \.self) { kind in
                            HStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: kind.color)).frame(width: 5, height: 5)
                                Text(kind.title)
                            }
                        }
                        Spacer(minLength: 4)
                        if burnCost > 0 {
                            Text("~" + TokenFormat.usd(burnCost)).monospacedDigit()
                                .help("Estimated spend across these twelve hours, from per-model list prices.")
                        }
                    }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.top, 2)
            }
        }
    }

    private func quietLine(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }

    private func idleLine(now: Date) -> String {
        var parts = ["Nothing running", "\(TokenFormat.compact(agents.todayTokens.total)) tokens"]
        if let cost = agents.todayCostUSD { parts.append("~" + TokenFormat.usd(cost) + " today") }
        if let lastActivity { parts.append("last active " + AgentTime.ago(lastActivity, now: now)) }
        return parts.joined(separator: " · ")
    }

    private var todayLines: [String] {
        var lines = ["\(agents.todayTokens.total.formatted()) tokens across \(agents.byKindToday.values.reduce(0, +)) sessions"]
        if let cost = agents.todayCostUSD {
            lines.append("~\(TokenFormat.usd(cost)) estimated from per-model list prices; providers may bill differently.")
        } else {
            lines.append("Today's models can't be priced, so no dollar estimate is shown.")
        }
        if agents.unpricedTokensToday > 0 { lines.append("+\(TokenFormat.compact(agents.unpricedTokensToday)) unpriced tokens") }
        if let footprintText { lines.append("\(footprintText) live memory across running sessions' process trees") }
        return lines
    }
}

enum AgentTime {
    /// "now", "4m", "2h", "3d" — compact enough for a trailing column.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}

/// One session that's running now: kind dot · project · kind · health
/// badge · live footprint · last activity. Hover shows the detail bubble
/// and swaps the time column for reveal/copy actions.
struct AgentSessionRow: View {
    let session: AgentSession
    let now: Date
    @ObservedObject var monitor: MemoryMonitor
    @State private var hover = false

    var project: String {
        let name = URL(fileURLWithPath: session.projectDir).lastPathComponent
        return name.isEmpty || session.projectDir.isEmpty ? String(session.sessionId.prefix(8)) : name
    }
    private var healthNote: String {
        switch session.health {
        case .live: return "Live" + (session.pid.map { " · pid \($0)" } ?? "")
        case .stuck: return "Stuck: process alive, transcript quiet" + (session.pid.map { " · pid \($0)" } ?? "")
        case .zombie: return "Zombie: transcript grew with no matching process"
        case .ended: return "Ended"
        }
    }
    var detailLines: [String] {
        var lines = [healthNote]
        lines.append(session.footprint.map { "Memory \(MemoryFormat.string($0)) (process tree, live)" } ?? "Memory not measured yet")
        lines.append("\(session.tokens.total.formatted()) tokens · " + (session.costUSD.map { "~" + TokenFormat.usd($0) } ?? "unpriced"))
        if !session.models.isEmpty { lines.append("Models: " + session.models.sorted().joined(separator: ", ")) }
        if session.toolTotal > 0 {
            lines.append("Top tools: " + session.tools.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        }
        var times: [String] = []
        if let start = session.startedAt { times.append("started " + start.formatted(date: .omitted, time: .shortened)) }
        if let last = session.lastEventAt {
            let ago = AgentTime.ago(last, now: now)
            times.append("last activity " + (ago == "now" ? "just now" : ago + " ago"))
        }
        let joined = times.joined(separator: " · ")
        if !joined.isEmpty { lines.append(joined.prefix(1).uppercased() + joined.dropFirst()) }
        if !session.projectDir.isEmpty { lines.append(session.projectDir) }
        return lines
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(nsColor: session.kind.color)).frame(width: 7, height: 7)
            Text(project).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(session.kind.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            if session.health == .stuck || session.health == .zombie {
                Text(session.health.title)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: session.health.color)))
                    .fixedSize()
            }
            Spacer(minLength: 4)
            Text(session.footprint.map(MemoryFormat.string) ?? "—")
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            ZStack(alignment: .trailing) {
                if hover {
                    HStack(spacing: 6) {
                        Button { monitor.reveal(session.projectDir) } label: { Image(systemName: "folder") }
                            .help("Reveal project folder in Finder").accessibilityLabel("Reveal \(project) in Finder")
                        Button { monitor.copyPath(session.projectDir) } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy project path").accessibilityLabel("Copy path of \(project)")
                    }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                        .disabled(session.projectDir.isEmpty)
                } else {
                    Text(session.lastEventAt.map { AgentTime.ago($0, now: now) } ?? "")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                }
            }.frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 6).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .hoverDetail("\(project) — \(session.kind.title)", detailLines, hovering: $hover)
        .contextMenu {
            Button("Reveal Project Folder") { monitor.reveal(session.projectDir) }
            Button("Copy Project Path") { monitor.copyPath(session.projectDir) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project), \(session.kind.title), \(session.health.title)")
        .accessibilityValue(session.footprint.map { "\(MemoryFormat.string($0)) memory" } ?? "memory not measured")
        .accessibilityAction(named: "Reveal project folder") { monitor.reveal(session.projectDir) }
        .accessibilityAction(named: "Copy project path") { monitor.copyPath(session.projectDir) }
    }
}

/// Twelve hourly token bars, oldest at the left, stacked by agent kind.
/// Secondary to the session rows, so it stays short; each bar is hoverable.
private struct BurnChart: View {
    let burn: [HourBurn]
    let kinds: [AgentKind]
    let maxTokens: Double
    static let height: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 0) {
                // Fewer than twelve buckets anchors the bars to the right so
                // a short window still reads as "the most recent hours".
                if burn.count < 12 { Spacer(minLength: 0) }
                ForEach(burn.indices, id: \.self) { index in
                    if index > burn.startIndex { Spacer(minLength: 2) }
                    BurnColumn(bucket: burn[index], kinds: kinds, maxTokens: maxTokens)
                }
            }
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }
}

/// One stacked bar: segment heights share the column proportional to their
/// token count, whole column scaled to the window's largest hour.
struct BurnColumn: View {
    let bucket: HourBurn
    let kinds: [AgentKind]
    let maxTokens: Double
    @State private var hover = false

    private var total: Double { Double(bucket.tokens.values.reduce(0, +)) }
    private var height: CGFloat {
        guard maxTokens > 0, total > 0 else { return 0 }
        return max(2, BurnChart.height * total / maxTokens)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(kinds.reversed(), id: \.self) { kind in
                let tokens = Double(bucket.tokens[kind] ?? 0)
                if tokens > 0 {
                    Rectangle().fill(Color(nsColor: kind.color))
                        .frame(height: max(1, height * tokens / total))
                }
            }
        }
        .frame(width: 14, height: height, alignment: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
        .frame(width: 18, height: BurnChart.height, alignment: .bottom)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .hoverDetail(title, lines, hovering: $hover)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(lines.joined(separator: ", "))
    }

    var title: String {
        let end = bucket.hour.addingTimeInterval(3600)
        return bucket.hour.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)
    }
    var lines: [String] {
        let parts = kinds.compactMap { kind -> String? in
            let tokens = bucket.tokens[kind] ?? 0
            guard tokens > 0 else { return nil }
            let cost = bucket.cost[kind].map { $0 > 0 ? " · ~" + TokenFormat.usd($0) : "" } ?? ""
            return "\(kind.title) \(TokenFormat.compact(tokens)) tokens" + cost
        }
        guard !parts.isEmpty else { return ["No tokens"] }
        let cost = bucket.cost.values.reduce(0, +)
        return parts + (parts.count > 1 ? ["Total \(TokenFormat.compact(Int64(total))) tokens" + (cost > 0 ? " · ~" + TokenFormat.usd(cost) : "")] : [])
    }
}
