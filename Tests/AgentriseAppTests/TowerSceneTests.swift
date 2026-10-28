// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import AppKit
import SpriteKit
@testable import AgentriseApp
@testable import Agentrise

@MainActor
@Suite struct TowerSceneTests {
    private func sprite(_ scene: TowerScene, _ name: String) -> SKSpriteNode {
        let n = scene.childNode(withName: name) as? SKSpriteNode
        #expect(n != nil, "missing \(name)")
        return n ?? SKSpriteNode()
    }

    @Test func sceneLaysOutForItsSize() {
        let scene = TowerScene(size: CGSize(width: 1080, height: 1900))
        #expect(scene.geo.orientation == .portrait)
        #expect(scene.geo.size == CGSize(width: 1080, height: 1900))
        #expect(sprite(scene, "background").size == CGSize(width: 1080, height: 1900))
        for name in ["background", "cab", "leds", "actors", "tethers", "tooltip", "header"] {
            #expect(scene.childNode(withName: name) != nil, "missing \(name)")
        }
    }

    @Test func pointConversionRoundTrips() {
        let scene = TowerScene(size: CGSize(width: 1080, height: 1900))
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 540, y: 950), CGPoint(x: 1080, y: 1900), CGPoint(x: 12.5, y: 77.25)] {
            #expect(scene.layoutPoint(scene.scenePoint(p)) == p)
        }
        #expect(scene.scenePoint(CGPoint(x: 0, y: 0)).y == 1900)
        #expect(scene.scenePoint(CGPoint(x: 30, y: 1900)).y == 0)
    }

    @Test func resizeRebakesBackground() {
        let scene = TowerScene(size: CGSize(width: 1080, height: 1900))
        let bg = sprite(scene, "background")
        let before = bg.texture
        var laidOut: BuildingLayout?
        scene.onLayout = { laidOut = $0 }
        scene.size = CGSize(width: 1400, height: 800)
        #expect(scene.geo.size == CGSize(width: 1400, height: 800))
        #expect(scene.geo.orientation == .landscape)
        #expect(bg.texture !== before)
        #expect(bg.size == CGSize(width: 1400, height: 800))
        #expect(laidOut?.size == CGSize(width: 1400, height: 800))
    }

    @Test func headerMatchesOldCopy() {
        let scene = TowerScene(size: CGSize(width: 1200, height: 800))
        scene.setHeader(TowerCounts(working: 1, waiting: 2, done: 3, subs: 6, contractors: 7, sleeping: 5, standby: 4))
        #expect(scene.headerText.hasPrefix("AGENTRISE"))
        #expect(scene.headerText.contains("在岗 1"))
        #expect(scene.headerText.contains("等你 2"))
        #expect(scene.headerText.contains("小弟 6 · 外包 7"))
        #expect(scene.headerText.contains("睡觉 5"))
    }

    @Test func cabParksAtTopFloorAndFollowsTransit() {
        let scene = TowerScene(size: CGSize(width: 1200, height: 800))
        scene.update(1)
        scene.update(1.05)
        let cab = sprite(scene, "cab")
        let stop = scene.geo.elevatorStop(floor: 3)
        #expect(scene.transit.cabPosition == stop)
        // The old cab body sat 14 pt above the stop point.
        let want = scene.scenePoint(CGPoint(x: stop.x, y: stop.y - 14))
        #expect(abs(cab.position.x - want.x) < 0.01 && abs(cab.position.y - want.y) < 0.01)
    }

    @Test func serverLedsBlinkWithActions() {
        let scene = TowerScene(size: CGSize(width: 1200, height: 800))
        let leds = scene.childNode(withName: "leds")
        #expect(leds?.children.count == 6)
        #expect(leds?.children.allSatisfy { $0.hasActions() } == true)
        let server = scene.geo.rooms[Room.serverRoom]![0]
        for led in leds?.children ?? [] {
            #expect(server.contains(scene.layoutPoint(led.position)))
        }
    }
}

// MARK: - Robots (Task 7)

@MainActor
@Suite struct TowerSceneRobotTests {
    private let size = CGSize(width: 1200, height: 800)
    /// Finished long enough ago to have handed in the report and gone to the pantry.
    private let rested = Date() - TowerScene.reportDuration - 1

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

    private func inRoom(_ scene: TowerScene, _ key: String, _ room: Room) -> Bool {
        guard let t = scene.transit.target(of: key) else { return false }
        return (scene.geo.rooms[room] ?? []).contains { $0.contains(t) }
    }

    private func near(_ a: CGPoint?, _ b: CGPoint?, _ tol: CGFloat = 0.01) -> Bool {
        guard let a, let b else { return false }
        return hypot(a.x - b.x, a.y - b.y) <= tol
    }

