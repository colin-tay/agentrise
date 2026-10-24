import AppKit
import SpriteKit

/// The old Core Animation `loop(...)` calls (`Robot.swift` @ 6535b39: `build()` idle loops, `setFace` blink,
/// `setBubble` pulse and `setAction`) ported one-to-one to SKActions.
///
/// Values are written exactly as in the old code, in robot design space (y down, `P()` adds the 14 pt
/// headroom); the channels convert them to the robot node's SpriteKit space (origin at the bottom centre of
/// the 60×84 canvas, y up), so y translations and z rotations change sign there.
///
/// Every old loop was a `CAKeyframeAnimation` with one `easeInEaseOut` timing function over the whole
/// duration (not per keyframe), linear between keyframes, optionally autoreversed, and started
/// `phase` seconds into its cycle (`timeOffset`). `loop(...)` reproduces all of that: the keyframes land
/// where CA's eased clock put them, each segment carries the matching slice of CA's ease curve, and the
/// phase starts the action mid-cycle instead of waiting.
enum RobotMotion {
    /// Old `P(x, y)`: design point with the 14 pt headroom added.
    static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y + 14) }

    /// Robot design space (60×84 canvas, y down) → the robot node's space (bottom centre, y up).
    static func robotPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - 30, y: 84 - p.y) }

    /// Sleeping: old `floatGroup.transform = translate(3, 6) · scale(0.9)` about the canvas centre (30, 42),
    /// i.e. q ↦ (30, 42) + 0.9·(q − (30, 42)) + (2.7, 5.4). But the float group's idle bob animates
    /// `transform.translation.y`, which replaces that y translation on screen, so what the old robot actually
    /// showed was q ↦ (30, 42) + 0.9·(q − (30, 42)) + (2.7, bob). With the float node's children in robot
    /// space and the node scaled about its own position, that is scale 0.9 at (2.7, 4.2), plus the bob.
    static let sleepingFloatScale: CGFloat = 0.9
    static let sleepingFloatPosition = CGPoint(x: 2.7, y: 4.2)

    // MARK: Idle

    /// Loops that run all the time: ears breathe, the neck ring glows, the body bobs, hands bob
    /// out of step, and open eyes blink (RobotSprite runs `eyes` only for the focused/calm faces).
    static func idle(phase p: TimeInterval) -> [(part: String, action: SKAction)] {
        [("ears", loop(Ch.alpha, [1, 0.35], 1.6, autoreverse: true, phase: p)),
         ("ring", loop(Ch.alpha, [1, 0.4], 1.6, autoreverse: true, phase: p)),
         ("float", loop(Ch.ty, [0, -2.5, 0], 2.6, phase: p)),
         ("leftHand", loop(Ch.ty, [0, -1.5, 0], 2.2, phase: p + 0.4)),
         ("rightHand", loop(Ch.ty, [0, -1.5, 0], 2.2, phase: p + 1.1)),
         ("eyes", loop(Ch.scaleY, [1, 1, 0.1, 1, 1], 4, times: [0, 0.46, 0.5, 0.54, 1], phase: p))]
    }

    /// The status bubble's glow: old `shadowOpacity [0, 1]` over 0.6 s, autoreversed.
    static func pulse() -> SKAction { loop(Ch.alpha, [0, 1], 0.6, autoreverse: true) }

    // MARK: Room actions

    /// A prop shown during an action, centred on `at` (design space, like the old layer `position`).
    struct Prop {
        enum Art { case emoji(String, size: CGFloat), doorSign }
        let name: String
        let art: Art
        let at: CGPoint
        var tint: NSColor? = nil
    }

    static func props(_ a: Activity) -> [Prop] {
        switch a {
        case .reading: return [Prop(name: "book", art: .emoji("📖", size: 15), at: P(30, 50))]
        case .searching: return [Prop(name: "lens", art: .emoji("🔍", size: 13), at: P(30, 8))]
        case .coding, .other: return [Prop(name: "laptop", art: .emoji("💻", size: 14), at: P(30, 60))]
        case .runningCommand: return [Prop(name: "wrench", art: .emoji("🔧", size: 13), at: P(56, 44))]
        case .commandFailed: return [Prop(name: "smoke", art: .emoji("💨", size: 13), at: P(30, -2))]
        case .browsing: return [Prop(name: "globe", art: .emoji("🌐", size: 15), at: P(4, 36))]
        case .planning: return [Prop(name: "memo", art: .emoji("📝", size: 12), at: P(54, 46))]
        case .delegating: return [Prop(name: "chart", art: .emoji("📊", size: 13), at: P(56, 30))]
        case .sendingLark: return [Prop(name: "envelope", art: .emoji("✉️", size: 13), at: P(52, 40))]
        case .thinking: return [Prop(name: "dots", art: .emoji("…", size: 14), at: P(46, 2))]
        case .compacting: return [Prop(name: "box", art: .emoji("📦", size: 13), at: P(54, 54)),
                                  Prop(name: "paper", art: .emoji("📄", size: 10), at: P(54, 30))]
        case .waitingAtDoor: return [Prop(name: "sign", art: .doorSign, at: P(56, 26))]
        case .reporting: return [Prop(name: "report", art: .emoji("📋", size: 13), at: P(56, 30))]
        case .waitingForSubs: return [Prop(name: "hourglass", art: .emoji("⏳", size: 13), at: P(48, 4))]
        case .resting: return [Prop(name: "cup", art: .emoji("☕", size: 13), at: P(52, 44))]
        case .sleeping:
            return (0..<2).map { i in
                Prop(name: "z\(i)", art: .emoji("z", size: CGFloat(10 + i * 3)), at: P(44 + CGFloat(i) * 4, 20),
                     tint: NSColor(hex: 0xCFC8FF))
            }
        case .briefing, .standby: return []
        }
    }

    /// Parts whose idle loop the action replaces. The old act animation used the same key path as the
    /// idle one (`transform.translation.y`), so it overrode it rather than adding to it.
    static func replacesIdle(_ a: Activity) -> Set<String> {
        switch a {
        case .coding, .other: return ["leftHand", "rightHand"]
        case .planning, .delegating, .reporting, .thinking: return ["rightHand"]
        case .waitingAtDoor: return ["float"]
        default: return []
        }
    }

    /// The action loops, keyed by part name (fixed parts, `rig` for the whole robot, or a prop's name).
    /// A part with several loops gets them as one group.
    static func act(_ a: Activity, waitingLong: Bool) -> [(part: String, action: SKAction)] {
        var list: [(String, SKAction)] = []
        switch a {
        case .reading:
            list = [("head", loop(Ch.rotation, [-0.1, 0.1], 1.2, autoreverse: true)),
                    ("book", loop(Ch.scaleX, [1, 1, -1, 1], 3, times: [0, 0.8, 0.9, 1]))]
        case .searching:
            list = [("lens", loop(Ch.posX, [8, 52], 1.6, autoreverse: true))]
        case .coding, .other:
            list = [("leftHand", loop(Ch.ty, [0, -2.5], 0.18, autoreverse: true)),
                    ("rightHand", loop(Ch.ty, [0, -2.5], 0.18, autoreverse: true, phase: 0.09))]
        case .runningCommand:
            list = [("wrench", loop(Ch.rotation, [-0.6, 0.4], 0.35, autoreverse: true))]
        case .commandFailed:
            list = [("smoke", loop(Ch.posY, [P(0, 4).y, P(0, -12).y], 1.4)),
                    ("smoke", loop(Ch.alpha, [1, 0], 1.4)),
                    // The old shake moved the whole robot layer; `rig` is everything under the robot node,
                    // so the scene can keep owning the robot's `position`.
                    ("rig", loop(Ch.tx, [-1, 1], 0.12, autoreverse: true))]
        case .browsing:
            list = [("globe", loop(Ch.rotation, [0, -2 * .pi], 4)),
                    ("leftHand", loop(Ch.tx, [0, -4], 0.6, autoreverse: true))]
        case .planning:
            list = [("rightHand", loop(Ch.ty, [0, -4], 0.3, autoreverse: true))]
        case .delegating:
            list = [("rightHand", loop(Ch.ty, [-6, -11], 0.8, autoreverse: true))]
        case .reporting:
            // Holds the report up at the CEO's door, like presenting at a meeting.
            list = [("rightHand", loop(Ch.ty, [-6, -11], 0.8, autoreverse: true)),
                    ("report", loop(Ch.posY, [P(0, 30).y, P(0, 26).y], 0.8, autoreverse: true))]
        case .briefing:
            // The old code also added a rotation.x nod, but under the same "act" key, so the translation
            // replaced it and only the dip ever ran.
            list = [("head", loop(Ch.ty, [0, 1.5], 0.45, autoreverse: true))]
        case .sendingLark:
            list = [("envelope", loop(Ch.pos, [P(52, 42), P(60, -14)], 1.4)),
                    ("envelope", loop(Ch.alpha, [1, 1, 0], 1.4, times: [0, 0.7, 1]))]
        case .thinking:
            list = [("dots", loop(Ch.alpha, [0.3, 1], 0.6, autoreverse: true)),
                    ("rightHand", loop(Ch.ty, [-9, -10], 1, autoreverse: true))]
        case .compacting:
            list = [("paper", loop(Ch.posY, [P(0, 30).y, P(0, 50).y], 1.2))]
        case .waitingAtDoor:
            let speed = waitingLong ? 0.28 : 0.6
            list = [("float", loop(Ch.ty, [0, -4], speed, autoreverse: true)),
                    ("sign", loop(Ch.rotation, [-0.25, 0.25], speed, autoreverse: true))]
        case .waitingForSubs:
            // The hourglass turns over every few seconds while the boss waits for the team.
            list = [("hourglass", loop(Ch.rotation, [0, 0, .pi], 2.4, times: [0, 0.75, 1]))]
        case .resting:
            list = [("cup", loop(Ch.rotation, [0, 0, 0.5, 0.5, 0], 3, times: [0, 0.55, 0.65, 0.85, 1]))]
        case .sleeping:
            for (i, d) in [0.0, 1.2].enumerated() {
                list.append(("z\(i)", loop(Ch.pos, [P(42, 34), P(56, 12)], 2.4, phase: d)))
                list.append(("z\(i)", loop(Ch.alpha, [0, 1, 0], 2.4, phase: d)))
            }
        case .standby:
            break
        }
        var order: [String] = []
        var byPart: [String: [SKAction]] = [:]
        for (part, action) in list {
            if byPart[part] == nil { order.append(part) }
            byPart[part, default: []].append(action)
        }
        return order.map { part in
            let actions = byPart[part]!
            return (part, actions.count == 1 ? actions[0] : .group(actions))
        }
    }

    // MARK: Core Animation's ease-in-ease-out

    /// `kCAMediaTimingFunctionEaseInEaseOut`, the cubic Bézier (0.42, 0) (0.58, 1): progress at time `x`.
    /// Every running loop calls this each frame, so it reads a precomputed table (linear interpolation;
    /// error < 1e-6) instead of solving the Bézier.
    static func caEase(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let f = x * Double(easeSteps)
        let i = min(Int(f), easeSteps - 1)
        let a = easeTable[i], b = easeTable[i + 1]
        return a + (b - a) * (f - Double(i))
    }

    /// The exact curve, by bisection (builds the table; the tests compare against it).
    static func caEaseExact(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return bezierY(solve(x, bezierX))
    }

    private static let easeSteps = 1024
    private static let easeTable: [Double] = (0...easeSteps).map { caEaseExact(Double($0) / Double(easeSteps)) }

    /// The time at which the CA ease curve reaches progress `y`.
    static func caEaseInverse(_ y: Double) -> Double {
        if y <= 0 { return 0 }
        if y >= 1 { return 1 }
        return bezierX(solve(y, bezierY))
    }

    private static func bezierX(_ s: Double) -> Double { let m = 1 - s; return 3 * m * m * s * 0.42 + 3 * m * s * s * 0.58 + s * s * s }
    private static func bezierY(_ s: Double) -> Double { let m = 1 - s; return 3 * m * s * s + s * s * s }

    /// The Bézier parameter where the (monotonic) coordinate `f` equals `v`.
    private static func solve(_ v: Double, _ f: (Double) -> Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            if f(mid) < v { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: Keyframe loops

    /// Old `loop(key, values, duration, times:, autoreverse:, phase:)` as an endless SKAction on `ch`.
    fileprivate static func loop<V: KeyValue>(_ ch: Channel<V>, _ values: [V], _ duration: TimeInterval,
                                               times: [Double]? = nil, autoreverse: Bool = false,
                                               phase: TimeInterval = 0) -> SKAction {
        let n = values.count
        let k = times ?? (0..<n).map { Double($0) / Double(n - 1) }
        let t = k.map(caEaseInverse)   // where CA's eased clock reaches each keyframe
        var segs: [Segment<V>] = []
        for i in 0..<(n - 1) {
            let (t0, t1, k0, k1) = (t[i], t[i + 1], k[i], k[i + 1])
            let timing: (Double) -> Double = n == 2 ? caEase : { u in
                k1 > k0 ? (caEase(t0 + u * (t1 - t0)) - k0) / (k1 - k0) : u
            }
            segs.append(Segment(from: values[i], to: values[i + 1], duration: (t1 - t0) * duration, timing: timing))
        }
        if autoreverse {
            segs += segs.reversed().map { s in
                Segment(from: s.to, to: s.from, duration: s.duration, timing: { u in 1 - s.timing(1 - u) })
            }
        } else if values[n - 1] != values[0] {
            segs.append(Segment(from: values[n - 1], to: values[0], duration: 0, timing: { $0 }))   // jump back
        }

        // `timeOffset = phase`: start `phase` seconds into the cycle, partway through one segment.
        let period = segs.reduce(0) { $0 + $1.duration }
        var local = phase.truncatingRemainder(dividingBy: period)
        if local < 0 { local += period }
        var start = values[0]
        var lead: [Segment<V>] = []
        if local > 1e-9 {
            var acc = 0.0
            for (i, s) in segs.enumerated() where s.duration > 0 {
                if local < acc + s.duration {
                    let u0 = (local - acc) / s.duration, e0 = s.timing(u0)
                    start = V.lerp(s.from, s.to, CGFloat(e0))
                    let rest: (Double) -> Double = { u in e0 < 1 ? (s.timing(u0 + u * (1 - u0)) - e0) / (1 - e0) : u }
                    lead = [Segment(from: start, to: s.to, duration: s.duration * (1 - u0), timing: rest)] + segs[(i + 1)...]
                    break
                }
                acc += s.duration
            }
        }
        let cycle = SKAction.repeatForever(.sequence(segs.map { action(ch, $0) }))
        return .sequence([ch.make(.zero, start, 0)] + lead.map { action(ch, $0) } + [cycle])
    }

    private static func action<V>(_ ch: Channel<V>, _ s: Segment<V>) -> SKAction {
        if s.from == s.to { return .wait(forDuration: s.duration) }
        let a = ch.make(s.from, s.to, s.duration)
        let timing = s.timing
        a.timingFunction = { Float(timing(Double($0))) }
        return a
    }
}

// MARK: - Keyframe plumbing

fileprivate protocol KeyValue: Equatable {
    static var zero: Self { get }
    static func lerp(_ a: Self, _ b: Self, _ t: CGFloat) -> Self
}

extension CGFloat: KeyValue {
    fileprivate static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

extension CGPoint: KeyValue {
    fileprivate static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// One stretch of a loop: `from` → `to` over `duration`, paced by `timing` (progress for time, both 0…1).
fileprivate struct Segment<V: KeyValue> {
    let from: V
    let to: V
    let duration: TimeInterval
    let timing: (Double) -> Double
}

/// How a keyframe value drives a node. Relative channels (translations) move by the difference, so the
/// action leaves the node where it found it after each cycle; the rest set absolute values.
/// `make(.zero, v, 0)` is the initial jump to `v`.
fileprivate struct Channel<V: KeyValue> {
    let make: (_ from: V, _ to: V, _ duration: TimeInterval) -> SKAction
}

/// The old key paths. Design space is y down, so y translations and z rotations flip sign.
fileprivate enum Ch {
    /// `transform.translation.y`
    static let ty = Channel<CGFloat> { a, b, d in .moveBy(x: 0, y: -(b - a), duration: d) }
    /// `transform.translation.x`
    static let tx = Channel<CGFloat> { a, b, d in .moveBy(x: b - a, y: 0, duration: d) }
    /// `transform.rotation.z`
    static let rotation = Channel<CGFloat> { _, b, d in .rotate(toAngle: -b, duration: d, shortestUnitArc: false) }
    /// `opacity`
    static let alpha = Channel<CGFloat> { _, b, d in .fadeAlpha(to: b, duration: d) }
    /// `transform.scale.x` / `transform.scale.y`
    static let scaleX = Channel<CGFloat> { _, b, d in .scaleX(to: b, duration: d) }
    static let scaleY = Channel<CGFloat> { _, b, d in .scaleY(to: b, duration: d) }
    /// `position.x` / `position.y` / `position` of a prop, in design space.
    static let posX = Channel<CGFloat> { _, b, d in .moveTo(x: b - 30, duration: d) }
    static let posY = Channel<CGFloat> { _, b, d in .moveTo(y: 84 - b, duration: d) }
    static let pos = Channel<CGPoint> { _, b, d in .move(to: RobotMotion.robotPoint(b), duration: d) }
}
