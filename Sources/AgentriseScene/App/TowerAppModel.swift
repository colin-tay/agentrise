// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit
import Agentrise

/// One card or row of the "待处理 / 组织架构" panel: only what the panel shows of a session.
package struct PanelEntry: Equatable {
    package var id, title: String
    package var status: SessionStatus
    package var summary: String?
    package var subs, contractors: Int
    /// False for agents that cannot report contractors: the row shows no contractor count.
    package var showsContractors: Bool
    package var lark: Bool
    package var since: Date
    package var teamIndex: Int

    package init(_ s: Session) {
        id = s.id; title = s.title; status = s.status; summary = s.waitingSummary; subs = s.subs.count
        contractors = s.contractors.count; showsContractors = s.capabilities.contains(.contractors)
        lark = s.larkSent || s.isLark; since = s.statusSince; teamIndex = s.teamIndex
    }

    /// Right-hand text of a row.
    package var countsText: String {
        if status == .standby { return "待命" }
        if status == .sleeping { return "睡觉" }
        let subs = "小弟 \(self.subs)"
        return showsContractors ? "\(subs) · 外包 \(contractors)" : subs
    }
}

/// Everything the panel and the tray / status item show.
package struct TowerPanelState: Equatable {
    package var counts = TowerCounts()
    /// Waiting or failed, longest-waiting first.
    package var waiting: [PanelEntry] = []
    /// Done, most recent first.
    package var done: [PanelEntry] = []
    /// Working or standing by, in team order.
    package var working: [PanelEntry] = []
    package var sleeping: [PanelEntry] = []
    package var toast: String?

    package init() {}
}

