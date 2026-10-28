// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A portable stand-in for `SKNode`/`SKSpriteNode`, with SpriteKit's conventions: positions in the parent's
/// points with y up, `zRotation` in radians counter-clockwise, `anchorPoint` in unit space of the image
/// (default centre). `TweenEngine.step` runs the tweens; a display layer draws the tree.
package final class SceneNode {
    package var name: String?
    package var position: CGPoint = .zero
    package var zPosition: CGFloat = 0
    package var alpha: CGFloat = 1
    package var xScale: CGFloat = 1
    package var yScale: CGFloat = 1
    package var zRotation: CGFloat = 0
    /// Only meaningful with an image.
    package var anchorPoint = CGPoint(x: 0.5, y: 0.5)
    package var image: BakedImage?
    package var isHidden = false
    package private(set) var children: [SceneNode] = []
    package private(set) weak var parent: SceneNode?

    /// Running tweens in the order they were added. `TweenEngine` owns the runners.
    var tweens: [TweenEngine.Running] = []

    package init(name: String? = nil) {
        self.name = name
    }

    // MARK: Tree

    /// Like SpriteKit, a node can have one parent; adding one that already has a parent is a programming error.
    package func addChild(_ n: SceneNode) {
        precondition(n.parent == nil, "SceneNode \(n.name ?? "<unnamed>") already has a parent")
        precondition(n !== self && !isDescendant(of: n), "adding \(n.name ?? "<unnamed>") would make a cycle")
        n.parent = self
        children.append(n)
    }

    package func removeFromParent() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        parent = nil
    }

    package func removeAllChildren() {
        for c in children { c.parent = nil }
        children.removeAll()
    }

    private func isDescendant(of n: SceneNode) -> Bool {
        var p = parent
        while let q = p {
            if q === n { return true }
            p = q.parent
        }
        return false
    }

    /// The topmost ancestor (self when there is no parent).
    package var root: SceneNode {
        var n = self
        while let p = n.parent { n = p }
        return n
    }

    /// SpriteKit's search syntax, without wildcards:
    /// - `name`: a direct child; `a/b`: a path of direct children;
    /// - `.//name`: any descendant of this node;
    /// - `//name`: any node in the tree below the root;
    /// - `/name`: a direct child of the root.
    /// Recursive searches go depth first, children in order.
    package func childNode(withName query: String) -> SceneNode? {
        if query.hasPrefix(".//") { return descendant(named: String(query.dropFirst(3))) }
        if query.hasPrefix("//") { return root.descendant(named: String(query.dropFirst(2))) }
        if query.hasPrefix("/") { return root.childNode(withName: String(query.dropFirst())) }
        var node: SceneNode? = self
        for part in query.split(separator: "/", omittingEmptySubsequences: false) {
            node = node?.children.first { $0.name == String(part) }
        }
        return node
    }

    private func descendant(named name: String) -> SceneNode? {
        for c in children {
            if c.name == name { return c }
            if let d = c.descendant(named: name) { return d }
        }
        return nil
    }

    // MARK: Tweens

    /// Starts `t` on the next `TweenEngine.step`. A tween with the same key replaces the running one.
    package func run(_ t: Tween, withKey key: String? = nil) {
        if let key { removeTween(forKey: key) }
        tweens.append(TweenEngine.Running(key: key, tween: t))
    }

    package func removeTween(forKey key: String) {
        tweens.removeAll { $0.key == key }
    }

    package func removeAllTweens() {
        tweens.removeAll()
    }

    package var hasTweens: Bool { !tweens.isEmpty }
}
