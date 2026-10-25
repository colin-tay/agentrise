// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit

/// OpenAI Codex's hook events (spec 5.5). Codex has no background tasks Agentrise can see, no
/// web-search hook and no session registry, so it declares no capabilities.
/// Tool names and payload shapes are the ones Codex 0.164.0 really sends (Fixtures/codex).
enum CodexAdapter: AgentAdapter {
    static let capabilities: AgentCapabilities = []

    static func translate(_ e: SlimEvent) -> TowerEvent {
        // A subagent's events carry the sub's own rollout file; the session keeps its own.
        TowerEvent(sessionId: e.sessionId, at: e.receivedAt, cwd: e.cwd,
                   transcriptPath: e.agentId == nil ? e.transcriptPath : nil, kind: kind(of: e))
    }

    /// Codex reports a namespaced tool with the namespace glued on: `collaborationspawn_agent`.
    static func baseName(_ toolName: String) -> String {
        let ns = "collaboration"
        guard toolName.hasPrefix(ns), toolName.count > ns.count else { return toolName }
        return String(toolName.dropFirst(ns.count).drop { $0 == "." || $0 == "_" || $0 == ":" })
    }

    static func activity(toolName: String) -> Activity {
        switch baseName(toolName) {
        case "Bash": return .runningCommand
        case "apply_patch": return .coding
        case "update_plan": return .planning
        // Not `.waitingForSubs` for wait_agent: the store's tick ends a waiting-for-subs session it sees no subs for.
        case "spawn_agent", "wait_agent", "followup_task", "send_message", "Agent": return .delegating
        default: return .other
        }
    }

    private static func kind(of e: SlimEvent) -> TowerEvent.Kind {
        if e.event == .sessionEnd { return .sessionEnded }

        // Approval is needed whoever asks, a sub included: the CEO has to come.
        if e.event == .permissionRequest { return .askedUser(question: e.toolDescription) }

        if let agentId = e.agentId, e.event != .subagentStart, e.event != .subagentStop {
            // Something a subagent is doing: only that sub moves.
            if e.event == .preToolUse, let tool = e.toolName {
                return .subActivity(id: agentId, type: e.agentType ?? "", activity: activity(toolName: tool))
            }
            if e.event == .postToolUse { return .subIdle(id: agentId) }
            return .keepAlive
        }

        switch e.event {
        case .sessionStart:
            return .sessionStarted(fresh: e.source == "startup" || e.source == "clear")
        case .userPromptSubmit:
            return .promptSubmitted
        case .preToolUse:
            let tool = e.toolName ?? ""
            // Plan mode's `request_user_input` blocks for the answer; Default mode's `request_user_input_async`
            // ends the turn and the answer comes back as the next prompt. Both put the question to the user.
            if tool == "request_user_input" || tool == "request_user_input_async" { return .askedUser(question: e.question) }
            return .toolStarted(activity: activity(toolName: tool), background: nil)
        case .postToolUse:
            // The async ask is only "delivered" here: the session keeps waiting for the next prompt.
            return e.toolName == "request_user_input" ? .answeredUser : .toolFinished
        case .stop:
            // No final message: the turn ended on an async question (or said nothing). Someone has to look.
            guard let m = e.lastAssistantMessage, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .needsAttention
            }
            return .turnEnded(lastMessage: m, backgroundSnapshot: nil)
        case .interrupt:
            return .interrupted
        case .subagentStart:
            return .subStarted(id: e.agentId, type: e.agentType ?? "")
        case .subagentStop:
            guard let id = e.agentId else { return .keepAlive }
            return .subFinished(id: id, lastMessage: e.lastAssistantMessage)
        case .preCompact:
            return .compacting
        case .postCompact:
            return .keepAlive
        case .sessionEnd:
            return .sessionEnded
        case .permissionRequest, .postToolUseFailure, .stopFailure, .notification:
            // Codex never sends the failure and notification events.
            return .keepAlive
        }
    }
}
