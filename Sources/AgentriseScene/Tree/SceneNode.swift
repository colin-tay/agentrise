// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A portable stand-in for `SKNode`/`SKSpriteNode`, with SpriteKit's conventions: positions in the parent's
/// points with y up, `zRotation` in radians counter-clockwise, `anchorPoint` in unit space of the image
/// (default centre). `TweenEngine.step` runs the tweens; a display layer draws the tree.
///
/// A sprite (`isSprite`) shows `image` (a baked bitmap, drawn from the display's atlas) or `drawing` (a bitmap
/// the display draws itself, once per instance), stretched to `size`; a node that is not a sprite only groups
/// its children.
package final class SceneNode {
    package var name: String?
    /// Whether the node shows a bitmap (`SKSpriteNode`) rather than only grouping its children (`SKNode`).
    package let isSprite: Bool
    package var position: CGPoint = .zero
    package var zPosition: CGFloat = 0
    package var alpha: CGFloat = 1
    package var xScale: CGFloat = 1
    package var yScale: CGFloat = 1
    package var zRotation: CGFloat = 0
    /// Only meaningful with an image.
    package var anchorPoint = CGPoint(x: 0.5, y: 0.5)
    package var image: BakedImage?
    /// Drawn by the display instead of `image` (big or one-off bitmaps: the building, the header, the tooltip).
    package var drawing: ArtDrawing?
    /// The sprite's size in points (what the bitmap is stretched to).
    package var size: CGSize = .zero
    /// Tints the bitmap like `SKSpriteNode.color` with `colorBlendFactor`.
    package var color: Color?
    package var colorBlendFactor: CGFloat = 0
    package var isHidden = false
    package private(set) var children: [SceneNode] = []
    package private(set) weak var parent: SceneNode?

    /// Running tweens in the order they were added. `TweenEngine` owns the runners.
    var tweens: [TweenEngine.Running] = []

    package init(name: String? = nil, sprite: Bool = false) {
        self.name = name
        isSprite = sprite
    }

    /// A sprite's rectangle in its parent's points (`SKSpriteNode.frame`, without rotation); a plain node's
    /// position as an empty rectangle.
    package var frame: CGRect {
        guard isSprite else { return CGRect(origin: position, size: .zero) }
        let w = size.width * xScale, h = size.height * yScale
        return CGRect(x: position.x - anchorPoint.x * w, y: position.y - anchorPoint.y * h, width: w, height: h).standardized
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
    /// - `name`: a direct child; `a/b`: a path of direct children (any child named `a` that has a `b`);
    /// - `.//name`: any descendant of this node;
    /// - `//name`: any node in the tree below the root;
    /// - `/name`: a direct child of the root.
    /// Recursive searches go as SpriteKit's do (checked against `SKNode` in `SceneNodeSearchTests`): a node's
    /// own children first, in order, then each child's subtree in turn. So a direct child beats anything
    /// deeper, but this is not a level-by-level search: a match deep in the first subtree beats a shallower
    /// one in a later subtree.
    package func childNode(withName query: String) -> SceneNode? {
        if query.hasPrefix(".//") { return descendant(named: String(query.dropFirst(3))) }
        if query.hasPrefix("//") { return root.descendant(named: String(query.dropFirst(2))) }
        if query.hasPrefix("/") { return root.childNode(withName: String(query.dropFirst())) }
        return path(query.split(separator: "/", omittingEmptySubsequences: false).map(String.init)[...])
    }

    /// `a/b/c`: like SpriteKit, every child named `a` is tried in order, not only the first.
    private func path(_ parts: ArraySlice<String>) -> SceneNode? {
        guard let first = parts.first else { return nil }
        for c in children where c.name == first {
            if parts.count == 1 { return c }
            if let hit = c.path(parts.dropFirst()) { return hit }
        }
        return nil
    }

    private func descendant(named name: String) -> SceneNode? {
        if let hit = children.first(where: { $0.name == name }) { return hit }
        for c in children {
            if let hit = c.descendant(named: name) { return hit }
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

    package func hasTween(forKey key: String) -> Bool { tweens.contains { $0.key == key } }

    /// `SKNode.setScale`.
    package func setScale(_ s: CGFloat) { xScale = s; yScale = s }
}
