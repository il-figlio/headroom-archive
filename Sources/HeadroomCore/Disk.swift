import Foundation
import CMemory

public enum DiskUrgency: Int, Codable {
    case ample, low, critical
    public var title: String {
        switch self {
        case .ample: return "Ample"
        case .low: return "Low"
        case .critical: return "Critical"
        }
    }
}

/// "Free" is space usable right now; "purgeable" is extra space macOS can
/// reclaim on demand. Both come from one cheap volume attribute read.
public struct DiskSpace: Codable {
    public let total: UInt64
    public let free: UInt64
    public let purgeable: UInt64
    public let valid: Bool
    public var used: UInt64 { total > free ? total - free : 0 }
    public var freeFraction: Double { total == 0 ? 0 : Double(free) / Double(total) }
    public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
    public var urgency: DiskUrgency {
        guard valid else { return .ample }
        if freeFraction < 0.05 { return .critical }
        if freeFraction < 0.10 { return .low }
        return .ample
    }
    public init(total: UInt64, free: UInt64, purgeable: UInt64, valid: Bool) {
        self.total = total; self.free = free; self.purgeable = purgeable; self.valid = valid
    }
    public static func read() -> DiskSpace {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacity,
              let important = values.volumeAvailableCapacityForImportantUsage else {
            return .init(total: 0, free: 0, purgeable: 0, valid: false)
        }
        return .init(total: UInt64(clamping: total), free: UInt64(clamping: available),
                     purgeable: UInt64(clamping: Int64(important) - Int64(available)), valid: true)
    }
}

public struct DiskPoint: Identifiable {
    public let date: Date
    public let freeGB: Double
    public let purgeableGB: Double
    public var id: Date { date }
}

public struct DiskConsumer: Identifiable, Codable {
    public let path: String
    public let name: String
    public let bytes: UInt64
    public let previousBytes: UInt64?
    public let scannedAt: Date?
    public let partial: Bool
    public var id: String { path }
    public var delta: Int64? {
        previousBytes.map { Int64(bitPattern: bytes) - Int64(bitPattern: $0) }
    }
    public init(path: String, name: String, bytes: UInt64, previousBytes: UInt64?, scannedAt: Date?, partial: Bool) {
        self.path = path; self.name = name; self.bytes = bytes
        self.previousBytes = previousBytes; self.scannedAt = scannedAt; self.partial = partial
    }
}

public struct ConsumerScan {
    public var items: [DiskConsumer] = []
    public var scannedAt: Date?
    public var localSnapshots: Int = 0
    public init() {}
    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

/// Walks a bounded set of roots once, on demand, at the lowest disk priority.
/// Never deletes anything; results are meant for the storage view and log.
public final class ConsumerScanner {
    public struct Result {
        public let consumers: [DiskConsumer]
        public let localSnapshots: Int
        public let cancelled: Bool
    }
    private var cancelled = false
    public init() {}
    public func cancel() { cancelled = true }

    /// Depth-1 of the home directory, with Library expanded one more level —
    /// that's where macOS concentrates most of its reclaimable weight.
    public static func defaultRoots() -> [URL] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var roots: [URL] = []
        let topLevel = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in topLevel {
            if url.lastPathComponent == "Library" {
                let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                roots.append(contentsOf: children)
            } else {
                roots.append(url)
            }
        }
        roots.append(URL(fileURLWithPath: "/Applications", isDirectory: true))
        return roots.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Runs on the caller's queue; call `ml_throttle_io()` on it first.
    /// `progress` receives (completed roots, total roots).
    public func scan(roots: [URL] = ConsumerScanner.defaultRoots(),
                     progress: @escaping (Int, Int) -> Void = { _, _ in }) -> Result {
        ml_throttle_io()
        let fm = FileManager.default
        var consumers: [DiskConsumer] = []
        var index = 0
        for root in roots {
            if cancelled { return Result(consumers: [], localSnapshots: 0, cancelled: true) }
            index += 1
            progress(index, roots.count)
            var partial = false
            let bytes = size(of: root, fileManager: fm, partial: &partial)
            consumers.append(DiskConsumer(path: root.path, name: displayName(for: root), bytes: bytes,
                                          previousBytes: nil, scannedAt: nil, partial: partial))
        }
        return Result(consumers: consumers, localSnapshots: localSnapshotCount(), cancelled: false)
    }

