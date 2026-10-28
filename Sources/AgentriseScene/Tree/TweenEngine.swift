// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Runs `SceneNode` tweens the way SpriteKit runs the equivalent SKActions, down to SpriteKit's rounding,
/// because the recorded motion baselines hold SpriteKit's exact frames. Each rule below was measured against
/// SpriteKit (`TweenParityTests` keeps checking them):
/// - `moveBy` adds its increments frame by frame; `moveTo`, `fadeAlpha`, `scaleX/Y` and `rotateTo` start from
///   the node's value at the moment the tween starts.
/// - Durations are `Float`s: a 1.4 s tween lasts `Double(Float(1.4))` (a hair less; 1.2 s a hair more), so
///   endless loops drift against the frame clock by that much per cycle.
/// - A sequence carries the time left over when one member finishes into the next (likewise `repeatForever`
///   from cycle to cycle). Members other than the last see the sequence's clock rounded to `Float`; the last
///   sees it exactly, but never less than the amount by which its start rounds up in `Float`. A member that
///   follows one ended early by its curve starts at that moment, rounded to `Float`.
/// - A group lasts as long as its longest member and stops touching the node for members that finished.
/// - `timed` remaps progress through the curve in `Float`, like `SKAction.timingFunction`, and a timed tween
///   is done when its *eased* progress reaches 1, not when its time runs out: a curve that reaches 1 early
///   ends the tween early (nothing carried over), one that stops short of 1 (even by 1e-7) never ends,
///   holding its last value and stalling whatever follows.
/// - A zero-duration tween at the start of a sequence (or run on its own) applies at once. Anywhere else it
///   takes no time but is only done once its local clock reaches 1e-6 s; until then it shows progress
///   `local / 1e-6`. Together with the `Float` drift this gives the one-frame partial jump SpriteKit shows at
///   the end of some loop cycles.
/// - A new tween with a running tween's key replaces it.
package enum TweenEngine {
    /// Advances every tween in the tree under `root` (root included, hidden nodes too) by `dt` seconds.
    /// Tweens run in the order they were added, parents before children. Blocks may edit the tree: nodes
    /// removed during the step are skipped, nodes added during it start on the next step.
    package static func step(_ root: SceneNode, dt: TimeInterval) {
        visit(root, dt: max(0, dt))
    }

    private static func visit(_ n: SceneNode, dt: TimeInterval) {
        for r in n.tweens where n.tweens.contains(where: { $0 === r }) {
            r.elapsed += dt
            if case .running = r.runner.update(n, r.elapsed) { continue }
            n.tweens.removeAll { $0 === r }
        }
        for c in n.children where c.parent === n { visit(c, dt: dt) }
    }

    /// A tween running on a node: its key, its clock, and the runner that applies it.
    final class Running {
        let key: String?
        let runner: Runner
        var elapsed: TimeInterval = 0

        init(key: String?, tween: Tween) {
            self.key = key
            runner = makeRunner(tween, timing: nil, leading: true)
        }
    }
}

// MARK: - Runners

/// The live state of one tween. `update(node, local)` shows it `local` seconds after it started (`local` never
/// decreases) and says whether it is done. The first call starts the tween (absolute tweens read their start
/// value then).
protocol Runner: AnyObject {
    func update(_ node: SceneNode, _ local: TimeInterval) -> Progress
}

enum Progress {
    case running
    /// Done at this local time; a sequence carries whatever is left of the step into the next member.
    case ended(at: TimeInterval)
    /// Done right now, by its timing curve rather than its clock: the next member starts at this very moment.
    case endedNow
}

/// `leading`: the tween starts together with its parent (first in a sequence, in a group, a loop's cycle, or a
/// root), which is when a zero-duration tween applies at once.
private func makeRunner(_ t: Tween, timing: ((Double) -> Double)?, leading: Bool) -> Runner {
    switch t {
    case .sequence(let ts): return wrap(SequenceRunner(ts), t, timing)
    case .group(let ts): return wrap(GroupRunner(ts), t, timing)
    case .repeatForever(let inner): return RepeatRunner(inner)
    case let .timed(inner, f):
        // Nested: the outer curve wins, as the bridge sets `timingFunction` on the same SKAction last.
        return makeRunner(inner, timing: timing ?? f, leading: leading)
    default: return LeafRunner(t, timing: timing, leading: leading)
    }
}

private func wrap(_ r: Runner, _ t: Tween, _ timing: ((Double) -> Double)?) -> Runner {
    guard let timing else { return r }
    return TimedContainerRunner(r, duration: spriteKitDuration(t.duration), timing: timing)
}

/// SpriteKit keeps durations as `Float`.
private func spriteKitDuration(_ d: TimeInterval) -> TimeInterval { d.isFinite ? Double(Float(max(0, d))) : d }

/// How long a zero-duration tween that is not leading waits before it counts as done.
private let zeroDurationSpan: TimeInterval = 1e-6

/// Progress through the timing curve in `Float`: what to show (at most 1) and whether the curve says done.
private func eased(_ u: Double, _ timing: ((Double) -> Double)?) -> (p: Double, done: Bool) {
    guard let timing else { return (u, u >= 1) }
    let f = Float(timing(Double(Float(u))))
    return (Double(min(f, 1)), f >= 1)
}

private final class LeafRunner: Runner {
    private let tween: Tween
    private let duration: TimeInterval
    private let timing: ((Double) -> Double)?
    private let leading: Bool
    private var started = false
    private var from: CGPoint = .zero   // start value (x, y), or (value, unused) for the scalar tweens
    private var last: CGFloat = 0       // moveBy: the progress already applied

