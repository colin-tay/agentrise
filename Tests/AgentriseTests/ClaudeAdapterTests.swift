// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit
@testable import Agentrise

@Suite struct ClaudeAdapterTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func ev(_ name: HookEventName, agent: String? = nil, _ f: (inout SlimEvent) -> Void = { _ in }) -> SlimEvent {
        var e = SlimEvent(event: name, sessionId: "m", receivedAt: t0)
        e.agentId = agent
        f(&e)
        return e
    }

    private func kind(_ e: SlimEvent) -> TowerEvent.Kind { ClaudeAdapter.translate(e).kind }

    @Test func carriesTheCommonFields() {
        let t = ClaudeAdapter.translate(ev(.userPromptSubmit) { $0.cwd = "/work"; $0.transcriptPath = "/t.jsonl" })
        #expect(t == TowerEvent(sessionId: "m", at: t0, cwd: "/work", transcriptPath: "/t.jsonl", kind: .promptSubmitted))
    }

    @Test func sessionStartIsFreshOnlyForStartupAndClear() {
        #expect(kind(ev(.sessionStart) { $0.source = "startup" }) == .sessionStarted(fresh: true))
        #expect(kind(ev(.sessionStart) { $0.source = "clear" }) == .sessionStarted(fresh: true))
        #expect(kind(ev(.sessionStart) { $0.source = "resume" }) == .sessionStarted(fresh: false))
        #expect(kind(ev(.sessionStart) { $0.source = "compact" }) == .sessionStarted(fresh: false))
        #expect(kind(ev(.sessionStart)) == .sessionStarted(fresh: false))
    }

    @Test func sessionEndEndsEvenWhenASubagentSendsIt() {
        #expect(kind(ev(.sessionEnd)) == .sessionEnded)
        #expect(kind(ev(.sessionEnd, agent: "a1")) == .sessionEnded)
    }

    @Test func askUserQuestionAsksAndItsAnswerAnswers() {
        #expect(kind(ev(.preToolUse) { $0.toolName = "AskUserQuestion"; $0.question = "用哪个？" }) == .askedUser(question: "用哪个？"))
        #expect(kind(ev(.preToolUse) { $0.toolName = "AskUserQuestion" }) == .askedUser(question: nil))
        #expect(kind(ev(.postToolUse) { $0.toolName = "AskUserQuestion" }) == .answeredUser)
    }

    @Test func otherToolsStartAndFinish() {
        #expect(kind(ev(.preToolUse) { $0.toolName = "Read" }) == .toolStarted(activity: .reading, background: nil))
        #expect(kind(ev(.preToolUse) { $0.toolName = "Grep" }) == .toolStarted(activity: .searching, background: nil))
        #expect(kind(ev(.preToolUse) { $0.toolName = "WebFetch" }) == .toolStarted(activity: .browsing, background: nil))
        #expect(kind(ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "ls" }) == .toolStarted(activity: .runningCommand, background: nil))
        #expect(kind(ev(.preToolUse)) == .toolStarted(activity: .other, background: nil))
        #expect(kind(ev(.postToolUse) { $0.toolName = "Read" }) == .toolFinished)
        #expect(kind(ev(.postToolUse)) == .toolFinished)
    }

    @Test func backgroundBashHiresAContractor() {
        let long = String(repeating: "x", count: 60)
        #expect(kind(ev(.preToolUse) { $0.toolName = "Bash"; $0.runInBackground = true; $0.toolUseId = "b1"; $0.command = long; $0.toolDescription = "desc" })
                == .toolStarted(activity: .runningCommand, background: Contractor(id: "b1", description: String(long.prefix(40)), startedAt: t0)))
        #expect(kind(ev(.preToolUse) { $0.toolName = "Bash"; $0.runInBackground = true; $0.toolUseId = "b2"; $0.toolDescription = "跑全量测试" })
                == .toolStarted(activity: .runningCommand, background: Contractor(id: "b2", description: "跑全量测试", startedAt: t0)))
        #expect(kind(ev(.preToolUse) { $0.toolName = "Bash"; $0.runInBackground = true; $0.toolUseId = "b3" })
                == .toolStarted(activity: .runningCommand, background: Contractor(id: "b3", description: "后台任务", startedAt: t0)))
        // No tool-use id, not in the background, or not Bash: no contractor.
        #expect(kind(ev(.preToolUse) { $0.toolName = "Bash"; $0.runInBackground = true })
                == .toolStarted(activity: .runningCommand, background: nil))
        #expect(kind(ev(.preToolUse) { $0.toolName = "Bash"; $0.runInBackground = false; $0.toolUseId = "b4" })
                == .toolStarted(activity: .runningCommand, background: nil))
        #expect(kind(ev(.preToolUse) { $0.toolName = "BashOutput"; $0.runInBackground = true; $0.toolUseId = "b5" })
                == .toolStarted(activity: .runningCommand, background: nil))
    }

    @Test func toolFailureKnowsInterrupts() {
        #expect(kind(ev(.postToolUseFailure) { $0.isInterrupt = true }) == .toolFailed(interrupted: true))
        #expect(kind(ev(.postToolUseFailure) { $0.isInterrupt = false }) == .toolFailed(interrupted: false))
        #expect(kind(ev(.postToolUseFailure)) == .toolFailed(interrupted: false))
    }

    @Test func stopCarriesTheMessageAndTheSnapshot() {
        let snap = [BackgroundTaskInfo(id: "x", type: "shell", status: "running", description: "d")]
        #expect(kind(ev(.stop) { $0.lastAssistantMessage = "好了"; $0.backgroundTasks = snap })
                == .turnEnded(lastMessage: "好了", backgroundSnapshot: snap))
        #expect(kind(ev(.stop)) == .turnEnded(lastMessage: nil, backgroundSnapshot: nil))
        #expect(kind(ev(.stopFailure) { $0.error = "rate_limit" }) == .turnFailed(error: "rate_limit"))
        #expect(kind(ev(.stopFailure)) == .turnFailed(error: nil))
    }

    @Test func onlyCallsForTheCEONeedAttention() {
        for t in ["permission_prompt", "elicitation_dialog", "agent_needs_input"] {
            #expect(kind(ev(.notification) { $0.notificationType = t }) == .needsAttention)
        }
        #expect(kind(ev(.notification) { $0.notificationType = "idle_prompt" }) == .keepAlive)
        #expect(kind(ev(.notification)) == .keepAlive)
    }

    @Test func subagentsComeAndGo() {
        #expect(kind(ev(.subagentStart, agent: "a1") { $0.agentType = "Explore" }) == .subStarted(id: "a1", type: "Explore"))
        #expect(kind(ev(.subagentStart, agent: "a1")) == .subStarted(id: "a1", type: ""))
        #expect(kind(ev(.subagentStart) { $0.agentType = "Explore" }) == .subStarted(id: nil, type: "Explore"))
        #expect(kind(ev(.subagentStop, agent: "a1") { $0.lastAssistantMessage = "交付" }) == .subFinished(id: "a1", lastMessage: "交付"))
        #expect(kind(ev(.subagentStop)) == .keepAlive)
    }

    @Test func whatASubagentDoesOnlyMovesThatSub() {
        #expect(kind(ev(.preToolUse, agent: "a1") { $0.toolName = "Grep"; $0.agentType = "Explore" })
                == .subActivity(id: "a1", type: "Explore", activity: .searching))
        #expect(kind(ev(.preToolUse, agent: "a1") { $0.toolName = "AskUserQuestion" })
                == .subActivity(id: "a1", type: "", activity: .other))
        #expect(kind(ev(.preToolUse, agent: "a1")) == .keepAlive)
        #expect(kind(ev(.postToolUse, agent: "a1") { $0.toolName = "Grep" }) == .subIdle(id: "a1"))
        #expect(kind(ev(.notification, agent: "a1") { $0.notificationType = "permission_prompt" }) == .keepAlive)
        #expect(kind(ev(.stop, agent: "a1") { $0.lastAssistantMessage = "好了" }) == .keepAlive)
        #expect(kind(ev(.postToolUseFailure, agent: "a1")) == .keepAlive)
        #expect(kind(ev(.userPromptSubmit, agent: "a1")) == .keepAlive)
    }

    @Test func compactingAndCapabilities() {
        #expect(kind(ev(.preCompact)) == .compacting)
        #expect(ClaudeAdapter.capabilities == [.contractors, .webSearch, .registry])
        #expect(Adapters.adapter(for: nil) == ClaudeAdapter.self)
    }

    @Test func storeKeepsAcceptingSlimEvents() {
        var store = TowerStore()
        let ctx = SessionContext(title: "主会话", source: .desktop(hostSessionId: nil), model: "claude-opus-5-5")
        _ = store.apply(ev(.preToolUse) { $0.toolName = "AskUserQuestion"; $0.question = "用哪个？" }, context: ctx)
        #expect(store.sessions["m"]?.status == .waiting)
        #expect(store.sessions["m"]?.waitingSummary == "用哪个？")
    }

    @Test func aSubagentStartWithoutAnIdStillDelegatesButAddsNoSub() {
        var store = TowerStore()
        let ctx = SessionContext(title: "主会话", source: .desktop(hostSessionId: nil), model: "claude-opus-5-5")
        _ = store.apply(ev(.userPromptSubmit), context: ctx)
        let effects = store.apply(ev(.subagentStart) { $0.agentType = "Explore" }, context: ctx)
        #expect(store.sessions["m"]?.status == .working)
        #expect(store.sessions["m"]?.activity == .delegating)
        #expect(store.sessions["m"]?.subs.isEmpty == true)
        #expect(effects.isEmpty)
    }

    @Test func interruptedStandsTheSessionDown() {
        var store = TowerStore()
        let ctx = SessionContext(title: "主会话", source: .desktop(hostSessionId: nil), model: nil)
        _ = store.apply(ev(.preToolUse) { $0.toolName = "AskUserQuestion"; $0.question = "q" }, context: ctx)
        let effects = store.apply(TowerEvent(sessionId: "m", at: t0 + 1, cwd: nil, transcriptPath: nil, kind: .interrupted), context: ctx)
        #expect(store.sessions["m"]?.status == .standby)
        #expect(store.sessions["m"]?.activity == .standby)
        #expect(store.sessions["m"]?.waitingSummary == nil)
        #expect(effects == [.statusChanged(sessionId: "m", from: .waiting, to: .standby)])
    }
}
