// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Agentrise

/// A robot assembled from `RobotArt`'s baked parts as a `SceneNode` tree, animated with `RobotMotion`'s tweens.
///
/// `root` is the robot's bottom centre (the pre-SpriteKit robot layer's anchor (0.5, 1) on its 60×84 layer); the
/// scene owns its `position`, `xScale`/`yScale` (`setRobotScale`) and `zPosition`. Everything else hangs off an
/// inner `rig` node, so the error shake never fights the scene over `position`:
///
///     rig ─ pod, halo, float ─ ears, head ─ eyes, headOverlay; ring, leftHand, rightHand, torso
///         ─ prop ─ (the action's props), bubble ─ bubbleGlow, bubbleBody; name, lark
///
/// Draw order matches the old layer tree. Every node also gets an increasing `zPosition` (steps of 0.001,
/// relative to its parent) so the order holds when the display ignores sibling order, while a whole robot stays
/// within 0.015 of the robot's own `zPosition`.
package final class RobotRig {
    package let root = SceneNode()
    package private(set) var look: RobotLook
    package let teamColor: Color
    package private(set) var face: RobotFace = .calm
    package private(set) var action: Activity = .standby
    package private(set) var robotScale: CGFloat = 1
    /// The bubble's current text (nil = no bubble).
    package private(set) var bubbleText: String?
    private var bubbleColor = Color(r: 0, g: 0, b: 0, a: 0)
    private var bubblePulse = false
    private var waitingLong = false
    package var isWaitingLong: Bool { waitingLong }
    private let phase: TimeInterval

    /// The baked parts this robot draws with (one per backing scale).
    package let art: RobotArt
    /// Where the robot's images are packed for batched drawing: every image the rig shows is queued on it.
    package var atlas: TextureAtlas? { didSet { requeue() } }

    private let rig = SceneNode(name: "rig")
    private let float = SceneNode(name: "float")
    private let halo: SceneNode, pod: SceneNode, lark: SceneNode
    private let ears: SceneNode, head: SceneNode, eyes: SceneNode, headOverlay: SceneNode
    private let ring: SceneNode, leftHand: SceneNode, rightHand: SceneNode, torso: SceneNode
    private let prop = SceneNode(name: "prop")
    private let bubble = SceneNode(name: "bubble")
    private let bubbleGlow = SceneNode(name: "bubbleGlow", sprite: true), bubbleBody = SceneNode(name: "bubbleBody", sprite: true)
    private let nameSprite = SceneNode(name: "name", sprite: true)

    /// Parts actions can address by name, and their resting pose.
    private var parts: [String: SceneNode] = [:]
    private var rest: [String: Pose] = [:]
    private var idle: [String: Tween] = [:]
    /// Parts the current action animates or reposes (restored when it changes).
    private var touched: Set<String> = []
    private var lastName: String?
    private var lastBubble: String?

    private struct Pose {
        let position: CGPoint, zRotation: CGFloat, xScale: CGFloat, yScale: CGFloat, alpha: CGFloat
        init(_ n: SceneNode) { position = n.position; zRotation = n.zRotation; xScale = n.xScale; yScale = n.yScale; alpha = n.alpha }
        func apply(to n: SceneNode) { n.position = position; n.zRotation = zRotation; n.xScale = xScale; n.yScale = yScale; n.alpha = alpha }
    }

    /// Absolute z of each layer within the robot, bottom to top (children store the difference to their parent).
    private enum Z {
        static let pod: CGFloat = 0.001, halo: CGFloat = 0.002, ears: CGFloat = 0.003, head: CGFloat = 0.004
        static let eyes: CGFloat = 0.005, headOverlay: CGFloat = 0.006, ring: CGFloat = 0.007
        static let leftHand: CGFloat = 0.008, rightHand: CGFloat = 0.009, torso: CGFloat = 0.010
        static let prop: CGFloat = 0.011, bubble: CGFloat = 0.012, name: CGFloat = 0.013, lark: CGFloat = 0.014
    }

    /// Design-space pivots: the canvas bottom centre, the neck (head turns and dips about it) and the eyes' centre (blink).
    private static let feet = CGPoint(x: 30, y: 84)
    private static let neck = CGPoint(x: 30, y: 14 + 34)
    private static let eyeLine = CGPoint(x: 30, y: 14 + 19.5)

    package init(look: RobotLook, teamColor: Color, art: RobotArt, phase: TimeInterval = .random(in: 0...2.6)) {
        self.look = look
        self.teamColor = teamColor
        self.art = art
        self.phase = phase
        let feet = Self.feet, neck = Self.neck
        func part(_ name: String, _ p: RobotPart, pivot: CGPoint, origin: CGPoint, z: CGFloat) -> SceneNode {
            let s = SceneNode(name: name, sprite: true)
            s.image = art.image(p)
            s.size = art.frame(p).size
            s.anchorPoint = art.anchorPoint(p, design: pivot)
            let at = RobotMotion.robotPoint(pivot), o = RobotMotion.robotPoint(origin)
            s.position = CGPoint(x: at.x - o.x, y: at.y - o.y)
            s.zPosition = z
            return s
        }
        pod = part("pod", .pod, pivot: feet, origin: feet, z: Z.pod)
        halo = part("halo", .halo, pivot: feet, origin: feet, z: Z.halo)
        ears = part("ears", .ears, pivot: feet, origin: feet, z: Z.ears)
        head = part("head", .head(look), pivot: neck, origin: feet, z: Z.head)
        eyes = part("eyes", .eyes(.calm), pivot: Self.eyeLine, origin: neck, z: Z.eyes - Z.head)
        if look.hasHeadOverlay {
            headOverlay = part("headOverlay", .headOverlay(look), pivot: neck, origin: neck, z: Z.headOverlay - Z.head)
        } else {
            headOverlay = SceneNode(name: "headOverlay", sprite: true)
            headOverlay.isHidden = true
        }
        ring = part("ring", .ring, pivot: feet, origin: feet, z: Z.ring)
        leftHand = part("leftHand", .leftHand, pivot: feet, origin: feet, z: Z.leftHand)
        rightHand = part("rightHand", .rightHand, pivot: feet, origin: feet, z: Z.rightHand)
        torso = part("torso", .torso(look), pivot: feet, origin: feet, z: Z.torso)
        lark = part("lark", .larkBadge, pivot: feet, origin: feet, z: Z.lark)

        halo.color = teamColor
        halo.colorBlendFactor = 1
        pod.isHidden = true
        lark.isHidden = true

        prop.zPosition = Z.prop
        bubble.zPosition = Z.bubble; bubble.isHidden = true
        bubbleGlow.alpha = 0
        bubbleBody.zPosition = 0.0005
        nameSprite.zPosition = Z.name
        nameSprite.anchorPoint = CGPoint(x: 0.5, y: 1)
        // Old label box top at design y 82; the image adds `namePadding` around it.
        nameSprite.position = RobotMotion.robotPoint(CGPoint(x: 30, y: 82 - RobotArt.namePadding))

        root.addChild(rig)
        for n in [pod, halo, float, prop, bubble, nameSprite, lark] { rig.addChild(n) }
        for n in [ears, head, ring, leftHand, rightHand, torso] { float.addChild(n) }
        head.addChild(eyes)
        head.addChild(headOverlay)
        bubble.addChild(bubbleGlow)
        bubble.addChild(bubbleBody)

        for n in [rig, float, pod, halo, ears, head, eyes, ring, leftHand, rightHand, torso, lark] {
            parts[n.name!] = n
            rest[n.name!] = Pose(n)
        }
        idle = Dictionary(RobotMotion.idle(phase: phase).map { ($0.part, $0.tween) }, uniquingKeysWith: { a, _ in a })
        for name in idle.keys where name != "eyes" { startIdle(name) }
        applyFace()
    }

    // MARK: Images

    /// Shows `image` on `node` and queues it on the atlas.
    private func bind(_ node: SceneNode, _ image: BakedImage) {
        node.image = image
        atlas?.want(image)
    }

    /// The baked image a part of this robot shows (nil for a node without one, or one that isn't this robot's).
    /// The motion baselines record which image each part draws.
    package func sourceImage(of node: SceneNode) -> BakedImage? {
        var n: SceneNode? = node
        while let c = n, c !== root { n = c.parent }
        return n === root ? node.image : nil
    }

    /// Queues every image the robot shows on the atlas again (the model calls this when the atlas `version`
    /// changes), so images dropped by an atlas reset come back.
    package func requeue() {
        guard let atlas else { return }
        func walk(_ n: SceneNode) {
            if let img = n.image { atlas.want(img) }
            for c in n.children { walk(c) }
        }
        walk(root)
    }

    // MARK: Face

    package func setFace(_ f: RobotFace) {
        guard f != face else { return }
        face = f
        applyFace()
    }

    private func applyFace() {
        bind(eyes, art.image(.eyes(face)))
        eyes.alpha = face == .calm ? 0.75 : 1
        eyes.removeTween(forKey: "idle")
        eyes.yScale = 1
        if face == .focused || face == .calm { startIdle("eyes") }
    }

    // MARK: Room actions

    package func setAction(_ a: Activity, waitingLong: Bool = false) {
        guard a != action || waitingLong != self.waitingLong else { return }
        action = a
        self.waitingLong = waitingLong
        prop.removeAllChildren()

        let acts = RobotMotion.act(a, waitingLong: waitingLong)
        let replaced = RobotMotion.replacesIdle(a)
        var now = Set(acts.map(\.part).filter { parts[$0] != nil })
        if a == .sleeping { now.insert("float") }
        // Return every part the old or new action moves to its resting pose with a fresh idle loop
        // (relative idle moves must start from rest), except where the new action replaces the idle.
        let reset = touched.union(now)
        for name in reset {
            guard let n = parts[name] else { continue }
            n.removeTween(forKey: "act")
            n.removeTween(forKey: "idle")
            rest[name]?.apply(to: n)
        }
        pod.isHidden = a != .sleeping
        if a == .sleeping {
            float.setScale(RobotMotion.sleepingFloatScale)
            float.position = RobotMotion.sleepingFloatPosition
        }
        // Sorted, so tweens start in the same order every time (they run in the order they were added).
        for name in reset.sorted() where !replaced.contains(name) { startIdle(name) }
        touched = now

        for (i, p) in RobotMotion.props(a).enumerated() { prop.addChild(makeProp(p, z: CGFloat(i) * 0.0001)) }
        for (part, tween) in acts {
            (parts[part] ?? prop.childNode(withName: part))?.run(tween, withKey: "act")
        }
    }

    private func startIdle(_ name: String) {
        guard let a = idle[name], let n = parts[name] else { return }
        n.run(a, withKey: "idle")
    }

    private func makeProp(_ p: RobotMotion.Prop, z: CGFloat) -> SceneNode {
        let image: BakedImage, size: CGSize
        switch p.art {
        case let .emoji(s, sz):
            image = art.emoji(s, size: sz)
            size = art.emojiSize(s, size: sz)
        case .doorSign:
            image = art.doorSign()
            size = CGSize(width: 16, height: 14)
        }
        let n = SceneNode(name: p.name, sprite: true)
        n.size = size
        bind(n, image)
        n.position = RobotMotion.robotPoint(p.at)
        n.zPosition = z
        if let tint = p.tint {
            n.color = tint
            n.colorBlendFactor = 1
        }
        return n
    }

    // MARK: Labels

    package func setBubble(_ text: String?, color: Color, pulse: Bool) {
        let sig = "\(String(describing: text))|\(color)|\(pulse)"
        guard sig != lastBubble else { return }
        lastBubble = sig
        bubbleText = text
        bubbleColor = color
        bubblePulse = pulse
        bubbleGlow.removeTween(forKey: "pulse")
        bubbleGlow.alpha = 0
        guard let text else { bubble.isHidden = true; return }
        bubble.isHidden = false
        // Old bubble centre: design y 2 for the sprout / hard hat wearers, 6 otherwise (no headroom added).
        placeBubble()
        let size = art.bubbleSize(text)
        bind(bubbleBody, art.bubble(text, color: color))
        bubbleBody.size = size
        if pulse {
            let pad = RobotArt.bubbleGlowPadding
            bind(bubbleGlow, art.bubbleGlow(text, color: color))
            bubbleGlow.size = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
            bubbleGlow.run(RobotMotion.pulse(), withKey: "pulse")
        }
    }

    private func placeBubble() {
        bubble.position = RobotMotion.robotPoint(CGPoint(x: 30, y: look.rank == .newGrad || look.kind == .contractor ? 2 : 6))
    }

    package func setName(_ s: String) {
        guard s != lastName else { return }
        lastName = s
        let small = look.kind == .sub || look.kind == .contractor
        bind(nameSprite, art.name(s, small: small, stripe: look.rank?.stripe))
        nameSprite.size = art.nameImageSize(s, small: small)
    }

    package func setLarkBadge(_ on: Bool) { lark.isHidden = !on }

    // MARK: Re-baking

    /// Redraws this robot in place with a new look (its rank changed in Settings): same nodes, position, room,
    /// motion, face, action and bubble; only the head, torso, head overlay, bubble anchor and name stripe change.
    /// `name`: the name to show from now on (a rank change usually changes it too), so it is baked once.
    package func setLook(_ new: RobotLook, name: String? = nil) {
        guard new != look else { return }
        look = new
        for (node, p, pivot) in [(head, RobotPart.head(new), Self.neck), (torso, .torso(new), Self.feet)] {
            node.size = art.frame(p).size
            node.anchorPoint = art.anchorPoint(p, design: pivot)
            bind(node, art.image(p))
        }
        if new.hasHeadOverlay {
            let p = RobotPart.headOverlay(new)
            headOverlay.size = art.frame(p).size
            headOverlay.anchorPoint = art.anchorPoint(p, design: Self.neck)
            headOverlay.position = .zero   // pivot and origin are both the neck
            headOverlay.zPosition = Z.headOverlay - Z.head
            bind(headOverlay, art.image(p))
            headOverlay.isHidden = false
        } else {
            headOverlay.image = nil
            headOverlay.isHidden = true
        }
        if bubbleText != nil { placeBubble() }
        if let n = name ?? lastName { lastName = nil; setName(n) }   // the stripe colour follows the rank
    }

    /// A fresh copy of this robot drawn with `art` (e.g. after a backing scale change): same look, idle
    /// phase, face, action, name, bubble, badge, scale, position, z and alpha. Extra children the scene
    /// hung on this robot are not copied.
    package func rebaked(with art: RobotArt) -> RobotRig {
        let r = RobotRig(look: look, teamColor: teamColor, art: art, phase: phase)
        if let n = lastName { r.setName(n) }
        r.setFace(face)
        r.setAction(action, waitingLong: waitingLong)
        r.setBubble(bubbleText, color: bubbleColor, pulse: bubblePulse)
        r.setLarkBadge(!lark.isHidden)
        r.setRobotScale(robotScale)
        r.root.position = root.position
        r.root.zPosition = root.zPosition
        r.fade = fade
        r.setDimmed(dimmed)
        r.root.name = root.name
        return r
    }

    // MARK: Hover / dim / scale

    package static let dimmedAlpha: CGFloat = 0.18

    /// The scene's fade-in/out factor (1 = fully visible). Dimming multiplies with it, so neither clobbers the other.
    package var fade: CGFloat = 1 { didSet { applyAlpha() } }
    /// Hover highlight: everyone but the highlighted team dims to `dimmedAlpha`.
    package private(set) var dimmed = false

    package func setDimmed(_ d: Bool) {
        dimmed = d
        applyAlpha()
    }

    private func applyAlpha() { root.alpha = fade * (dimmed ? Self.dimmedAlpha : 1) }

    package func setRobotScale(_ s: CGFloat) {
        robotScale = s
        root.setScale(s)
    }

    /// The old `hit()` box: the 60×84 canvas at the robot's scale, standing on `position`, in its parent's space
    /// (the scene's: robots hang off `actors`, which sits at the origin unscaled).
    package var hitRect: CGRect {
        let s = robotScale, p = root.position
        return CGRect(x: p.x - 30 * s, y: p.y, width: 60 * s, height: 84 * s)
    }
}
