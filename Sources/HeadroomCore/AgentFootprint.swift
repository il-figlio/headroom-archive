import Foundation

/// Physical footprint of one agent process tree.
public struct AgentFootprintReading: Equatable, Sendable {
    /// Sum over the readable members.
    public var bytes: UInt64
    public var processCount: Int
    /// Some member's footprint was unreadable; `bytes` is a lower bound.
    public var partial: Bool
    public init(bytes: UInt64, processCount: Int, partial: Bool) {
        self.bytes = bytes; self.processCount = processCount; self.partial = partial
    }
}

public enum AgentFootprint {
    /// Per root pid: the root plus every descendant reachable through
    /// `parent` links. Roots absent from `processes` (exited) get no entry.
    /// A root nested under another root is counted in both trees — each
    /// reading answers "what does this process tree hold", not a share.
    public static func measure(processes: [ProcessMemory], roots: Set<Int32>) -> [Int32: AgentFootprintReading] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Int32]] = [:]
        for process in processes where process.parent != process.pid {
            children[process.parent, default: []].append(process.pid)
        }
        var result: [Int32: AgentFootprintReading] = [:]
        for root in roots {
            guard root > 1, byPID[root] != nil else { continue }
            var reading = AgentFootprintReading(bytes: 0, processCount: 0, partial: false)
            var visited: Set<Int32> = [root]
            var stack = [root]
            while let pid = stack.popLast() {
                guard let process = byPID[pid] else { continue }
                reading.processCount += 1
                if let footprint = process.footprint { reading.bytes += footprint } else { reading.partial = true }
                for child in children[pid] ?? [] where visited.insert(child).inserted { stack.append(child) }
            }
            result[root] = reading
        }
        return result
    }
}