    @Test func doneReportsToTheCEOThenRestsAfterTwentyMinutes() {
        let t0 = Date()
        let scene = TowerScene(size: size)
        scene.clock = { t0 }
        scene.render([session("d", status: .done, since: t0),
                      session("old", status: .done, team: 1, since: t0 - TowerScene.reportDuration - 1)], animated: false)
        #expect(inRoom(scene, "s:d", .ceoOffice))
        #expect(scene.robot("s:d")?.face == .happy)
        #expect(inRoom(scene, "s:old", .pantry))
        #expect(scene.robot("s:old")?.action == .resting)

        // Still reporting just before the deadline; no new render arrives when time is up.
        scene.clock = { t0 + TowerScene.reportDuration - 1 }
        scene.advance(by: 0.1)
        #expect(inRoom(scene, "s:d", .ceoOffice))
        scene.clock = { t0 + TowerScene.reportDuration + 1 }
        scene.advance(by: 0.1)
        #expect(inRoom(scene, "s:d", .pantry))
        #expect(scene.robot("s:d")?.action == .resting)
        #expect(scene.robot("s:d")?.bubbleText == "✓ 做完了")
        scene.advance(by: 30)
        #expect(scene.transit.phase(of: "s:d") == .idle)
        #expect(inRoom(scene, "s:d", .pantry))
    }

    @Test func bossWaitingForItsSubsWaitsInTheMeetingRoom() {
        let scene = TowerScene(size: size)
        var s = session("b", status: .working, activity: .waitingForSubs)
        s.subs = ["x": sub("x", .searching)]
        scene.render([s], animated: false)
        #expect(inRoom(scene, "s:b", .meeting))
        #expect(scene.robot("s:b")?.bubbleText == "等小弟")
        #expect(scene.robot("s:b")?.action == .waitingForSubs)
        #expect(scene.robot("a:b:x") != nil)
    }

    @Test func waitingTurnsUrgentAfterTenMinutesWithoutANewRender() {
        let t0 = Date()
        let scene = TowerScene(size: size)
        scene.clock = { t0 }
        scene.render([session("q", status: .waiting, since: t0)], animated: false)
        #expect(scene.robot("s:q")?.isWaitingLong == false)
        scene.clock = { t0 + 601 }
        scene.advance(by: 0.1)
        #expect(scene.robot("s:q")?.isWaitingLong == true)
    }

    @Test func statusesMapToOldRooms() {
        let scene = TowerScene(size: size)
        scene.render([
            session("w", status: .working, activity: .coding, team: 0),
            session("q", status: .waiting, team: 1),
            session("d", status: .done, team: 2),
            session("e", status: .error, team: 3),
            session("z", status: .sleeping, team: 4),
            session("h", status: .working, team: 5, hidden: true),
        ], animated: false)
        #expect(inRoom(scene, "s:w", .desks))
        #expect(inRoom(scene, "s:q", .ceoOffice))
        #expect(scene.robot("s:q")?.bubbleText == "等你回复")
        #expect(scene.robot("s:q")?.face == .waiting)
        #expect(scene.robot("s:q")?.action == .waitingAtDoor)
        #expect(inRoom(scene, "s:d", .ceoOffice))
        #expect(scene.robot("s:d")?.bubbleText == "✓ 做完了")
        #expect(scene.robot("s:d")?.action == .reporting)
        #expect(inRoom(scene, "s:e", .serverRoom))
        #expect(scene.robot("s:e")?.bubbleText == "出错了")
        #expect(inRoom(scene, "s:z", .sleepPods))
        #expect(scene.robot("s:z")?.action == .sleeping)
        #expect(scene.robot("s:w")?.bubbleText == Activity.coding.label)
        #expect(scene.robot("s:h") == nil)
        #expect(scene.transit.position(of: "s:h") == nil)
    }

    @Test func subsAndContractorsAreSmaller() {
        let scene = TowerScene(size: size)
        var a = session("a", status: .working, activity: .coding, team: 0)
        a.subs = ["x": sub("x", .coding)]
        var b = session("b", status: .working, activity: .runningCommand, team: 1)
        b.contractors = ["c": Contractor(id: "c", description: "build", startedAt: Date())]
        scene.render([a, b], animated: false)
        let boss = scene.robot("s:a")?.robotScale ?? 0, s = scene.robot("a:a:x")?.robotScale ?? 0
        #expect(inRoom(scene, "a:a:x", .desks))
        #expect(boss > 0 && abs(s - boss * 0.62) < 1e-9)
        let boss2 = scene.robot("s:b")?.robotScale ?? 0, c = scene.robot("c:b:c")?.robotScale ?? 0
        #expect(inRoom(scene, "c:b:c", .serverRoom) && inRoom(scene, "s:b", .serverRoom))
        #expect(boss2 > 0 && abs(c - boss2 * 0.62) < 1e-9)
    }

    @Test func crossFloorMoveUsesElevator() {
        let scene = TowerScene(size: size)
        var s = session("m", status: .standby, activity: .standby)
        scene.render([s], animated: false)
        #expect(inRoom(scene, "s:m", .desks))
        s.status = .done; s.statusSince = rested   // past the report: desks (floor 2) -> pantry (floor 1)
        scene.render([s])
        #expect(inRoom(scene, "s:m", .pantry))
        var rode = false
        for _ in 0..<400 {
            scene.advance(by: 0.05)
            if scene.transit.phase(of: "s:m") == .riding { rode = true }
            if rode, scene.transit.phase(of: "s:m") == .idle { break }
        }
        #expect(rode)
        let target = scene.transit.target(of: "s:m")
        #expect(near(scene.transit.position(of: "s:m"), target))
        // The sprite follows Transit, flipped into scene space.
        #expect(near(scene.robot("s:m").map { scene.layoutPoint($0.position) }, target))
    }

