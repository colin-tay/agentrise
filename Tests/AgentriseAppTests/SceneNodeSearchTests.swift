// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import SpriteKit
@testable import AgentriseScene

/// `SceneNode.childNode(withName:)` against `SKNode.childNode(withName:)` on the same trees, with names
/// repeated at different depths, so the search order is SpriteKit's: a node's own children first, then each
/// child's subtree in turn (neither plain depth-first nor level by level).
@MainActor
@Suite struct SceneNodeSearchTests {
    /// The same tree twice, built from (parent index, name) pairs; node 0 is the root.
    private static func trees(_ shape: [(parent: Int, name: String)]) -> ([SKNode], [SceneNode]) {
        let sk = [SKNode()], tw = [SceneNode(name: "root")]
        sk[0].name = "root"
        var a = sk, b = tw
        for (p, name) in shape {
            let n = SKNode(), m = SceneNode(name: name)
            n.name = name
            a[p].addChild(n)
            b[p].addChild(m)
            a.append(n)
            b.append(m)
        }
        return (a, b)
    }

    private static let queries = ["x", "y", "root", ".//x", ".//y", ".//root", "//x", "//y", "//root", "/x", "/y",
                                  "a/x", "a/b/y", "b/y", "a/x/y", "nope", ".//nope"]

    /// Every query from every node finds the same node (by index) on both sides.
    private static func check(_ shape: [(parent: Int, name: String)]) {
        let (sk, tw) = trees(shape)
        for from in sk.indices {
            for q in queries {
                let want = sk[from].childNode(withName: q).flatMap { hit in sk.firstIndex { $0 === hit } }
                let got = tw[from].childNode(withName: q).flatMap { hit in tw.firstIndex { $0 === hit } }
                #expect(got == want, "from node \(from), \"\(q)\": SpriteKit \(String(describing: want)), SceneNode \(String(describing: got))")
            }
        }
    }

    @Test func directChildrenFirstThenEachSubtreeInTurn() {
        // root → a → b → y (depth 3) comes first in child order, root → y (depth 1) later.
        Self.check([(0, "a"), (1, "b"), (2, "y"), (0, "y")])
        // …but a depth-3 y in the first subtree beats depth-2 ys in later ones, so it is not level by level.
        Self.check([(0, "a"), (1, "x"), (2, "y"), (0, "b"), (4, "y"), (4, "x"), (0, "x"), (7, "y")])
    }

    @Test func randomTreesSearchLikeSpriteKit() {
        // A fixed-seed generator (64-bit LCG), so a failure reproduces.
        var seed: UInt64 = 0x5EED
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let names = ["x", "y", "a", "b", "root"]
        for _ in 0..<200 {
            var shape: [(parent: Int, name: String)] = []
            for i in 0..<(3 + next(16)) { shape.append((next(i + 1), names[next(names.count)])) }
            Self.check(shape)
        }
    }
}
