import AppKit
import SwiftUI
import HeadroomCore

extension SessionHealth {
    var color: NSColor {
        switch self {
        case .live: return .systemGreen
        case .stuck: return .systemOrange
        case .zombie: return .systemRed
        case .ended: return .systemGray
        }
    }
}

/// Agents section inside the Trends window: today's totals, detected agent
/// folders, and the most recent sessions across every provider.
struct AgentsSection: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject private var widgets = PanelWidgets.shared

    private var agents: AgentSnapshot { monitor.agents }
    private var recent: [AgentSession] {
        Array(agents.sessions.sorted { ($0.lastEventAt ?? .distantPast) > ($1.lastEventAt ?? .distantPast) }.prefix(12))
    }
    private var sessionsToday: Int { agents.byKindToday.values.reduce(0, +) }
    /// Existing roots grouped by kind, in stable declaration order.
    private var detected: [(kind: AgentKind, files: Int)] {
        var files: [AgentKind: Int] = [:]
        for root in agents.roots where root.exists { files[root.kind, default: 0] += root.sessionFiles }
        return AgentKind.allCases.compactMap { kind in
            guard let count = files[kind] else { return nil }
            return (kind, count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agents").font(.headline)
            if !widgets.isVisible(.agents) && agents.scannedAt == nil {
                Text("Agent tracking is off. Turn on Agents under Widgets in the panel's menu to read coding-agent session transcripts — read-only; nothing is modified or uploaded.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if agents.roots.isEmpty {
                Text(agents.scannedAt == nil
                     ? "Looking for coding-agent sessions…"
                     : "No coding-agent folders found. When agents like Claude Code, Codex, or Gemini run on this Mac, Headroom reads their session transcripts under folders such as ~/.claude and ~/.codex — read-only; nothing is modified or uploaded.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 24) {
                    stat("Active now", "\(agents.live.count)")
                    stat("Sessions today", "\(sessionsToday)")
                    stat("Tokens today", TokenFormat.compact(agents.todayTokens.total))
                    stat("Est. cost", agents.todayCostUSD.map { "~" + TokenFormat.usd($0) } ?? "—")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                if agents.unpricedTokensToday > 0 {
                    Text("+\(TokenFormat.compact(agents.unpricedTokensToday)) unpriced tokens today — the estimate only covers models with known prices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(detected, id: \.kind) { item in
                            Text("\(item.kind.title) \(item.files)")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.05)))
                                .opacity(item.files > 0 ? 1 : 0.45)
                                .help(item.files == 1 ? "1 session file" : "\(item.files) session files")
                        }
                    }
                }
                if recent.isEmpty {
                    Text("No agent sessions recorded yet. Headroom scans folders like ~/.claude and ~/.codex for session transcripts — read-only; nothing is modified or uploaded.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 2) {
                        ForEach(recent, id: \.filePath) { sessionRow($0) }
                    }.padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                    if let scannedAt = agents.scannedAt {
                        HStack(spacing: 3) {
                            Text("Sessions as of")
                            Text(scannedAt, style: .date)
                            Text(scannedAt, style: .time)
                            Text("· Read-only transcripts.")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: session.health.color)).frame(width: 7, height: 7)
                .help(session.pid.map { "\(session.health.title) · pid \($0)" } ?? session.health.title)
            Text(session.kind.title).font(.system(size: 12, weight: .medium))
            Text(projectName(session.projectDir) ?? String(session.sessionId.prefix(8)))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let at = session.lastEventAt {
                Text(at, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(TokenFormat.compact(session.tokens.total))
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                .help(tokenDetail(session))
            if let cost = session.costUSD {
                Text(TokenFormat.usd(cost))
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            if session.toolTotal > 0 {
                Text("\(session.toolTotal) tools").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(toolDetail(session))
            }
            Button { monitor.reveal(session.projectDir) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal project folder in Finder")
                .accessibilityLabel("Reveal project folder in Finder")
            Button { monitor.copyPath(session.projectDir) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy project path")
                .accessibilityLabel("Copy project path")
        }.padding(.vertical, 5)
    }

    private func projectName(_ dir: String) -> String? {
        let name = URL(fileURLWithPath: dir).lastPathComponent
        return name.isEmpty ? nil : name
    }
    private func tokenDetail(_ session: AgentSession) -> String {
        var detail = "\(session.tokens.total.formatted()) tokens"
        if !session.models.isEmpty { detail += " · " + session.models.sorted().joined(separator: ", ") }
        if session.unpricedTokens > 0 { detail += " · \(TokenFormat.compact(session.unpricedTokens)) unpriced" }
        return detail
    }
    private func toolDetail(_ session: AgentSession) -> String {
        session.tools.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(4).map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }
}
