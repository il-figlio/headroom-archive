import Foundation

/// Shared lenient JSONL helpers. All field access is defensive: transcripts
/// evolve between agent versions and partial lines must never throw upward.
enum AgentLine {
    static func dict(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func string(_ obj: [String: Any], _ keys: [String]) -> String? {
        for key in keys { if let s = obj[key] as? String, !s.isEmpty { return s } }
        return nil
    }
    static func dict(_ obj: [String: Any], _ keys: [String]) -> [String: Any]? {
        for key in keys { if let d = obj[key] as? [String: Any] { return d } }
        return nil
    }
    static func date(_ value: Any?) -> Date? {
        switch value {
        case let s as String:
            return ISO8601DateFormatter.withFractional.date(from: s) ?? ISO8601DateFormatter.plain.date(from: s)
        case let n as NSNumber:
            let t = n.doubleValue
            return Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t)
        default: return nil
        }
    }
    /// usage-ish dict → TokenUsage. Accepts the common key spellings.
    static func usage(_ d: [String: Any]) -> TokenUsage {
        func v(_ keys: [String]) -> Int64 {
            for k in keys { if let n = d[k] as? NSNumber { return n.int64Value } }
            return 0
        }
        var u = TokenUsage()
        u.input = v(["input_tokens", "prompt_tokens", "input"])
        u.output = v(["output_tokens", "completion_tokens", "output"]) + v(["reasoning_output_tokens"])
        u.cacheRead = v(["cache_read_input_tokens", "cached_input_tokens", "cache_read"])
        u.cacheWrite = v(["cache_creation_input_tokens", "cache_write_input_tokens", "cache_write"])
        return u
    }
    static func touch(_ date: Date?, into session: inout AgentSession) {
        guard let date else { return }
        if session.startedAt == nil || date < session.startedAt! { session.startedAt = date }
        if session.lastEventAt == nil || date > session.lastEventAt! { session.lastEventAt = date }
    }
}

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
}

/// Providers that track which model produced which tokens let the scanner
/// price honestly; `takeModelTokens` returns deltas since the previous call.
protocol ModelTokenTracking {
    func takeModelTokens(file: String) -> [String: TokenUsage]
}

