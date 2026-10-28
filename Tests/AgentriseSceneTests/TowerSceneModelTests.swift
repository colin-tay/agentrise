// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import Agentrise
@testable import AgentriseScene

/// A tower model on the recording backend (draws nothing), at backing scale 2 like a view without a window.
func makeModel(_ size: CGSize, scale: CGFloat = 2, clock: @escaping () -> Date = Date.init) -> TowerSceneModel {
    TowerSceneModel(size: size, scale: scale, art: RecordingBackend(), clock: clock)
}

@Suite struct TowerSceneModelTests {
    private func sprite(_ model: TowerSceneModel, _ name: String) -> SceneNode {
        let n = model.root.childNode(withName: name)
        #expect(n?.isSprite == true, "missing \(name)")
        return n ?? SceneNode()
    }

    @Test func sceneLaysOutForItsSize() {
        let model = makeModel(CGSize(width: 1080, height: 1900))
        #expect(model.geo.orientation == .portrait)
        #expect(model.geo.size == CGSize(width: 1080, height: 1900))
        #expect(sprite(model, "background").size == CGSize(width: 1080, height: 1900))
        for name in ["background", "cab", "leds", "actors", "tethers", "tooltip", "header"] {
            #expect(model.root.childNode(withName: name) != nil, "missing \(name)")
        }
    }

    @Test func pointConversionRoundTrips() {
        let model = makeModel(CGSize(width: 1080, height: 1900))
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 540, y: 950), CGPoint(x: 1080, y: 1900), CGPoint(x: 12.5, y: 77.25)] {
            #expect(model.layoutPoint(model.scenePoint(p)) == p)
        }
        #expect(model.scenePoint(CGPoint(x: 0, y: 0)).y == 1900)
        #expect(model.scenePoint(CGPoint(x: 30, y: 1900)).y == 0)
    }

    @Test func resizeRebakesBackground() {
        let model = makeModel(CGSize(width: 1080, height: 1900))
        let bg = sprite(model, "background")
        let before = bg.drawing
        #expect(before != nil)
        model.resize(to: CGSize(width: 1400, height: 800), scale: 2)
        #expect(model.geo.size == CGSize(width: 1400, height: 800))
        #expect(model.geo.orientation == .landscape)
        #expect(bg.drawing !== before)
        #expect(bg.size == CGSize(width: 1400, height: 800))
        #expect(bg.drawing?.size == CGSize(width: 1400, height: 800))
        // Nothing changed: nothing is drawn again.
        let now = bg.drawing
        model.resize(to: CGSize(width: 1400, height: 800), scale: 2)
        #expect(bg.drawing === now)
    }

    @Test func headerMatchesOldCopy() {
        let model = makeModel(CGSize(width: 1200, height: 800))
        model.setHeader(TowerCounts(working: 1, waiting: 2, done: 3, subs: 6, contractors: 7, sleeping: 5, standby: 4))
        #expect(model.headerText.hasPrefix("AGENTRISE"))
        #expect(model.headerText.contains("在岗 1"))
        #expect(model.headerText.contains("等你 2"))
        #expect(model.headerText.contains("小弟 6 · 外包 7"))
        #expect(model.headerText.contains("睡觉 5"))
    }

    @Test func cabParksAtTopFloorAndFollowsTransit() {
        let model = makeModel(CGSize(width: 1200, height: 800))
        model.step(dt: 0)
        model.step(dt: 0.05)
        let cab = sprite(model, "cab")
        let stop = model.geo.elevatorStop(floor: 3)
        #expect(model.transit.cabPosition == stop)
        // The old cab body sat 14 pt above the stop point.
        let want = model.scenePoint(CGPoint(x: stop.x, y: stop.y - 14))
        #expect(abs(cab.position.x - want.x) < 0.01 && abs(cab.position.y - want.y) < 0.01)
    }

    @Test func serverLedsBlinkWithTweens() {
        let model = makeModel(CGSize(width: 1200, height: 800))
        let leds = model.root.childNode(withName: "leds")
        #expect(leds?.children.count == 6)
        #expect(leds?.children.allSatisfy { $0.hasTweens && $0.image != nil } == true)
        let server = model.geo.rooms[Room.serverRoom]![0]
        for led in leds?.children ?? [] {
            #expect(server.contains(model.layoutPoint(led.position)))
        }
    }

    // MARK: Bake once, only blit

    private func busy(_ id: String, team: Int) -> Session {
        var s = Session(id: id, title: "任务 \(id)", source: .desktop(hostSessionId: nil), rank: .seniorEngineer, status: .working,
                        activity: .coding, teamIndex: team, statusSince: Date(), lastActivityAt: Date())
        s.subs = ["x": SubAgent(id: "x", type: "Explore", activity: .searching, startedAt: Date())]
        return s
    }

    /// Once everyone has arrived, frames only step tweens and move nodes: nothing is baked or drawn again.
    @Test func steadyStateDoesNotBake() {
        let model = makeModel(CGSize(width: 1200, height: 800))
        model.setHeader(TowerCounts(working: 5))
        model.render([], animated: false)
        model.render((0..<5).map { busy("s\($0)", team: $0) }, animated: true)
        model.advance(by: 2)
        let baked = model.bakeCount
        #expect(baked > 0)
        model.advance(by: 600.0 / 60)
        #expect(model.bakeCount == baked)
    }

    /// A rank change re-bakes that robot's rank-dependent parts (head, torso, head overlay, name) and nothing else.
    @Test func rankChangeBakesOnlyThatRobot() {
        let model = makeModel(CGSize(width: 1200, height: 800))
        var sessions = (0..<3).map { busy("s\($0)", team: $0) }
        model.render(sessions, animated: false)
        model.advance(by: 0.5)
        let before = model.bakeCount
        sessions[1].rank = .seniorExpert
        model.render(sessions, animated: true)
        model.advance(by: 0.5)
        let rig = model.robot("s:s1")!
        // head, torso, headOverlay (a senior expert wears a monocle) and the name with its new stripe.
        #expect(rig.look.hasHeadOverlay)
        #expect(model.bakeCount - before == 4)
    }
}

