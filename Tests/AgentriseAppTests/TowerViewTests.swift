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
        let view = TowerView(frame: frame)
        view.render([session("a")])
        let image = view.snapshot()
        #expect(image != nil)
        #expect((image?.width ?? 0) > 0)
    }

    @Test func occludedRendersLeaveNoDepartingRobots() {
        let view = TowerView(frame: frame)
        let scene = view.model
        view.render([session("a", subs: ["x"]), session("b", status: .sleeping)])
        view.setOccluded(true)
        // While covered `update` doesn't run, but the controller keeps rendering.
        view.render([session("a")])
        #expect(scene.robot("a:a:x") == nil)
        #expect(scene.transit.position(of: "a:a:x") == nil)
        view.render([])
        #expect(scene.robot("s:a") == nil && scene.robot("s:b") == nil)
        #expect(scene.transit.position(of: "s:a") == nil)
        // Once visible again, departures animate as usual.
        view.setOccluded(false)
        view.render([session("a", subs: ["x"])])
        #expect(scene.robot("s:a") != nil)
        view.render([session("a")])
        #expect(scene.robot("a:a:x") != nil)
    }

    @Test func robotsLeavingWhenTheWindowGetsCoveredAreFinishedByTheNextRender() {
        let view = TowerView(frame: frame)
        let scene = view.model
        view.render([session("a", subs: ["x"])])
        view.render([session("a")])              // x starts leaving
        #expect(scene.robot("a:a:x") != nil)
        view.render([session("a", subs: ["y"])])  // y fades in
        view.setOccluded(true)
        view.render([session("a", subs: ["y"])])
        #expect(scene.robot("a:a:x") == nil)
        #expect(scene.transit.position(of: "a:a:x") == nil)
        #expect(scene.robot("a:a:y")?.fade == 1)
    }
}
