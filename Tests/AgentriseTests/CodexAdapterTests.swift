// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit
@testable import Agentrise

/// The fixtures are real Codex 0.164.0 payloads (see Fixtures/codex/RECORDED.txt).
@Suite struct CodexAdapterTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let t0 = CodexAdapterTests.t0
    private static let sid = "01a16ced-15c9-7840-acb8-a48120355792"
    private static let sub = "01a16ced-320b-7f32-9cac-24c9ba902958"
    private let sid = CodexAdapterTests.sid
    private let sub = CodexAdapterTests.sub

    private static func raw(_ file: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex/\(file).json")
        return try Data(contentsOf: url)
    }

    private static func slim(_ file: String) throws -> SlimEvent {
        try #require(EventSlimmer.slim(rawJSON: try raw(file), env: [:], agent: .codex, now: t0))
    }

    private func translated(_ file: String) throws -> TowerEvent { CodexAdapter.translate(try Self.slim(file)) }

    // One row per line of spec 5.5.
    @Test(arguments: [
        ("session-start", TowerEvent.Kind.sessionStarted(fresh: true)),
        ("session-end", .sessionEnded),
        ("user-prompt-submit", .promptSubmitted),
        ("pre-tool-bash", .toolStarted(activity: .runningCommand, background: nil)),
        ("pre-tool-apply-patch", .toolStarted(activity: .coding, background: nil)),
        ("pre-tool-update-plan", .toolStarted(activity: .planning, background: nil)),
        ("pre-tool-spawn-agent", .toolStarted(activity: .delegating, background: nil)),
        ("pre-tool-wait-agent", .toolStarted(activity: .delegating, background: nil)),
        ("pre-tool-request-user-input", .askedUser(question: "Which database should I use?")),
        ("pre-tool-request-user-input-async", .askedUser(question: "Database choice")),
        ("post-tool-bash", .toolFinished),
        ("post-tool-request-user-input", .answeredUser),
        ("post-tool-request-user-input-async", .toolFinished),
        ("permission-request", .askedUser(question: "touch b.txt")),
        ("stop", .turnEnded(lastMessage: "1", backgroundSnapshot: nil)),
        ("stop-without-message", .needsAttention),
        ("interrupt", .interrupted),
        ("subagent-start", .subStarted(id: CodexAdapterTests.sub, type: "default")),
        ("subagent-stop", .subFinished(id: CodexAdapterTests.sub, lastMessage: "`ls` output:\n\n```text\na.txt\n```")),
        ("sub-pre-tool", .subActivity(id: CodexAdapterTests.sub, type: "default", activity: .runningCommand)),
        ("pre-compact", .compacting),
        ("post-compact", .keepAlive),
    ])
    func codexEventTranslatesPerSpec(file: String, expected: TowerEvent.Kind) throws {
        let t = try translated(file)
        #expect(t.kind == expected)
        #expect(t.sessionId == sid)
        #expect(t.at == t0)
        #expect(t.cwd == "/Users/tester/work/demo")
        // A sub's events carry the sub's own rollout file, never the session's.
        let isSub = (try Self.slim(file)).agentId != nil
        #expect((t.transcriptPath == nil) == isSub, "\(file)")
    }

    private func ev(_ name: HookEventName, _ f: (inout SlimEvent) -> Void = { _ in }) -> SlimEvent {
        var e = SlimEvent(event: name, sessionId: "c", receivedAt: t0)
        e.agent = .codex
        f(&e)
        return e
    }

    private func kind(_ e: SlimEvent) -> TowerEvent.Kind { CodexAdapter.translate(e).kind }

    @Test func unknownToolsAreOther() {
        #expect(kind(ev(.preToolUse) { $0.toolName = "mcp__x__y" }) == .toolStarted(activity: .other, background: nil))
        #expect(kind(ev(.preToolUse)) == .toolStarted(activity: .other, background: nil))
        #expect(kind(ev(.preToolUse) { $0.toolName = "Agent" }) == .toolStarted(activity: .delegating, background: nil))
        #expect(kind(ev(.preToolUse) { $0.toolName = "collaborationlist_agents" }) == .toolStarted(activity: .other, background: nil))
        #expect(kind(ev(.postToolUse) { $0.toolName = "mcp__x__y" }) == .toolFinished)
    }

    @Test func namespacedCollaborationToolsDelegate() {
        // Codex 0.164 glues the namespace on (`collaborationspawn_agent`); separators are tolerated too.
        for name in ["collaborationspawn_agent", "spawn_agent", "collaboration.spawn_agent", "collaboration__spawn_agent",
                     "collaborationwait_agent", "collaborationsend_message", "collaborationfollowup_task"] {
            #expect(CodexAdapter.activity(toolName: name) == .delegating, "\(name)")
        }
        #expect(CodexAdapter.baseName("collaboration") == "collaboration")
        #expect(CodexAdapter.activity(toolName: "collaborationinterrupt_agent") == .other)
    }

    @Test func codexShellNeverHiresAContractorOrSendsFeishu() {
        #expect(kind(ev(.preToolUse) { $0.toolName = "Bash"; $0.toolUseId = "b"; $0.runInBackground = true; $0.command = "cc-connect send hi" })
                == .toolStarted(activity: .runningCommand, background: nil))
    }

    @Test func sessionStartIsFreshOnlyForStartupAndClear() {
        #expect(kind(ev(.sessionStart) { $0.source = "clear" }) == .sessionStarted(fresh: true))
        #expect(kind(ev(.sessionStart) { $0.source = "resume" }) == .sessionStarted(fresh: false))
        #expect(kind(ev(.sessionStart)) == .sessionStarted(fresh: false))
    }

    @Test func requestUserInputWithoutAQuestionStillAsks() {
        #expect(kind(ev(.preToolUse) { $0.toolName = "request_user_input" }) == .askedUser(question: nil))
        #expect(kind(ev(.preToolUse) { $0.toolName = "request_user_input_async" }) == .askedUser(question: nil))
    }

    @Test func aStopWithoutAFinalMessageNeedsAttention() {
        #expect(kind(ev(.stop)) == .needsAttention)
        #expect(kind(ev(.stop) { $0.lastAssistantMessage = " \n" }) == .needsAttention)
        #expect(kind(ev(.stop) { $0.lastAssistantMessage = "好了" }) == .turnEnded(lastMessage: "好了", backgroundSnapshot: nil))
    }

    @Test func approvalWithoutADescriptionAsksWithoutAQuestion() {
        #expect(kind(ev(.permissionRequest) { $0.toolName = "Bash" }) == .askedUser(question: nil))
    }

    @Test func whatASubagentDoesOnlyMovesThatSub() {
        #expect(kind(ev(.postToolUse) { $0.agentId = "a1"; $0.toolName = "Bash" }) == .subIdle(id: "a1"))
        #expect(kind(ev(.preToolUse) { $0.agentId = "a1"; $0.toolName = "apply_patch" })
                == .subActivity(id: "a1", type: "", activity: .coding))
        #expect(kind(ev(.preToolUse) { $0.agentId = "a1" }) == .keepAlive)
        #expect(kind(ev(.stop) { $0.agentId = "a1"; $0.lastAssistantMessage = "好了" }) == .keepAlive)
        #expect(kind(ev(.userPromptSubmit) { $0.agentId = "a1" }) == .keepAlive)
        #expect(kind(ev(.sessionEnd) { $0.agentId = "a1" }) == .sessionEnded)
        #expect(kind(ev(.subagentStop)) == .keepAlive)
        #expect(kind(ev(.subagentStart)) == .subStarted(id: nil, type: ""))
    }

    @Test func eventsCodexNeverSendAreKeptAlive() {
        #expect(kind(ev(.notification) { $0.notificationType = "permission_prompt" }) == .keepAlive)
        #expect(kind(ev(.postToolUseFailure)) == .keepAlive)
        #expect(kind(ev(.stopFailure) { $0.error = "x" }) == .keepAlive)
    }

    @Test func capabilitiesAreEmptyAndCodexGetsItsOwnAdapter() {
        #expect(CodexAdapter.capabilities == [])
        #expect(Adapters.adapter(for: .codex) == CodexAdapter.self)
        #expect(Adapters.adapter(for: .claude) == ClaudeAdapter.self)
        #expect(Adapters.adapter(for: nil) == ClaudeAdapter.self)
    }

    // MARK: Slimming

    @Test func codexSlimKeepsModelAndDropsPrompt() throws {
        let raw = try Self.raw("user-prompt-submit")
        #expect(String(decoding: raw, as: UTF8.self).contains("SECRET-PROMPT"))
        let e = try Self.slim("user-prompt-submit")
        let line = String(decoding: EventSlimmer.encodeLine(e), as: UTF8.self)
        #expect(!line.contains("SECRET-PROMPT"))
        #expect(!line.contains("帮我跑一下测试"))
        #expect(e.model == "gpt-6-luna")
        #expect(e.agent == .codex)
        #expect(e.event == .userPromptSubmit)
    }

    @Test func codexSlimTakesTheCommonFieldsFromEveryEvent() throws {
        for file in ["session-start", "pre-tool-bash", "stop", "interrupt", "subagent-start", "post-compact"] {
            let e = try Self.slim(file)
            #expect(e.agent == .codex, "\(file)")
            #expect(e.model == "gpt-6-luna", "\(file)")
            #expect(e.cwd == "/Users/tester/work/demo", "\(file)")
            #expect(e.sessionId == sid, "\(file)")
            #expect(e.transcriptPath?.hasSuffix(".jsonl") == true, "\(file)")
        }
        // SessionEnd carries no model.
        let end = try Self.slim("session-end")
        #expect(end.model == nil)
        #expect(end.cwd == "/Users/tester/work/demo")
        #expect(try Self.slim("session-start").source == "startup")
        let sub = try Self.slim("sub-pre-tool")
        #expect(sub.agentId == self.sub)
        #expect(sub.agentType == "default")
        #expect(sub.toolName == "Bash")
        #expect(sub.toolUseId == "exec-405148c1-eac0-4195-9431-7f7435aae378")
        #expect(sub.transcriptPath?.contains(self.sub) == true)
    }

    @Test func codexSlimTakesTheCommandOnlyForShell() throws {
        #expect(try Self.slim("pre-tool-bash").command == "ls")
        #expect(try Self.slim("post-tool-bash").command == "ls")
        // A patch body is file content: never kept.
        let patch = try Self.slim("pre-tool-apply-patch")
        #expect(patch.toolName == "apply_patch")
        #expect(patch.command == nil)
        #expect(!String(decoding: EventSlimmer.encodeLine(patch), as: UTF8.self).contains("Begin Patch"))
    }

    @Test func codexSlimKeepsTheApprovalDescriptionAndTheQuestion() throws {
        // Codex 0.164 sends the shell approval's command, no description.
        let p = try Self.slim("permission-request")
        #expect(p.toolName == "Bash")
        #expect(p.toolDescription == "touch b.txt")
        let q = try Self.slim("pre-tool-request-user-input")
        #expect(q.question == "Which database should I use?")
        #expect(q.toolName == "request_user_input")
        let a = try Self.slim("pre-tool-request-user-input-async")
        #expect(a.question == "Database choice")
        #expect(a.toolName == "request_user_input_async")
    }

    @Test func anApprovalPrefersTheDescriptionAndNeverKeepsAPatch() throws {
        func slim(_ json: String) throws -> SlimEvent {
            try #require(EventSlimmer.slim(rawJSON: Data(json.utf8), env: [:], agent: .codex, now: t0))
        }
        let described = try slim(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"清理构建目录"}}"#)
        #expect(described.toolDescription == "清理构建目录")
        let patch = try slim(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n+secret\n*** End Patch"}}"#)
        #expect(patch.toolDescription == nil)
        #expect(!String(decoding: EventSlimmer.encodeLine(patch), as: UTF8.self).contains("secret"))
    }

    @Test func codexSlimClipsLongFields() throws {
        func slim(_ json: String) throws -> SlimEvent {
            try #require(EventSlimmer.slim(rawJSON: Data(json.utf8), env: [:], agent: .codex, now: t0))
        }
        let long = String(repeating: "长", count: 1000)
        let cmd = try slim(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"\#(long)"}}"#)
        #expect(cmd.command?.count == 512)
        let desc = try slim(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"description":"\#(long)"}}"#)
        #expect(desc.toolDescription?.count == 120)
        let q = try slim(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"request_user_input","tool_input":{"questions":[{"question":"\#(long)"}]}}"#)
        #expect(q.question?.count == 120)
        let stop = try slim(#"{"hook_event_name":"Stop","session_id":"s","last_assistant_message":"\#(long)尾"}"#)
        #expect(stop.lastAssistantMessage?.count == 600)
        #expect(stop.lastAssistantMessage?.hasSuffix("尾") == true)
        let sub = try slim(#"{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"a","last_assistant_message":"\#(long)"}"#)
        #expect(sub.lastAssistantMessage?.count == 600)
    }

    @Test func codexSlimToleratesNullsAndRejectsMissingIds() throws {
        let e = try #require(EventSlimmer.slim(rawJSON: Data(#"{"hook_event_name":"Stop","session_id":"s","transcript_path":null,"last_assistant_message":null}"#.utf8), env: [:], agent: .codex))
        #expect(e.transcriptPath == nil)
        #expect(e.lastAssistantMessage == nil)
        #expect(EventSlimmer.slim(rawJSON: Data(#"{"hook_event_name":"Stop"}"#.utf8), env: [:], agent: .codex) == nil)
        #expect(EventSlimmer.slim(rawJSON: Data(#"{"hook_event_name":"Nope","session_id":"s"}"#.utf8), env: [:], agent: .codex) == nil)
    }

    @Test func codexSlimReadsTheTerminalEnvironment() throws {
        let e = try #require(EventSlimmer.slim(rawJSON: Self.raw("stop"), env: ["__CFBundleIdentifier": "com.openai.codex", "TERM_PROGRAM": "iTerm.app", "CLAUDE_CODE_ENTRYPOINT": "x"], agent: .codex))
        #expect(e.bundleId == "com.openai.codex")
        #expect(e.termProgram == "iTerm.app")
        #expect(e.entrypoint == nil)
    }

    // MARK: Through the store

    private func applyFile(_ file: String, to store: inout TowerStore, at offset: TimeInterval = 0) throws -> [TowerEffect] {
        var e = try Self.slim(file)
        e.receivedAt = t0 + offset
        let ctx = SessionContext(title: "Codex", source: .terminal(bundleId: nil), model: e.model)
        return store.apply(e, context: ctx)
    }

    @Test func codexStopRunsTheWaitingClassifier() throws {
        var store = TowerStore()
        _ = try applyFile("user-prompt-submit", to: &store)
        _ = try applyFile("stop", to: &store, at: 1)
        #expect(store.sessions[sid]?.status == .done)
        _ = try applyFile("user-prompt-submit", to: &store, at: 2)
        var asks = try Self.slim("stop")
        asks.receivedAt = t0 + 3
        asks.lastAssistantMessage = "改好了，测试都过了。要不要把测试也加上？"
        _ = store.apply(asks, context: SessionContext(title: "Codex", source: .terminal(bundleId: nil), model: asks.model))
        let s = try #require(store.sessions[sid])
        #expect(s.status == .waiting)
        #expect(s.waitingSummary?.contains("测试") == true)
    }

    @Test func anAsyncQuestionKeepsTheRobotAtTheDoorAfterTheTurnEnds() throws {
        var store = TowerStore()
        _ = try applyFile("user-prompt-submit", to: &store)
        _ = try applyFile("pre-tool-request-user-input-async", to: &store, at: 1)
        #expect(store.sessions[sid]?.status == .waiting)
        #expect(store.sessions[sid]?.waitingSummary == "Database choice")
        _ = try applyFile("post-tool-request-user-input-async", to: &store, at: 2)
        let effects = try applyFile("stop-without-message", to: &store, at: 3)
        #expect(effects.isEmpty)
        #expect(store.sessions[sid]?.status == .waiting)
        #expect(store.sessions[sid]?.waitingSummary == "Database choice")
        _ = try applyFile("user-prompt-submit", to: &store, at: 4)
        #expect(store.sessions[sid]?.status == .working)
    }

    @Test func aBlockingQuestionWaitsUntilAnswered() throws {
        var store = TowerStore()
        _ = try applyFile("user-prompt-submit", to: &store)
        _ = try applyFile("pre-tool-request-user-input", to: &store, at: 1)
        #expect(store.sessions[sid]?.status == .waiting)
        _ = try applyFile("post-tool-request-user-input", to: &store, at: 2)
        #expect(store.sessions[sid]?.status == .working)
    }

    @Test func codexInterruptGoesToStandbyWithoutChime() throws {
        var store = TowerStore()
        _ = try applyFile("user-prompt-submit", to: &store)
        _ = try applyFile("pre-tool-bash", to: &store, at: 1)
        let id = sid
        #expect(store.sessions[id]?.status == .working)
        let effects = try applyFile("interrupt", to: &store, at: 2)
        #expect(store.sessions[id]?.status == .standby)
        #expect(store.sessions[id]?.activity == .standby)
        #expect(store.sessions[id]?.waitingSummary == nil)
        #expect(!effects.contains { if case .statusChanged(_, _, .done) = $0 { return true } else { return false } })
        #expect(effects == [.statusChanged(sessionId: id, from: .working, to: .standby)])
    }

    @Test func anApprovalRequestSendsTheRobotToTheDoor() throws {
        var store = TowerStore()
        _ = try applyFile("user-prompt-submit", to: &store)
        _ = try applyFile("permission-request", to: &store, at: 1)
        let s = try #require(store.sessions[sid])
        #expect(s.status == .waiting)
        #expect(s.waitingSummary == "touch b.txt")
    }

    @Test func codexSubagentsComeAndGoThroughTheStore() throws {
        var store = TowerStore()
        let id = sid
        // The order Codex really sent them in.
        _ = try applyFile("user-prompt-submit", to: &store)
        _ = try applyFile("pre-tool-spawn-agent", to: &store, at: 1)
        _ = try applyFile("pre-tool-wait-agent", to: &store, at: 2)
        #expect(store.sessions[id]?.activity == .delegating)
        _ = try applyFile("subagent-start", to: &store, at: 3)
        #expect(store.sessions[id]?.subs[sub] != nil)
        _ = try applyFile("sub-pre-tool", to: &store, at: 4)
        #expect(store.sessions[id]?.subs[sub]?.activity == .runningCommand)
        _ = try applyFile("subagent-stop", to: &store, at: 5)
        #expect(store.sessions[id]?.subs[sub] == nil)
        #expect(store.sessions[id]?.delivered == 1)
        // The sub's rollout never replaces the session's.
        #expect(store.sessions[id]?.transcriptPath?.contains(sub) == false)
    }
}
