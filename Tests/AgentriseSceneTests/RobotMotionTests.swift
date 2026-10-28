// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
@testable import AgentriseScene
@testable import Agentrise

/// `RobotMotion`'s loops and curves, run on bare `SceneNode`s by `TweenEngine` (no robot art needed).
@Suite struct RobotMotionTests {
    private func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.02) -> Bool { abs(a - b) <= tol }

    /// A node per part, each running its loop; `at(t)` steps at 60 fps to `t` seconds after the start.
    private final class Rig {
        let root = SceneNode()
        private var frame = 0
        init(_ loops: [(part: String, tween: Tween)]) {
            for (part, t) in loops {
                let n = root.childNode(withName: part) ?? { let n = SceneNode(name: part); root.addChild(n); return n }()
                n.run(t)
            }
            TweenEngine.step(root, dt: 0)
        }
        func node(_ name: String) -> SceneNode { root.childNode(withName: name)! }
        func at(_ t: TimeInterval) {
            let target = Int((t * 60).rounded())
            while frame < target { TweenEngine.step(root, dt: 1.0 / 60); frame += 1 }
        }
    }

    @Test func bobMatchesTheOldKeyframes() {
        // phase 0: float [0, -2.5, 0] over 2.6 s, eased over the whole loop (peak at 1.3 s).
        let r = Rig(RobotMotion.idle(phase: 0))
        let float = r.node("float")
        r.at(1.3); #expect(near(float.position.y, 2.5))
        r.at(2.6); #expect(near(float.position.y, 0))
        // CA eased the whole loop, not each keyframe: a quarter in, the progress is caEase(0.25) ≈ 0.129.
        r.at(2.6 + 0.65); #expect(near(float.position.y, 0.646))
    }

    @Test func phaseStartsMidLoop() {
        let r = Rig(RobotMotion.idle(phase: 1.3))
        // The old `timeOffset = phase`: at t = 0 the bob is already 1.3 s in, i.e. at its peak.
        r.at(0); #expect(near(r.node("float").position.y, 2.5))
        r.at(1.3); #expect(near(r.node("float").position.y, 0))
    }

    @Test func blinkFollowsKeyTimes() {
        let r = Rig(RobotMotion.idle(phase: 0))
        let eyes = r.node("eyes")
        r.at(1.5); #expect(near(eyes.yScale, 1))
        r.at(2.0); #expect(near(eyes.yScale, 0.1))
        r.at(2.5); #expect(near(eyes.yScale, 1))
    }

    @Test func designSpaceFlipsIntoSceneSpace() {
        // Old rotation −0.1…0.1 (y down) is +0.1…−0.1 in the scene; old position.y 8 → 84 − 8.
        let r = Rig(RobotMotion.act(.reading, waitingLong: false) + RobotMotion.act(.compacting, waitingLong: false))
        r.at(0)
        #expect(near(r.node("head").zRotation, 0.1, 1e-6))
        // The paper starts at old P(0, 30).y = 44 → scene y 40.
        #expect(near(r.node("paper").position.y, 40, 1e-6))
        r.at(1.2); #expect(near(r.node("head").zRotation, -0.1, 0.005))
        #expect(RobotMotion.robotPoint(CGPoint(x: 30, y: 84)) == .zero)
    }

    @Test func actGroupsLoopsPerPart() {
        let parts = RobotMotion.act(.commandFailed, waitingLong: false).map(\.part)
        #expect(parts == ["smoke", "rig"])
        #expect(RobotMotion.act(.standby, waitingLong: false).isEmpty)
        #expect(RobotMotion.act(.sleeping, waitingLong: false).map(\.part) == ["z0", "z1"])
    }

    @Test func caEaseMatchesBezier() {
        #expect(abs(RobotMotion.caEase(0.5) - 0.5) < 1e-6)
        #expect(RobotMotion.caEase(0) == 0 && abs(RobotMotion.caEase(1) - 1) < 1e-6)
        for y in [0.1, 0.46, 0.54, 0.9] {
            #expect(abs(RobotMotion.caEase(RobotMotion.caEaseInverse(y)) - y) < 1e-4)
        }
    }

    @Test func caEaseTableTracksExactCurve() {
        var worst = 0.0
        for i in 0...4000 {
            let x = Double(i) / 4000
            worst = max(worst, abs(RobotMotion.caEase(x) - RobotMotion.caEaseExact(x)))
        }
        #expect(worst < 1e-4)
    }
}
