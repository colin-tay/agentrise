import Foundation

/// Takes the fields Agentrise needs from a Codex hook payload and clips them.
/// The prompt, patch bodies and tool output are never kept.
enum CodexSlimmer {
    static func slim(obj: [String: Any], env: [String: String], now: Date) -> SlimEvent? {
        guard let name = obj["hook_event_name"] as? String,
              let event = HookEventName(rawValue: name),
              let sid = obj["session_id"] as? String, !sid.isEmpty else { return nil }
        var e = SlimEvent(event: event, sessionId: sid, receivedAt: now)
        e.agent = .codex
        e.agentId = obj["agent_id"] as? String
        e.agentType = obj["agent_type"] as? String
        e.cwd = obj["cwd"] as? String
        e.transcriptPath = obj["transcript_path"] as? String
        e.model = obj["model"] as? String
        e.bundleId = env["__CFBundleIdentifier"]
        e.termProgram = env["TERM_PROGRAM"]

        switch event {
        case .preToolUse, .postToolUse:
            e.toolName = obj["tool_name"] as? String
            e.toolUseId = obj["tool_use_id"] as? String
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            if e.toolName == "Bash", let cmd = input["command"] as? String {
                e.command = EventSlimmer.clip(cmd, 512)
            }
            if e.toolName == "request_user_input",
               let qs = input["questions"] as? [[String: Any]],
               let q = qs.first?["question"] as? String {
                e.question = EventSlimmer.clip(q, 120)
            }
        case .permissionRequest:
            e.toolName = obj["tool_name"] as? String
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            if let d = input["description"] as? String { e.toolDescription = EventSlimmer.clip(d, 120) }
        case .stop, .subagentStop:
            if let m = obj["last_assistant_message"] as? String { e.lastAssistantMessage = EventSlimmer.tail(m, 600) }
        case .sessionStart:
            e.source = obj["source"] as? String
        default:
            break
        }
        return e
    }
}
