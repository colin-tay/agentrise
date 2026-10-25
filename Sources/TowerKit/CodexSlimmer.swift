// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

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
            // `request_user_input` asks `question`; `request_user_input_async` (Default mode) only has a `title`.
            if e.toolName?.hasPrefix("request_user_input") == true,
               let first = (input["questions"] as? [[String: Any]])?.first,
               let q = first["question"] as? String ?? first["title"] as? String {
                e.question = EventSlimmer.clip(q, 120)
            }
        case .permissionRequest:
            e.toolName = obj["tool_name"] as? String
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            // Codex 0.164 sends only the command for a shell approval; a description wins when there is one.
            // Never an apply_patch "command": that is the patch body.
            let shell = e.toolName == "Bash" ? input["command"] as? String : nil
            if let d = input["description"] as? String ?? shell {
                e.toolDescription = EventSlimmer.clip(d, 120)
            }
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
