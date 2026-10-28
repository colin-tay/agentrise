// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import TowerKit
import Agentrise
import AgentriseScene

final class TowerViewModel: ObservableObject {
    @Published var panel = TowerPanelState()
    /// UI only: set straight away by the panel and the tower, never through the model's coalesced publish.
    @Published var hovered: String?
    @Published var orientation: TowerOrientation = .landscape
}

/// The Mac shell around the portable `TowerAppModel`: turns its publishes into `@Published` state for
/// SwiftUI and its effects into the desk chime, the status item blink and Bark pushes.
final class TowerController {
    let vm: TowerViewModel
    let model: TowerAppModel
    var onNewWaiting: (() -> Void)?
    private var bark = BarkPolicy()
    private let batcher = BarkBatcher()
    private let chime = DeskChime()
    private var barkConfig = BarkConfig.load()

    init(vm: TowerViewModel, view: TowerView) {
        self.vm = vm
        model = TowerAppModel(platform: MacPlatform(), scene: view.model, settings: UserDefaults.standard)
        // While the window is covered no frames run, so departures and fade-ins would never finish.
        model.renderAnimated = { [weak view] in view.map { !$0.isPaused } ?? true }
        model.onPublish = { [weak self] in self?.vm.panel = $0 }
        model.onEffects = { [weak self] in self?.process($0, sessions: $1) }
    }

    func start() { model.start() }
    func stop() { model.stop() }

    func reloadBarkConfig() { barkConfig = BarkConfig.load() }

    /// Settings saved new ranks (already in `RankBook.current`).
    func reloadRanks() { model.reloadRanks() }

    /// Click on an agent: mark as read and jump to it.
    func open(sessionId: String) { model.open(sessionId: sessionId) }

    private func process(_ effects: [TowerEffect], sessions: [String: Session]) {
        let away = AwayDetector.isAway(threshold: barkConfig.awayThreshold)
        for ef in effects {
            if case let .statusChanged(sid, _, to) = ef, to == .waiting, sessions[sid]?.isHidden == false { onNewWaiting?() }
            if case let .statusChanged(sid, _, to) = ef, [.waiting, .done, .error].contains(to), sessions[sid]?.isHidden == false {
                chime.ring(sessionId: sid, status: to)
            }
            if case let .statusChanged(sid, _, _) = ef, barkConfig.isUsable,
               let msg = bark.message(for: ef, session: sessions[sid], isAway: away, now: Date()) {
                batcher.enqueue(msg) { [weak self] in self?.barkConfig ?? BarkConfig.load() }
            }
        }
    }
}