    init(_ t: Tween, timing: ((Double) -> Double)?, leading: Bool) {
        tween = t
        duration = spriteKitDuration(t.duration)
        self.timing = timing
        self.leading = leading
    }

    func update(_ node: SceneNode, _ local: TimeInterval) -> Progress {
        let isStart = !started
        if isStart {
            started = true
            switch tween {
            case .moveTo: from = node.position
            case .rotateTo: from.x = node.zRotation
            case .fadeAlpha: from.x = node.alpha
            case .scaleX: from.x = node.xScale
            case .scaleY: from.x = node.yScale
            default: break
            }
        }
        let t = max(0, local)
        let u: Double
        if duration > 0 { u = min(t / duration, 1) }
        else { u = leading ? 1 : min(t / zeroDurationSpan, 1) }
        let (pd, done) = eased(u, timing)
        let p = CGFloat(pd)
        switch tween {
        case let .moveBy(dx, dy, _):
            let dp = p - last
            last = p
            node.position.x += dx * dp
            node.position.y += dy * dp
        case let .moveTo(x, y, _):
            if let x { node.position.x = from.x + (x - from.x) * p }
            if let y { node.position.y = from.y + (y - from.y) * p }
        case let .rotateTo(a, _): node.zRotation = from.x + (a - from.x) * p
        case let .fadeAlpha(a, _): node.alpha = from.x + (a - from.x) * p
        case let .scaleX(s, _): node.xScale = from.x + (s - from.x) * p
        case let .scaleY(s, _): node.yScale = from.x + (s - from.x) * p
        case .wait: break
        case .custom(_, let block): block(node, min(t, duration))
        case .run(let block): if isStart { block() }
        case .sequence, .group, .repeatForever, .timed: break   // built by makeRunner
        }
        guard done else { return .running }
        // Ran its full time: ends at its duration (zero-duration tweens take none). A curve that reached 1
        // early ends it here and now.
        return u >= 1 ? .ended(at: duration) : .endedNow
    }
}

private final class SequenceRunner: Runner {
    private let tweens: [Tween]
    private var index = 0
    private var start: TimeInterval = 0   // local time at which tweens[index] started
    private var current: Runner?

    init(_ ts: [Tween]) { tweens = ts }

    func update(_ node: SceneNode, _ local: TimeInterval) -> Progress {
        var startsNow = false
        while index < tweens.count {
            let isLast = index == tweens.count - 1
            let t: TimeInterval
            if startsNow {
                // The previous member ended by its curve: this one starts at this moment (kept as a `Float`).
                start = Double(Float(local))
                t = 0
            } else if isLast {
                // The last member sees the clock exactly, but never less than the amount by which its start
                // rounds up in `Float`.
                t = max(local - start, Double(Float(start)) - start)
            } else {
                // The others see it rounded to `Float`.
                t = Double(Float(local)) - start
            }
            startsNow = false
            let r = current ?? makeRunner(tweens[index], timing: nil, leading: index == 0)
            current = r
            switch r.update(node, t) {
            case .running: return .running
            case .ended(let end): start += end   // whatever is left of `local` carries into the next one
            case .endedNow: startsNow = true
            }
            index += 1
            current = nil
        }
        return startsNow ? .endedNow : .ended(at: start)
    }
}

private final class GroupRunner: Runner {
    private let runners: [Runner]
    private var ends: [TimeInterval?]

    init(_ ts: [Tween]) {
        runners = ts.map { makeRunner($0, timing: nil, leading: true) }
        ends = Array(repeating: nil, count: ts.count)
    }

    func update(_ node: SceneNode, _ local: TimeInterval) -> Progress {
        for (i, r) in runners.enumerated() where ends[i] == nil {
            switch r.update(node, local) {
            case .running: break
            case .ended(let end): ends[i] = end
            case .endedNow: ends[i] = local
            }
        }
        var latest: TimeInterval = 0
        for e in ends {
            guard let e else { return .running }
            latest = max(latest, e)
        }
        return .ended(at: latest)
    }
}

private final class RepeatRunner: Runner {
    private let inner: Tween
    private let period: TimeInterval
    private var cycleStart: TimeInterval = 0
    private var current: Runner

    init(_ t: Tween) {
        inner = t
        period = spriteKitDuration(t.duration)
        current = makeRunner(t, timing: nil, leading: true)
    }

    func update(_ node: SceneNode, _ local: TimeInterval) -> Progress {
        for _ in 0..<10_000 {
            let before = cycleStart
            switch current.update(node, local - cycleStart) {
            case .running: return .running
            case .ended(let end): cycleStart += end
            case .endedNow: cycleStart = local
            }
            current = makeRunner(inner, timing: nil, leading: true)
            // A cycle that took no time runs once per step rather than forever within one.
            if cycleStart <= before { break }
        }
        return .running
    }
}

/// `timed` around a sequence or group: runs the inner tween's clock through the timing curve.
private final class TimedContainerRunner: Runner {
    private let inner: Runner
    private let duration: TimeInterval
    private let timing: (Double) -> Double

    init(_ r: Runner, duration: TimeInterval, timing: @escaping (Double) -> Double) {
        inner = r
        self.duration = duration
        self.timing = timing
    }

    func update(_ node: SceneNode, _ local: TimeInterval) -> Progress {
        let t = max(0, local)
        let u = duration > 0 ? min(t / duration, 1) : 1
        let (p, done) = eased(u, timing)
        _ = inner.update(node, duration * p)
        guard done else { return .running }
        return u >= 1 ? .ended(at: duration) : .endedNow
    }
}
