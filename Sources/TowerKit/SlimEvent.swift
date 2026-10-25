// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation

/// Which coding agent sent an event. Claude Code events carry no tag on the wire.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex

    /// The name of the agent's process, as the kernel reports it.
    public var processName: String { rawValue }
}

/// The hook events Agentrise listens to. Claude Code never gets PermissionRequest,
/// Interrupt or PostCompact installed: a silent PermissionRequest hook makes Claude Code
/// deny tools in sessions that cannot show a prompt. Only Codex sends those.
public enum HookEventName: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case notification = "Notification"
    case preCompact = "PreCompact"
    case permissionRequest = "PermissionRequest"
    case interrupt = "Interrupt"
    case postCompact = "PostCompact"
}

public struct BackgroundTaskInfo: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var status: String
    public var description: String
    public init(id: String, type: String, status: String, description: String) {
        self.id = id; self.type = type; self.status = status; self.description = description
    }
}

/// A hook payload with everything Agentrise does not need removed:
/// no prompt text, no file contents, bounded strings.
public struct SlimEvent: Codable, Equatable, Sendable {
    public var event: HookEventName
    public var sessionId: String
    public var agentId: String?
    public var agentType: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var toolName: String?
    public var toolUseId: String?
    public var command: String?
    public var runInBackground: Bool?
    public var toolDescription: String?
    public var question: String?
    public var lastAssistantMessage: String?
    public var backgroundTasks: [BackgroundTaskInfo]?
    public var notificationType: String?
    public var error: String?
    public var isInterrupt: Bool?
    public var model: String?
    public var sessionTitle: String?
    public var source: String?
    public var entrypoint: String?
    public var bundleId: String?
    public var termProgram: String?
    /// Which agent sent this; nil means Claude Code (also what old hook binaries send).
    public var agent: AgentKind?
    /// The agent's own process id, when the hook could find it.
    public var agentPid: Int32?
    public var receivedAt: Date

    public init(event: HookEventName, sessionId: String, receivedAt: Date = Date()) {
        self.event = event; self.sessionId = sessionId; self.receivedAt = receivedAt
    }
}

public enum EventSlimmer {
    public static let maxLineBytes = 8192

    public static func slim(rawJSON: Data, env: [String: String], agent: AgentKind = .claude, now: Date = Date()) -> SlimEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any],
              let name = obj["hook_event_name"] as? String,
              let event = HookEventName(rawValue: name),
              let sid = obj["session_id"] as? String, !sid.isEmpty else { return nil }
        if agent == .codex { return CodexSlimmer.slim(obj: obj, env: env, now: now) }
        var e = SlimEvent(event: event, sessionId: sid, receivedAt: now)
        e.agentId = obj["agent_id"] as? String
        e.agentType = obj["agent_type"] as? String
        e.cwd = obj["cwd"] as? String
        e.transcriptPath = obj["transcript_path"] as? String
        e.entrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
        e.bundleId = env["__CFBundleIdentifier"]
        e.termProgram = env["TERM_PROGRAM"]

        switch event {
        case .preToolUse, .postToolUse, .postToolUseFailure:
            e.toolName = obj["tool_name"] as? String
            e.toolUseId = obj["tool_use_id"] as? String
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            if let cmd = input["command"] as? String, e.toolName == "Bash" {
                e.command = clip(cmd, 512)
            }
            if let bg = input["run_in_background"] as? Bool { e.runInBackground = bg }
            if let d = input["description"] as? String { e.toolDescription = clip(d, 120) }
            if e.toolName == "AskUserQuestion",
               let qs = input["questions"] as? [[String: Any]],
               let q = qs.first?["question"] as? String {
                e.question = clip(q, 120)
            }
            if event == .postToolUseFailure {
                e.error = (obj["error"] as? String).map { clip($0, 200) }
                e.isInterrupt = obj["is_interrupt"] as? Bool
            }
        case .stop, .subagentStop:
            if let m = obj["last_assistant_message"] as? String { e.lastAssistantMessage = tail(m, 600) }
            if let tasks = obj["background_tasks"] as? [[String: Any]] {
                e.backgroundTasks = tasks.compactMap { t in
                    guard let id = t["id"] as? String else { return nil }
                    return BackgroundTaskInfo(id: id, type: t["type"] as? String ?? "",
                                              status: t["status"] as? String ?? "",
                                              description: clip(t["description"] as? String ?? "", 120))
                }
            }
        case .stopFailure:
            e.error = (obj["error"] as? String).map { clip($0, 120) }
        case .notification:
            e.notificationType = obj["notification_type"] as? String
        case .sessionStart:
            e.model = obj["model"] as? String
            e.sessionTitle = (obj["session_title"] as? String).map { clip($0, 80) }
            e.source = obj["source"] as? String
        case .userPromptSubmit:
            // The prompt itself is never kept.
            e.sessionTitle = (obj["session_title"] as? String).map { clip($0, 80) }
        default:
            break
        }
        return e
    }

    public static func encodeLine(_ event: SlimEvent) -> Data {
        var e = event
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        for _ in 0..<4 {
            if let d = try? enc.encode(e), d.count + 1 <= maxLineBytes { return d + Data([0x0A]) }
            e.lastAssistantMessage = e.lastAssistantMessage.map { tail($0, 200) }
            e.command = e.command.map { clip($0, 120) }
            e.backgroundTasks = e.backgroundTasks.map { Array($0.prefix(10)) }
        }
        e.lastAssistantMessage = nil; e.backgroundTasks = nil
        return ((try? enc.encode(e)) ?? Data()) + Data([0x0A])
    }

    public static func decodeLine(_ data: Data) -> SlimEvent? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(SlimEvent.self, from: data)
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) }
    static func tail(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.suffix(n)) }
}
