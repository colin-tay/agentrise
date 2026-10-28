// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit
@testable import Agentrise

@Suite struct StoreWaitForSubsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let ctx = SessionContext(title: "主会话", source: .desktop(hostSessionId: nil), model: "claude-opus-5-5")

    private func ev(_ name: HookEventName, at t: TimeInterval, agent: String? = nil, _ f: (inout SlimEvent) -> Void = { _ in }) -> SlimEvent {
        var e = SlimEvent(event: name, sessionId: "m", receivedAt: t0 + t)
        e.agentId = agent
        f(&e)
        return e
    }

    /// A turn that launched one background subagent `a1` and then stopped.
    private func stoppedWithLiveSub(_ store: inout TowerStore) -> [TowerEffect] {
        _ = store.apply(ev(.userPromptSubmit, at: 0), context: ctx)
        _ = store.apply(ev(.subagentStart, at: 1, agent: "a1") { $0.agentType = "general-purpose" }, context: ctx)
        _ = store.apply(ev(.preToolUse, at: 2, agent: "a1") { $0.toolName = "Grep" }, context: ctx)
        return store.apply(ev(.stop, at: 3) { $0.lastAssistantMessage = "全周统计交给后台的小弟了，结果出来再汇总。" }, context: ctx)
    }

    @Test func stopWithALiveSubWaitsForItInsteadOfBeingDone() {
        var store = TowerStore()
        let effects = stoppedWithLiveSub(&store)
        #expect(store.sessions["m"]?.status == .working)
        #expect(store.sessions["m"]?.activity == .waitingForSubs)
        #expect(!effects.contains { if case .statusChanged(_, _, .done) = $0 { return true }; return false })
        #expect(store.counts.done == 0)
        #expect(store.counts.working == 1)
    }

    @Test func doneOnceTheLastSubHasFinishedAndTheMainStaysQuiet() {
        var store = TowerStore()
        _ = stoppedWithLiveSub(&store)
        _ = store.apply(ev(.subagentStop, at: 60, agent: "a1") { $0.lastAssistantMessage = "统计完了" }, context: ctx)
        #expect(store.tick(now: t0 + 60 + TowerStore.subsSettle - 1).isEmpty)
        #expect(store.sessions["m"]?.status == .working)
        let effects = store.tick(now: t0 + 60 + TowerStore.subsSettle + 1)
        #expect(store.sessions["m"]?.status == .done)
        #expect(store.sessions["m"]?.activity == .resting)
        #expect(effects == [.statusChanged(sessionId: "m", from: .working, to: .done)])
    }

    @Test func mainResumingAfterTheSubKeepsWorking() {
        var store = TowerStore()
        _ = stoppedWithLiveSub(&store)
        _ = store.apply(ev(.subagentStop, at: 60, agent: "a1") { $0.lastAssistantMessage = "统计完了" }, context: ctx)
        _ = store.apply(ev(.preToolUse, at: 65) { $0.toolName = "Read" }, context: ctx)   // the main wakes up on the notification
        _ = store.tick(now: t0 + 65 + TowerStore.subsSettle + 1)
        #expect(store.sessions["m"]?.status == .working)
        #expect(store.sessions["m"]?.activity == .reading)
        // …and its own next stop is a real finish.
        _ = store.apply(ev(.stop, at: 120) { $0.lastAssistantMessage = "已经汇总好了。" }, context: ctx)
        #expect(store.sessions["m"]?.status == .done)
    }

    @Test func aLiveBackgroundCommandAlsoMakesTheBossWait() {
        var store = TowerStore()
        _ = store.apply(ev(.userPromptSubmit, at: 0), context: ctx)
        _ = store.apply(ev(.preToolUse, at: 1) { $0.toolName = "Bash"; $0.command = "npm run build -- --watch"; $0.runInBackground = true; $0.toolUseId = "b1" }, context: ctx)
        _ = store.apply(ev(.stop, at: 2) { $0.lastAssistantMessage = "构建在后台跑着。" }, context: ctx)
        #expect(store.sessions["m"]?.contractors.isEmpty == false)
        #expect(store.sessions["m"]?.activity == .waitingForSubs)
    }

    @Test func aQuestionStillWaitsForTheCEOEvenWithSubsRunning() {
        var store = TowerStore()
        _ = store.apply(ev(.userPromptSubmit, at: 0), context: ctx)
        _ = store.apply(ev(.subagentStart, at: 1, agent: "a1"), context: ctx)
        _ = store.apply(ev(.stop, at: 2) { $0.lastAssistantMessage = "要不要把测试网也包含进去？" }, context: ctx)
        #expect(store.sessions["m"]?.status == .waiting)
    }

    @Test func stopWithNothingInTheBackgroundIsDoneRightAway() {
        var store = TowerStore()
        _ = store.apply(ev(.userPromptSubmit, at: 0), context: ctx)
        _ = store.apply(ev(.stop, at: 1) { $0.lastAssistantMessage = "已完成。" }, context: ctx)
        #expect(store.sessions["m"]?.status == .done)
    }

    @Test func aSubThatNeverReportsBackDoesNotBlockForever() {
        var store = TowerStore()
        _ = stoppedWithLiveSub(&store)   // SubagentStop never arrives (missed hook)
        let effects = store.tick(now: t0 + 3 + TowerStore.subsGiveUp + 1)
        #expect(store.sessions["m"]?.status == .done)
        #expect(store.sessions["m"]?.subs.isEmpty == true)
        #expect(effects.contains(.statusChanged(sessionId: "m", from: .working, to: .done)))
    }
}

