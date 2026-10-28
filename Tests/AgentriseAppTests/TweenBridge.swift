// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import SpriteKit
import AgentriseScene

/// Test-only: turns a portable `Tween` into the SKAction it stands for (the very SKActions `RobotMotion` used to
/// build itself), so `TweenParityTests` can run both and compare. The app has no bridge: `TweenEngine` runs
/// every tween and SpriteKit only draws.
extension SKAction {
    static func from(_ t: Tween) -> SKAction {
        switch t {
        case let .moveBy(dx, dy, d):
            return .moveBy(x: dx, y: dy, duration: d)
        case let .moveTo(x?, y?, d):
            return .move(to: CGPoint(x: x, y: y), duration: d)
        case let .moveTo(x?, nil, d):
            return .moveTo(x: x, duration: d)
        case let .moveTo(nil, y?, d):
            return .moveTo(y: y, duration: d)
        case let .moveTo(nil, nil, d):
            return .wait(forDuration: d)
        case let .rotateTo(a, d):
            return .rotate(toAngle: a, duration: d, shortestUnitArc: false)
        case let .fadeAlpha(a, d):
            return .fadeAlpha(to: a, duration: d)
        case let .scaleX(s, d):
            return .scaleX(to: s, duration: d)
        case let .scaleY(s, d):
            return .scaleY(to: s, duration: d)
        case let .wait(d):
            return .wait(forDuration: d)
        case let .sequence(ts):
            return .sequence(ts.map(from))
        case let .group(ts):
            return .group(ts.map(from))
        case let .repeatForever(inner):
            return .repeatForever(from(inner))
        case let .custom(d, block):
            // The block works on a SceneNode: hand it a stand-in carrying the SKNode's state, and copy back
            // whatever it changed.
            return .customAction(withDuration: d) { node, elapsed in
                let proxy = SceneNode(name: node.name)
                proxy.position = node.position
                proxy.zPosition = node.zPosition
                proxy.alpha = node.alpha
                proxy.xScale = node.xScale
                proxy.yScale = node.yScale
                proxy.zRotation = node.zRotation
                proxy.isHidden = node.isHidden
                block(proxy, TimeInterval(elapsed))
                node.name = proxy.name
                node.position = proxy.position
                node.zPosition = proxy.zPosition
                node.alpha = proxy.alpha
                node.xScale = proxy.xScale
                node.yScale = proxy.yScale
                node.zRotation = proxy.zRotation
                node.isHidden = proxy.isHidden
            }
        case let .run(block):
            return .run(block)
        case let .timed(inner, timing):
            let a = from(inner)
            a.timingFunction = { Float(timing(Double($0))) }
            return a
        }
    }
}
