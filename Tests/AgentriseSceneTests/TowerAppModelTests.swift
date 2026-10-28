// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import Agentrise
@testable import AgentriseScene

/// A platform over a temporary home that records what it was asked to open.
final class FakePlatform: PlatformServices {
    let homeDirectory: URL
    var supportDirectory: URL { homeDirectory.appendingPathComponent("support") }
    var socketPath: String { supportDirectory.appendingPathComponent("tower.sock").path }
    var running: (Int32) -> Bool = { _ in true }
    var opens = true
    var opened: [SessionLink] = []

    init() throws {
        homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("agentrise-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    }

    func isRunning(_ pid: Int32) -> Bool { running(pid) }
    func openSession(_ link: SessionLink) -> Bool { opened.append(link); return opens }

    /// Writes ~/.claude/sessions/<pid>.json like a live Claude Code process.
    func writeRegistry(pid: Int32, sessionId: String, entrypoint: String, hostSessionId: String? = nil, at t: Date) throws {
        let dir = SessionRegistry.dir(home: homeDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var o: [String: Any] = ["sessionId": sessionId, "pid": pid, "status": "idle", "entrypoint": entrypoint,
                                "cwd": "/work/demo", "updatedAt": t.timeIntervalSince1970 * 1000]
        if let hostSessionId { o["hostSessionId"] = hostSessionId }
        try JSONSerialization.data(withJSONObject: o).write(to: dir.appendingPathComponent("\(pid).json"))
    }

    func removeRegistry(pid: Int32) throws {
        try FileManager.default.removeItem(at: SessionRegistry.dir(home: homeDirectory).appendingPathComponent("\(pid).json"))
    }
}

/// Virtual time: work runs only when the test advances the clock.
final class ManualScheduler: TowerScheduler {
    var now: Date
    private var queue: [(due: Date, seq: Int, work: () -> Void)] = []
    private var seq = 0

    init(now: Date) { self.now = now }

    func onMain(_ work: @escaping () -> Void) { after(0, work) }
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        seq += 1
        queue.append((now.addingTimeInterval(seconds), seq, work))
    }
    func every(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        after(seconds) { [weak self] in work(); self?.every(seconds, work) }
    }
    func inBackground(_ work: @escaping () -> Void) { work() }

    /// Runs everything due within `dt`, in order, moving the clock to each item's time.
    func advance(by dt: TimeInterval) {
        let end = now.addingTimeInterval(dt)
        while let i = queue.indices.min(by: { (queue[$0].due, queue[$0].seq) < (queue[$1].due, queue[$1].seq) }),
              queue[i].due <= end {
            let item = queue.remove(at: i)
            now = max(now, item.due)
            item.work()
        }
        now = end
    }
}

@Suite struct TowerAppModelTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func make() throws -> (TowerAppModel, FakePlatform, ManualScheduler, MemorySettings, TowerSceneModel) {
        let platform = try FakePlatform()
        let scheduler = ManualScheduler(now: t0)
        let settings = MemorySettings()
        let scene = makeModel(CGSize(width: 1200, height: 800), clock: { scheduler.now })
        let model = TowerAppModel(platform: platform, scene: scene, settings: settings, scheduler: scheduler, clock: { scheduler.now })
        return (model, platform, scheduler, settings, scene)
    }

    private func terminalEvent(_ name: HookEventName, _ id: String, at t: Date, bundleId: String? = "com.example.term") -> SlimEvent {
        var e = SlimEvent(event: name, sessionId: id, receivedAt: t)
        e.entrypoint = "cli"
        e.cwd = "/work/demo"
        e.bundleId = bundleId
        e.model = "claude-opus-5-5"
        return e
    }

    @Test func publishIsCoalesced() throws {
        let (model, _, scheduler, _, scene) = try make()
        var published: [TowerPanelState] = []
        model.onPublish = { published.append($0) }
        // 20 events in 0.1 s.
        for i in 0..<20 {
            model.receive(terminalEvent(.userPromptSubmit, "s\(i % 4)", at: scheduler.now))
            scheduler.advance(by: 0.005)
        }
        scheduler.advance(by: 1)
        #expect(published.count >= 1)
        #expect(published.count <= 2)
        #expect(published.last?.counts.working == 4)
        #expect(published.last?.working.map(\.id) == ["s0", "s1", "s2", "s3"])
        #expect(scene.robot("s:s3") != nil)
    }

    @Test func firstPublishLandsWithinTheWindow() throws {
        let (model, _, scheduler, _, _) = try make()
        var published: [TowerPanelState] = []
        model.onPublish = { published.append($0) }
        model.receive(terminalEvent(.userPromptSubmit, "s0", at: scheduler.now))
        scheduler.advance(by: TowerAppModel.publishDelay - 0.01)
        #expect(published.isEmpty)
        scheduler.advance(by: 0.01)
        #expect(published.count == 1)
        #expect(TowerAppModel.publishDelay <= 0.25)
        // Nothing changed since: no second publish.
        model.tick()
        scheduler.advance(by: 1)
        #expect(published.count == 1)
    }

    @Test func panelGroupsWaitingDoneWorkingAndSleeping() throws {
        let (model, _, scheduler, _, _) = try make()
        var last: TowerPanelState?
        model.onPublish = { last = $0 }
        model.receive(terminalEvent(.userPromptSubmit, "w", at: scheduler.now))
        var cx = SlimEvent(event: .permissionRequest, sessionId: "cx", receivedAt: scheduler.now)
        cx.agent = .codex; cx.cwd = "/work/demo"; cx.model = "gpt-5-codex"
        model.receive(cx)
        scheduler.advance(by: 1)
        #expect(last?.working.map(\.id) == ["w"])
        #expect(last?.waiting.map(\.id) == ["cx"])
        #expect(last?.waiting.first?.showsContractors == false)
        #expect(last?.counts.waiting == 1)
        #expect(last?.toast == nil)
    }

    @Test func terminalSessionThatCannotBeFoundRaisesAToast() throws {
        let (model, platform, scheduler, _, _) = try make()
        var published: [TowerPanelState] = []
        model.onPublish = { published.append($0) }
        model.receive(terminalEvent(.userPromptSubmit, "s0", at: scheduler.now))
        scheduler.advance(by: 1)
        platform.opens = false
        model.open(sessionId: "s0")
        #expect(platform.opened == [.terminal(bundleId: "com.example.term")])
        scheduler.advance(by: TowerAppModel.publishDelay)
        #expect(published.last?.toast == "这是终端会话")
        scheduler.advance(by: TowerAppModel.toastDuration + 1)
        #expect(published.last?.toast == nil)

        platform.opens = true
        model.open(sessionId: "s0")
        scheduler.advance(by: 1)
        #expect(platform.opened.count == 2)
        #expect(published.last?.toast == nil)
        model.open(sessionId: "unknown")
        #expect(platform.opened.count == 2)
    }

    @Test func desktopSessionOpensItsDeepLink() throws {
        let (model, platform, scheduler, _, _) = try make()
        try platform.writeRegistry(pid: 101, sessionId: "d1", entrypoint: "claude-desktop", hostSessionId: "h1", at: t0)
        model.refreshSources()
        model.open(sessionId: "d1")
        #expect(platform.opened == [.desktop(URL(string: "claude://claude.ai/epitaxy/h1")!)])
        var published: [TowerPanelState] = []
        model.onPublish = { published.append($0) }
        scheduler.advance(by: 1)
        #expect(published.last?.toast == nil)
    }

    @Test func staleRegistryFilesAreSkipped() throws {
        let (model, platform, scheduler, _, _) = try make()
        try platform.writeRegistry(pid: 4242, sessionId: "gone", entrypoint: "cli", at: t0)
        try platform.writeRegistry(pid: 101, sessionId: "live", entrypoint: "cli", at: t0)
        platform.running = { $0 != 4242 }
        model.refreshSources()
        scheduler.advance(by: 1)
        #expect(model.visibleSessions.map(\.id) == ["live"])
    }

    /// PR #4: a session whose registry file is gone leaves past the grace even though the registry stops
    /// changing, because `removeDeparted` runs on every refresh before the "nothing changed" early return.
    @Test func departedSessionLeavesOnAnUnchangedRefresh() throws {
        let (model, platform, scheduler, _, _) = try make()
        var left: [TowerEffect] = []
        model.onEffects = { effects, _ in left += effects.filter { if case .sessionLeft = $0 { return true }; return false } }
        try platform.writeRegistry(pid: 101, sessionId: "m", entrypoint: "cli", at: t0)
        model.refreshSources()
        scheduler.advance(by: 1)
        #expect(model.visibleSessions.map(\.id) == ["m"])
        try platform.removeRegistry(pid: 101)
        // The first refresh sees the registry change; every later one sees the same empty registry.
        for _ in 0..<8 {
            scheduler.advance(by: 5)
            model.refreshSources()
            if scheduler.now.timeIntervalSince(t0) <= TowerStore.registryGrace { #expect(left.isEmpty) }
        }
        #expect(left == [.sessionLeft(sessionId: "m")])
        scheduler.advance(by: 1)
        #expect(model.visibleSessions.isEmpty)
    }

    @Test func effectsArriveWithTheSessionsAsTheyAreNow() throws {
        let (model, _, scheduler, settings, _) = try make()
        var seen: [(TowerEffect, SessionStatus?)] = []
        model.onEffects = { effects, sessions in
            for ef in effects { if case let .statusChanged(id, _, _) = ef { seen.append((ef, sessions[id]?.status)) } }
        }
        var cx = SlimEvent(event: .permissionRequest, sessionId: "cx", receivedAt: scheduler.now)
        cx.agent = .codex; cx.cwd = "/work/demo"
        model.receive(cx)
        #expect(seen.contains { if case .statusChanged("cx", _, .waiting) = $0.0 { return true }; return false })
        #expect(seen.last?.1 == .waiting)
        // A Codex event marks the Codex hook as working (Settings).
        #expect(settings.values[HookPlan.codexSeenKey] == true)
    }
}
