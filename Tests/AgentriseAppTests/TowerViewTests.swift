// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import AppKit
import SpriteKit
@testable import AgentriseApp
@testable import Agentrise
@testable import AgentriseScene

@MainActor
@Suite struct TowerViewTests {
    private let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)

    private func session(_ id: String, status: SessionStatus = .working, subs: [String] = []) -> Session {
        var s = Session(id: id, title: "任务 \(id)", source: .desktop(hostSessionId: nil), rank: .seniorEngineer, status: status,
                        activity: .coding, teamIndex: 0, statusSince: Date(), lastActivityAt: Date())
        s.subs = Dictionary(uniqueKeysWithValues: subs.map { ($0, SubAgent(id: $0, type: "Explore", activity: .coding, startedAt: Date())) })
        return s
    }

    /// The app's own path: `TowerController` points the app model at the view's scene, and the model renders it,
    /// animated unless the view is paused (`renderAnimated`), as `TowerAppModel.publishNow` does.
    @MainActor private final class Rendering {
        let view: TowerView
        let controller: TowerController
        init(_ frame: NSRect) {
            view = TowerView(frame: frame)
            controller = TowerController(vm: TowerViewModel(), view: view)
        }
        func render(_ sessions: [Session]) { view.model.render(sessions, animated: controller.model.renderAnimated()) }
    }

    @Test func onLayoutFiresImmediatelyWithTheCurrentLayout() {
        let view = TowerView(frame: frame)
        var got: [BuildingLayout] = []
        view.onLayout = { got.append($0) }
        #expect(got.count == 1)
        #expect(got.first?.size == view.model.geo.size)
        #expect(got.first?.size == frame.size)
    }

    @Test func occlusionTogglesPause() {
        let view = TowerView(frame: frame)
        #expect(view.isPaused == false)
        view.setOccluded(true)
        #expect(view.isPaused)
        view.setOccluded(false)
        #expect(view.isPaused == false)
    }

    @Test func snapshotReturnsAnImage() {
        let r = Rendering(frame), view = r.view
        r.render([session("a")])
        let image = view.snapshot()
        #expect(image != nil)
        #expect((image?.width ?? 0) > 0)
    }

    @Test func occludedRendersLeaveNoDepartingRobots() {
        let r = Rendering(frame), view = r.view
        let scene = view.model
        r.render([session("a", subs: ["x"]), session("b", status: .sleeping)])
        view.setOccluded(true)
        // While covered `update` doesn't run, but the controller keeps rendering.
        r.render([session("a")])
        #expect(scene.robot("a:a:x") == nil)
        #expect(scene.transit.position(of: "a:a:x") == nil)
        r.render([])
        #expect(scene.robot("s:a") == nil && scene.robot("s:b") == nil)
        #expect(scene.transit.position(of: "s:a") == nil)
        // Once visible again, departures animate as usual.
        view.setOccluded(false)
        r.render([session("a", subs: ["x"])])
        #expect(scene.robot("s:a") != nil)
        r.render([session("a")])
        #expect(scene.robot("a:a:x") != nil)
    }

    @Test func robotsLeavingWhenTheWindowGetsCoveredAreFinishedByTheNextRender() {
        let r = Rendering(frame), view = r.view
        let scene = view.model
        r.render([session("a", subs: ["x"])])
        r.render([session("a")])              // x starts leaving
        #expect(scene.robot("a:a:x") != nil)
        r.render([session("a", subs: ["y"])])  // y fades in
        view.setOccluded(true)
        r.render([session("a", subs: ["y"])])
        #expect(scene.robot("a:a:x") == nil)
        #expect(scene.transit.position(of: "a:a:x") == nil)
        #expect(scene.robot("a:a:y")?.fade == 1)
    }
}