/// Owns the state machine and feeds it from the hook socket, the session registry and cc-connect, then
/// pushes snapshots to the scene and, coalesced, to the panel (`onPublish`). Runs on the main thread.
package final class TowerAppModel {
    /// The panel's state; called only when it changed, at most ~4 times a second.
    package var onPublish: ((TowerPanelState) -> Void)?
    /// Every batch of effects the state machine produced, with the sessions as they are now (sounds, pushes).
    package var onEffects: (([TowerEffect], [String: Session]) -> Void)?
    /// False while the scene is not drawing frames: render without animation then.
    package var renderAnimated: () -> Bool = { true }

    /// Bursts of hook events are coalesced into one publish this long after the first.
    package static let publishDelay: TimeInterval = 0.25
    /// How long a toast stays up.
    package static let toastDuration: TimeInterval = 3

    private let platform: PlatformServices
    private let scene: TowerSceneModel
    private let settings: SettingsStore
    private let scheduler: TowerScheduler
    private let clock: () -> Date
    private var store = TowerStore()
    private var server: SocketServer?
    private var registry: [String: RegistryEntry] = [:]
    private var cc: [String: String] = [:]
    private var larkNumbers: [String: Int] = [:]
    private var codexIndex: [String: String] = [:]
    /// mtime and size of session_index.jsonl at the last read; it is re-parsed only when they change.
    private var codexIndexStamp: CodexSessionIndex.Stamp?
    private var modelLookups = Set<String>()
    private var toast: String?

    package init(platform: PlatformServices, scene: TowerSceneModel, settings: SettingsStore,
                 scheduler: TowerScheduler = MainQueueScheduler(), clock: @escaping () -> Date = Date.init) {
        self.platform = platform
        self.scene = scene
        self.settings = settings
        self.scheduler = scheduler
        self.clock = clock
    }

    private var home: URL { platform.homeDirectory }
    private var claudeDir: URL { platform.claudeDirectory }
    private var codexIndexFile: URL { CodexSessionIndex.file(codexHome: platform.codexHome) }

    /// The sessions shown in the tower, in team order, as last published.
    package var visibleSessions: [Session] { lastPublished }

    package func start() {
        RankBook.current = RankBook.load(from: platform.ranksFile)   // before the first seed, so every robot starts with the user's ranks
        registry = SessionRegistry.load(dir: SessionRegistry.dir(claudeDir: claudeDir), isSameProcess: { [platform] in platform.isSameProcess(pid: $0, start: $1) })
        cc = CCConnectIndex.load(home: home, enabled: settings.bool(forKey: CCConnectIndex.enabledKey))
        codexIndexStamp = CodexSessionIndex.stamp(of: codexIndexFile)
        codexIndex = CodexSessionIndex.load(from: codexIndexFile)
        let now = clock()
        for (id, r) in registry {
            var ctx = SessionResolver.context(sessionId: id, event: nil, registry: registry, cc: cc, larkNumbers: &larkNumbers)
            ctx.model = TranscriptModelReader.model(transcriptPath: nil, sessionId: id, claudeDir: claudeDir)
            store.seed(id: id, context: ctx, busy: r.status == "busy", lastActive: r.updatedAt ?? now, now: now)
            store.touchRegistry(id, now: now)
        }
        do {
            server = try SocketServer(path: platform.socketPath) { [weak self, scheduler] line in
                guard let e = EventSlimmer.decodeLine(line) else { return }
                scheduler.onMain { self?.receive(e) }
            }
        } catch {
            toast = "无法监听本机 socket：\(error.localizedDescription)"
        }
        scheduler.every(5) { [weak self] in self?.refreshSources() }
        scheduler.every(30) { [weak self] in self?.tick() }
        publish()
    }

    package func stop() { server?.stop() }

    /// Settings saved new ranks (already in `RankBook.current`): re-rank every session whose model is known.
    package func reloadRanks() {
        store.rerank()
        lastPublished = []   // a rename alone changes no session, but the name labels must be redrawn
        publish()
    }

    /// One hook event, on the main thread.
    package func receive(_ e: SlimEvent) {
        let isClaude = (e.agent ?? .claude) == .claude
        HookPlan.noteEvent(from: e.agent, settings: settings)
        var ctx = SessionResolver.context(sessionId: e.sessionId, event: e, registry: registry, cc: cc, larkNumbers: &larkNumbers,
                                          codexIndex: codexIndex)
        // An event without its own title must not rename a session we already know.
        if isClaude, store.sessions[e.sessionId] != nil, e.sessionTitle == nil, registry[e.sessionId]?.name == nil, cc[e.sessionId] == nil { ctx.title = nil }
        if !isClaude, store.sessions[e.sessionId] != nil, codexIndex[e.sessionId] == nil { ctx.title = nil }
        let effects = store.apply(e, context: ctx)
        // Only Claude Code keeps its model in a transcript we know how to read; Codex sends it on every event.
        if isClaude, let s = store.sessions[e.sessionId], !s.modelKnown, e.event != .sessionEnd, !modelLookups.contains(e.sessionId) {
            modelLookups.insert(e.sessionId)
            let path = e.transcriptPath, sid = e.sessionId, claudeDir = claudeDir
            scheduler.inBackground { [weak self, scheduler] in
                let m = TranscriptModelReader.model(transcriptPath: path, sessionId: sid, claudeDir: claudeDir)
                scheduler.onMain {
                    guard let self, let m else { return }   // tried once; don't rescan on every event
                    var c = SessionContext(); c.model = m; c.source = self.store.sessions[sid]?.isHidden == true ? nil : self.store.sessions[sid]?.source
                    self.store.updateContext(sid, context: c)
                    self.publish()
                }
            }
        }
        process(effects)
        publish()
    }

    private func process(_ effects: [TowerEffect]) {
        guard !effects.isEmpty else { return }
        for ef in effects {
            if case let .subFinished(sid, sub, ok) = ef { scene.noteSubResult(sessionId: sid, subId: sub, success: ok) }
        }
        onEffects?(effects, store.sessions)
    }

    /// Re-reads the registry, cc-connect and the Codex index (every 5 s).
    package func refreshSources() {
        let now = clock()
        let newRegistry = SessionRegistry.load(dir: SessionRegistry.dir(claudeDir: claudeDir), isSameProcess: { [platform] in platform.isSameProcess(pid: $0, start: $1) })
        let newCC = CCConnectIndex.load(home: home, enabled: settings.bool(forKey: CCConnectIndex.enabledKey))
        var codexRenamed = false
        let stamp = CodexSessionIndex.stamp(of: codexIndexFile)
        if stamp != codexIndexStamp {
            codexIndexStamp = stamp
            let newCodex = CodexSessionIndex.load(from: codexIndexFile)
            codexRenamed = newCodex != codexIndex
            codexIndex = newCodex
        }
        // Agents without a registry: gone when their process is, renamed only by their own index.
        let outside = store.removeExited(isRunning: platform.isRunning)
        for (id, s) in store.sessions where !s.capabilities.contains(.registry) {
            if codexRenamed, let t = codexIndex[id], t != s.title {
                var c = SessionContext(); c.agent = s.agent; c.title = t; c.source = s.isHidden ? nil : s.source
                store.updateContext(id, context: c)
            }
        }
        let changed = newRegistry.keys.sorted() != registry.keys.sorted() || newCC != cc
            || newRegistry.contains { registry[$0.key]?.name != $0.value.name || registry[$0.key]?.status != $0.value.status }
        registry = newRegistry
        cc = newCC
        var effects: [TowerEffect] = []
        for (id, r) in registry {
            if store.sessions[id] == nil {
                var ctx = SessionResolver.context(sessionId: id, event: nil, registry: registry, cc: cc, larkNumbers: &larkNumbers)
                ctx.model = TranscriptModelReader.model(transcriptPath: nil, sessionId: id, claudeDir: claudeDir)
                store.seed(id: id, context: ctx, busy: r.status == "busy", lastActive: r.updatedAt ?? now, now: now)
            }
            store.touchRegistry(id, now: now)   // after the seed, so a fresh session is already marked as seen
            effects += store.setStatusFromRegistry(id, busy: r.status == "busy", now: now)
        }
        // Every refresh, not only when the registry changed: once a session's file is gone it stops changing.
        let departed = store.removeDeparted(registry: Set(registry.keys), now: now, isRunning: platform.isRunning)
        guard changed || !effects.isEmpty else {
            if !outside.isEmpty || !departed.isEmpty || codexRenamed { process(outside + departed); publish() }
            return
        }
        effects = outside + departed + effects
        for (id, s) in store.sessions where s.capabilities.contains(.registry) {
            var ctx = SessionResolver.context(sessionId: id, event: nil, registry: registry, cc: cc, larkNumbers: &larkNumbers)
            if case .terminal = s.source, ctx.source == nil { ctx.source = s.source }   // keep known terminals
            if s.isHidden, ctx.source == nil { continue }
            if !s.isHidden, ctx.source == nil { ctx.source = s.source }
            // Only the registry (sidebar title) or cc-connect may rename a session.
            if registry[id]?.name == nil && cc[id] == nil { ctx.title = s.title }
            store.updateContext(id, context: ctx)
        }
        process(effects)
        publish()
    }

    /// Time-based state changes (every 30 s).
    package func tick() {
        let effects = store.tick(now: clock())
        process(effects)
        publish()
    }

    // MARK: Publishing

    private var publishScheduled = false

    /// Coalesces bursts of hook events into at most ~4 publishes a second.
    private func publish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        scheduler.after(Self.publishDelay) { [weak self] in
            self?.publishScheduled = false
            self?.publishNow()
        }
    }

    private var lastPublished: [Session] = []
    private var state = TowerPanelState()
    private var lastState = TowerPanelState()

    private func publishNow() {
        let list = store.sessions.values.filter { !$0.isHidden }.sorted { $0.teamIndex < $1.teamIndex }
        if list != lastPublished {
            lastPublished = list
            // The panel only cares about who needs the CEO, not what everyone is doing.
            let entries = list.map(PanelEntry.init)
            state.waiting = entries.filter { $0.status == .waiting || $0.status == .error }.sorted { $0.since < $1.since }
            state.done = entries.filter { $0.status == .done }.sorted { $0.since > $1.since }
            state.working = entries.filter { $0.status == .working || $0.status == .standby }
            state.sleeping = entries.filter { $0.status == .sleeping }
            if state.counts != store.counts { state.counts = store.counts; scene.setHeader(store.counts) }
            scene.render(list, animated: renderAnimated())
        }
        state.toast = toast
        guard state != lastState else { return }
        lastState = state
        onPublish?(state)
    }

    // MARK: Clicks

    /// Click on an agent: mark as read and jump to it.
    package func open(sessionId: String) {
        guard let s = store.sessions[sessionId] else { return }
        markRead(sessionId)
        switch s.source {
        case .desktop(let host):
            let url = (host ?? registry[sessionId]?.hostSessionId).flatMap(SessionLink.url(hostSessionId:))
            if url.map({ platform.openSession(.desktop($0)) }) != true { flash("找不到这个会话的链接") }
        case .lark:
            flash("这是飞书会话，回复在飞书里")
        case .terminal(let bundle):
            // The registry's pid is Claude Code's own process; the hook's `agentPid` is the fallback (and Codex's).
            let reg = registry[sessionId]
            let pid = reg?.pid ?? s.agentPid
            let start = reg?.pid != nil ? reg?.start : nil
            if !platform.openSession(.terminal(bundleId: bundle, pid: pid, start: start)) { flash("这是终端会话") }
        }
    }

    package func markRead(_ sessionId: String) {
        _ = store.markRead(sessionId, now: clock())
        publish()
    }

    private func flash(_ s: String) {
        toast = s
        publish()
        scheduler.after(Self.toastDuration) { [weak self] in
            guard let self, self.toast == s else { return }
            self.toast = nil
            self.publish()
        }
    }
}