    private func displayName(for url: URL) -> String {
        let home = NSHomeDirectory()
        var path = url.path
        if path.hasPrefix(home) {
            path = "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func size(of root: URL, fileManager fm: FileManager, partial: inout Bool) -> UInt64 {
        var total: UInt64 = 0
        var values = try? root.resourceValues(forKeys: [.isDirectoryKey, .fileAllocatedSizeKey])
        guard values?.isDirectory == true else {
            return UInt64(values?.fileAllocatedSize ?? 0)
        }
        var sawError = false
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileAllocatedSizeKey],
                                             options: [], errorHandler: { _, _ in sawError = true; return true }) else {
            partial = true
            return 0
        }
        for case let url as URL in enumerator {
            if cancelled { sawError = true; break }
            values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileAllocatedSizeKey])
            if let size = values?.fileAllocatedSize { total += UInt64(size) }
        }
        if sawError { partial = true }
        return total
    }

    private func localSnapshotCount() -> Int {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.split(separator: "\n").filter { $0.hasPrefix("com.apple.TimeMachine.") }.count
        } catch { return 0 }
    }
}

public enum DiskAdvice {
    /// Free-space and growth recommendations. Deletion is always left to the user.
    public static func recommend(_ summary: TrendSummary) -> [Recommendation] {
        var result: [Recommendation] = []
        guard let free = summary.latestDiskFree, let total = summary.latestDiskTotal, total > 0 else { return result }
        let fraction = Double(free) / Double(total)
        let purgeable = summary.latestDiskPurgeable.map { MemoryFormat.string($0) }
        let reclaimHint = purgeable.map { " \( $0 ) is purgeable caches macOS can reclaim on its own." } ?? ""
        if fraction < 0.05 {
            result.append(.init(title: "Free up disk space soon",
                                detail: "Only \(MemoryFormat.compact(free)) of \(MemoryFormat.compact(total)) remains. Below about 5% free, macOS slows writes and swap and updates can fail. Sort the storage view by size and remove or relocate the largest items; Headroom never deletes anything itself.\(reclaimHint)"))
        } else if fraction < 0.10 {
            result.append(.init(title: "Disk space is getting low",
                                detail: "\(MemoryFormat.compact(free)) free of \(MemoryFormat.compact(total)). Review Downloads, developer caches, and large media before it becomes urgent.\(reclaimHint)"))
        }
        if let days = summary.daysUntilFull, days > 0, days < 14, let rate = summary.diskRateGBPerDay, rate > 0.1 {
            result.append(.init(title: "Disk is filling quickly",
                                detail: "Free space shrank by about \(MemoryFormat.perDay(gb: rate)) over the recorded window; at that pace it runs out in roughly \(Int(days.rounded(.up))) day(s). Check the largest consumers below."))
        }
        let grown = summary.consumers.items.compactMap { item -> (DiskConsumer, Int64)? in
            guard let delta = item.delta, delta >= 1_073_741_824, Double(delta) >= Double(item.previousBytes ?? 1) * 0.10 else { return nil }
            return (item, delta)
        }.sorted { $0.1 > $1.1 }.first
        if let (item, delta) = grown {
            result.append(.init(title: "\(item.name) grew \(MemoryFormat.string(UInt64(delta)))",
                                detail: "Its measured size rose from \(item.previousBytes.map(MemoryFormat.string) ?? "unknown") to \(MemoryFormat.string(item.bytes)) between the last two storage scans. Review it from the storage view if the growth wasn't intentional."))
        }
        if summary.consumers.localSnapshots > 0 {
            result.append(.init(title: "Local Time Machine snapshots",
                                detail: "macOS is keeping \(summary.consumers.localSnapshots) local snapshot(s). They reserve space until Time Machine moves them off; the system manages and shrinks them on its own."))
        }
        return result
    }
}
