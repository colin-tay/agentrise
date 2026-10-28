// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import SpriteKit
import Metal
@testable import AgentriseApp
@testable import Agentrise
@testable import AgentriseScene

/// Every tween `RobotMotion` makes, run two ways for 6 s at 60 fps: bridged to SKActions under SpriteKit
/// (stepped headlessly with `SKRenderer`, like `RobotSpriteTests`) and on a `SceneNode` by `TweenEngine`.
/// Frame by frame, both must agree within 0.002 on every animated property.
///
/// Only here while the bridge exists: once the scene runs on `SceneNode`, `MotionSnapshotTests` guards the motion.
@MainActor
@Suite struct TweenParityTests {
    static let tolerance: CGFloat = 0.002
    static let frames = 360

    static let activities: [Activity] = [
        .reading, .searching, .coding, .runningCommand, .commandFailed, .browsing, .planning, .delegating,
        .sendingLark, .thinking, .compacting, .waitingAtDoor, .waitingForSubs, .reporting, .resting, .standby,
        .sleeping, .briefing, .other,
    ]

    /// Every (label, tween) pair: the idle loops at a few phases, the bubble pulse, and each action's loops.
    static var cases: [(String, Tween)] {
        var out: [(String, Tween)] = []
        for phase in [0, 0.37, 0.7, 1.1, 1.3, 2.2, 3.3, 5.9] {
            out += RobotMotion.idle(phase: phase).map { ("idle(\(phase)).\($0.part)", $0.tween) }
        }
        out.append(("pulse", RobotMotion.pulse()))
        for a in activities {
            for long in a == .waitingAtDoor ? [false, true] : [false] {
                out += RobotMotion.act(a, waitingLong: long).map { ("act(\(a)\(long ? ", long" : "")).\($0.part)", $0.tween) }
            }
        }
        return out
    }

    private static func state(_ n: SKNode) -> [CGFloat] {
        [n.position.x, n.position.y, n.zRotation, n.alpha, n.xScale, n.yScale]
    }

    private static func state(_ n: SceneNode) -> [CGFloat] {
        [n.position.x, n.position.y, n.zRotation, n.alpha, n.xScale, n.yScale]
    }

    /// Runs every case both ways for `frames` frames at 60 fps; returns the worst deviation per case.
    private static func compare(_ cases: [(String, Tween)], frames: Int) -> [CGFloat] {
        // All SKNodes share one scene and renderer, each `SceneNode` gets its own root.
        let renderer = SKRenderer(device: MTLCreateSystemDefaultDevice()!)
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        renderer.scene = scene
        var sk: [SKNode] = [], tw: [SceneNode] = []
        for (_, t) in cases {
            let a = SKNode(), b = SceneNode()
            a.run(.from(t))
            b.run(t)
            scene.addChild(a)
            tw.append(b)
            sk.append(a)
        }
        let base: TimeInterval = 1000
        renderer.update(atTime: base)
        tw.forEach { TweenEngine.step($0, dt: 0) }

        var worst = Array(repeating: CGFloat(0), count: cases.count)
        for frame in 0...frames {
            if frame > 0 {
                renderer.update(atTime: base + Double(frame) / 60)
                tw.forEach { TweenEngine.step($0, dt: 1.0 / 60) }
            }
            for i in cases.indices {
                let d = zip(state(sk[i]), state(tw[i])).map { abs($0 - $1) }.max() ?? 0
                worst[i] = max(worst[i], d)
            }
        }
        return worst
    }

    private static func check(_ cases: [(String, Tween)], frames: Int) {
        let worst = compare(cases, frames: frames)
        var report = "TweenParity max deviation over frames 0…\(frames):\n"
        for (i, c) in cases.enumerated() {
            report += String(format: "  %-40@ %.6f\n", c.0 as NSString, Double(worst[i]))
            #expect(worst[i] <= tolerance, "\(c.0): max deviation \(worst[i])")
        }
        print(report)
    }

    @Test func everyRobotMotionTweenMatchesSpriteKit() {
        Self.check(Self.cases, frames: Self.frames)
    }

