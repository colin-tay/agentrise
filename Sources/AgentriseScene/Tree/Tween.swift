// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A description of an animation, with `SKAction`'s semantics (see `TweenEngine`). Values are in scene space:
/// points with y up, rotation in radians counter-clockwise.
package indirect enum Tween {
    /// Adds `(dx, dy)` to the position over `duration`, frame by frame (so other moves combine with it).
    case moveBy(dx: CGFloat, dy: CGFloat, duration: TimeInterval)
    /// Moves to `x` / `y` (nil leaves that axis alone) from wherever the node is when the tween starts.
    case moveTo(x: CGFloat?, y: CGFloat?, duration: TimeInterval)
    /// `SKAction.rotate(toAngle:duration:shortestUnitArc: false)`: straight from the start angle, no wrapping.
    case rotateTo(CGFloat, duration: TimeInterval)
    case fadeAlpha(to: CGFloat, duration: TimeInterval)
    case scaleX(to: CGFloat, duration: TimeInterval)
    case scaleY(to: CGFloat, duration: TimeInterval)
    case wait(TimeInterval)
    /// One after another; time left over when one finishes carries into the next.
    case sequence([Tween])
    /// All at once; lasts as long as the longest.
    case group([Tween])
    case repeatForever(Tween)
    /// Calls the block every step with the node and the elapsed time (clamped to `duration`).
    case custom(duration: TimeInterval, (SceneNode, TimeInterval) -> Void)
    /// Calls the block once, taking no time.
    case run(() -> Void)
    /// `SKAction.timingFunction`: maps the wrapped tween's linear progress (0…1) to the progress it shows.
    case timed(Tween, timing: (Double) -> Double)

    /// Seconds for one run; `.infinity` for `repeatForever`.
    package var duration: TimeInterval {
        switch self {
        case let .moveBy(_, _, d), let .moveTo(_, _, d), let .rotateTo(_, d), let .fadeAlpha(_, d),
             let .scaleX(_, d), let .scaleY(_, d), let .wait(d), let .custom(d, _):
            return max(0, d)
        case let .sequence(ts): return ts.reduce(0) { $0 + $1.duration }
        case let .group(ts): return ts.map(\.duration).max() ?? 0
        case .repeatForever: return .infinity
        case .run: return 0
        case let .timed(t, _): return t.duration
        }
    }
}
