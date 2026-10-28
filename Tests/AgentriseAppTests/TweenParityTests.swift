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

    /// One node's script: tweens to run (with an optional key) just before update `i`, by `i`.
    typealias Script = [Int: [(Tween, String?)]]

    /// Runs every script both ways, updating at `times` (seconds after the first update, `times[0] == 0`):
    /// SpriteKit through `SKRenderer.update(atTime:)`, the engine through `step(dt:)` by the same gaps. The
    /// first update is each side's first frame (SpriteKit starts actions there at progress 0; the engine's
    /// first step for a new tween is likewise at local time 0). Returns the worst deviation per script.
    /// `floatSlack`: forgive 1e-6 of each SpriteKit value on top, for SpriteKit storing positions as `Float`
    /// (after thousands of `moveBy` cycles its running sum carries that much rounding).
    private static func compare(_ scripts: [Script], times: [Double], floatSlack: Bool = false) -> [CGFloat] {
        // All SKNodes share one scene and renderer, each `SceneNode` gets its own root.
        let renderer = SKRenderer(device: MTLCreateSystemDefaultDevice()!)
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        renderer.scene = scene
        let sk = scripts.map { _ in SKNode() }, tw = scripts.map { _ in SceneNode() }
        sk.forEach(scene.addChild)
        let base: TimeInterval = 1000
        var worst = Array(repeating: CGFloat(0), count: scripts.count)
        for (i, time) in times.enumerated() {
            for (k, script) in scripts.enumerated() {
                for (t, key) in script[i] ?? [] {
                    sk[k].run(.from(t), withKey: key ?? "")
                    tw[k].run(t, withKey: key)
                }
            }
            renderer.update(atTime: base + time)
            let dt = i == 0 ? 0 : time - times[i - 1]
            tw.forEach { TweenEngine.step($0, dt: dt) }
            for k in scripts.indices {
                var d: CGFloat = 0
                for (a, b) in zip(state(sk[k]), state(tw[k])) {
                    let slack: CGFloat = floatSlack ? 1e-6 * abs(a) : 0
                    d = max(d, abs(a - b) - slack)
                }
                worst[k] = max(worst[k], d)
            }
        }
        return worst
    }

    private static func check(_ names: [String], _ scripts: [Script], times: [Double], floatSlack: Bool = false) {
        let worst = compare(scripts, times: times, floatSlack: floatSlack)
        var report = "TweenParity max deviation over \(times.count) updates:\n"
        for (i, name) in names.enumerated() {
            report += String(format: "  %-40@ %.6f\n", name as NSString, Double(worst[i]))
            #expect(worst[i] <= Self.tolerance, "\(name): max deviation \(worst[i])")
        }
        print(report)
    }

    /// Each tween started before the first frame, then `frames` frames at 60 fps.
    private static func check(_ cases: [(String, Tween)], frames: Int) {
        check(cases.map(\.0), cases.map { [0: [($0.1, nil)]] }, times: (0...frames).map { Double($0) / 60 })
    }

    @Test func everyRobotMotionTweenMatchesSpriteKit() {
        Self.check(Self.cases, frames: Self.frames)
    }

    /// The SpriteKit rules `TweenEngine` copies, each on its own: leftover time carried through sequences and
    /// loops, curves that end a tween early or never, zero-duration actions in and at the end of a sequence,
    /// `Float` durations drifting against the frame clock.
    @Test func spriteKitTimingRulesMatch() {
        let x = { (d: TimeInterval) in Tween.moveBy(dx: 1, dy: 0, duration: d) }
        let jump = Tween.moveTo(x: 0, y: nil, duration: 0)
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
            // `timed` around containers: the curve remaps the container's clock; past its time it finishes
            // even when the curve falls short; around repeatForever SpriteKit ignores it.
            ("timed sequence", .timed(.sequence([x(0.5), .moveBy(dx: 10, dy: 0, duration: 0.5)]), timing: { $0 * $0 })),
            ("timed group", .timed(.group([x(0.5), .moveBy(dx: 10, dy: 0, duration: 1)]), timing: { $0 * $0 })),
            ("timed sequence, early", .sequence([.timed(.sequence([x(0.5), .moveBy(dx: 10, dy: 0, duration: 0.5)]),
                                                        timing: { min(1, 2 * $0) }), x(1)])),
            ("timed sequence, short", .sequence([.timed(.sequence([x(0.5), .moveBy(dx: 10, dy: 0, duration: 0.5)]),
                                                        timing: { 0.5 * $0 }), x(1)])),
            ("timed group, short", .sequence([.timed(.group([x(1)]), timing: { 0.5 * $0 }), x(1)])),
            ("timed sequence, inner curve", .timed(.sequence([.timed(x(0.5), timing: { $0 * $0 }), x(0.5)]), timing: { $0 * $0 })),
            ("timed repeatForever", .timed(.repeatForever(x(0.5)), timing: { $0 * $0 })),
            ("timed loop of sequences", .repeatForever(.timed(.sequence([x(0.3), .fadeAlpha(to: 0.2, duration: 0.3)]),
                                                              timing: { $0 * $0 * (3 - 2 * $0) }))),
            // A zero-duration member at the end of a timed container completes one step after the container's
            // time (or its curve) is up, as in SpriteKit.
            ("timed, trailing jump", .sequence([.timed(.sequence([.moveTo(x: 16, y: nil, duration: 0.5), jump]),
                                                       timing: { $0 * $0 }), .wait(1)])),
            ("timed, trailing jump, early", .sequence([.timed(.sequence([.moveTo(x: 16, y: nil, duration: 0.5), jump]),
                                                              timing: { min(1, 2 * $0) }), x(1)])),
            ("timed, trailing jump, short", .sequence([.timed(.sequence([.moveTo(x: 16, y: nil, duration: 0.5), jump]),
                                                              timing: { 0.5 * $0 }), x(1)])),
            ("timed, two trailing jumps", .sequence([.timed(.sequence([.moveTo(x: 16, y: nil, duration: 0.5), jump,
                                                                       .moveTo(x: 5, y: nil, duration: 0)]), timing: { $0 * $0 }), x(1)])),
            ("timed group, trailing jump", .sequence([.timed(.group([.sequence([.moveTo(x: 16, y: nil, duration: 0.5), jump])]),
                                                             timing: { $0 * $0 }), x(1)])),
            ("loop of timed, trailing jump", .repeatForever(.timed(.sequence([x(0.3), jump]), timing: { $0 * $0 }))),
        ]
        Self.check(cases, frames: Self.frames)
    }

    /// Tweens run between frames, after the node has been animating for a while — the way `RobotSprite`
    /// starts its actions — including a same-key replacement mid-loop.
    @Test func tweensStartedMidStreamMatchSpriteKit() {
        let bob = Tween.repeatForever(.sequence([.moveBy(dx: 0, dy: 2, duration: 0.3), .moveBy(dx: 0, dy: -2, duration: 0.3)]))
        let late: Script = [7: [(.moveBy(dx: 60, dy: 0, duration: 1), nil)]]
        let fade = Tween.repeatForever(.fadeAlpha(to: 0.1, duration: 0.25))
        let replaced: Script = [0: [(bob, "k")], 13: [(fade, "k")], 41: [(.moveBy(dx: 5, dy: 0, duration: 0.2), "k")]]
        let flip = Tween.sequence([.moveTo(x: 3, y: nil, duration: 0), .scaleX(to: -1, duration: 0.4)])
        let beside: Script = [0: [(bob, "idle")], 9: [(.rotateTo(1, duration: 0.5), "act")], 30: [(flip, "act")]]
        var scripts: [(String, Script)] = [("late start", late), ("same key replaces", replaced), ("added beside", beside)]
        for (i, c) in Self.cases.enumerated() {
            let robot: Script = [0: [(bob, "idle")], 5 + i % 40: [(c.1, "act")]]
            scripts.append(("late " + c.0, robot))
        }
        Self.check(scripts.map(\.0), scripts.map(\.1), times: (0...Self.frames).map { Double($0) / 60 })
    }

    /// After a long pause (an app woken from sleep: one update 3600 s after the last) every loop lands at the
    /// same phase as in SpriteKit, and carries on from there.
    @Test func aLongPauseLandsAtSpriteKitsPhase() {
        let before: [Double] = (0...3).map { Double($0) / 60 }
        let after: [Double] = (0...30).map { 3600 + Double($0) / 60 }
        let times = before + after
        let x = { (d: TimeInterval) in Tween.moveBy(dx: 1, dy: 0, duration: d) }
        let extra: [(String, Tween)] = [
            ("loop moveBy 0.7", .repeatForever(x(0.7))),
            ("loop 0.01", .repeatForever(.sequence([x(0.004), .moveTo(x: nil, y: 5, duration: 0.006)]))),
            ("loop moveTo", .repeatForever(.sequence([.moveTo(x: 5, y: nil, duration: 0.3), .moveTo(x: 0, y: nil, duration: 0.4)]))),
            ("loop of timed, trailing jump", .repeatForever(.timed(.sequence([x(0.3), .moveTo(x: 0, y: nil, duration: 0)]),
                                                                   timing: { $0 * $0 }))),
        ]
        let cases = extra + Self.cases
        let scripts: [Script] = cases.map { [0: [($0.1, nil)]] }
        Self.check(cases.map(\.0), scripts, times: times, floatSlack: true)
    }

    /// Block call counts, after every update, for loops and timed containers that end in a `run` — frame by
    /// frame and through a long pause.
    @Test func blocksRunAsOftenAsSpriteKit() {
        let shapes: [(String, (@escaping () -> Void) -> Tween)] = [
            ("loop wait, run", { f in .repeatForever(.sequence([.wait(0.5), .run(f)])) }),
            ("loop custom", { f in .repeatForever(.custom(duration: 1.2) { _, _ in f() }) }),
            ("timed, trailing run", { f in .timed(.sequence([.wait(0.5), .run(f)]), timing: { $0 * $0 }) }),
            ("timed, trailing run, early", { f in .timed(.sequence([.wait(0.5), .run(f)]), timing: { min(1, 2 * $0) }) }),
            ("timed, trailing run, short", { f in .timed(.sequence([.wait(0.5), .run(f)]), timing: { 0.5 * $0 }) }),
            ("loop of timed, trailing run", { f in .repeatForever(.timed(.sequence([.moveBy(dx: 1, dy: 0, duration: 0.3), .run(f)]),
                                                                         timing: { $0 })) }),
            ("loop of timed, trailing run, eased", { f in .repeatForever(.timed(.sequence([.wait(0.3), .run(f)]),
                                                                                timing: { $0 * $0 })) }),
        ]
        let frames: [Double] = (0...150).map { Double($0) / 60 }
        let pause: [Double] = [3600, 3600 + 1.0 / 60, 3600 + 2.0 / 60]
        for (name, make) in shapes {
            let renderer = SKRenderer(device: MTLCreateSystemDefaultDevice()!)
            let scene = SKScene(size: CGSize(width: 200, height: 200))
            renderer.scene = scene
            var skCalls = 0, calls = 0
            let a = SKNode(), b = SceneNode()
            a.run(.from(make { skCalls += 1 }))
            b.run(make { calls += 1 })
            scene.addChild(a)
            let times = frames + pause
            for (i, t) in times.enumerated() {
                renderer.update(atTime: 1000 + t)
                TweenEngine.step(b, dt: i == 0 ? 0 : t - times[i - 1])
                #expect(calls == skCalls, "\(name) after \(t) s: SpriteKit \(skCalls), engine \(calls)")
                #expect(abs(a.position.x - b.position.x) <= 0.002 + 1e-6 * abs(a.position.x), "\(name) after \(t) s: x")
            }
            print("TweenParity blocks \(name): \(skCalls) calls in SpriteKit, \(calls) in the engine")
        }
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
