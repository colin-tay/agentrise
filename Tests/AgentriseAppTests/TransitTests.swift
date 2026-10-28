// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import CoreGraphics
import Foundation
@testable import AgentriseApp
@testable import Agentrise

@Suite struct TransitTests {
    private let layout = BuildingLayout.make(size: CGSize(width: 1080, height: 1900))

    /// 以 1/60 秒步进推进 `seconds` 秒；`each` 在每步之后调用。
    private func advance(_ t: Transit, seconds: Double, each: (() -> Void)? = nil) {
        let steps = Int((seconds * 60).rounded(.up))
        for _ in 0..<steps {
            t.step(1.0 / 60)
            each?()
        }
    }

    /// 推进直到 `cond` 成立（最多 `limit` 秒），返回是否成立。
    @discardableResult
    private func advance(_ t: Transit, until cond: () -> Bool, limit: Double = 30) -> Bool {
        let steps = Int(limit * 60)
        for _ in 0..<steps {
            if cond() { return true }
            t.step(1.0 / 60)
        }
        return cond()
    }

    /// 房间底部中点（机器人站立点）。
    private func spot(_ room: Room, dx: CGFloat = 0, in l: BuildingLayout? = nil) -> CGPoint {
        let r = (l ?? layout).rooms[room]![0]
        return CGPoint(x: r.midX + dx, y: r.maxY - 4)
    }

