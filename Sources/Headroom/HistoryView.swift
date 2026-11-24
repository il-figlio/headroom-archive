import SwiftUI
import Charts
import HeadroomCore

struct HistoryView: View {
    @ObservedObject var monitor: MemoryMonitor
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Trends & recommendations").font(.system(size: 23, weight: .semibold, design: .rounded))
                        Text("Last 24 hours · \(monitor.trends.sampleCount) samples").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Record history", isOn: $monitor.historyEnabled).toggleStyle(.switch).fixedSize()
                }
                if !monitor.historyEnabled {
                    Label("History is paused. The live memory indicator still works.", systemImage: "pause.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error = monitor.historyError {
                    Label("History couldn't be saved: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                HStack(spacing: 24) {
                    stat("Observed", "\(Int(monitor.trends.observedMinutes.rounded())) min")
                    stat("Under pressure", "\(Int(monitor.trends.pressuredMinutes.rounded())) min")
                    stat("Peak swap", MemoryFormat.string(monitor.trends.peakSwap))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Memory & swap").font(.headline)
                    if monitor.trends.points.count >= 2 {
                        let axis = ByteAxis.fitting(maxGB: monitor.trends.points.map { max($0.usedGB, $0.swapGB) }.max() ?? 0)
                        Chart(monitor.trends.points) { point in
                            LineMark(x: .value("Time", point.date), y: .value(axis.unit, point.usedGB * axis.scale)).foregroundStyle(by: .value("Metric", "Memory used"))
                            LineMark(x: .value("Time", point.date), y: .value(axis.unit, point.swapGB * axis.scale)).foregroundStyle(by: .value("Metric", "Swap"))
                        }.chartForegroundStyleScale(["Memory used": Color.teal, "Swap": Color.orange])
                            .chartYAxisLabel(axis.unit).frame(height: 150)
                    } else {
                        Text("The chart appears as readings accumulate. Leave Headroom running during your normal work.")
                            .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Storage").font(.headline)
                        Spacer()
                        if let scanText = monitor.consumerScanText {
                            Text(scanText).font(.caption).foregroundStyle(.secondary)
                            Button("Stop") { monitor.cancelConsumerScan() }
                        } else {
                            Button(monitor.consumers.items.isEmpty ? "Scan consumers" : "Rescan") { monitor.rescanConsumers() }
                                .help("Measure the largest locations once, at the lowest disk priority. Sizes persist until the next scan.")
                        }
                    }
                    if let free = monitor.trends.latestDiskFree, let total = monitor.trends.latestDiskTotal, total > 0 {
                        HStack(spacing: 24) {
                            stat("Free now", MemoryFormat.string(free))
                            stat("Purgeable", MemoryFormat.string(monitor.trends.latestDiskPurgeable ?? 0))
                            stat("Filled/day", monitor.trends.diskRateGBPerDay.map { $0 > 0.1 ? MemoryFormat.compact(UInt64($0 * 1_073_741_824)) : "flat" } ?? "—")
                            stat("Runs out in", monitor.trends.daysUntilFull.map { "\(Int($0.rounded(.up)))d" } ?? "—")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                        if monitor.trends.diskPoints.count >= 2 {
                            let axis = ByteAxis.fitting(maxGB: monitor.trends.diskPoints.map(\.freeGB).max() ?? 0)
                            Chart(monitor.trends.diskPoints) { point in
                                LineMark(x: .value("Time", point.date), y: .value(axis.unit, point.freeGB * axis.scale)).foregroundStyle(by: .value("Metric", "Disk free"))
                            }.chartForegroundStyleScale(["Disk free": Color.purple])
                                .chartYAxisLabel(axis.unit).frame(height: 110)
                        }
                        let used = total > free ? total - free : 0
                        let scanned = monitor.consumers.totalBytes
                        let other = used > scanned ? used - scanned : 0
                        if !monitor.consumers.items.isEmpty {
                            VStack(spacing: 2) {
                                ForEach(monitor.consumers.items.prefix(15)) { item in consumerRow(item) }
                                if other > 0 {
                                    consumerLine("System & other volumes", bytes: other, detail: "macOS, preboot, VM, and unreadable areas", path: nil, delta: nil)
                                }
                                if monitor.consumers.localSnapshots > 0 {
                                    consumerLine("Time Machine local snapshots", bytes: nil, detail: "\(monitor.consumers.localSnapshots) snapshot(s), managed by macOS", path: nil, delta: nil)
                                }
                            }.padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                            HStack(spacing: 3) {
                                Text("Largest locations.")
                                if let scannedAt = monitor.consumers.scannedAt {
                                    Text("Sizes as of")
                                    Text(scannedAt, style: .date)
                                    Text(scannedAt, style: .time)
                                }
                                Text("· Headroom never deletes files.")
                            }.font(.caption).foregroundStyle(.secondary)
                        } else if monitor.consumerScanText == nil {
                            Text("Scan once to see which locations use the most space. It runs at the lowest disk priority and never deletes anything; re-scan whenever you like.")
                                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Disk readings appear once history records a sample.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                AgentsSection(monitor: monitor)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Recommendations").font(.headline)
                    ForEach(monitor.trends.recommendations) { advice in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(advice.title).font(.system(size: 13, weight: .semibold))
                            Text(advice.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                    }
                    if let latest = monitor.trends.latestAt {
                        HStack(spacing: 3) {
                            Text("Last recorded reading:")
                            Text(latest, style: .date)
                            Text(latest, style: .time)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack {
                    Button("Open log.md") { monitor.openLog() }
                    Button("Show history folder") { monitor.revealHistory() }
                    Spacer()
                    Button("Archive history…") { monitor.archiveHistory() }
                }
                Text("One app snapshot about every minute. Thirty days retained locally. Sleep and downtime aren't counted as observed time. Recommendations use measured rules and don't send data to an AI service.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
        }.frame(minWidth: 600, minHeight: 660).background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // A stale (or missing) consumer table refreshes itself, once a day
            // at most, always throttled and always cancellable.
            if monitor.consumersStale && monitor.consumerScanText == nil { monitor.rescanConsumers() }
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
        }
    }
    private func consumerRow(_ item: DiskConsumer) -> some View {
        consumerLine(item.name, bytes: item.bytes,
                     detail: item.partial ? "partial reading" : nil, path: item.path, delta: item.delta)
    }
    private func consumerLine(_ name: String, bytes: UInt64?, detail: String?, path: String?, delta: Int64?) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if let delta, delta != 0 {
                Text("\(delta > 0 ? "+" : "−")\(MemoryFormat.string(delta.magnitude))")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(delta > 0 ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 4)
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(bytes.map(MemoryFormat.string) ?? "—")
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            if let path {
                Button { monitor.reveal(path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
                Button { monitor.copyPath(path) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy path")
            }
        }.padding(.vertical, 5)
    }
}