func expandAgentPath(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

func jsonlFiles(under root: String, depth: Int, nameHasPrefix prefix: String? = nil) -> [URL] {
    let url = URL(fileURLWithPath: expandAgentPath(root), isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
    var files: [URL] = []
    for case let file as URL in enumerator {
        let relative = file.pathComponents.count - url.pathComponents.count
        if relative >= depth { enumerator.skipDescendants() }
        guard relative > 0, relative <= depth, file.pathExtension == "jsonl" else { continue }
        if let prefix, !file.lastPathComponent.hasPrefix(prefix) { continue }
        files.append(file)
    }
    return files
}

/// ~/.claude/projects/<escaped-path>/<session-uuid>.jsonl
public final class ClaudeCodeProvider: AgentProvider {
    public let kind = AgentKind.claude
    public let roots: [String]
    private var byModel: [String: [String: TokenUsage]] = [:]
    /// `root` is injectable so tests never read the real ~/.claude.
    public init(root: String = "~/.claude") { roots = [root] }

    public var sessionTrees: [AgentSessionTree] {
        [AgentSessionTree(path: roots[0] + "/projects", depth: 2, minDepth: 2)]
    }

    public func sessionFiles() -> [URL] {
        let projects = URL(fileURLWithPath: expandAgentPath(roots[0] + "/projects"), isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for dir in dirs {
            guard let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            files.append(contentsOf: children.filter { $0.pathExtension == "jsonl" })
        }
        return files
    }

    public func parse(line: Data, into session: inout AgentSession, event: inout AgentLineEvent) -> Bool {
        guard let obj = AgentLine.dict(line) else { return false }
        let stamp = AgentLine.date(obj["timestamp"])
        AgentLine.touch(stamp, into: &session)
        event.at = stamp
        if let sid = AgentLine.string(obj, ["sessionId"]) { session.sessionId = sid }
        if let cwd = AgentLine.string(obj, ["cwd"]) { session.projectDir = cwd }
        guard let message = obj["message"] as? [String: Any] else { return true }
        let usage = AgentLine.dict(message, ["usage"]).map(AgentLine.usage) ?? TokenUsage()
        if usage.total > 0 { session.tokens += usage; event.tokens += usage }
        if let model = AgentLine.string(message, ["model"]) {
            session.models.insert(model)
            if usage.total > 0 {
                byModel[session.filePath, default: [:]][model, default: TokenUsage()] += usage
                event.model = model
            }
        } else if usage.total > 0 {
            byModel[session.filePath, default: [:]]["", default: TokenUsage()] += usage
        }
        // Subagent (sidechain) calls show up again on the parent side as Task
        // tool uses — count their tokens but not their tool calls.
        if (obj["isSidechain"] as? Bool) != true,
           let content = message["content"] as? [[String: Any]] {
            for item in content where item["type"] as? String == "tool_use" {
                if let name = AgentLine.string(item, ["name"]) {
                    session.tools[name, default: 0] += 1
                }
            }
        }
        return true
    }
}

extension ClaudeCodeProvider: ModelTokenTracking {
    func takeModelTokens(file: String) -> [String: TokenUsage] {
        byModel.removeValue(forKey: file) ?? [:]
    }
}

/// ~/.codex/sessions/**/rollout-<ts>-<uuid>.jsonl plus archived_sessions.
/// Codex emits both per-response deltas (`token_usage_record.usage`) and
/// cumulative counters (`token_count.total_token_usage`); the cumulative
/// form wins so resumed scans stay exact.
public final class CodexProvider: AgentProvider {
    public let kind = AgentKind.codex
    public let roots: [String]
    private var byModel: [String: [String: TokenUsage]] = [:]
    private var currentModel: [String: String] = [:]
    /// `root` is injectable so tests never read the real ~/.codex.
    public init(root: String = "~/.codex") { roots = [root] }

    /// sessions/YYYY/MM/DD/rollout-*.jsonl sits five levels below the root —
    /// deeper than the generic root walk reaches.
    public var sessionTrees: [AgentSessionTree] {
        [AgentSessionTree(path: roots[0] + "/sessions", depth: 4, namePrefix: "rollout-"),
         AgentSessionTree(path: roots[0] + "/archived_sessions", depth: 2, namePrefix: "rollout-")]
    }

    public func sessionFiles() -> [URL] {
        sessionTrees.flatMap { jsonlFiles(under: $0.path, depth: $0.depth, nameHasPrefix: $0.namePrefix) }
    }

    /// rollout-2026-10-03T23-27-41-<uuid>.jsonl → trailing 5 dash groups.
    static func sessionID(fromFile url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let parts = base.split(separator: "-")
        return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : base
    }

    public func parse(line: Data, into session: inout AgentSession, event: inout AgentLineEvent) -> Bool {
        guard let obj = AgentLine.dict(line) else { return false }
        let stamp = AgentLine.date(obj["timestamp"])
        AgentLine.touch(stamp, into: &session)
        event.at = stamp
        let payload = obj["payload"] as? [String: Any] ?? [:]
        if let cwd = AgentLine.string(payload, ["cwd"]) { session.projectDir = cwd }
        // Only the session_meta record names the session; other payloads
        // carry message, call or turn ids under the same keys.
        if obj["type"] as? String == "session_meta",
           let sid = AgentLine.string(payload, ["session_id", "id", "thread_id"]) { session.sessionId = sid }
        if let model = AgentLine.string(payload, ["model"])
            ?? (AgentLine.dict(payload, ["collaboration_mode"])
                .flatMap { AgentLine.dict($0, ["settings"]) }
                .flatMap { AgentLine.string($0, ["model"]) }) {
            session.models.insert(model)
            currentModel[session.filePath] = model
        }
        switch obj["type"] as? String {
        case "token_usage_record":
            if let delta = AgentLine.dict(payload, ["usage"]) {
                addUsage(AgentLine.usage(delta), to: &session, event: &event)
            }
        case "event_msg":
            if payload["type"] as? String == "token_count",
               let info = AgentLine.dict(payload, ["info"]),
               let total = AgentLine.dict(info, ["total_token_usage"]) {
                let u = AgentLine.usage(total)
                // Cumulative counter — attribute the jump over what we've seen
                // so per-model tracking and tokens.total stay consistent.
                if u.total > session.tokens.total {
                    var delta = TokenUsage()
                    delta.input = max(0, u.input - session.tokens.input)
                    delta.output = max(0, u.output - session.tokens.output)
                    delta.cacheRead = max(0, u.cacheRead - session.tokens.cacheRead)
                    delta.cacheWrite = max(0, u.cacheWrite - session.tokens.cacheWrite)
                    addUsage(delta, to: &session, event: &event)
                    session.tokens = u
                }
            }
        case "response_item":
            guard let t = payload["type"] as? String, t.hasSuffix("_call") else { break }
            let name = AgentLine.string(payload, ["name"]) ?? String(t.dropLast(5))
            session.tools[name, default: 0] += 1
        default: break
        }
        return true
    }

    private func addUsage(_ usage: TokenUsage, to session: inout AgentSession, event: inout AgentLineEvent) {
        guard usage.total > 0 else { return }
        session.tokens += usage
        event.tokens += usage
        // Usage lines don't carry the model; the last turn_context does.
        if let model = currentModel[session.filePath] { event.model = model }
        let key = currentModel[session.filePath] ?? ""
        byModel[session.filePath, default: [:]][key, default: TokenUsage()] += usage
    }
}

extension CodexProvider: ModelTokenTracking {
    func takeModelTokens(file: String) -> [String: TokenUsage] {
        byModel.removeValue(forKey: file) ?? [:]
    }
}

/// OpenClaw transcripts aren't stable yet; accept anything Claude-shaped or
/// generically shaped under ~/.openclaw.
public final class OpenClawProvider: AgentProvider {
    public let kind = AgentKind.openclaw
    public let roots = ["~/.openclaw"]
    public init() {}

    public func sessionFiles() -> [URL] {
        let agents = jsonlFiles(under: "~/.openclaw/agents", depth: 3)
        return agents.isEmpty ? jsonlFiles(under: "~/.openclaw", depth: 3) : agents
    }

    public func parse(line: Data, into session: inout AgentSession, event: inout AgentLineEvent) -> Bool {
        guard let obj = AgentLine.dict(line) else { return false }
        let stamp = AgentLine.date(obj["timestamp"] ?? obj["ts"] ?? obj["created_at"])
        AgentLine.touch(stamp, into: &session)
        event.at = stamp
        // A bare `id` names the session only on the session header line;
        // message lines use it for the message itself.
        if let sid = AgentLine.string(obj, ["sessionId", "session_id"])
            ?? (obj["type"] as? String == "session" ? AgentLine.string(obj, ["id"]) : nil) { session.sessionId = sid }
        if let cwd = AgentLine.string(obj, ["cwd"]) { session.projectDir = cwd }
        if let message = obj["message"] as? [String: Any] {
            if let model = AgentLine.string(message, ["model"]) { session.models.insert(model) }
            if let u = AgentLine.dict(message, ["usage"]).map(AgentLine.usage), u.total > 0 {
                session.tokens += u
                event.tokens += u
                event.model = AgentLine.string(message, ["model"]) ?? event.model
            }
            if let content = message["content"] as? [[String: Any]] {
                for item in content where item["type"] as? String == "tool_use" {
                    if let name = AgentLine.string(item, ["name"]) { session.tools[name, default: 0] += 1 }
                }
            }
        }
        if let model = AgentLine.string(obj, ["model"]) { session.models.insert(model) }
        if let u = AgentLine.dict(obj, ["usage", "token_usage"]).map(AgentLine.usage), u.total > 0 {
            session.tokens += u
            event.tokens += u
            event.model = AgentLine.string(obj, ["model"]) ?? event.model
        }
        return true
    }
}

/// Fallback for any unclaimed .jsonl under a watched root. A line counts as a
/// turn when it decodes to an object carrying (role|type) and a timestamp.
public final class GenericProvider: AgentProvider {
    public let kind = AgentKind.other
    public let roots: [String] = []
    public init() {}

    public func sessionFiles() -> [URL] { [] }

    public func parse(line: Data, into session: inout AgentSession, event: inout AgentLineEvent) -> Bool {
        guard let obj = AgentLine.dict(line),
              obj["role"] != nil || obj["type"] != nil,
              let stamp = AgentLine.date(obj["timestamp"] ?? obj["ts"] ?? obj["created_at"]) else { return false }
        AgentLine.touch(stamp, into: &session)
        event.at = stamp
        if let sid = AgentLine.string(obj, ["session_id", "sessionId", "conversation_id"]) { session.sessionId = sid }
        if let cwd = AgentLine.string(obj, ["cwd", "project_dir", "workspace"]) { session.projectDir = cwd }
        if let model = AgentLine.string(obj, ["model"]) { session.models.insert(model) }
        if let u = AgentLine.dict(obj, ["usage", "token_usage"]).map(AgentLine.usage), u.total > 0 {
            session.tokens += u
            event.tokens += u
            event.model = AgentLine.string(obj, ["model"]) ?? event.model
        }
        if obj["type"] as? String == "tool_use" || obj["type"] as? String == "function_call",
           let name = AgentLine.string(obj, ["name"]) {
            session.tools[name, default: 0] += 1
        }
        return true
    }
}

/// Registry order matters only for claiming; the generic fallback is kept last.
public enum AgentProviders {
    public static let all: [AgentProvider] = [
        ClaudeCodeProvider(), CodexProvider(), OpenClawProvider(), GenericProvider()
    ]
}
