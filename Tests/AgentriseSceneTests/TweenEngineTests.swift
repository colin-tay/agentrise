// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
@testable import AgentriseScene

@Suite struct TweenEngineTests {
    /// Durations are `Float`s, as in SpriteKit, so exact-looking values land within ~1e-7.
    private func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1e-6) -> Bool { abs(a - b) <= tol }

    /// A root with one child that runs `t`, returned as (root, child).
    private func tree(_ t: Tween, key: String? = nil) -> (SceneNode, SceneNode) {
        let root = SceneNode(name: "root"), n = SceneNode(name: "n")
        root.addChild(n)
        n.run(t, withKey: key)
        return (root, n)
    }

    // MARK: Scene tree

    @Test func defaultsMatchSpriteKit() {
        let n = SceneNode()
        #expect(n.name == nil)
        #expect(n.position == .zero && n.zPosition == 0 && n.zRotation == 0)
        #expect(n.alpha == 1 && n.xScale == 1 && n.yScale == 1)
        #expect(n.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(n.image == nil && !n.isHidden && n.children.isEmpty && n.parent == nil && !n.hasTweens)
    }

    @Test func addAndRemoveChildren() {
        let root = SceneNode(name: "root"), a = SceneNode(name: "a"), b = SceneNode(name: "b")
        root.addChild(a)
        root.addChild(b)
        #expect(root.children.map(\.name) == ["a", "b"])
        #expect(a.parent === root)
        a.removeFromParent()
        #expect(a.parent == nil && root.children.map(\.name) == ["b"])
        root.removeAllChildren()
        #expect(root.children.isEmpty && b.parent == nil)
    }

    @Test func childNodeWithNameFollowsSpriteKitSearchSyntax() {
        let root = SceneNode(name: "root"), rig = SceneNode(name: "rig"), float = SceneNode(name: "float")
        let head = SceneNode(name: "head"), eyes = SceneNode(name: "eyes"), other = SceneNode(name: "other")
        let deep = SceneNode(name: "deep")
        root.addChild(rig); rig.addChild(float); float.addChild(head); head.addChild(eyes)
        root.addChild(other); other.addChild(deep)
        // Plain name: direct children only.
        #expect(root.childNode(withName: "rig") === rig)
        #expect(root.childNode(withName: "head") == nil)
        #expect(head.childNode(withName: "eyes") === eyes)
        // ".//name": any descendant of self.
        #expect(rig.childNode(withName: ".//eyes") === eyes)
        #expect(rig.childNode(withName: ".//deep") == nil)
        #expect(rig.childNode(withName: ".//rig") == nil)
        // "//name": anywhere in the tree, searched from the root.
        #expect(eyes.childNode(withName: "//deep") === deep)
        #expect(root.childNode(withName: "//eyes") === eyes)
        // "/name": a child of the root; "a/b": a path of direct children.
        #expect(eyes.childNode(withName: "/other") === other)
        #expect(root.childNode(withName: "rig/float/head") === head)
        #expect(root.childNode(withName: "rig/head") == nil)
    }

    @Test func stepsEveryNodeInTheTreeIncludingHiddenOnes() {
        let root = SceneNode(), a = SceneNode(), b = SceneNode()
        root.addChild(a); a.addChild(b)
        a.isHidden = true
        for n in [root, a, b] { n.run(.moveBy(dx: 1, dy: 0, duration: 1)) }
        TweenEngine.step(root, dt: 0.5)
        #expect([root, a, b].allSatisfy { near($0.position.x, 0.5) })
    }

    @Test func sameKeyReplacesAndRemoveStops() {
        let (root, n) = tree(.moveBy(dx: 1, dy: 0, duration: 1), key: "k")
        n.run(.moveBy(dx: 10, dy: 0, duration: 1), withKey: "k")
        n.run(.fadeAlpha(to: 0, duration: 1))
        TweenEngine.step(root, dt: 0.5)
        #expect(near(n.position.x, 5) && near(n.alpha, 0.5))
        n.removeTween(forKey: "k")
        TweenEngine.step(root, dt: 0.25)
        #expect(near(n.position.x, 5) && near(n.alpha, 0.25))
        #expect(n.hasTweens)
        n.removeAllTweens()
        #expect(!n.hasTweens)
    }

    @Test func finishedTweensAreRemoved() {
        let (root, n) = tree(.wait(0.5))
        TweenEngine.step(root, dt: 0.4)
        #expect(n.hasTweens)
        TweenEngine.step(root, dt: 0.1)
        #expect(!n.hasTweens)
    }

    // MARK: One case at a time

    @Test func moveByAddsIncrements() {
        let (root, n) = tree(.moveBy(dx: 6, dy: -3, duration: 1))
        n.position = CGPoint(x: 10, y: 0)
        TweenEngine.step(root, dt: 0.25)
        #expect(near(n.position.x, 11.5) && near(n.position.y, -0.75))
        // Relative: someone else moving the node in between is kept.
        n.position.x += 100
        TweenEngine.step(root, dt: 0.75)
        #expect(near(n.position.x, 116) && near(n.position.y, -3))
        #expect(!n.hasTweens)
    }

    @Test func moveToStartsFromTheValueWhenTheTweenStarts() {
        let (root, n) = tree(.sequence([.wait(1), .moveTo(x: 10, y: nil, duration: 1)]))
        n.position = CGPoint(x: 0, y: 7)
        TweenEngine.step(root, dt: 0.5)
        n.position.x = 4   // changed before the move starts
        TweenEngine.step(root, dt: 1)
        #expect(near(n.position.x, 7))   // 4 + (10 − 4)·0.5
        #expect(near(n.position.y, 7))   // nil leaves y alone
        let (r2, m) = tree(.moveTo(x: 2, y: -4, duration: 2))
        TweenEngine.step(r2, dt: 1)
        #expect(m.position == CGPoint(x: 1, y: -2))
    }

    @Test func rotateToTakesTheLongWayRound() {
        let (root, n) = tree(.rotateTo(-2 * .pi, duration: 4))
        TweenEngine.step(root, dt: 1)
        #expect(near(n.zRotation, -.pi / 2))
        TweenEngine.step(root, dt: 3)
        #expect(near(n.zRotation, -2 * .pi))
    }

    @Test func fadeAlphaGoesFromTheCurrentAlpha() {
        let (root, n) = tree(.fadeAlpha(to: 0, duration: 2))
        n.alpha = 0.8
        TweenEngine.step(root, dt: 0.5)
        #expect(near(n.alpha, 0.6))
    }

    @Test func scaleXAndScaleY() {
        let (root, n) = tree(.group([.scaleX(to: -1, duration: 1), .scaleY(to: 0.1, duration: 2)]))
        TweenEngine.step(root, dt: 0.5)
        #expect(near(n.xScale, 0) && near(n.yScale, 0.775))
        TweenEngine.step(root, dt: 0.5)
        #expect(near(n.xScale, -1) && near(n.yScale, 0.55))
    }

    @Test func waitHoldsItsPlaceInASequence() {
        let (root, n) = tree(.sequence([.wait(0.5), .moveBy(dx: 1, dy: 0, duration: 0.5)]))
        TweenEngine.step(root, dt: 0.5)
        #expect(n.position.x == 0)
        TweenEngine.step(root, dt: 0.25)
        #expect(near(n.position.x, 0.5))
    }

    @Test func zeroDurationTweenAppliesOnTheFirstStep() {
        let (root, n) = tree(.sequence([.moveBy(dx: 0, dy: 3, duration: 0), .wait(1)]))
        TweenEngine.step(root, dt: 0)
        #expect(n.position.y == 3)
        let (r2, m) = tree(.rotateTo(1, duration: 0))
        TweenEngine.step(r2, dt: 0)
        #expect(m.zRotation == 1 && !m.hasTweens)
    }

    @Test func zeroDurationTweenLaterInASequenceNeedsAMicrosecond() {
        // SpriteKit: anywhere but first, a zero-duration action is done once 1e-6 s of its clock has passed,
        // showing `elapsed / 1e-6` until then, and takes no time from what follows.
        let (root, n) = tree(.sequence([.wait(1), .fadeAlpha(to: 0, duration: 0), .moveBy(dx: 1, dy: 0, duration: 1)]))
        TweenEngine.step(root, dt: 1)
        #expect(n.alpha == 1)
        let (r2, m) = tree(.sequence([.wait(1), .fadeAlpha(to: 0, duration: 0)]))
        TweenEngine.step(r2, dt: 1 + 2.5e-7)
        #expect(near(m.alpha, 0.75, 1e-3))
        TweenEngine.step(r2, dt: 1e-6)
        #expect(m.alpha == 0 && !m.hasTweens)
        TweenEngine.step(root, dt: 0.5)
        #expect(n.alpha == 0 && near(n.position.x, 0.5))
    }

    @Test func groupLastsAsLongAsItsLongestMember() {
        let (root, n) = tree(.group([.moveBy(dx: 1, dy: 0, duration: 1), .fadeAlpha(to: 0, duration: 2)]))
        TweenEngine.step(root, dt: 1.5)
        #expect(near(n.position.x, 1) && near(n.alpha, 0.25))
        #expect(n.hasTweens)
        TweenEngine.step(root, dt: 0.5)
        #expect(near(n.alpha, 0) && !n.hasTweens)
    }

    @Test func repeatForeverRestartsEachCycle() {
        let (root, n) = tree(.repeatForever(.moveBy(dx: 1, dy: 0, duration: 1)))
        TweenEngine.step(root, dt: 2.5)
        #expect(near(n.position.x, 2.5))
        #expect(n.hasTweens)
    }

    @Test func repeatForeverOfNothingDoesNotHang() {
        var count = 0
        let (root, n) = tree(.repeatForever(.run { count += 1 }))
        TweenEngine.step(root, dt: 1.0 / 60)
        TweenEngine.step(root, dt: 1.0 / 60)
        #expect(count == 2)
        #expect(n.hasTweens)
    }

    @Test func customGetsTheElapsedTime() {
        var seen: [TimeInterval] = []
        let (root, n) = tree(.custom(duration: 1) { node, t in node.alpha = CGFloat(t); seen.append(t) })
        TweenEngine.step(root, dt: 0.25)
        #expect(near(n.alpha, 0.25))
        TweenEngine.step(root, dt: 1)
        #expect(near(n.alpha, 1))   // clamped to the duration
        #expect(seen.count == 2 && !n.hasTweens)
    }

    @Test func runFiresOnceWhenReached() {
        var count = 0
        let (root, _) = tree(.sequence([.wait(0.5), .run { count += 1 }]))
        TweenEngine.step(root, dt: 0.4)
        #expect(count == 0)
        TweenEngine.step(root, dt: 0.2)
        #expect(count == 1)
        TweenEngine.step(root, dt: 1)
        #expect(count == 1)
    }

    @Test func timedPacesItsOwnProgress() {
        let (root, n) = tree(.sequence([.moveBy(dx: 1, dy: 0, duration: 1),
                                        .timed(.moveBy(dx: 1, dy: 0, duration: 1), timing: { $0 * $0 })]))
        TweenEngine.step(root, dt: 0.5)
        #expect(near(n.position.x, 0.5))   // the first segment is linear
        TweenEngine.step(root, dt: 1)
        #expect(near(n.position.x, 1.25))  // 1 + 0.5²
        TweenEngine.step(root, dt: 0.5)
        #expect(near(n.position.x, 2))
        // Absolute tweens too, and a timing curve that leaves 0…1 overshoots like SpriteKit's.
        let (r2, m) = tree(.timed(.fadeAlpha(to: 0, duration: 1), timing: { 1 - $0 }))
        TweenEngine.step(r2, dt: 0.25)
        #expect(near(m.alpha, 0.25))
    }

    @Test func timedEndsWhenItsCurveReachesOne() {
        // SpriteKit's rule: a curve that reaches 1 halfway ends the tween there, and the next starts then
        // (no time carried over).
        let (root, n) = tree(.sequence([.timed(.moveBy(dx: 1, dy: 0, duration: 0.5), timing: { min(1, 2 * $0) }),
                                        .moveBy(dx: 1, dy: 0, duration: 0.5)]))
        for _ in 0..<15 { TweenEngine.step(root, dt: 1.0 / 60) }   // 0.25 s
        #expect(near(n.position.x, 1))
        for _ in 0..<3 { TweenEngine.step(root, dt: 1.0 / 60) }    // 0.3 s
        #expect(near(n.position.x, 1.1))
    }

    @Test func timedNeverEndsWhenItsCurveStopsShortOfOne() {
        // …and one that ends at 0.9 never finishes: it holds its last value and stalls the sequence.
        let (root, n) = tree(.sequence([.timed(.moveBy(dx: 1, dy: 0, duration: 0.5), timing: { 0.9 * $0 }),
                                        .moveBy(dx: 1, dy: 0, duration: 0.5)]))
        TweenEngine.step(root, dt: 0.5)
        #expect(near(n.position.x, 0.9))
        TweenEngine.step(root, dt: 10)
        #expect(near(n.position.x, 0.9) && n.hasTweens)
    }

    // MARK: Time bookkeeping

    @Test func sequenceCarriesOvershoot() {
        // 0.1 s then 0.3 s: one 0.25 s step lands 0.15 s into the second segment, as if stepped finely.
        let t = Tween.sequence([.moveBy(dx: 1, dy: 0, duration: 0.1), .moveTo(x: 4, y: nil, duration: 0.3),
                                .fadeAlpha(to: 0, duration: 0.3)])
        let (coarse, a) = tree(t)
        TweenEngine.step(coarse, dt: 0.25)
        let (fine, b) = tree(t)
        for _ in 0..<25 { TweenEngine.step(fine, dt: 0.01) }
        #expect(near(a.position.x, 2.5))   // 1 + (4 − 1)·0.5
        #expect(near(a.position.x, b.position.x))
        TweenEngine.step(coarse, dt: 0.25)   // 0.5 s: 0.1 s into the fade
        #expect(near(a.position.x, 4) && near(a.alpha, 2.0 / 3))
    }

    @Test func repeatForeverIsSeamless() {
        // A 1 s cycle with a relative bob, an absolute fade and an eased stretch, stepped at 60 fps: after
        // 100 cycles every value is back where it started.
        let cycle = Tween.sequence([
            .timed(.moveBy(dx: 0, dy: 2.5, duration: 0.3), timing: { $0 * $0 * (3 - 2 * $0) }),
            .group([.moveBy(dx: 0, dy: -2.5, duration: 0.7),
                    .sequence([.fadeAlpha(to: 0.2, duration: 0.35), .fadeAlpha(to: 1, duration: 0.35)])]),
        ])
        let (root, n) = tree(.repeatForever(cycle))
        for _ in 0..<6000 { TweenEngine.step(root, dt: 1.0 / 60) }
        #expect(abs(n.position.y) < 1e-6)
        // Every frame of cycle 101 matches the same frame of cycle 1.
        let (first, m) = tree(.repeatForever(cycle))
        var worst: CGFloat = 0
        for _ in 0..<60 {
            TweenEngine.step(first, dt: 1.0 / 60)
            TweenEngine.step(root, dt: 1.0 / 60)
            worst = max(worst, abs(n.position.y - m.position.y), abs(n.alpha - m.alpha))
        }
        #expect(worst < 1e-6)
    }

    @Test func runCanEditTheTreeMidStep() {
        let root = SceneNode(), a = SceneNode(), b = SceneNode()
        root.addChild(a); root.addChild(b)
        a.run(.run { b.removeFromParent(); root.addChild(SceneNode(name: "new")) })
        b.run(.moveBy(dx: 1, dy: 0, duration: 1))
        TweenEngine.step(root, dt: 0.5)
        #expect(root.childNode(withName: "new") != nil)
    }
}