// MARK: - Robots

@Suite struct TowerSceneRobotTests {
    private let size = CGSize(width: 1200, height: 800)
    /// Finished long enough ago to have handed in the report and gone to the pantry.
    private let rested = Date() - TowerSceneModel.reportDuration - 1

    private func session(_ id: String, status: SessionStatus, activity: Activity = .coding, team: Int = 0,
                         rank: Rank = .seniorEngineer, hidden: Bool = false, since: Date = Date()) -> Session {
        var s = Session(id: id, title: "任务 \(id)", source: .desktop(hostSessionId: nil), rank: rank, status: status,
                        activity: activity, teamIndex: team, statusSince: since, lastActivityAt: Date())
        s.isHidden = hidden
        return s
    }

    private func sub(_ id: String, _ activity: Activity = .coding) -> SubAgent {
        SubAgent(id: id, type: "Explore", activity: activity, startedAt: Date())
    }

    private func inRoom(_ model: TowerSceneModel, _ key: String, _ room: Room) -> Bool {
        guard let t = model.transit.target(of: key) else { return false }
        return (model.geo.rooms[room] ?? []).contains { $0.contains(t) }
    }

    private func near(_ a: CGPoint?, _ b: CGPoint?, _ tol: CGFloat = 0.01) -> Bool {
        guard let a, let b else { return false }
        return hypot(a.x - b.x, a.y - b.y) <= tol
    }

    @Test func doneReportsToTheCEOThenRestsAfterTwentyMinutes() {
        let t0 = Date()
        var now = t0
        let model = makeModel(size, clock: { now })
        model.render([session("d", status: .done, since: t0),
                      session("old", status: .done, team: 1, since: t0 - TowerSceneModel.reportDuration - 1)], animated: false)
        #expect(inRoom(model, "s:d", .ceoOffice))
        #expect(model.robot("s:d")?.face == .happy)
        #expect(inRoom(model, "s:old", .pantry))
        #expect(model.robot("s:old")?.action == .resting)

        // Still reporting just before the deadline; no new render arrives when time is up.
        now = t0 + TowerSceneModel.reportDuration - 1
        model.advance(by: 0.1)
        #expect(inRoom(model, "s:d", .ceoOffice))
        now = t0 + TowerSceneModel.reportDuration + 1
        model.advance(by: 0.1)
        #expect(inRoom(model, "s:d", .pantry))
        #expect(model.robot("s:d")?.action == .resting)
        #expect(model.robot("s:d")?.bubbleText == "✓ 做完了")
        model.advance(by: 30)
        #expect(model.transit.phase(of: "s:d") == .idle)
        #expect(inRoom(model, "s:d", .pantry))
    }

    @Test func bossWaitingForItsSubsWaitsInTheMeetingRoom() {
        let model = makeModel(size)
        var s = session("b", status: .working, activity: .waitingForSubs)
        s.subs = ["x": sub("x", .searching)]
        model.render([s], animated: false)
        #expect(inRoom(model, "s:b", .meeting))
        #expect(model.robot("s:b")?.bubbleText == "等小弟")
        #expect(model.robot("s:b")?.action == .waitingForSubs)
        #expect(model.robot("a:b:x") != nil)
    }

    @Test func waitingTurnsUrgentAfterTenMinutesWithoutANewRender() {
        let t0 = Date()
        var now = t0
        let model = makeModel(size, clock: { now })
        model.render([session("q", status: .waiting, since: t0)], animated: false)
        #expect(model.robot("s:q")?.isWaitingLong == false)
        now = t0 + 601
        model.advance(by: 0.1)
        #expect(model.robot("s:q")?.isWaitingLong == true)
    }