@Suite struct StoreDepartureTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let ctx = SessionContext(title: "主会话", source: .desktop(hostSessionId: nil), model: "claude-opus-5-5")
    private let alive: (Int32) -> Bool = { _ in true }
    private let dead: (Int32) -> Bool = { _ in false }

    /// A session known from a hook event, optionally with its agent pid, last listed in the registry at `seen`.
    private func store(_ id: String = "m", agent: AgentKind? = nil, pid: Int32? = nil, seen: TimeInterval? = nil,
                       context: SessionContext? = nil) -> TowerStore {
        var store = TowerStore()
        var e = SlimEvent(event: .userPromptSubmit, sessionId: id, receivedAt: t0)
        e.agent = agent
        e.agentPid = pid
        var c = context ?? ctx
        c.agent = agent ?? .claude
        _ = store.apply(e, context: c)
        if let seen { store.touchRegistry(id, now: t0 + seen) }
        return store
    }

    @Test func aSessionGoneFromTheRegistryPastTheGraceLeaves() {
        var s = store(seen: 0)
        let effects = s.removeDeparted(registry: [], now: t0 + 31, isRunning: alive)
        #expect(s.sessions["m"] == nil)
        #expect(effects == [.sessionLeft(sessionId: "m")])
    }

    @Test func aSessionGoneFromTheRegistryWithinTheGraceStays() {
        var s = store(seen: 0)
        #expect(s.removeDeparted(registry: [], now: t0 + 10, isRunning: alive).isEmpty)
        #expect(s.sessions["m"] != nil)
    }

    @Test func aSessionStillInTheRegistryStaysHoweverOldItsLastSighting() {
        var s = store(seen: 0)
        #expect(s.removeDeparted(registry: ["m"], now: t0 + 3600, isRunning: dead).isEmpty)
        #expect(s.sessions["m"] != nil)
    }

    @Test func aLarkSessionMissingFromTheRegistryStays() {
        var s = store(seen: 0, context: SessionContext(title: "飞书", source: .lark, model: "claude-opus-5-5"))
        #expect(s.removeDeparted(registry: [], now: t0 + 3600, isRunning: dead).isEmpty)
        #expect(s.sessions["m"] != nil)
    }

    @Test func aNeverListedSessionLeavesOnlyOnceItsProcessHasExited() {
        var gone = store(pid: 4242)
        #expect(gone.removeDeparted(registry: [], now: t0 + 1, isRunning: dead) == [.sessionLeft(sessionId: "m")])
        #expect(gone.sessions["m"] == nil)

        var running = store(pid: 4242)
        #expect(running.removeDeparted(registry: [], now: t0 + 3600, isRunning: alive).isEmpty)
        #expect(running.sessions["m"] != nil)

        var unknown = store()
        #expect(unknown.removeDeparted(registry: [], now: t0 + 3600, isRunning: dead).isEmpty)
        #expect(unknown.sessions["m"] != nil)
    }

    @Test func aCodexSessionIsNeverTouched() {
        var s = store("c", agent: .codex, pid: 4242, seen: 0)
        #expect(s.sessions["c"]?.agent == .codex)
        #expect(s.removeDeparted(registry: [], now: t0 + 3600, isRunning: dead).isEmpty)
        #expect(s.sessions["c"] != nil)
    }

    /// Pins that the Store's departure rule needs no registry change: the same unchanged registry, fed again as time
    /// passes, removes the session once past the grace. (TowerAppModel calls this on every refresh, before its
    /// `guard changed` early return; `TowerAppModelTests.departedSessionLeavesOnAnUnchangedRefresh` pins that call site.)
    @Test func removalDoesNotDependOnTheRegistryChanging() {
        var s = store(seen: 0)
        var left: [TowerEffect] = []
        for t in stride(from: 5.0, through: 35.0, by: 5.0) {
            let effects = s.removeDeparted(registry: [], now: t0 + t, isRunning: alive)
            if t <= TowerStore.registryGrace { #expect(effects.isEmpty) }
            left += effects
        }
        #expect(left == [.sessionLeft(sessionId: "m")])
        #expect(s.sessions["m"] == nil)
    }
}
