// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit
@testable import Agentrise

@Suite struct CodexSessionTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func codexEvent(_ name: HookEventName, at t: TimeInterval = 0, _ f: (inout SlimEvent) -> Void = { _ in }) -> SlimEvent {
        var e = SlimEvent(event: name, sessionId: "cx", receivedAt: t0 + t)
        e.agent = .codex
        e.cwd = "/Users/tester/work/demo"
        e.model = "gpt-5-codex"
        e.bundleId = "com.googlecode.iterm2"
        f(&e)
        return e
    }

    private func context(_ e: SlimEvent, index: [String: String]) -> SessionContext {
        var lark: [String: Int] = [:]
        return SessionResolver.context(sessionId: e.sessionId, event: e, registry: [:], cc: [:],
                                       larkNumbers: &lark, codexIndex: index, arguments: { _ in nil })
    }

    @Test func codexContextUsesIndexTitleAndTerminal() {
        let e = codexEvent(.userPromptSubmit)
        let titled = context(e, index: ["cx": "修复登录"])
        #expect(titled.agent == .codex)
        #expect(titled.source == .terminal(bundleId: "com.googlecode.iterm2"))
        #expect(titled.title == "修复登录")
        #expect(titled.model == "gpt-5-codex")
        let untitled = context(e, index: [:])
        #expect(untitled.title == "demo · 终端")
        #expect(untitled.source == .terminal(bundleId: "com.googlecode.iterm2"))
        // Codex has no registry or entrypoint, but must never be hidden as a headless run.
        var other = e; other.entrypoint = nil; other.bundleId = nil
        #expect(context(other, index: [:]).source == .terminal(bundleId: nil))
    }

    @Test func codexExecRunsAreHidden() {
        let e = codexEvent(.userPromptSubmit) { $0.agentPid = 77 }
        var lark: [String: Int] = [:]
        func ctx(_ argv: [String]?) -> SessionContext {
            SessionResolver.context(sessionId: e.sessionId, event: e, registry: [:], cc: [:], larkNumbers: &lark,
                                    arguments: { pid in pid == 77 ? argv : nil })
        }
        #expect(ctx(["codex", "exec", "-s", "workspace-write", "--json", "echo hi"]).source == nil)
        #expect(ctx(["/opt/homebrew/bin/codex", "-c", "model=\"o3\"", "e", "hi"]).source == nil)
        #expect(ctx(["codex"]).source == .terminal(bundleId: "com.googlecode.iterm2"))
        #expect(ctx(["codex", "--no-alt-screen", "fix the exec bug"]).source == .terminal(bundleId: "com.googlecode.iterm2"))
        #expect(ctx(["codex", "-m", "exec"]).source == .terminal(bundleId: "com.googlecode.iterm2"))
        // The process is gone or unreadable: shown.
        #expect(ctx(nil).source == .terminal(bundleId: "com.googlecode.iterm2"))
        #expect(ctx(nil).agent == .codex)
        var noPid = e; noPid.agentPid = nil
        #expect(SessionResolver.context(sessionId: "cx", event: noPid, registry: [:], cc: [:], larkNumbers: &lark,
                                        arguments: { _ in ["codex", "exec"] }).source == .terminal(bundleId: "com.googlecode.iterm2"))
    }

    @Test func aSubsModelNeverRanksTheSession() {
        let sub = codexEvent(.preToolUse) { $0.agentId = "a1"; $0.model = "gpt-5-mini" }
        #expect(context(sub, index: [:]).model == nil)
        #expect(context(codexEvent(.preToolUse), index: [:]).model == "gpt-5-codex")
    }

    @Test func claudeContextStaysClaude() {
        var e = codexEvent(.userPromptSubmit); e.agent = nil; e.entrypoint = "cli"
        #expect(context(e, index: ["cx": "不该用"]).agent == .claude)
        #expect(context(e, index: ["cx": "不该用"]).title == "demo · 终端")
    }

    @Test func indexKeepsTheLastName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session_index.jsonl")
        let lines = [
            #"{"id":"a","thread_name":"旧名字","updated_at":"2026-10-24T01:00:00Z"}"#,
            "not json at all",
            #"{"id":"b","thread_name":"另一个","updated_at":"2026-10-24T01:01:00Z"}"#,
            #"{"thread_name":"没有 id"}"#,
            #"{"id":"a","thread_name":"新名字","updated_at":"2026-10-24T02:00:00Z"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(CodexSessionIndex.load(from: url) == ["a": "新名字", "b": "另一个"])
        #expect(CodexSessionIndex.load(from: dir.appendingPathComponent("missing.jsonl")).isEmpty)
    }

    @Test func indexStampChangesOnlyWhenTheFileDoes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session_index.jsonl")
        #expect(CodexSessionIndex.stamp(of: url) == .init(modified: nil, size: nil))
        try "a\n".write(to: url, atomically: true, encoding: .utf8)
        let first = CodexSessionIndex.stamp(of: url)
        #expect(first.size == 2)
        #expect(CodexSessionIndex.stamp(of: url) == first)
        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(CodexSessionIndex.stamp(of: url) != first)
    }

    @Test func quietCodexSessionFallsBackToStandby() {
        var store = TowerStore()
        let e = codexEvent(.userPromptSubmit)
        _ = store.apply(e, context: context(e, index: [:]))
        var cc = e; cc.sessionId = "cc"; cc.agent = nil
        _ = store.apply(cc, context: SessionContext(title: "CC", source: .terminal(bundleId: nil), model: "claude-opus-5-5"))
        #expect(store.sessions["cx"]?.agent == .codex)
        #expect(store.sessions["cx"]?.agentPid == nil)
        #expect(store.tick(now: t0 + TowerStore.quietTimeout - 1).isEmpty)
        let effects = store.tick(now: t0 + TowerStore.quietTimeout + 1)
        #expect(effects == [.statusChanged(sessionId: "cx", from: .working, to: .standby)])
        #expect(store.sessions["cx"]?.status == .standby)
        #expect(store.sessions["cx"]?.activity == .standby)
        #expect(store.sessions["cc"]?.status == .working)
    }

    @Test func quietCodexSessionWithAPidIsLeftToTheLivenessCheck() {
        var store = TowerStore()
        let e = codexEvent(.userPromptSubmit) { $0.agentPid = 4242 }
        _ = store.apply(e, context: context(e, index: [:]))
        #expect(store.sessions["cx"]?.agentPid == 4242)
        #expect(store.tick(now: t0 + TowerStore.quietTimeout + 1).isEmpty)
        #expect(store.sessions["cx"]?.status == .working)
    }

    @Test func exitedCodexProcessLeavesTheBuilding() {
        var store = TowerStore()
        let e = codexEvent(.userPromptSubmit) { $0.agentPid = 4242 }
        _ = store.apply(e, context: context(e, index: [:]))
        var noPid = codexEvent(.userPromptSubmit); noPid.sessionId = "cx2"
        _ = store.apply(noPid, context: context(noPid, index: [:]))
        // A Claude Code session with a pid is left to the registry, whatever the probe says.
        var cc = codexEvent(.userPromptSubmit) { $0.agentPid = 4242 }; cc.sessionId = "cc"; cc.agent = nil
        _ = store.apply(cc, context: SessionContext(title: "CC", source: .terminal(bundleId: nil), model: "claude-opus-5-5"))
        #expect(store.removeExited(isRunning: { _ in true }).isEmpty)
        #expect(store.removeExited(isRunning: { $0 != 4242 }) == [.sessionLeft(sessionId: "cx")])
        #expect(store.sessions["cx"] == nil)
        #expect(store.sessions["cx2"] != nil && store.sessions["cc"] != nil)
    }

    @Test func probeSeesLiveAndExitedProcesses() throws {
        #expect(ProcessProbe.isRunning(getpid()))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        #expect(!ProcessProbe.isRunning(p.processIdentifier))
    }

    @Test func interruptedCodexTurnLeavesNoSubsBehind() {
        var store = TowerStore()
        let ctx = context(codexEvent(.userPromptSubmit), index: [:])
        _ = store.apply(codexEvent(.userPromptSubmit), context: ctx)
        _ = store.apply(codexEvent(.subagentStart, at: 1) { $0.agentId = "a1"; $0.agentType = "explorer" }, context: ctx)
        #expect(store.sessions["cx"]?.subs.count == 1)
        _ = store.apply(codexEvent(.interrupt, at: 2), context: ctx)
        #expect(store.sessions["cx"]?.status == .standby)
        #expect(store.sessions["cx"]?.subs.isEmpty == true)
        // The sub's late stop is a no-op: no counters, no effects.
        let effects = store.apply(codexEvent(.subagentStop, at: 3) { $0.agentId = "a1" }, context: ctx)
        #expect(effects.isEmpty)
        #expect(store.sessions["cx"]?.subs.isEmpty == true)
        #expect(store.sessions["cx"]?.delivered == 0 && store.sessions["cx"]?.failedSubs == 0)
        #expect(store.sessions["cx"]?.status == .standby)
    }

    @Test func waitingCodexSessionAlsoFallsBack() {
        var store = TowerStore()
        let e = codexEvent(.permissionRequest)
        _ = store.apply(e, context: context(e, index: [:]))
        #expect(store.sessions["cx"]?.status == .waiting)
        let effects = store.tick(now: t0 + TowerStore.quietTimeout + 1)
        #expect(effects == [.statusChanged(sessionId: "cx", from: .waiting, to: .standby)])
        #expect(store.sessions["cx"]?.waitingSummary == nil)
    }

    @Test func codexTooltipHidesContractors() {
        var s = Session(id: "cx", title: "修复登录", source: .terminal(bundleId: nil), rank: .seniorEngineer,
                        status: .working, activity: .coding, teamIndex: 0, statusSince: Date(), lastActivityAt: Date())
        #expect(s.capabilities.contains(.contractors))
        #expect(TowerScene.tooltipLines(for: s).count == 5)
        #expect(TowerScene.tooltipLines(for: s).last?.hasPrefix("外包") == true)
        s.agent = .codex
        #expect(!s.capabilities.contains(.contractors))
        let lines = TowerScene.tooltipLines(for: s)
        #expect(lines.count == 4)
        #expect(!lines.contains { $0.contains("外包") })
    }

    @Test func panelLineDropsContractorsWithoutTheCapability() {
        var s = Session(id: "cx", title: "t", source: .terminal(bundleId: nil), rank: .seniorEngineer,
                        status: .working, activity: .coding, teamIndex: 0, statusSince: Date(), lastActivityAt: Date())
        s.subs["a"] = SubAgent(id: "a", type: "explorer", activity: .coding, startedAt: Date())
        #expect(PanelView.countsText(for: s) == "小弟 1 · 外包 0")
        s.agent = .codex
        #expect(PanelView.countsText(for: s) == "小弟 1")
        s.status = .standby
        #expect(PanelView.countsText(for: s) == "待命")
    }
}