    @Test func statusesMapToOldRooms() {
        let model = makeModel(size)
        model.render([
            session("w", status: .working, activity: .coding, team: 0),
            session("q", status: .waiting, team: 1),
            session("d", status: .done, team: 2),
            session("e", status: .error, team: 3),
            session("z", status: .sleeping, team: 4),
            session("h", status: .working, team: 5, hidden: true),
        ], animated: false)
        #expect(inRoom(model, "s:w", .desks))
        #expect(inRoom(model, "s:q", .ceoOffice))
        #expect(model.robot("s:q")?.bubbleText == "等你回复")
        #expect(model.robot("s:q")?.face == .waiting)
        #expect(model.robot("s:q")?.action == .waitingAtDoor)
        #expect(inRoom(model, "s:d", .ceoOffice))
        #expect(model.robot("s:d")?.bubbleText == "✓ 做完了")
        #expect(model.robot("s:d")?.action == .reporting)
        #expect(inRoom(model, "s:e", .serverRoom))
        #expect(model.robot("s:e")?.bubbleText == "出错了")
        #expect(inRoom(model, "s:z", .sleepPods))
        #expect(model.robot("s:z")?.action == .sleeping)
        #expect(model.robot("s:w")?.bubbleText == Activity.coding.label)
        #expect(model.robot("s:h") == nil)
        #expect(model.transit.position(of: "s:h") == nil)
    }

    @Test func subsAndContractorsAreSmaller() {
        let model = makeModel(size)
        var a = session("a", status: .working, activity: .coding, team: 0)
        a.subs = ["x": sub("x", .coding)]
        var b = session("b", status: .working, activity: .runningCommand, team: 1)
        b.contractors = ["c": Contractor(id: "c", description: "build", startedAt: Date())]
        model.render([a, b], animated: false)
        let boss = model.robot("s:a")?.robotScale ?? 0, s = model.robot("a:a:x")?.robotScale ?? 0
        #expect(inRoom(model, "a:a:x", .desks))
        #expect(boss > 0 && abs(s - boss * 0.62) < 1e-9)
        let boss2 = model.robot("s:b")?.robotScale ?? 0, c = model.robot("c:b:c")?.robotScale ?? 0
        #expect(inRoom(model, "c:b:c", .serverRoom) && inRoom(model, "s:b", .serverRoom))
        #expect(boss2 > 0 && abs(c - boss2 * 0.62) < 1e-9)
    }

    @Test func crossFloorMoveUsesElevator() {
        let model = makeModel(size)
        var s = session("m", status: .standby, activity: .standby)
        model.render([s], animated: false)
        #expect(inRoom(model, "s:m", .desks))
        s.status = .done; s.statusSince = rested   // past the report: desks (floor 2) -> pantry (floor 1)
        model.render([s], animated: true)
        #expect(inRoom(model, "s:m", .pantry))
        var rode = false
        for _ in 0..<400 {
            model.advance(by: 0.05)
            if model.transit.phase(of: "s:m") == .riding { rode = true }
            if rode, model.transit.phase(of: "s:m") == .idle { break }
        }
        #expect(rode)
        let target = model.transit.target(of: "s:m")
        #expect(near(model.transit.position(of: "s:m"), target))
        // The node follows Transit, flipped into scene space.
        #expect(near(model.robot("s:m").map { model.layoutPoint($0.root.position) }, target))
    }

    @Test func newRobotFadesInAtElevatorDoor() {
        let model = makeModel(size)
        model.render([], animated: true)
        model.render([session("n", status: .standby, activity: .standby)], animated: true)
        let r = model.robot("s:n")
        let target = model.transit.target(of: "s:n") ?? .zero
        #expect(inRoom(model, "s:n", .desks))
        let door = model.geo.elevatorDoor(floor: 2, side: model.geo.doorSide(for: target))
        #expect(near(model.transit.position(of: "s:n"), door))
        #expect(near(r.map { model.layoutPoint($0.root.position) }, door))
        #expect(r?.root.alpha == 0)
        model.advance(by: 2)
        #expect(r?.root.alpha == 1)
        #expect(near(model.transit.position(of: "s:n"), target))
    }

