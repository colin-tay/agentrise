import Foundation
import TowerKit

/// OpenAI Codex's hook events (spec 5.5). Codex has no background tasks Agentrise can see, no
/// web-search hook and no session registry, so it declares no capabilities.
enum CodexAdapter: AgentAdapter {
    static let capabilities: AgentCapabilities = []

    static func translate(_ e: SlimEvent) -> TowerEvent {
        TowerEvent(sessionId: e.sessionId, at: e.receivedAt, cwd: e.cwd, transcriptPath: e.transcriptPath, kind: kind(of: e))
    }

    static func activity(toolName: String) -> Activity {
        switch toolName {
        case "Bash": return .runningCommand
        case "apply_patch": return .coding
        case "update_plan": return .planning
        case "spawn_agent", "Agent": return .delegating
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
            if tool == "request_user_input" { return .askedUser(question: e.question) }
            return .toolStarted(activity: activity(toolName: tool), background: nil)
        case .postToolUse:
            return e.toolName == "request_user_input" ? .answeredUser : .toolFinished
        case .stop:
            return .turnEnded(lastMessage: e.lastAssistantMessage, backgroundSnapshot: nil)
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