    @Test func newRobotFadesInAtElevatorDoor() {
        let scene = TowerScene(size: size)
        scene.render([], animated: true)
        scene.render([session("n", status: .standby, activity: .standby)], animated: true)
        let r = scene.robot("s:n")
        let target = scene.transit.target(of: "s:n") ?? .zero
        #expect(inRoom(scene, "s:n", .desks))
        let door = scene.geo.elevatorDoor(floor: 2, side: scene.geo.doorSide(for: target))
        #expect(near(scene.transit.position(of: "s:n"), door))
        #expect(near(r.map { scene.layoutPoint($0.position) }, door))
        #expect(r?.alpha == 0)
        scene.advance(by: 2)
        #expect(r?.alpha == 1)
        #expect(near(scene.transit.position(of: "s:n"), target))
    }

    @Test func departingSubWalksToBossThenLeaves() {
        let scene = TowerScene(size: size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding)]
        scene.render([s], animated: false)
        let sprite = scene.robot("a:b:x")
        #expect(sprite != nil)
        scene.noteSubResult(sessionId: "b", subId: "x", success: true)
        s.subs = [:]
        scene.render([s])
        #expect(sprite?.face == .happy)
        #expect(sprite?.childNode(withName: "report") != nil)
        let boss = scene.transit.position(of: "s:b") ?? .zero
        var closest = CGFloat.infinity
        var removedAt: Double?
        for i in 1...180 {
            scene.advance(by: 1.0 / 60)
            if let p = scene.transit.position(of: "a:b:x") { closest = min(closest, hypot(p.x - boss.x, p.y - boss.y)) }
            if scene.robot("a:b:x") == nil { removedAt = Double(i) / 60; break }
        }
        #expect(closest < 40)
        #expect(removedAt != nil)
        #expect(sprite?.parent == nil)
        #expect(scene.transit.position(of: "a:b:x") == nil)
        #expect(scene.robot("s:b") != nil)
    }

    @Test func nonAnimatedRenderRemovesLeavingRobotsAtOnce() {
        let scene = TowerScene(size: size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding)]
        scene.render([s], animated: false)
        let sprite = scene.robot("a:b:x")
        #expect(sprite?.parent != nil)
        s.subs = [:]
        scene.render([s], animated: false)
        #expect(scene.robot("a:b:x") == nil)
        #expect(sprite?.parent == nil)
        #expect(scene.transit.position(of: "a:b:x") == nil)
        #expect(scene.robot("s:b") != nil)
        // A whole session going away is no different.
        scene.render([], animated: false)
        #expect(scene.robot("s:b") == nil)
        #expect(scene.transit.position(of: "s:b") == nil)
    }

    @Test func nonAnimatedRenderFinishesRobotsAlreadyLeavingOrFadingIn() {
        let scene = TowerScene(size: size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding)]
        scene.render([s], animated: false)
        s.subs = [:]
        scene.render([s])                       // x starts walking out
        #expect(scene.robot("a:b:x") != nil)
        s.subs = ["y": sub("y", .coding)]
        scene.render([s])                       // y fades in
        #expect(scene.robot("a:b:y")?.fade == 0)
        scene.render([s], animated: false)      // e.g. the window got covered
        #expect(scene.robot("a:b:x") == nil)
        #expect(scene.transit.position(of: "a:b:x") == nil)
        #expect(scene.robot("a:b:y")?.fade == 1)
        // A robot that was leaving and is wanted again comes back fully visible.
        s.subs = [:]
        scene.render([s])
        s.subs = ["y": sub("y", .coding)]
        scene.render([s], animated: false)
        #expect(scene.robot("a:b:y")?.fade == 1)
    }

    @Test func sessionEndingWhileRidingExitsAtTheFloorTheCabIsHeadingTo() {
        let scene = TowerScene(size: size)
        var s = session("m", status: .standby, activity: .standby)
        scene.render([s], animated: false)
        s.status = .done; s.statusSince = rested   // desks (floor 2) -> pantry (floor 1)
        scene.render([s])
        var midShaft = false
        for _ in 0..<2000 {
            scene.advance(by: 1.0 / 60)
            let y = scene.transit.cabPosition.y
            if scene.transit.phase(of: "s:m") == .riding,
               y > scene.geo.elevatorStop(floor: 2).y + 8, y < scene.geo.elevatorStop(floor: 1).y - 8 { midShaft = true; break }
        }
        #expect(midShaft)
        scene.render([])                        // the session ends while its robot rides down
        let door = scene.transit.target(of: "s:m") ?? .zero
        #expect(scene.geo.floorOf(door) == 1)
        for _ in 0..<600 where scene.robot("s:m") != nil { scene.advance(by: 1.0 / 60) }
        #expect(scene.robot("s:m") == nil)
    }

    @Test func failedSubLeavesWithErrorFace() {
        let scene = TowerScene(size: size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding)]
        scene.render([s], animated: false)
        scene.noteSubResult(sessionId: "b", subId: "x", success: false)
        s.subs = [:]
        scene.render([s])
        #expect(scene.robot("a:b:x")?.face == .error)
        #expect(scene.robot("a:b:x")?.action == .commandFailed)
        #expect(scene.robot("a:b:x")?.childNode(withName: "report") == nil)
    }

    @Test func firstRenderPlacesWithoutAnimation() {
        let scene = TowerScene(size: size)
        scene.render([session("f", status: .done, since: rested)], animated: false)
        let target = scene.transit.target(of: "s:f")
        #expect(inRoom(scene, "s:f", .pantry))
        #expect(near(scene.transit.position(of: "s:f"), target))
        #expect(scene.transit.phase(of: "s:f") == .idle)
        #expect(scene.robot("s:f")?.alpha == 1)
        #expect(near(scene.robot("s:f").map { scene.layoutPoint($0.position) }, target))
        // The very first render of a new scene doesn't animate either.
        let fresh = TowerScene(size: size)
        fresh.render([session("f", status: .done)])
        #expect(fresh.transit.phase(of: "s:f") == .idle)
        #expect(fresh.robot("s:f")?.alpha == 1)
    }

    @Test func resizeSnapsRobotsToNewSlots() {
        let scene = TowerScene(size: size)
        scene.render([session("r", status: .done, since: rested)], animated: false)
        scene.size = CGSize(width: 1080, height: 1700)
        #expect(inRoom(scene, "s:r", .pantry))
        #expect(near(scene.transit.position(of: "s:r"), scene.transit.target(of: "s:r")))
        #expect(near(scene.robot("s:r").map { scene.layoutPoint($0.position) }, scene.transit.target(of: "s:r")))
    }

    @Test func lowerRobotsDrawInFrontBelowHeader() {
        let scene = TowerScene(size: size)
        scene.render([session("top", status: .waiting, team: 0), session("low", status: .sleeping, team: 1)], animated: false)
        let top = scene.robot("s:top")?.zPosition ?? 0, low = scene.robot("s:low")?.zPosition ?? 0
        #expect(low > top)
        let actors = scene.childNode(withName: "actors")!.zPosition
        let header = scene.childNode(withName: "header")!.zPosition
        let tooltip = scene.childNode(withName: "tooltip")!.zPosition
        #expect(actors + low + 1 < header && header < tooltip)
    }

    @Test func elevatorLabelDrawsAboveCab() {
        let scene = TowerScene(size: size)
        let label = scene.childNode(withName: "elevatorLabel")
        let cab = scene.childNode(withName: "cab")!
        #expect(label != nil)
        #expect((label?.zPosition ?? 0) > cab.zPosition)
        #expect((label?.zPosition ?? .infinity) < scene.childNode(withName: "actors")!.zPosition)
        let mid = CGPoint(x: scene.geo.elevator.midX, y: scene.geo.elevator.midY)
        #expect(near(label.map { scene.layoutPoint($0.position) }, mid))
    }

    /// Every node's z relative to `actors` (the sum of zPositions from the node up to the robot).
    private func partZs(_ r: RobotSprite) -> [CGFloat] {
        var out: [CGFloat] = [r.zPosition]
        r.enumerateChildNodes(withName: ".//*") { n, _ in
            var z: CGFloat = 0
            var cur: SKNode? = n
            while let c = cur, c !== r { z += c.zPosition; cur = c.parent }
            out.append(z + r.zPosition)
        }
        return out
    }

    @Test func coincidentRobotsNeverInterleave() {
        let scene = TowerScene(size: size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding), "y": sub("y", .coding)]
        scene.render([s, session("c", status: .standby, team: 1)], animated: false)
        let spot = scene.geo.elevatorStop(floor: 2)
        let keys = ["s:b", "a:b:x", "a:b:y", "s:c"]
        for k in keys { scene.transit.place(k, at: spot) }
        scene.advance(by: 1.0 / 60)
        let ranges = keys.map { k -> ClosedRange<CGFloat> in
            let zs = partZs(scene.robot(k)!)
            return zs.min()!...zs.max()!
        }
        for i in ranges.indices {
            for j in ranges.indices where j > i {
                let a = ranges[i], b = ranges[j]
                #expect(a.upperBound < b.lowerBound || b.upperBound < a.lowerBound, "\(keys[i]) / \(keys[j]) interleave: \(a) \(b)")
            }
        }
        // Nearly coincident with opposite x order still doesn't overlap.
        scene.transit.place("s:b", at: CGPoint(x: spot.x + 40, y: spot.y))
        scene.transit.place("s:c", at: CGPoint(x: spot.x - 40, y: spot.y + 0.4))
        scene.advance(by: 1.0 / 60)
        let b = partZs(scene.robot("s:b")!), c = partZs(scene.robot("s:c")!)
        #expect(b.max()! < c.min()!)
    }

    @Test func backingScaleChangeRebakesRobots() {
        let scene = TowerScene(size: size)
        var s = session("b", status: .working, activity: .coding)
        s.subs = ["x": sub("x", .coding), "y": sub("y", .coding)]
        scene.render([s], animated: false)
        #expect(scene.robot("s:b")?.art.scale == 2.5)
        scene.noteSubResult(sessionId: "b", subId: "x", success: true)
        s.subs = ["y": sub("y", .coding)]
        scene.render([s])
        scene.advance(by: 0.1)
        let leaving = scene.robot("a:b:x")
        let reportBefore = (leaving?.childNode(withName: "report") as? SKSpriteNode)?.texture
        let before = ["s:b", "a:b:y"].map { scene.robot($0) }
        let posBefore = scene.robot("s:b")?.position

        scene.backingScaleChanged(1)

        for k in ["s:b", "a:b:y", "a:b:x"] {
            let r = scene.robot(k)
            #expect(r?.art.scale == 1.25, "\(k)")
            #expect(r?.parent === scene.childNode(withName: "actors"), "\(k)")
        }
        #expect(before.allSatisfy { $0?.parent == nil })
        #expect(leaving?.parent == nil)
        #expect(scene.robot("s:b")?.position == posBefore)
        #expect(scene.robot("s:b")?.bubbleText == Activity.coding.label)
        #expect(scene.robot("s:b")?.robotScale == before[0]?.robotScale)
        #expect(scene.robot("a:b:y")?.robotScale == before[1]?.robotScale)
        let report = scene.robot("a:b:x")?.childNode(withName: "report") as? SKSpriteNode
        #expect(report != nil && report?.texture !== reportBefore)
        #expect(scene.robot("a:b:x")?.face == .happy)
        // The departure still completes with the new sprite.
        scene.advance(by: 3)
        #expect(scene.robot("a:b:x") == nil)
        // New robots use the new scale too.
        scene.render([s, session("n", status: .done, team: 2)])
        #expect(scene.robot("s:n")?.art.scale == 1.25)
    }
}