    @Test func departingSubWalksToBossThenLeaves() {
        let model = makeModel(size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding)]
        model.render([s], animated: false)
        let rig = model.robot("a:b:x")
        #expect(rig != nil)
        model.noteSubResult(sessionId: "b", subId: "x", success: true)
        s.subs = [:]
        model.render([s], animated: true)
        #expect(rig?.face == .happy)
        #expect(rig?.root.childNode(withName: "report") != nil)
        let boss = model.transit.position(of: "s:b") ?? .zero
        var closest = CGFloat.infinity
        var removedAt: Double?
        for i in 1...180 {
            model.advance(by: 1.0 / 60)
            if let p = model.transit.position(of: "a:b:x") { closest = min(closest, hypot(p.x - boss.x, p.y - boss.y)) }
            if model.robot("a:b:x") == nil { removedAt = Double(i) / 60; break }
        }
        #expect(closest < 40)
        #expect(removedAt != nil)
        #expect(rig?.root.parent == nil)
        #expect(model.transit.position(of: "a:b:x") == nil)
        #expect(model.robot("s:b") != nil)
    }

    @Test func nonAnimatedRenderRemovesLeavingRobotsAtOnce() {
        let model = makeModel(size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding)]
        model.render([s], animated: false)
        let rig = model.robot("a:b:x")
        #expect(rig?.root.parent != nil)
        s.subs = [:]
        model.render([s], animated: false)
        #expect(model.robot("a:b:x") == nil)
        #expect(rig?.root.parent == nil)
        #expect(model.transit.position(of: "a:b:x") == nil)
        #expect(model.robot("s:b") != nil)
        // A whole session going away is no different.
        model.render([], animated: false)
        #expect(model.robot("s:b") == nil)
        #expect(model.transit.position(of: "s:b") == nil)
    }

    @Test func nonAnimatedRenderFinishesRobotsAlreadyLeavingOrFadingIn() {
        let model = makeModel(size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding)]
        model.render([s], animated: false)
        s.subs = [:]
        model.render([s], animated: true)       // x starts walking out
        #expect(model.robot("a:b:x") != nil)
        s.subs = ["y": sub("y", .coding)]
        model.render([s], animated: true)       // y fades in
        #expect(model.robot("a:b:y")?.fade == 0)
        model.render([s], animated: false)      // e.g. the window got covered
        #expect(model.robot("a:b:x") == nil)
        #expect(model.transit.position(of: "a:b:x") == nil)
        #expect(model.robot("a:b:y")?.fade == 1)
        // A robot that was leaving and is wanted again comes back fully visible.
        s.subs = [:]
        model.render([s], animated: true)
        s.subs = ["y": sub("y", .coding)]
        model.render([s], animated: false)
        #expect(model.robot("a:b:y")?.fade == 1)
    }

    @Test func sessionEndingWhileRidingExitsAtTheFloorTheCabIsHeadingTo() {
        let model = makeModel(size)
        var s = session("m", status: .standby, activity: .standby)
        model.render([s], animated: false)
        s.status = .done; s.statusSince = rested   // desks (floor 2) -> pantry (floor 1)
        model.render([s], animated: true)
        var midShaft = false
        for _ in 0..<2000 {
            model.advance(by: 1.0 / 60)
            let y = model.transit.cabPosition.y
            if model.transit.phase(of: "s:m") == .riding,
               y > model.geo.elevatorStop(floor: 2).y + 8, y < model.geo.elevatorStop(floor: 1).y - 8 { midShaft = true; break }
        }
        #expect(midShaft)
        model.render([], animated: true)        // the session ends while its robot rides down
        let door = model.transit.target(of: "s:m") ?? .zero
        #expect(model.geo.floorOf(door) == 1)
        for _ in 0..<600 where model.robot("s:m") != nil { model.advance(by: 1.0 / 60) }
        #expect(model.robot("s:m") == nil)
    }

    @Test func failedSubLeavesWithErrorFace() {
        let model = makeModel(size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding)]
        model.render([s], animated: false)
        model.noteSubResult(sessionId: "b", subId: "x", success: false)
        s.subs = [:]
        model.render([s], animated: true)
        #expect(model.robot("a:b:x")?.face == .error)
        #expect(model.robot("a:b:x")?.action == .commandFailed)
        #expect(model.robot("a:b:x")?.root.childNode(withName: "report") == nil)
    }

    @Test func firstRenderPlacesWithoutAnimation() {
        let model = makeModel(size)
        model.render([session("f", status: .done, since: rested)], animated: false)
        let target = model.transit.target(of: "s:f")
        #expect(inRoom(model, "s:f", .pantry))
        #expect(near(model.transit.position(of: "s:f"), target))
        #expect(model.transit.phase(of: "s:f") == .idle)
        #expect(model.robot("s:f")?.root.alpha == 1)
        #expect(near(model.robot("s:f").map { model.layoutPoint($0.root.position) }, target))
        // The very first render of a new scene doesn't animate either.
        let fresh = makeModel(size)
        fresh.render([session("f", status: .done)], animated: true)
        #expect(fresh.transit.phase(of: "s:f") == .idle)
        #expect(fresh.robot("s:f")?.root.alpha == 1)
    }

    @Test func resizeSnapsRobotsToNewSlots() {
        let model = makeModel(size)
        model.render([session("r", status: .done, since: rested)], animated: false)
        model.resize(to: CGSize(width: 1080, height: 1700), scale: 2)
        #expect(inRoom(model, "s:r", .pantry))
        #expect(near(model.transit.position(of: "s:r"), model.transit.target(of: "s:r")))
        #expect(near(model.robot("s:r").map { model.layoutPoint($0.root.position) }, model.transit.target(of: "s:r")))
    }

    @Test func lowerRobotsDrawInFrontBelowHeader() {
        let model = makeModel(size)
        model.render([session("top", status: .waiting, team: 0), session("low", status: .sleeping, team: 1)], animated: false)
        let top = model.robot("s:top")?.root.zPosition ?? 0, low = model.robot("s:low")?.root.zPosition ?? 0
        #expect(low > top)
        let actors = model.root.childNode(withName: "actors")!.zPosition
        let header = model.root.childNode(withName: "header")!.zPosition
        let tooltip = model.root.childNode(withName: "tooltip")!.zPosition
        #expect(actors + low + 1 < header && header < tooltip)
    }

    @Test func elevatorLabelDrawsAboveCab() {
        let model = makeModel(size)
        let label = model.root.childNode(withName: "elevatorLabel")
        let cab = model.root.childNode(withName: "cab")!
        #expect(label != nil)
        #expect((label?.zPosition ?? 0) > cab.zPosition)
        #expect((label?.zPosition ?? .infinity) < model.root.childNode(withName: "actors")!.zPosition)
        let mid = CGPoint(x: model.geo.elevator.midX, y: model.geo.elevator.midY)
        #expect(near(label.map { model.layoutPoint($0.position) }, mid))
    }

    /// Every node's z relative to `actors` (the sum of zPositions from the node up to the robot).
    private func partZs(_ r: RobotRig) -> [CGFloat] {
        var out: [CGFloat] = [r.root.zPosition]
        func walk(_ n: SceneNode, _ z: CGFloat) {
            for c in n.children {
                out.append(z + c.zPosition)
                walk(c, z + c.zPosition)
            }
        }
        walk(r.root, r.root.zPosition)
        return out
    }

    @Test func coincidentRobotsNeverInterleave() {
        let model = makeModel(size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding), "y": sub("y", .coding)]
        model.render([s, session("c", status: .standby, team: 1)], animated: false)
        let spot = model.geo.elevatorStop(floor: 2)
        let keys = ["s:b", "a:b:x", "a:b:y", "s:c"]
        for k in keys { model.transit.place(k, at: spot) }
        model.advance(by: 1.0 / 60)
        let ranges = keys.map { k -> ClosedRange<CGFloat> in
            let zs = partZs(model.robot(k)!)
            return zs.min()!...zs.max()!
        }
        for i in ranges.indices {
            for j in ranges.indices where j > i {
                let a = ranges[i], b = ranges[j]
                #expect(a.upperBound < b.lowerBound || b.upperBound < a.lowerBound, "\(keys[i]) / \(keys[j]) interleave: \(a) \(b)")
            }
        }
        // Nearly coincident with opposite x order still doesn't overlap.
        model.transit.place("s:b", at: CGPoint(x: spot.x + 40, y: spot.y))
        model.transit.place("s:c", at: CGPoint(x: spot.x - 40, y: spot.y + 0.4))
        model.advance(by: 1.0 / 60)
        let b = partZs(model.robot("s:b")!), c = partZs(model.robot("s:c")!)
        #expect(b.max()! < c.min()!)
    }

    @Test func backingScaleChangeRebakesRobots() {
        let model = makeModel(size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding), "y": sub("y", .coding)]
        model.render([s], animated: false)
        #expect(model.robot("s:b")?.art.scale == 2.5)
        model.noteSubResult(sessionId: "b", subId: "x", success: true)
        s.subs = ["y": sub("y", .coding)]
        model.render([s], animated: true)
        model.advance(by: 0.1)
        let leaving = model.robot("a:b:x")
        let reportBefore = leaving?.root.childNode(withName: "report")?.drawing
        let before = ["s:b", "a:b:y"].map { model.robot($0) }
        let posBefore = model.robot("s:b")?.root.position

        model.resize(to: size, scale: 1)

        for k in ["s:b", "a:b:y", "a:b:x"] {
            let r = model.robot(k)
            #expect(r?.art.scale == 1.25, "\(k)")
            #expect(r?.root.parent === model.root.childNode(withName: "actors"), "\(k)")
        }
        #expect(before.allSatisfy { $0?.root.parent == nil })
        #expect(leaving?.root.parent == nil)
        #expect(model.robot("s:b")?.root.position == posBefore)
        #expect(model.robot("s:b")?.bubbleText == Activity.coding.label)
        #expect(model.robot("s:b")?.robotScale == before[0]?.robotScale)
        #expect(model.robot("a:b:y")?.robotScale == before[1]?.robotScale)
        let report = model.robot("a:b:x")?.root.childNode(withName: "report")
        #expect(report?.drawing != nil && report?.drawing !== reportBefore)
        #expect(report?.drawing?.scale == 1.25)
        #expect(model.robot("a:b:x")?.face == .happy)
        // The departure still completes with the new rig.
        model.advance(by: 3)
        #expect(model.robot("a:b:x") == nil)
        // New robots use the new scale too.
        model.render([s, session("n", status: .done, team: 2)], animated: true)
        #expect(model.robot("s:n")?.art.scale == 1.25)
    }
}

