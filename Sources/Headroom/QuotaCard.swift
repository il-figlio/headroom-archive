import AppKit
import SwiftUI
import HeadroomCore

/// LIMITS card: subscription quota windows per provider account. Collapsed,
/// each account shows only its most constrained window; the chevron expands
/// to every window. Hidden when no provider has reported a reading, and
/// while Limits is off (it's turned on in Settings, not from the panel).
struct QuotaCard: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject private var preferences = AppPreferences.shared
    var isNotch = false

    var body: some View {
        if monitor.quotas.isEmpty || !preferences.limitsEnabled {
            EmptyView()
        } else {
            // Re-evaluates staleness and passed resets without waiting for a poll.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 11) {
                    Text("LIMITS").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                    ForEach(monitor.quotas) { reading in
                        QuotaAccountBlock(reading: reading, now: context.date)
                    }
                }
            }.padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(isNotch ? 0.055 : 0.035)))
                .padding(.horizontal, 16).padding(.top, 8)
        }
    }
}

extension EnvironmentValues {
    /// Screenshot export renders an expanded Limits variant through this.
    var quotaExpandedByDefault: Bool {
        get { self[QuotaExpandedKey.self] }
        set { self[QuotaExpandedKey.self] = newValue }
    }
}
private struct QuotaExpandedKey: EnvironmentKey { static let defaultValue = false }

