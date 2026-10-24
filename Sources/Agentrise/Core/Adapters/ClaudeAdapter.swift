import Foundation
import TowerKit

/// Claude Code's hook events, read the way Agentrise always has.
enum ClaudeAdapter: AgentAdapter {
    static let capabilities: AgentCapabilities = [.contractors, .webSearch, .registry]

    static let attentionNotifications: Set<String> = ["permission_prompt", "elicitation_dialog", "agent_needs_input"]

    static func translate(_ e: SlimEvent) -> TowerEvent {
        TowerEvent(sessionId: e.sessionId, at: e.receivedAt, cwd: e.cwd, transcriptPath: e.transcriptPath, kind: kind(of: e))
    }

    private static func kind(of e: SlimEvent) -> TowerEvent.Kind {
        if e.event == .sessionEnd { return .sessionEnded }

        if let agentId = e.agentId, e.event != .subagentStart, e.event != .subagentStop {
            // Something a subagent is doing: only that sub moves.
            if e.event == .preToolUse, let tool = e.toolName {
                return .subActivity(id: agentId, type: e.agentType ?? "",
                                    activity: ActivityMap.activity(toolName: tool, command: e.command))
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
            if tool == "AskUserQuestion" { return .askedUser(question: e.question) }
            var background: Contractor?
            if tool == "Bash", e.runInBackground == true, let id = e.toolUseId {
                let desc = String((e.command ?? e.toolDescription ?? "后台任务").prefix(40))
                background = Contractor(id: id, description: desc, startedAt: e.receivedAt)
            }
            return .toolStarted(activity: ActivityMap.activity(toolName: tool, command: e.command), background: background)
        case .postToolUse:
            return e.toolName == "AskUserQuestion" ? .answeredUser : .toolFinished
        case .postToolUseFailure:
            return .toolFailed(interrupted: e.isInterrupt == true)
        case .stop:
            return .turnEnded(lastMessage: e.lastAssistantMessage, backgroundSnapshot: e.backgroundTasks)
        case .stopFailure:
            return .turnFailed(error: e.error)
        case .notification:
            if let t = e.notificationType, attentionNotifications.contains(t) { return .needsAttention }
            return .keepAlive
        case .subagentStart:
            return .subStarted(id: e.agentId, type: e.agentType ?? "")
        case .subagentStop:
            guard let id = e.agentId else { return .keepAlive }
            return .subFinished(id: id, lastMessage: e.lastAssistantMessage)
        case .preCompact:
            return .compacting
        case .sessionEnd:
            return .sessionEnded
        }
    }
}