// MARK: - Interaction (Task 8)

@MainActor
@Suite struct TowerSceneInteractionTests {
    private let size = CGSize(width: 1200, height: 800)

    private func session(_ id: String, status: SessionStatus = .working, activity: Activity = .coding, team: Int = 0,
                         since: Date = Date()) -> Session {
        Session(id: id, title: "任务 \(id)", source: .desktop(hostSessionId: nil), rank: .seniorEngineer, status: status,
                activity: activity, teamIndex: team, statusSince: since, lastActivityAt: Date())
    }

    private func sub(_ id: String) -> SubAgent { SubAgent(id: id, type: "Explore", activity: .coding, startedAt: Date()) }

    /// SpriteKit stores alpha as a Float.
    private func isDim(_ r: RobotSprite?) -> Bool { abs((r?.alpha ?? 0) - 0.18) < 1e-6 }

    private func foot(_ scene: TowerScene, _ key: String) -> CGPoint { scene.transit.position(of: key) ?? .zero }

    /// Each scale has its own atlas, with its own version count: after a scale change the scene must still
    /// move the re-baked robots (and the LEDs) onto the new atlas. (Scales unused elsewhere: shared atlases.)
    @Test func scaleChangeRebindsToTheNewAtlas() {
        let scene = TowerScene(size: size)
        scene.backingScaleChanged(2.4)
        scene.render([session("a")], animated: false)
        scene.advance(by: 0.05)
        func onAtlas() -> Bool {
            guard let r = scene.robot("s:a"), let torso = r.childNode(withName: ".//torso") as? SKSpriteNode else { return false }
            let image = r.art.image(.torso(r.look))
            return r.art.atlas.isPacked(image) && torso.texture === r.art.atlas.texture(for: image)
        }
        func ledsOnAtlas() -> Bool {
            let atlas = RobotArt.shared(scale: scene.robot("s:a")!.art.scale).atlas
            let leds = scene.childNode(withName: "leds")!.children.compactMap { $0 as? SKSpriteNode }
            return !leds.isEmpty && leds.allSatisfy { led in led.texture.map { $0.textureRect().width < 1 } == true }
                && atlas.version > 0
        }
        #expect(onAtlas())
        #expect(ledsOnAtlas())
        scene.backingScaleChanged(1.6)
        #expect(scene.robot("s:a")?.art.scale == 2)
        scene.advance(by: 0.05)
        #expect(onAtlas())
        #expect(ledsOnAtlas())
    }