/// View-layer quota formatting; staleness and reset logic live in HeadroomCore.
enum QuotaDisplay {
    static func isStale(_ reading: QuotaReading, now: Date) -> Bool { reading.isStale(now: now) }
    static func percent(_ fraction: Double) -> Int { Int((min(1, max(0, fraction)) * 100).rounded()) }
    /// "Claude Personal" — account names are shown verbatim.
    static func accountName(_ reading: QuotaReading) -> String {
        [reading.provider.title, reading.account].compactMap { $0 }.joined(separator: " ")
    }
    /// Spoken/long window name: "5h" → "5-hour".
    static func longLabel(_ label: String) -> String {
        switch label.lowercased() {
        case "5h": return "5-hour"
        case "week": return "Weekly"
        case "day": return "Daily"
        default: return label
        }
    }
    /// Time alone within 24 h; weekday + time beyond.
    static func shortReset(_ date: Date, now: Date) -> String {
        date.timeIntervalSince(now) < 86400
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
    static func fullReset(_ date: Date, now: Date) -> String {
        let stamp = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        guard date > now else { return stamp }
        let until = DateComponentsFormatter()
        until.unitsStyle = .abbreviated; until.allowedUnits = [.day, .hour, .minute]; until.maximumUnitCount = 2
        return stamp + (until.string(from: date.timeIntervalSince(now)).map { " (in \($0))" } ?? "")
    }
    /// Compact header badge: "as of 2:14 PM", or "as of Nov 23" when it isn't
    /// today. The full timestamp lives in the hover detail.
    static func asOf(_ date: Date) -> String {
        "as of " + (Calendar.current.isDateInToday(date)
                    ? date.formatted(date: .omitted, time: .shortened)
                    : date.formatted(.dateTime.month(.abbreviated).day()))
    }
    /// "Updated 2:14 PM", or with the date when it isn't today.
    static func updated(_ date: Date) -> String {
        "Updated " + (Calendar.current.isDateInToday(date)
                      ? date.formatted(date: .omitted, time: .shortened)
                      : date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
    }
}

/// One account: "CLAUDE · Personal · Max" header, staleness, disclosure,
/// and its window rows.
private struct QuotaAccountBlock: View {
    let reading: QuotaReading
    let now: Date
    @Environment(\.quotaExpandedByDefault) private var expandedByDefault
    @State private var toggled = false

    private var expanded: Bool { expandedByDefault != toggled }
    private var color: Color { Color(nsColor: reading.provider.color) }
    private var name: String { QuotaDisplay.accountName(reading) }
    private var stale: Bool { QuotaDisplay.isStale(reading, now: now) }
    private var visibleWindows: [QuotaWindow] {
        if expanded { return reading.windows }
        // Every reset passed: fall back to the first window.
        return (reading.mostConstrained(now: now) ?? reading.windows.first).map { [$0] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(Array(visibleWindows.enumerated()), id: \.offset) { _, window in
                QuotaWindowRow(window: window, reading: reading, now: now, stale: stale, color: color)
            }
            if reading.windows.isEmpty {
                Text(reading.error ?? "No usage windows reported")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            if expanded, let balance = reading.balance {
                Text(balance).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    .help(reading.provider == .codex ? "Credit balance on the ChatGPT plan" : "Extra-usage spend on the plan")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(reading.provider.title.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            if let account = reading.account {
                separator
                Text(account).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
            }
            if let plan = reading.plan {
                separator
                Text(plan).font(.system(size: 9, weight: .medium)).foregroundStyle(color).lineLimit(1)
            }
            Spacer(minLength: 6)
            if stale { staleBadge }
            if reading.windows.count > 1 { disclosure }
        }
    }

    private var separator: some View {
        Text("·").font(.system(size: 9)).foregroundStyle(.tertiary)
    }

    private var staleBadge: some View {
        HStack(spacing: 3) {
            if reading.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            Text(QuotaDisplay.asOf(reading.fetchedAt)).font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
        }
        .fixedSize()
        .hoverDetail(reading.error == nil ? "Reading is out of date" : "Couldn't refresh \(name)",
                     [reading.error, "Showing the last reading, from \(reading.fetchedAt.formatted(date: .abbreviated, time: .shortened)).",
                      "Headroom checks every \(Int(QuotaPolicy.interval / 60)) minutes."].compactMap { $0 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) limits are out of date. \(QuotaDisplay.updated(reading.fetchedAt))")
        .accessibilityHint(reading.error ?? "")
    }

    private var disclosure: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { toggled.toggle() } } label: {
            HStack(spacing: 3) {
                if !expanded { Text("+\(reading.windows.count - 1)").font(.system(size: 9)).monospacedDigit() }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).frame(height: 16)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Show fewer limits for \(name)" : "Show all limits for \(name)")
    }
}

/// One window: label · MeterBar (fill = used, attention zone at 90%) ·
/// "61% used · resets 3:30 PM". Remaining share lives in the hover detail
/// and the VoiceOver value.
struct QuotaWindowRow: View {
    let window: QuotaWindow
    let reading: QuotaReading
    let now: Date
    let stale: Bool
    let color: Color
    @State private var hover = false

    private var passed: Bool { window.hasReset(now: now) }
    private var used: Int { QuotaDisplay.percent(window.usedFraction) }
    private var summary: String {
        if passed { return "Reset — updating" }
        return "\(used)% used" + (window.resetsAt.map { " · resets " + QuotaDisplay.shortReset($0, now: now) } ?? "")
    }
    private var spokenValue: String {
        if passed { return "Reset, waiting for a new reading" }
        return "\(used)% used, \(100 - used)% left" + (window.resetsAt.map { ", resets " + QuotaDisplay.shortReset($0, now: now) } ?? "")
            + (stale ? ", out of date" : "")
    }
    var detailLines: [String] {
        var lines: [String] = []
        if passed {
            lines.append("Window reset \(window.resetsAt.map { QuotaDisplay.fullReset($0, now: now) } ?? ""); waiting for the next reading.")
        } else {
            lines.append("\(used)% used · \(100 - used)% left")
            if let resetsAt = window.resetsAt { lines.append("Resets " + QuotaDisplay.fullReset(resetsAt, now: now)) }
        }
        if let detail = window.detail { lines.append(detail) }
        lines.append(QuotaDisplay.updated(reading.fetchedAt))
        if let error = reading.error { lines.append("⚠︎ " + error) }
        return lines
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label).font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading).lineLimit(1).accessibilityHidden(true)
            MeterBar(fraction: passed ? 0 : window.usedFraction,
                     color: window.usedFraction >= 0.98 && !passed ? Color(nsColor: .systemRed) : color,
                     attention: 0.9,
                     accessibilityLabel: "\(QuotaDisplay.accountName(reading)), \(QuotaDisplay.longLabel(window.label))",
                     accessibilityValue: spokenValue)
                .opacity(stale ? 0.4 : 1)
            Text(summary)
                .font(.system(size: 9.5)).foregroundStyle(passed || stale ? .tertiary : .secondary).monospacedDigit()
                .lineLimit(1).fixedSize()
                .frame(minWidth: 146, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.06 : 0))
            .padding(.horizontal, -5))
        .contentShape(Rectangle())
        .hoverDetail("\(QuotaDisplay.accountName(reading)) · \(QuotaDisplay.longLabel(window.label))", detailLines, hovering: $hover)
    }
}