// MARK: - Interaction

@Suite struct TowerSceneInteractionTests {
    private let size = CGSize(width: 1200, height: 800)

    private func session(_ id: String, status: SessionStatus = .working, activity: Activity = .coding, team: Int = 0,
                         since: Date = Date()) -> Session {
        Session(id: id, title: "任务 \(id)", source: .desktop(hostSessionId: nil), rank: .seniorEngineer, status: status,
                activity: activity, teamIndex: team, statusSince: since, lastActivityAt: Date())
    }

    private func sub(_ id: String) -> SubAgent { SubAgent(id: id, type: "Explore", activity: .coding, startedAt: Date()) }

    private func isDim(_ r: RobotRig?) -> Bool { abs((r?.root.alpha ?? 0) - 0.18) < 1e-6 }

    private func foot(_ model: TowerSceneModel, _ key: String) -> CGPoint { model.transit.position(of: key) ?? .zero }

    /// Each scale has its own atlas: after a scale change the model moves the re-baked robots (and the LEDs)
    /// onto the new atlas, and the display finds them there.
    @Test func scaleChangeRebindsToTheNewAtlas() {
        let model = makeModel(size, scale: 2.4)
        model.render([session("a")], animated: false)
        model.advance(by: 0.05)
        func onAtlas() -> Bool {
            guard let r = model.robot("s:a"), let torso = r.root.childNode(withName: ".//torso") else { return false }
            let image = r.art.image(.torso(r.look))
            return torso.image === image && model.atlas.isPacked(image)
        }
        func ledsOnAtlas() -> Bool {
            let leds = model.root.childNode(withName: "leds")!.children
            return !leds.isEmpty && leds.allSatisfy { $0.image.map(model.atlas.isPacked) == true } && model.atlas.version > 0
        }
        #expect(onAtlas())
        #expect(ledsOnAtlas())
        let first = model.atlas
        model.resize(to: size, scale: 1.6)
        #expect(model.robot("s:a")?.art.scale == 2)
        #expect(model.atlas !== first)
        model.advance(by: 0.05)
        #expect(onAtlas())
        #expect(ledsOnAtlas())
    }