    /// After a scale change the old scale's art (image caches and atlas) is released once nothing uses it,
    /// instead of being kept per scale forever. Every robot, staying or on its way out, is re-baked with the
    /// new art, so nothing holds the old one afterwards.
    ///
    /// `RobotArt.shared` is per scale and tests run in parallel: the art scales here (2.75 and 1.75, from
    /// backing scales 2.2 and 1.4) must stay unused by every other test, or one holding that instance would
    /// keep `old` alive.
    @Test func oldScaleArtIsReleasedAfterAScaleChange() {
        let scene = TowerScene(size: size)
        scene.backingScaleChanged(2.2)
        scene.render([session("a"), session("b")], animated: false)
        scene.advance(by: 0.05)
        weak var old = scene.robot("s:a")?.art
        weak var oldAtlas = old?.atlas
        #expect(old?.scale == 2.75)
        scene.backingScaleChanged(1.4)
        scene.advance(by: 0.05)
        #expect(scene.robot("s:a")?.art.scale == 1.75)
        #expect(old == nil)
        #expect(oldAtlas == nil)
        // A new instance for the scale if it comes back; the current one is shared.
        #expect(RobotArt.shared(scale: 1.75) === scene.robot("s:b")?.art)
    }

    /// Textures made while a relief is pending get one more relief after it, so the last upload of a burst
    /// (a live resize rebakes every frame) is returned to the system too; a quiet scene runs none.
    @Test func reliefRunsOnceMoreAfterABurst() {
        let scene = TowerScene(size: size)
        scene.advance(by: TowerScene.reliefDelay + 0.1)
        let start = scene.reliefRuns                     // the initial bake's
        func counts(_ n: Int) -> TowerCounts { TowerCounts(working: n, waiting: 0, done: 0, subs: 0, contractors: 0, sleeping: 0, standby: 0) }
        scene.setHeader(counts(1))                       // arms the relief
        scene.advance(by: 0.3)
        scene.setHeader(counts(2))                       // made while it is pending
        scene.advance(by: 0.3)
        #expect(scene.reliefRuns == start + 1)
        scene.advance(by: TowerScene.reliefDelay + 0.1)
        #expect(scene.reliefRuns == start + 2)          // once more, for the second header
        scene.advance(by: 2)
        #expect(scene.reliefRuns == start + 2)          // then nothing until the next upload
    }

