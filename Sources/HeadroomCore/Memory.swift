import Foundation
import CMemory

public enum Pressure: Int, Codable {
    case unknown = 0, normal = 1, warning = 2, critical = 4
    public var title: String {
        switch self {
        case .unknown: return "Unavailable"
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
    public static func fromKernel(_ value: Int) -> Pressure {
        if value & 4 != 0 { return .critical }
        if value & 2 != 0 { return .warning }
        if value & 1 != 0 { return .normal }
        return .unknown
    }
}

public struct SystemMemory: Codable {
    public let total: UInt64
    public let used: UInt64
    public let compressed: UInt64
    public let swap: UInt64
    public let pressure: Pressure
    public let valid: Bool
    public var fraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
    public static func read() -> SystemMemory {
        let value = ml_read_system()
        return .init(total: value.total, used: value.used, compressed: value.compressed,
                     swap: value.swap, pressure: Pressure.fromKernel(Int(value.pressure)), valid: value.valid != 0)
    }
}

public struct ProcessMemory {
    public let pid: Int32
    public let parent: Int32
    public let path: String
    public let footprint: UInt64?
    public init(pid: Int32, parent: Int32, path: String, footprint: UInt64?) {
        self.pid = pid; self.parent = parent; self.path = path; self.footprint = footprint
    }
    public static func read() -> [ProcessMemory] {
        var count = 0
        guard let pointer = ml_read_processes(&count) else { return [] }
        defer { ml_free_processes(pointer) }
        return UnsafeBufferPointer(start: pointer, count: count).map { value in
            var path = value.path
            let string = withUnsafePointer(to: &path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
            }
            return ProcessMemory(pid: value.pid, parent: value.parent, path: string,
                                 footprint: value.readable == 0 ? nil : value.footprint)
        }
    }
}

public struct AppIdentity: Codable {
    public let pid: Int32
    public let name: String
    public let bundlePath: String
    public let bundleIdentifier: String?
    public let launchDate: Date?
    public init(pid: Int32, name: String, bundlePath: String, bundleIdentifier: String?, launchDate: Date?) {
        self.pid = pid; self.name = name; self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier; self.launchDate = launchDate
    }
}

public struct AppMemory: Identifiable, Codable {
    public let app: AppIdentity
    public let bytes: UInt64?
    public let processCount: Int
    public let unreadableCount: Int
    public var id: Int32 { app.pid }
}

public enum AppGrouping {
    /// Attribute descendants first. Bundle paths also catch reparented helpers.
    /// Every PID belongs to at most one visible app; standalone GUI apps own themselves.
    public static func group(apps: [AppIdentity], processes: [ProcessMemory]) -> [AppMemory] {
        let roots = Set(apps.map(\.pid))
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = apps.filter { !$0.bundlePath.isEmpty }.sorted { $0.bundlePath.count > $1.bundlePath.count }
        var groups: [Int32: [ProcessMemory]] = [:]
        for process in processes {
            var cursor = process.pid
            var visited = Set<Int32>()
            var owner: Int32?
            while cursor > 1, visited.insert(cursor).inserted {
                if roots.contains(cursor) { owner = cursor; break }
                guard let ancestor = byPID[cursor] else { break }
                cursor = ancestor.parent
            }
            if owner == nil {
                owner = paths.first(where: { process.path.hasPrefix($0.bundlePath + "/") })?.pid
            }
            if let owner { groups[owner, default: []].append(process) }
        }
        return apps.map { app in
            let members = groups[app.pid, default: []]
            let values = members.compactMap(\.footprint)
            return AppMemory(app: app, bytes: values.isEmpty ? nil : values.reduce(0, +),
                             processCount: members.count, unreadableCount: members.filter { $0.footprint == nil }.count)
        }.sorted {
            if $0.bytes != $1.bytes { return ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            return $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending
        }
    }
}

public enum Placement: String, CaseIterable {
    case automatic, menuBar, notch
    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .menuBar: return "Menu bar"
        case .notch: return "Notch"
        }
    }
    public func usesNotch(available: Bool) -> Bool { available && self != .menuBar }
}

/// Byte counts in binary units labeled GB/TB, matching what Headroom has
/// always shown. Sizes that would print as 1000 GB or more switch to TB
/// (only disks get there): two decimals below 10 TB, one above.
public enum MemoryFormat {
    public static func string(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if let tb = terabytes(gb, decimals: 2) { return tb }
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
    public static func compact(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if let tb = terabytes(gb, decimals: 1) { return tb }
        // Below 1 GB as rounded for display, MB reads better than "0.3 GB".
        if (gb * 10).rounded() / 10 < 1 { return String(format: "%.0f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.1f GB", gb)
    }
    /// A daily change in GB, in whichever unit fits it: "205 MB/day", "1.6 GB/day", "1.20 TB/day".
    public static func perDay(gb: Double) -> String {
        compact(UInt64(max(0, gb) * 1_073_741_824)) + "/day"
    }
    /// nil below 1 TB (1024 GB in these binary units), as rounded for display,
    /// so a TB value never reads under "1.00 TB".
    private static func terabytes(_ gb: Double, decimals: Int) -> String? {
        let scale = pow(10, Double(decimals))
        guard (gb * scale).rounded() / scale >= 1024 else { return nil }
        let tb = gb / 1024
        return (tb * 100).rounded() / 100 >= 10 ? String(format: "%.1f TB", tb) : String(format: "%.2f TB", tb)
    }
}

/// Unit for a chart axis, chosen from the largest value it plots, so a 2 TB disk
/// reads in TB and a small swap series in MB. Values come in GB (binary).
public struct ByteAxis: Equatable {
    public let unit: String
    /// Multiply a GB value by this to plot it in `unit`.
    public let scale: Double
    public static func fitting(maxGB: Double) -> ByteAxis {
        if maxGB >= 1024 { return ByteAxis(unit: "TB", scale: 1.0 / 1024) }
        if maxGB > 0 && maxGB < 1 { return ByteAxis(unit: "MB", scale: 1024) }
        return ByteAxis(unit: "GB", scale: 1)
    }
}