    /// After a scale change the old scale's art (image caches and atlas) is released once nothing uses it,
    /// instead of being kept per scale forever. Every robot, staying or on its way out, is re-baked with the
    /// new art, so nothing holds the old one afterwards.
    @Test func oldScaleArtIsReleasedAfterAScaleChange() {
        let model = makeModel(size, scale: 2.2)
        model.render([session("a"), session("b")], animated: false)
        model.advance(by: 0.05)
        weak var old = model.robot("s:a")?.art
        weak var oldAtlas = model.atlas
        #expect(old?.scale == 2.75)
        model.resize(to: size, scale: 1.4)
        model.advance(by: 0.05)
        #expect(model.robot("s:a")?.art.scale == 1.75)
        #expect(old == nil)
        #expect(oldAtlas == nil)
        // Every robot draws with the one current art.
        #expect(model.robot("s:a")?.art === model.robot("s:b")?.art)
    }

    @Test func headerIsBakedOncePerCopy() {
        let model = makeModel(size)
        let header = model.root.childNode(withName: "header")
        let counts = TowerCounts(working: 1, waiting: 0, done: 0, subs: 0, contractors: 0, sleeping: 0, standby: 0)
        model.setHeader(counts)
        let first = header?.drawing
        #expect(first != nil && (header?.size.width ?? 0) > 100)
        model.setHeader(counts)
        #expect(header?.drawing === first)               // same copy: no re-render
        model.setHeader(TowerCounts(working: 2, waiting: 0, done: 0, subs: 0, contractors: 0, sleeping: 0, standby: 0))
        #expect(header?.drawing !== first)
        #expect(model.headerText.contains("在岗 2"))
    }

    @Test func hitTestFindsRobotUnderPointer() {
        let model = makeModel(size)
        model.render([session("a", team: 0), session("b", status: .sleeping, team: 1)], animated: false)
        let a = foot(model, "s:a"), b = foot(model, "s:b")
        let s = model.robot("s:a")!.robotScale
        #expect(model.sessionId(at: CGPoint(x: a.x, y: a.y - 30)) == "a")
        #expect(model.sessionId(at: CGPoint(x: b.x, y: b.y - 30)) == "b")
        // Edges of the 60×84 box (scaled), and just outside it.
        #expect(model.sessionId(at: CGPoint(x: a.x + 29 * s, y: a.y - 83 * s)) == "a")
        #expect(model.sessionId(at: CGPoint(x: a.x + 31 * s, y: a.y - 40 * s)) == nil)
        #expect(model.sessionId(at: CGPoint(x: a.x, y: a.y + 2)) == nil)
        #expect(model.sessionId(at: CGPoint(x: 3, y: 3)) == nil)
    }