    private func near(_ a: CGPoint?, _ b: CGPoint, tol: CGFloat = 0.01) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol
    }

    @Test func sameFloorWalkArrivesWithinOldDuration() {
        let t = Transit(layout: layout)
        let a = spot(.desks, dx: -150)
        let b = CGPoint(x: a.x + 300, y: a.y)
        t.place("r1", at: a)
        t.send("r1", to: b)
        #expect(t.phase(of: "r1") == .walking)
        advance(t, seconds: 0.85)
        #expect(t.phase(of: "r1") == .idle)
        #expect(near(t.position(of: "r1"), b))
    }

    @Test func crossFloorRidesTheCab() {
        let t = Transit(layout: layout)
        var arrivals: [String] = []
        t.onArrive = { arrivals.append($0) }
        let a = spot(.desks), b = spot(.pantry)
        t.place("r1", at: a)
        t.send("r1", to: b)

        var phases: [TransitPhase] = []
        var ridingOK = true
        var sawRiding = false
        advance(t, seconds: 20) {
            let p = t.phase(of: "r1")!
            if phases.last != p { phases.append(p) }
            if p == .riding {
                sawRiding = true
                if t.position(of: "r1") != t.cabPosition { ridingOK = false }
                if t.position(of: "r1")!.x != layout.elevator.midX { ridingOK = false }
            }
        }
        let iWalk = phases.firstIndex(of: .walking)
        let iWait = phases.firstIndex(of: .waiting)
        let iRide = phases.firstIndex(of: .riding)
        #expect(iWalk != nil && iWait != nil && iRide != nil)
        if let iWalk, let iWait, let iRide { #expect(iWalk < iWait && iWait < iRide) }
        #expect(sawRiding && ridingOK)
        #expect(t.phase(of: "r1") == .idle)
        #expect(near(t.position(of: "r1"), b))
        #expect(arrivals == ["r1"])
    }

    @Test func retargetMidRideEndsAtNewTarget() {
        let t = Transit(layout: layout)
        t.place("r1", at: spot(.desks))
        t.send("r1", to: spot(.sleepPods))
        #expect(advance(t, until: { t.phase(of: "r1") == .riding }))
        let newTarget = spot(.meeting)
        t.send("r1", to: newTarget)
        #expect(t.target(of: "r1") == newTarget)
        #expect(advance(t, until: { t.phase(of: "r1") == .idle }))
        #expect(near(t.position(of: "r1"), newTarget))
    }

    @Test func twoRidersSameDirectionShareOneTrip() {
        let t = Transit(layout: layout)
        let a = spot(.desks), b = spot(.sleepPods)
        t.place("r1", at: a); t.place("r2", at: a)
        t.send("r1", to: b); t.send("r2", to: b)
        #expect(advance(t, until: { t.phase(of: "r1") == .idle && t.phase(of: "r2") == .idle }))
        #expect(near(t.position(of: "r1"), b) && near(t.position(of: "r2"), b))
        #expect(t.tripCount == 2)
    }

    // MARK: - Review Focus

    @Test func relayoutSnapsEveryoneAndClearsElevator() {
        let t = Transit(layout: layout)
        var arrivals: [String] = []
        t.onArrive = { arrivals.append($0) }
        t.place("walker", at: spot(.desks, dx: -100))
        t.send("walker", to: spot(.desks, dx: 100))
        t.place("rider", at: spot(.desks))
        t.send("rider", to: spot(.sleepPods))
        t.place("waiter", at: spot(.pantry))
        t.send("waiter", to: spot(.meeting))
        #expect(advance(t, until: { t.phase(of: "rider") == .riding }))

        let newLayout = BuildingLayout.make(size: CGSize(width: 1600, height: 1000))
        let targets = [
            "walker": spot(.intel, in: newLayout),
            "rider": spot(.archive, in: newLayout),
            "waiter": spot(.ceoOffice, in: newLayout),
        ]
        t.relayout(newLayout, targets: targets)
        let trips = t.tripCount
        let arrivalsBefore = arrivals
        for (id, p) in targets {
            #expect(t.phase(of: id) == .idle)
            #expect(t.position(of: id) == p)
            #expect(t.target(of: id) == p)
        }
        #expect(t.layout.size == newLayout.size)
        #expect(!t.cabDoorsOpen)
        #expect(t.cabPosition.x == newLayout.elevator.midX)

        advance(t, seconds: 5)
        for (id, p) in targets { #expect(t.position(of: id) == p && t.phase(of: id) == .idle) }
        #expect(t.tripCount == trips)
        #expect(arrivals == arrivalsBefore)   // 吸附不算到达
    }

    @Test func twelveCrossFloorRidersAllArriveWithin30s() {
        let t = Transit(layout: layout)
        var arrivals: [String: Int] = [:]
        t.onArrive = { arrivals[$0, default: 0] += 1 }
        let dests: [Room] = [.pantry, .sleepPods, .meeting]
        var targets: [String: CGPoint] = [:]
        for i in 0..<12 {
            let id = "r\(i)"
            t.place(id, at: spot(.desks, dx: CGFloat(i * 12 - 66)))
            let dest = spot(dests[i % 3], dx: CGFloat(i * 6 - 33))
            targets[id] = dest
            t.send(id, to: dest)
        }
        advance(t, seconds: 30)
        for (id, p) in targets {
            #expect(t.phase(of: id) == .idle, "\(id) phase \(String(describing: t.phase(of: id)))")
            #expect(near(t.position(of: id), p))
            #expect(arrivals[id] == 1)
        }
    }

    @Test func removingRiderMidRideKeepsElevatorServing() {
        let t = Transit(layout: layout)
        t.place("r1", at: spot(.desks))
        t.send("r1", to: spot(.sleepPods))
        let r2Target = spot(.meeting)
        t.place("r2", at: spot(.pantry))
        t.send("r2", to: r2Target)
        #expect(advance(t, until: { t.phase(of: "r1") == .riding }))
        t.remove("r1")
        #expect(t.position(of: "r1") == nil && t.phase(of: "r1") == nil)
        #expect(advance(t, until: { t.phase(of: "r2") == .idle }))
        #expect(near(t.position(of: "r2"), r2Target))
    }

    @Test func hugeDtIsClampedPerStep() {
        let t = Transit(layout: layout)
        let a = spot(.desks, dx: -150)
        let b = CGPoint(x: a.x + 300, y: a.y)
        t.place("r1", at: a)
        t.send("r1", to: b)
        t.step(5)
        let speed = 300 / min(1.5, 0.35 + 300.0 / 700)
        let moved = hypot(t.position(of: "r1")!.x - a.x, t.position(of: "r1")!.y - a.y)
        #expect(moved > 0)
        #expect(moved <= speed * 0.1 + 0.001)
        #expect(t.phase(of: "r1") == .walking)
    }

    // MARK: - Fix round 1

    private func walkSpeed(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = hypot(b.x - a.x, b.y - a.y)
        return d / min(1.5, 0.35 + d / 700)
    }

    @Test func boardingWalksIntoTheCab() {
        let t = Transit(layout: layout)
        t.place("r1", at: spot(.desks))          // 2F 左侧
        t.send("r1", to: spot(.sleepPods))
        let door = layout.elevatorDoor(floor: 2, side: .left)
        let stop = layout.elevatorStop(floor: 2)
        let dt = 1.0 / 60
        let maxJump = walkSpeed(door, stop) * CGFloat(dt) + 0.5

        #expect(advance(t, until: { t.phase(of: "r1") == .waiting }))
        var xs: [CGFloat] = [t.position(of: "r1")!.x]
        var cabWhileBoarding: Set<CGFloat> = []
        var doorsOpenWhileBoarding = true
        while t.phase(of: "r1") == .waiting, xs.count < 60 * 30 {
            t.step(dt)
            let p = t.position(of: "r1")!
            xs.append(p.x)
            if p.x != door.x, t.phase(of: "r1") == .waiting {
                cabWhileBoarding.insert(t.cabPosition.y)
                if !t.cabDoorsOpen { doorsOpenWhileBoarding = false }
            }
        }
        #expect(t.phase(of: "r1") == .riding)
        #expect(t.position(of: "r1") == t.cabPosition)
        #expect(xs.first == door.x && xs.last == layout.elevator.midX)
        let walkIn = xs.filter { $0 != door.x }
        #expect(walkIn.count > 5)                                   // 真的走了若干帧
        for i in 1..<xs.count {
            #expect(xs[i] >= xs[i - 1])                             // 单调向轿厢
            #expect(xs[i] - xs[i - 1] <= maxJump)                   // 没有瞬移
        }
        #expect(cabWhileBoarding == [stop.y])                       // 走进去之前轿厢不走
        #expect(doorsOpenWhileBoarding)
    }

    @Test func alightingWalksOutOfTheCab() {
        let t = Transit(layout: layout)
        let target = spot(.sleepPods)            // 0F 左侧
        t.place("r1", at: spot(.desks))
        t.send("r1", to: target)
        #expect(advance(t, until: { t.phase(of: "r1") == .riding }))
        while t.phase(of: "r1") == .riding { t.step(1.0 / 60) }
        #expect(t.phase(of: "r1") == .walking)
        let stop = layout.elevatorStop(floor: 0)
        let door = layout.elevatorDoor(floor: 0, side: .left)
        #expect(t.cabPosition == stop)
        let maxJump = walkSpeed(stop, door) / 60 + 0.5
        var prev = t.position(of: "r1")!
        #expect(hypot(prev.x - t.cabPosition.x, prev.y - t.cabPosition.y) <= maxJump)
        // 走出轿厢到门口这一段逐帧连续
        while t.phase(of: "r1") == .walking, prev.x > door.x {
            t.step(1.0 / 60)
            let p = t.position(of: "r1")!
            let fastest = max(walkSpeed(stop, door), walkSpeed(door, target)) / 60 + 0.5   // 跨过门口那帧会用到下一段速度
            #expect(hypot(p.x - prev.x, p.y - prev.y) <= fastest)
            prev = p
        }
        #expect(advance(t, until: { t.phase(of: "r1") == .idle }))
        #expect(near(t.position(of: "r1"), target))
    }

    @Test func onArriveSkipsRiderRemovedByEarlierCallback() {
        let t = Transit(layout: layout)
        let a = spot(.desks, dx: -100), b = spot(.desks, dx: 100), c = spot(.desks, dx: -150)
        for id in ["r1", "r2", "r3"] { t.place(id, at: a); t.send(id, to: b) }
        var arrivals: [String] = []
        t.onArrive = { id in
            arrivals.append(id)
            if id == "r1" {
                t.remove("r2")          // 同一步里后面的人被删
                t.send("r3", to: c)     // 同一步里后面的人被改派
            }
        }
        #expect(advance(t, until: { !arrivals.isEmpty }))
        #expect(arrivals == ["r1"])
        #expect(advance(t, until: { t.phase(of: "r3") == .idle }))
        #expect(arrivals == ["r1", "r3"])
        #expect(near(t.position(of: "r3"), c))
    }
}
