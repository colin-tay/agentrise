import AppKit
import TowerKit

final class TowerViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var counts = TowerCounts()
    @Published var hovered: String?
    @Published var toast: String?
    @Published var orientation: TowerOrientation = .landscape
}

/// Owns the state machine and feeds it from the hook socket, the session registry
/// and cc-connect, then pushes snapshots to the view and to Bark.
final class TowerController {
    let vm: TowerViewModel
    weak var building: TowerDisplay?
    var onNewWaiting: (() -> Void)?
    private var store = TowerStore()
    private var server: SocketServer?
    private var registry: [String: RegistryEntry] = [:]
    private var cc: [String: String] = [:]
    private var larkNumbers: [String: Int] = [:]
    private var bark = BarkPolicy()
    private let batcher = BarkBatcher()
    private let chime = DeskChime()
    private var barkConfig = BarkConfig.load()
    private var timers: [Timer] = []
    private var modelLookups = Set<String>()

    init(vm: TowerViewModel) { self.vm = vm }

    func start() {
        registry = SessionRegistry.load()
        cc = CCConnectIndex.load()
        let now = Date()
        for (id, r) in registry {
            var ctx = SessionResolver.context(sessionId: id, event: nil, registry: registry, cc: cc, larkNumbers: &larkNumbers)
            ctx.model = TranscriptModelReader.model(transcriptPath: nil, sessionId: id)
            store.seed(id: id, context: ctx, busy: r.status == "busy", lastActive: r.updatedAt ?? now, now: now)
            store.touchRegistry(id, now: now)
        }
        do {
            server = try SocketServer(path: TowerPaths.socketPath()) { [weak self] line in
                guard let e = EventSlimmer.decodeLine(line) else { return }
                DispatchQueue.main.async { self?.handle(e) }
            }
        } catch {
            vm.toast = "无法监听本机 socket：\(error.localizedDescription)"
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshSources() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() })
        for t in timers { t.tolerance = 2 }
        publish()
    }

    func reloadBarkConfig() { barkConfig = BarkConfig.load() }

    private func handle(_ e: SlimEvent) {
        var ctx = SessionResolver.context(sessionId: e.sessionId, event: e, registry: registry, cc: cc, larkNumbers: &larkNumbers)
        // An event without its own title must not rename a session we already know.
        if store.sessions[e.sessionId] != nil, e.sessionTitle == nil, registry[e.sessionId]?.name == nil, cc[e.sessionId] == nil { ctx.title = nil }
        let effects = store.apply(e, context: ctx)
        if let s = store.sessions[e.sessionId], !s.modelKnown, e.event != .sessionEnd, !modelLookups.contains(e.sessionId) {
            modelLookups.insert(e.sessionId)
            let path = e.transcriptPath, sid = e.sessionId
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let m = TranscriptModelReader.model(transcriptPath: path, sessionId: sid)
                DispatchQueue.main.async {
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
        let away = AwayDetector.isAway(threshold: barkConfig.awayThreshold)
        for ef in effects {
            if case let .subFinished(sid, sub, ok) = ef { building?.noteSubResult(sessionId: sid, subId: sub, success: ok) }
            if case let .statusChanged(sid, _, to) = ef, to == .waiting, store.sessions[sid]?.isHidden == false { onNewWaiting?() }
            if case let .statusChanged(sid, _, to) = ef, [.waiting, .done, .error].contains(to), store.sessions[sid]?.isHidden == false {
                chime.ring(sessionId: sid, status: to)
            }
            if case let .statusChanged(sid, _, _) = ef, barkConfig.isUsable,
               let msg = bark.message(for: ef, session: store.sessions[sid], isAway: away, now: Date()) {
                batcher.enqueue(msg) { [weak self] in self?.barkConfig ?? BarkConfig.load() }
            }
        }
    }

    private func refreshSources() {
        let now = Date()
        let newRegistry = SessionRegistry.load()
        let newCC = CCConnectIndex.load()
        let changed = newRegistry.keys.sorted() != registry.keys.sorted() || newCC != cc
            || newRegistry.contains { registry[$0.key]?.name != $0.value.name || registry[$0.key]?.status != $0.value.status }
        registry = newRegistry
        cc = newCC
        var effects: [TowerEffect] = []
        for (id, r) in registry {
            store.touchRegistry(id, now: now)
            if store.sessions[id] == nil {
                var ctx = SessionResolver.context(sessionId: id, event: nil, registry: registry, cc: cc, larkNumbers: &larkNumbers)
                ctx.model = TranscriptModelReader.model(transcriptPath: nil, sessionId: id)
                store.seed(id: id, context: ctx, busy: r.status == "busy", lastActive: r.updatedAt ?? now, now: now)
            }
            effects += store.setStatusFromRegistry(id, busy: r.status == "busy", now: now)
        }
        guard changed || !effects.isEmpty else { return }
        for (id, s) in store.sessions {
            var ctx = SessionResolver.context(sessionId: id, event: nil, registry: registry, cc: cc, larkNumbers: &larkNumbers)
            if case .terminal = s.source, ctx.source == nil { ctx.source = s.source }   // keep known terminals
            if s.isHidden, ctx.source == nil { continue }
            if !s.isHidden, ctx.source == nil { ctx.source = s.source }
            // Only the registry (sidebar title) or cc-connect may rename a session.
            if registry[id]?.name == nil && cc[id] == nil { ctx.title = s.title }
            store.updateContext(id, context: ctx)
            // A desktop or terminal session whose process is gone has left the building.
            if registry[id] == nil, let seen = s.lastSeenInRegistry, now.timeIntervalSince(seen) > 30, !s.isLark {
                effects += store.remove(id)
            }
        }
        process(effects)
        publish()
    }

    private func tick() {
        let effects = store.tick(now: Date())
        process(effects)
        publish()
    }

    private var publishScheduled = false

    /// Coalesces bursts of hook events into at most ~4 redraws a second.
    private func publish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.publishScheduled = false
            self?.publishNow()
        }
    }

    private var lastPublished: [Session] = []
    private var lastPanel: [PanelRow] = []

    private func publishNow() {
        let list = store.sessions.values.filter { !$0.isHidden }.sorted { $0.teamIndex < $1.teamIndex }
        guard list != lastPublished else { return }
        lastPublished = list
        // The panel only cares about who needs the CEO, not what everyone is doing.
        let panel = list.map { PanelRow($0) }
        if panel != lastPanel { lastPanel = panel; vm.sessions = list }
        if vm.counts != store.counts { vm.counts = store.counts; building?.setHeader(store.counts) }
        building?.render(list)
    }

    /// Click on an agent: mark as read and jump to it.
    func open(sessionId: String) {
        guard let s = store.sessions[sessionId] else { return }
        _ = store.markRead(sessionId, now: Date())
        publish()
        switch s.source {
        case .desktop(let host):
            if let h = host ?? registry[sessionId]?.hostSessionId, let url = SessionLink.url(hostSessionId: h) {
                NSWorkspace.shared.open(url)
            } else { flash("找不到这个会话的链接") }
        case .lark:
            flash("这是飞书会话，回复在飞书里")
        case .terminal(let bundle):
            if let b = bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
                app.activate()
            } else if let t = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first {
                t.activate()
            } else { flash("这是终端会话") }
        }
    }

    private func flash(_ s: String) {
        vm.toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.vm.toast == s { self?.vm.toast = nil } }
    }

    func stop() { server?.stop() }
}

struct PanelRow: Equatable {
    var id, title: String; var status: SessionStatus; var summary: String?; var subs, contractors: Int; var lark: Bool; var since: Date
    init(_ s: Session) { id = s.id; title = s.title; status = s.status; summary = s.waitingSummary; subs = s.subs.count
        contractors = s.contractors.count; lark = s.larkSent || s.isLark; since = s.statusSince }
}