    /// The SpriteKit rules `TweenEngine` copies, each on its own: leftover time carried through sequences and
    /// loops, curves that end a tween early or never, zero-duration actions in and at the end of a sequence,
    /// `Float` durations drifting against the frame clock.
    @Test func spriteKitTimingRulesMatch() {
        let x = { (d: TimeInterval) in Tween.moveBy(dx: 1, dy: 0, duration: d) }
        let cases: [(String, Tween)] = [
            ("carry", .sequence([x(0.11), x(0.5), .fadeAlpha(to: 0.2, duration: 0.37)])),
            ("repeat carry", .repeatForever(x(0.11))),
            ("early curve", .sequence([.timed(x(0.5), timing: { min(1, 2 * $0) }), x(0.5)])),
            ("overshooting curve", .sequence([.timed(x(0.5), timing: { $0 < 0.5 ? 2.4 * $0 : 1 }), x(0.5)])),
            ("stalled curve", .sequence([.timed(x(0.5), timing: { 0.9 * $0 }), x(0.5)])),
            ("stalled group", .sequence([.group([.timed(x(0.2), timing: { 0.9 * $0 }), .fadeAlpha(to: 0, duration: 0.5)]), x(0.5)])),
            ("zero first", .sequence([.moveTo(x: 5, y: nil, duration: 0), x(0.5)])),
            ("zero mid", .sequence([.wait(1.4), .moveTo(x: 16, y: nil, duration: 0), x(0.5)])),
            ("zero last", .sequence([.moveTo(x: 16, y: nil, duration: 1.4), .moveTo(x: 0, y: nil, duration: 0)])),
            ("loop jump 1.4", .repeatForever(.sequence([.moveTo(x: 16, y: nil, duration: 1.4), .moveTo(x: 0, y: nil, duration: 0)]))),
            ("loop jump 2.6", .repeatForever(.sequence([.moveTo(x: 16, y: nil, duration: 2.6), .moveTo(x: 0, y: nil, duration: 0)]))),
            ("loop jump 1.2", .repeatForever(.sequence([.moveTo(x: 16, y: nil, duration: 1.2), .moveTo(x: 0, y: nil, duration: 0)]))),
            ("loop 3 parts", .repeatForever(.sequence([.wait(1.5691120894751711), .rotateTo(-.pi, duration: 0.8308879105248289),
                                                       .rotateTo(0, duration: 0)]))),
            ("nested loops", .repeatForever(.sequence([.group([x(0.3), .repeatForever(.fadeAlpha(to: 0.5, duration: 0.07))]), x(0.2)]))),
        ]
        Self.check(cases, frames: Self.frames)
    }

    /// The bridge maps `custom` and `run` as SpriteKit would run them: the block sees the node's state and its
    /// changes land on the SKNode.
    @Test func customAndRunReachTheSKNode() {
        let renderer = SKRenderer(device: MTLCreateSystemDefaultDevice()!)
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        renderer.scene = scene
        var ran = 0, names: [String?] = []
        let t = Tween.sequence([
            .custom(duration: 1) { n, e in names.append(n.name); n.position.x += 1; n.alpha = CGFloat(1 - e) },
            .run { ran += 1 },
        ])
        let a = SKNode(), b = SceneNode(name: "n")
        a.name = "n"
        a.run(.from(t))
        b.run(t)
        scene.addChild(a)
        renderer.update(atTime: 1000)
        TweenEngine.step(b, dt: 0)
        for frame in 1...90 {
            renderer.update(atTime: 1000 + Double(frame) / 60)
            TweenEngine.step(b, dt: 1.0 / 60)
            #expect(abs(a.alpha - b.alpha) <= Self.tolerance)
        }
        #expect(ran == 2)   // once on each side
        #expect(names.allSatisfy { $0 == "n" })
        #expect(abs(a.position.x - b.position.x) <= 1, "SpriteKit \(a.position.x), engine \(b.position.x)")
        #expect(a.alpha == 0 && b.alpha == 0)
    }
}