    @Test func hitTestResolvesSubsToTheirSession() {
        let model = makeModel(size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        model.render([a], animated: false)
        let p = foot(model, "a:a:x")
        #expect(model.sessionId(at: CGPoint(x: p.x, y: p.y - 15)) == "a")
    }

    @Test func departingRobotsAreNotHittable() {
        let model = makeModel(size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        model.render([a], animated: false)
        let p = foot(model, "a:a:x"), boss = foot(model, "s:a")
        // Stand where only the sub is (far from the boss's own box).
        #expect(abs(p.x - boss.x) > 40 || abs(p.y - boss.y) > 5)
        a.subs = [:]
        model.render([a], animated: true)
        model.advance(by: 0.02)
        let q = foot(model, "a:a:x")
        if abs(q.x - boss.x) > 40 { #expect(model.sessionId(at: CGPoint(x: q.x, y: q.y - 15)) == nil) }
    }

    @Test func hoverShowsTooltipAndLeavingRemovesItImmediately() {
        let model = makeModel(size)
        model.render([session("a")], animated: false)
        let tooltip = model.root.childNode(withName: "tooltip")!
        #expect(tooltip.children.isEmpty)
        let a = foot(model, "s:a")
        let shown = model.hover(at: CGPoint(x: a.x, y: a.y - 30))
        #expect(shown.sessionId == "a")
        #expect(shown.tooltip != nil && shown.tooltip?.parent === tooltip)
        #expect(!tooltip.children.isEmpty)
        #expect(!tooltip.children.contains { $0.hasTweens })
        #expect(model.hover(at: nil).tooltip == nil)
        #expect(tooltip.children.isEmpty)
        // Hovering an empty spot also removes it.
        model.hover(at: CGPoint(x: a.x, y: a.y - 30))
        #expect(!tooltip.children.isEmpty)
        model.hover(at: CGPoint(x: 3, y: 3))
        #expect(tooltip.children.isEmpty)
    }

    @Test func hoverNotifiesOnlyWhenTheSessionChanges() {
        let model = makeModel(size)
        model.render([session("a"), session("b", status: .sleeping, team: 1)], animated: false)
        var events: [String?] = []
        model.onHoverSession = { events.append($0) }
        let a = foot(model, "s:a"), b = foot(model, "s:b")
        model.hover(at: CGPoint(x: a.x, y: a.y - 30))
        model.hover(at: CGPoint(x: a.x + 2, y: a.y - 31))
        model.hover(at: CGPoint(x: b.x, y: b.y - 30))
        model.hover(at: nil)
        model.hover(at: nil)
        #expect(events == ["a", "b", nil])
        // Hovering highlights: the other robot dims, and leaving restores it.
        model.hover(at: CGPoint(x: a.x, y: a.y - 30))
        #expect(isDim(model.robot("s:b")) && model.robot("s:a")?.root.alpha == 1)
        model.hover(at: nil)
        #expect(model.robot("s:b")?.root.alpha == 1)
    }

    @Test func clickReportsTheSessionUnderThePointer() {
        let model = makeModel(size)
        model.render([session("a")], animated: false)
        var clicked: [String] = []
        model.onClickSession = { clicked.append($0) }
        let a = foot(model, "s:a")
        model.click(at: CGPoint(x: a.x, y: a.y - 30))
        model.click(at: CGPoint(x: 3, y: 3))
        #expect(clicked == ["a"])
    }

    @Test func highlightDimsOthersAndTiesTheTeam() {
        let model = makeModel(size)
        var a = session("a")
        a.subs = ["x": sub("x"), "y": sub("y")]
        a.contractors = [:]
        model.render([a, session("b", status: .sleeping, team: 1), session("c", status: .done, team: 2)], animated: false)
        let tethers = model.root.childNode(withName: "tethers")!
        #expect(tethers.children.isEmpty && model.tethers.isEmpty)
        model.highlight("a")
        for k in ["s:b", "s:c"] { #expect(isDim(model.robot(k)), "\(k)") }
        for k in ["s:a", "a:a:x", "a:a:y"] { #expect(model.robot(k)?.root.alpha == 1, "\(k)") }
        #expect(tethers.children.count == 2)
        #expect(model.tethers.map(\.key) == ["a:a:x", "a:a:y"])
        #expect(model.tethers.allSatisfy { $0.color == Team.color(0) && $0.node.parent === tethers })
        #expect(model.tethers.allSatisfy { model.tetherCurve(from: $0.bossKey, to: $0.key) != nil })
        // The dashes flow: −24 pt over 1.2 s.
        model.advance(by: 0.6)
        #expect(abs(model.tethers[0].phase - -12) < 0.5)
        model.highlight(nil)
        for k in ["s:a", "s:b", "s:c", "a:a:x", "a:a:y"] { #expect(model.robot(k)?.root.alpha == 1, "\(k)") }
        #expect(tethers.children.isEmpty && model.tethers.isEmpty)
    }

    @Test func highlightKeepsDepartingRobotsFading() {
        let model = makeModel(size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        model.render([a, session("b", status: .sleeping, team: 1)], animated: false)
        a.subs = [:]
        model.render([a, session("b", status: .sleeping, team: 1)], animated: true)
        let leaving = model.robot("a:a:x")
        model.highlight("b")
        #expect(leaving?.dimmed == false)
        model.highlight(nil)
        #expect(leaving?.dimmed == false)
        #expect(model.root.childNode(withName: "tethers")!.children.isEmpty)
    }

    @Test func newRobotsAppearDimmedWhileHighlightIsActive() {
        let model = makeModel(size)
        model.render([session("a")], animated: false)
        model.highlight("a")
        model.render([session("a"), session("b", status: .sleeping, team: 1)], animated: true)
        #expect(model.robot("s:b")?.dimmed == true)
        model.advance(by: 2)
        #expect(isDim(model.robot("s:b")))   // fade 1 × dim 0.18
    }

    @Test func tethersFollowTheRobotsWhileHighlighted() {
        let model = makeModel(size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        model.render([a], animated: false)
        model.highlight("a")
        let before = model.tetherCurve(from: "s:a", to: "a:a:x")
        // A newly created sub walks in: the tether set is refreshed on render.
        a.subs["y"] = sub("y")
        model.render([a], animated: true)
        #expect(model.root.childNode(withName: "tethers")!.children.count == 2)
        #expect(before != nil)
        // The new sub's tether follows it as it walks.
        let start = model.tetherCurve(from: "s:a", to: "a:a:y")
        model.advance(by: 0.5)
        #expect(model.tetherCurve(from: "s:a", to: "a:a:y")?.to != start?.to)
        // An unchanged set keeps its nodes (the flow doesn't restart).
        let kept = model.tethers.map(\.node)
        model.render([a], animated: true)
        #expect(model.tethers.map(\.node).elementsEqual(kept, by: ===))
    }

    @Test func highlightedSessionVanishingClearsEverything() {
        let model = makeModel(size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        let b = session("b", status: .sleeping, team: 1)
        model.render([a, b], animated: false)
        var events: [String?] = []
        model.onHoverSession = { events.append($0) }
        let p = foot(model, "s:a")
        model.hover(at: CGPoint(x: p.x, y: p.y - 30))
        #expect(isDim(model.robot("s:b")))
        #expect(!model.root.childNode(withName: "tooltip")!.children.isEmpty)
        events.removeAll()
        model.render([b], animated: true)
        #expect(model.robot("s:b")?.root.alpha == 1)
        #expect(model.root.childNode(withName: "tethers")!.children.isEmpty)
        #expect(model.root.childNode(withName: "tooltip")!.children.isEmpty)
        #expect(events == [nil])
        model.advance(by: 5)
        for k in ["s:b", "a:a:x", "s:a"] { #expect((model.robot(k)?.root.alpha ?? 1) >= 0 && !(model.robot(k)?.dimmed ?? false)) }
    }

    @Test func tooltipCopyMatchesOld() {
        var s = session("a", status: .working, activity: .coding, since: Date().addingTimeInterval(-7 * 60 - 5))
        s.title = "修复登录"
        s.subs = ["x": sub("x"), "y": sub("y")]
        s.contractors = ["c": Contractor(id: "c", description: "build", startedAt: Date())]
        s.delivered = 3
        s.failedSubs = 1
        s.contractorsDone = 4
        #expect(TowerSceneModel.tooltipLines(for: s) == [
            "\(Team.glyph(0)) 修复登录", "高级工程师 · Claude App", "干活中 · \(Activity.coding.label) · 7 分钟",
            "小弟 2 在岗 · 已交付 3 · 失败 1", "外包 1 在岗 · 已完成 4"])
        s.status = .waiting; s.waitingSummary = "要不要继续"; s.source = .lark; s.teamIndex = 1
        #expect(TowerSceneModel.tooltipLines(for: s)[0] == "\(Team.glyph(1)) 修复登录")
        #expect(TowerSceneModel.tooltipLines(for: s)[1] == "高级工程师 · 飞书")
        #expect(TowerSceneModel.tooltipLines(for: s)[2] == "等你回复：要不要继续 · 7 分钟")
        s.status = .error; s.source = .terminal(bundleId: nil)
        #expect(TowerSceneModel.tooltipLines(for: s)[1] == "高级工程师 · 终端")
        #expect(TowerSceneModel.tooltipLines(for: s)[2] == "出错了（要不要继续） · 7 分钟")
        s.waitingSummary = nil
        s.status = .done
        #expect(TowerSceneModel.tooltipLines(for: s)[2] == "做完了 · 7 分钟")
        s.status = .standby
        #expect(TowerSceneModel.tooltipLines(for: s)[2] == "待命 · 7 分钟")
        s.status = .sleeping
        #expect(TowerSceneModel.tooltipLines(for: s)[2] == "睡觉中 · 7 分钟")
    }

    @Test func tooltipUsesCopyAndStaysInsideTheScene() {
        let model = makeModel(size)
        model.render([session("a")], animated: false)
        let a = foot(model, "s:a")
        model.hover(at: CGPoint(x: a.x, y: a.y - 30))
        #expect(model.tooltipLines.first == "\(Team.glyph(0)) 任务 a")
        let box = model.root.childNode(withName: "tooltip")!.children.first!
        #expect(box.size.width <= 320 && box.size.height > 40)
        // Normal placement: top-left corner 14 pt right and below the pointer (layout coordinates).
        let p = CGPoint(x: a.x, y: a.y - 30)
        let tl = model.layoutPoint(CGPoint(x: box.frame.minX, y: box.frame.maxY))
        #expect(abs(tl.x - (p.x + 14)) < 0.01 && abs(tl.y - (p.y + 14)) < 0.01)
        // Near the right / bottom edge the box flips to the other side of the pointer.
        let corner = CGPoint(x: size.width - 5, y: size.height - 5)
        model.hover(at: nil)
        model.showTooltip("a", at: corner)
        let flipped = model.root.childNode(withName: "tooltip")!.children.first!
        let br = model.layoutPoint(CGPoint(x: flipped.frame.maxX, y: flipped.frame.minY))
        #expect(abs(br.x - (corner.x - 10)) < 0.01 && abs(br.y - (corner.y - 10)) < 0.01)
    }
}