    @Test func savedFramePrefersOwnKeyAndMigratesAutosave() {
        let d = UserDefaults(suiteName: "agentrise.tests.\(UUID().uuidString)")!
        #expect(AppDelegate.savedFrame(d) == nil)
        d.set("-1512 -147 1512 944 -1512 -147 1512 944 ", forKey: "NSWindow Frame AgentriseMain")
        #expect(AppDelegate.savedFrame(d) == NSRect(x: -1512, y: -147, width: 1512, height: 944))
        d.set(NSStringFromRect(NSRect(x: 1920, y: -776, width: 1080, height: 1895)), forKey: AppDelegate.frameKey)
        #expect(AppDelegate.savedFrame(d) == NSRect(x: 1920, y: -776, width: 1080, height: 1895))
        d.set("garbage", forKey: AppDelegate.frameKey)
        #expect(AppDelegate.savedFrame(d) == nil)
    }

    @Test func savedFrameMustStillLieOnAScreen() {
        let screens = [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: -1512, y: -147, width: 1512, height: 982)]
        #expect(AppDelegate.isOnScreen(NSRect(x: -1512, y: -147, width: 1512, height: 944), screens: screens))
        #expect(!AppDelegate.isOnScreen(NSRect(x: 1920, y: -776, width: 1080, height: 1895), screens: screens))  // portrait unplugged
        #expect(!AppDelegate.isOnScreen(NSRect(x: 1880, y: 0, width: 800, height: 600), screens: screens))      // only a 40 pt sliver
    }

    @Test func devFrameNeedsFourNumbersAndAPositiveSize() {
        #expect(AppDelegate.devFrame(["x", "--frame", "-1500,-130,1000,900"]) == NSRect(x: -1500, y: -130, width: 1000, height: 900))
        #expect(AppDelegate.devFrame(["x", "--frame", " 1, 2 ,3,4"]) == NSRect(x: 1, y: 2, width: 3, height: 4))
        for bad in ["1,2,3", "1,2,3,4,5", "1,,3,4", "1,2,0,4", "1,2,3,-4", "a,2,3,4"] {
            #expect(AppDelegate.devFrame(["x", "--frame", bad]) == nil, "\(bad)")
        }
        #expect(AppDelegate.devFrame(["x", "--frame"]) == nil)
        #expect(AppDelegate.devFrame(["x"]) == nil)
    }

    @Test func headerIsBakedOncePerCopy() {
        let scene = TowerScene(size: size)
        scene.backingScaleChanged(2)
        let header = scene.childNode(withName: "header") as? SKSpriteNode
        let counts = TowerCounts(working: 1, waiting: 0, done: 0, subs: 0, contractors: 0, sleeping: 0, standby: 0)
        scene.setHeader(counts)
        let first = header?.texture
        #expect(first != nil && (header?.size.width ?? 0) > 100)
        scene.setHeader(counts)
        #expect(header?.texture === first)               // same copy: no re-render
        scene.setHeader(TowerCounts(working: 2, waiting: 0, done: 0, subs: 0, contractors: 0, sleeping: 0, standby: 0))
        #expect(header?.texture !== first)
        #expect(scene.headerText.contains("在岗 2"))
    }

    @Test func hitTestFindsRobotUnderPointer() {
        let scene = TowerScene(size: size)
        scene.render([session("a", team: 0), session("b", status: .sleeping, team: 1)], animated: false)
        let a = foot(scene, "s:a"), b = foot(scene, "s:b")
        let s = scene.robot("s:a")!.robotScale
        #expect(scene.sessionId(at: CGPoint(x: a.x, y: a.y - 30)) == "a")
        #expect(scene.sessionId(at: CGPoint(x: b.x, y: b.y - 30)) == "b")
        // Edges of the 60×84 box (scaled), and just outside it.
        #expect(scene.sessionId(at: CGPoint(x: a.x + 29 * s, y: a.y - 83 * s)) == "a")
        #expect(scene.sessionId(at: CGPoint(x: a.x + 31 * s, y: a.y - 40 * s)) == nil)
        #expect(scene.sessionId(at: CGPoint(x: a.x, y: a.y + 2)) == nil)
        #expect(scene.sessionId(at: CGPoint(x: 3, y: 3)) == nil)
    }

    @Test func hitTestResolvesSubsToTheirSession() {
        let scene = TowerScene(size: size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        scene.render([a], animated: false)
        let p = foot(scene, "a:a:x")
        #expect(scene.sessionId(at: CGPoint(x: p.x, y: p.y - 15)) == "a")
    }

    @Test func departingRobotsAreNotHittable() {
        let scene = TowerScene(size: size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        scene.render([a], animated: false)
        let p = foot(scene, "a:a:x"), boss = foot(scene, "s:a")
        // Stand where only the sub is (far from the boss's own box).
        #expect(abs(p.x - boss.x) > 40 || abs(p.y - boss.y) > 5)
        a.subs = [:]
        scene.render([a])
        scene.advance(by: 0.02)
        let q = foot(scene, "a:a:x")
        if abs(q.x - boss.x) > 40 { #expect(scene.sessionId(at: CGPoint(x: q.x, y: q.y - 15)) == nil) }
    }

    @Test func hoverShowsTooltipAndLeavingRemovesItImmediately() {
        let scene = TowerScene(size: size)
        scene.render([session("a")], animated: false)
        let tooltip = scene.childNode(withName: "tooltip")!
        #expect(tooltip.children.isEmpty)
        let a = foot(scene, "s:a")
        scene.hover(at: CGPoint(x: a.x, y: a.y - 30))
        #expect(!tooltip.children.isEmpty)
        #expect(!tooltip.children.contains { $0.hasActions() })
        scene.hover(at: nil)
        #expect(tooltip.children.isEmpty)
        // Hovering an empty spot also removes it.
        scene.hover(at: CGPoint(x: a.x, y: a.y - 30))
        #expect(!tooltip.children.isEmpty)
        scene.hover(at: CGPoint(x: 3, y: 3))
        #expect(tooltip.children.isEmpty)
    }

    @Test func hoverNotifiesOnlyWhenTheSessionChanges() {
        let scene = TowerScene(size: size)
        scene.render([session("a"), session("b", status: .sleeping, team: 1)], animated: false)
        var events: [String?] = []
        scene.onHoverSession = { events.append($0) }
        let a = foot(scene, "s:a"), b = foot(scene, "s:b")
        scene.hover(at: CGPoint(x: a.x, y: a.y - 30))
        scene.hover(at: CGPoint(x: a.x + 2, y: a.y - 31))
        scene.hover(at: CGPoint(x: b.x, y: b.y - 30))
        scene.hover(at: nil)
        scene.hover(at: nil)
        #expect(events == ["a", "b", nil])
        // Hovering highlights: the other robot dims, and leaving restores it.
        scene.hover(at: CGPoint(x: a.x, y: a.y - 30))
        #expect(isDim(scene.robot("s:b")) && scene.robot("s:a")?.alpha == 1)
        scene.hover(at: nil)
        #expect(scene.robot("s:b")?.alpha == 1)
    }

    @Test func clickReportsTheSessionUnderThePointer() {
        let scene = TowerScene(size: size)
        scene.render([session("a")], animated: false)
        var clicked: [String] = []
        scene.onClickSession = { clicked.append($0) }
        let a = foot(scene, "s:a")
        scene.click(at: CGPoint(x: a.x, y: a.y - 30))
        scene.click(at: CGPoint(x: 3, y: 3))
        #expect(clicked == ["a"])
    }

    @Test func highlightDimsOthersAndDrawsTethers() {
        let scene = TowerScene(size: size)
        var a = session("a")
        a.subs = ["x": sub("x"), "y": sub("y")]
        a.contractors = [:]
        scene.render([a, session("b", status: .sleeping, team: 1), session("c", status: .done, team: 2)], animated: false)
        let tethers = scene.childNode(withName: "tethers")!
        #expect(tethers.children.isEmpty)
        scene.highlight("a")
        for k in ["s:b", "s:c"] { #expect(isDim(scene.robot(k)), "\(k)") }
        for k in ["s:a", "a:a:x", "a:a:y"] { #expect(scene.robot(k)?.alpha == 1, "\(k)") }
        #expect(tethers.children.count == 2)
        let shape = tethers.children.first as? SKShapeNode
        #expect(shape?.glowWidth == 2 && shape?.lineWidth == 2)
        #expect(shape?.strokeColor == Team.color(0))
        #expect(shape?.path?.boundingBoxOfPath.isEmpty == false)
        scene.highlight(nil)
        for k in ["s:a", "s:b", "s:c", "a:a:x", "a:a:y"] { #expect(scene.robot(k)?.alpha == 1, "\(k)") }
        #expect(tethers.children.isEmpty)
    }

    @Test func highlightKeepsDepartingRobotsFading() {
        let scene = TowerScene(size: size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        scene.render([a, session("b", status: .sleeping, team: 1)], animated: false)
        a.subs = [:]
        scene.render([a, session("b", status: .sleeping, team: 1)])
        let leaving = scene.robot("a:a:x")
        scene.highlight("b")
        #expect(leaving?.dimmed == false)
        scene.highlight(nil)
        #expect(leaving?.dimmed == false)
        #expect(scene.childNode(withName: "tethers")!.children.isEmpty)
    }

    @Test func newRobotsAppearDimmedWhileHighlightIsActive() {
        let scene = TowerScene(size: size)
        scene.render([session("a")], animated: false)
        scene.highlight("a")
        scene.render([session("a"), session("b", status: .sleeping, team: 1)])
        #expect(scene.robot("s:b")?.dimmed == true)
        scene.advance(by: 2)
        #expect(isDim(scene.robot("s:b")))   // fade 1 × dim 0.18
    }

    @Test func tethersFollowTheRobotsWhileHighlighted() {
        let scene = TowerScene(size: size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        scene.render([a], animated: false)
        scene.highlight("a")
        let before = (scene.childNode(withName: "tethers")!.children.first as? SKShapeNode)?.path?.boundingBoxOfPath
        // A newly created sub walks in: the tether set is refreshed on render.
        a.subs["y"] = sub("y")
        scene.render([a])
        #expect(scene.childNode(withName: "tethers")!.children.count == 2)
        #expect(before != nil)
    }

    @Test func highlightedSessionVanishingClearsEverything() {
        let scene = TowerScene(size: size)
        var a = session("a")
        a.subs = ["x": sub("x")]
        let b = session("b", status: .sleeping, team: 1)
        scene.render([a, b], animated: false)
        var events: [String?] = []
        scene.onHoverSession = { events.append($0) }
        let p = foot(scene, "s:a")
        scene.hover(at: CGPoint(x: p.x, y: p.y - 30))
        #expect(isDim(scene.robot("s:b")))
        #expect(!scene.childNode(withName: "tooltip")!.children.isEmpty)
        events.removeAll()
        scene.render([b])
        #expect(scene.robot("s:b")?.alpha == 1)
        #expect(scene.childNode(withName: "tethers")!.children.isEmpty)
        #expect(scene.childNode(withName: "tooltip")!.children.isEmpty)
        #expect(events == [nil])
        scene.advance(by: 5)
        for k in ["s:b", "a:a:x", "s:a"] { #expect((scene.robot(k)?.alpha ?? 1) >= 0 && !(scene.robot(k)?.dimmed ?? false)) }
    }

    @Test func tooltipCopyMatchesOld() {
        var s = session("a", status: .working, activity: .coding, since: Date().addingTimeInterval(-7 * 60 - 5))
        s.title = "修复登录"
        s.subs = ["x": sub("x"), "y": sub("y")]
        s.contractors = ["c": Contractor(id: "c", description: "build", startedAt: Date())]
        s.delivered = 3
        s.failedSubs = 1
        s.contractorsDone = 4
        #expect(TowerScene.tooltipLines(for: s) == [
            "\(Team.glyph(0)) 修复登录", "高级工程师 · Claude App", "干活中 · \(Activity.coding.label) · 7 分钟",
            "小弟 2 在岗 · 已交付 3 · 失败 1", "外包 1 在岗 · 已完成 4"])
        s.status = .waiting; s.waitingSummary = "要不要继续"; s.source = .lark; s.teamIndex = 1
        #expect(TowerScene.tooltipLines(for: s)[0] == "\(Team.glyph(1)) 修复登录")
        #expect(TowerScene.tooltipLines(for: s)[1] == "高级工程师 · 飞书")
        #expect(TowerScene.tooltipLines(for: s)[2] == "等你回复：要不要继续 · 7 分钟")
        s.status = .error; s.source = .terminal(bundleId: nil)
        #expect(TowerScene.tooltipLines(for: s)[1] == "高级工程师 · 终端")
        #expect(TowerScene.tooltipLines(for: s)[2] == "出错了（要不要继续） · 7 分钟")
        s.waitingSummary = nil
        s.status = .done
        #expect(TowerScene.tooltipLines(for: s)[2] == "做完了 · 7 分钟")
        s.status = .standby
        #expect(TowerScene.tooltipLines(for: s)[2] == "待命 · 7 分钟")
        s.status = .sleeping
        #expect(TowerScene.tooltipLines(for: s)[2] == "睡觉中 · 7 分钟")
    }

    @Test func tooltipUsesCopyAndStaysInsideTheScene() {
        let scene = TowerScene(size: size)
        scene.render([session("a")], animated: false)
        let a = foot(scene, "s:a")
        scene.hover(at: CGPoint(x: a.x, y: a.y - 30))
        #expect(scene.tooltipLines.first == "\(Team.glyph(0)) 任务 a")
        let box = scene.childNode(withName: "tooltip")!.children.first as! SKSpriteNode
        #expect(box.size.width <= 320 && box.size.height > 40)
        // Normal placement: top-left corner 14 pt right and below the pointer (layout coordinates).
        let p = CGPoint(x: a.x, y: a.y - 30)
        let tl = scene.layoutPoint(CGPoint(x: box.frame.minX, y: box.frame.maxY))
        #expect(abs(tl.x - (p.x + 14)) < 0.01 && abs(tl.y - (p.y + 14)) < 0.01)
        // Near the right / bottom edge the box flips to the other side of the pointer.
        let corner = CGPoint(x: size.width - 5, y: size.height - 5)
        scene.hover(at: nil)
        scene.showTooltip("a", at: corner)
        let flipped = scene.childNode(withName: "tooltip")!.children.first as! SKSpriteNode
        let br = scene.layoutPoint(CGPoint(x: flipped.frame.maxX, y: flipped.frame.minY))
        #expect(abs(br.x - (corner.x - 10)) < 0.01 && abs(br.y - (corner.y - 10)) < 0.01)
    }
}
