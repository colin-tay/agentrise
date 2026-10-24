import AppKit
import SpriteKit

/// A robot assembled from `RobotArt`'s baked parts, animated with `RobotMotion`'s SKActions.
///
/// The node's origin is the robot's bottom centre (the pre-SpriteKit robot layer's anchor (0.5, 1) on its 60×84
/// layer); the scene owns `position`, `xScale`/`yScale` (`setRobotScale`) and `zPosition`. Everything else
/// hangs off an inner `rig` node, so the error shake never fights the scene over `position`:
///
///     rig ─ pod, halo, float ─ ears, head ─ eyes, headOverlay; ring, leftHand, rightHand, torso
///         ─ prop ─ (the action's props), bubble ─ bubbleGlow, bubbleBody; name, lark
///
/// Draw order matches the old layer tree. Every node also gets an increasing `zPosition` (steps of 0.001,
/// relative to its parent) so the order holds when the view sets `ignoresSiblingOrder`, while a whole
/// robot stays within 0.015 of the robot's own `zPosition`.
final class RobotSprite: SKNode {
    private(set) var look: RobotLook
    let teamColor: NSColor
    private(set) var face: RobotFace = .calm
    private(set) var action: Activity = .standby
    private(set) var robotScale: CGFloat = 1
    /// The bubble's current text (nil = no bubble).
    private(set) var bubbleText: String?
    private var bubbleColor: NSColor = .clear
    private var bubblePulse = false
    private var waitingLong = false
    var isWaitingLong: Bool { waitingLong }
    private let phase: TimeInterval

    /// The baked parts this robot draws with (one per backing scale).
    let art: RobotArt
    private let rig = SKNode()
    private let float = SKNode()
    private let halo: SKSpriteNode, pod: SKSpriteNode, lark: SKSpriteNode
    private let ears: SKSpriteNode, head: SKSpriteNode, eyes: SKSpriteNode, headOverlay: SKSpriteNode
    private let ring: SKSpriteNode, leftHand: SKSpriteNode, rightHand: SKSpriteNode, torso: SKSpriteNode
    private let prop = SKNode()
    private let bubble = SKNode(), bubbleGlow = SKSpriteNode(), bubbleBody = SKSpriteNode()
    private let nameSprite = SKSpriteNode()

    /// Parts actions can address by name, and their resting pose.
    private var parts: [String: SKNode] = [:]
    private var rest: [String: Pose] = [:]
    private var idle: [String: SKAction] = [:]
    /// Parts the current action animates or reposes (restored when it changes).
    private var touched: Set<String> = []
    private var lastName: String?
    private var lastBubble: String?
    /// Every sprite's source image, so its texture can be swapped for the atlas copy (`rebindTextures`).
    private var sources: [ObjectIdentifier: (node: SKSpriteNode, image: CGImage)] = [:]

    private struct Pose {
        let position: CGPoint, zRotation: CGFloat, xScale: CGFloat, yScale: CGFloat, alpha: CGFloat
        init(_ n: SKNode) { position = n.position; zRotation = n.zRotation; xScale = n.xScale; yScale = n.yScale; alpha = n.alpha }
        func apply(to n: SKNode) { n.position = position; n.zRotation = zRotation; n.xScale = xScale; n.yScale = yScale; n.alpha = alpha }
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

    init(look: RobotLook, teamColor: NSColor, art: RobotArt, phase: TimeInterval = .random(in: 0...2.6)) {
        self.look = look
        self.teamColor = teamColor
        self.art = art
        self.phase = phase
        let feet = Self.feet, neck = Self.neck
        var baked: [(SKSpriteNode, CGImage)] = []
        func part(_ name: String, _ p: RobotPart, pivot: CGPoint, origin: CGPoint, z: CGFloat) -> SKSpriteNode {
            let image = art.image(p)
            let s = SKSpriteNode(texture: nil, size: RobotArt.frame(p).size)
            baked.append((s, image))
            s.name = name
            s.anchorPoint = RobotArt.anchorPoint(p, design: pivot)
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
            headOverlay = SKSpriteNode()
            headOverlay.name = "headOverlay"
            headOverlay.isHidden = true
        }
        ring = part("ring", .ring, pivot: feet, origin: feet, z: Z.ring)
        leftHand = part("leftHand", .leftHand, pivot: feet, origin: feet, z: Z.leftHand)
        rightHand = part("rightHand", .rightHand, pivot: feet, origin: feet, z: Z.rightHand)
        torso = part("torso", .torso(look), pivot: feet, origin: feet, z: Z.torso)
        lark = part("lark", .larkBadge, pivot: feet, origin: feet, z: Z.lark)
        super.init()
        for (node, image) in baked { bind(node, image) }

        halo.color = teamColor
        halo.colorBlendFactor = 1
        pod.isHidden = true
        lark.isHidden = true

        rig.name = "rig"
        float.name = "float"
        prop.name = "prop"; prop.zPosition = Z.prop
        bubble.name = "bubble"; bubble.zPosition = Z.bubble; bubble.isHidden = true
        bubbleGlow.name = "bubbleGlow"; bubbleGlow.alpha = 0
        bubbleBody.name = "bubbleBody"; bubbleBody.zPosition = 0.0005
        nameSprite.name = "name"; nameSprite.zPosition = Z.name
        nameSprite.anchorPoint = CGPoint(x: 0.5, y: 1)
        // Old label box top at design y 82; the image adds `namePadding` around it.
        nameSprite.position = RobotMotion.robotPoint(CGPoint(x: 30, y: 82 - RobotArt.namePadding))

        addChild(rig)
        for n in [pod, halo, float, prop, bubble, nameSprite, lark] as [SKNode] { rig.addChild(n) }
        for n in [ears, head, ring, leftHand, rightHand, torso] { float.addChild(n) }
        head.addChild(eyes)
        head.addChild(headOverlay)
        bubble.addChild(bubbleGlow)
        bubble.addChild(bubbleBody)

        for n in [rig, float, pod, halo, ears, head, eyes, ring, leftHand, rightHand, torso, lark] {
            parts[n.name!] = n
            rest[n.name!] = Pose(n)
        }
        idle = Dictionary(RobotMotion.idle(phase: phase).map { ($0.part, $0.action) }, uniquingKeysWith: { a, _ in a })
        for name in idle.keys where name != "eyes" { startIdle(name) }
        applyFace()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Textures

    private static let textures: NSCache<CGImage, SKTexture> = {
        let c = NSCache<CGImage, SKTexture>()
        c.totalCostLimit = standaloneCostLimit
        return c
    }()

    /// Byte budget (image `bytesPerRow × height`) of the standalone texture cache. Packed images leave it, so it
    /// mostly holds images that don't fit in the atlas (overflow after a reset, oversized ones) and images
    /// waiting for the next commit; roomy enough that those aren't re-uploaded every time they are shown.
    static let standaloneCostLimit = 16 << 20

    /// One standalone SKTexture per baked image (keyed by the image itself, which the cache keeps alive), shared
    /// by all robots; used until the image is packed into `art.atlas`, which then drops it (`forgetTexture`).
    /// Each costs its image's bytes on the GPU (and the image on the CPU), hence the byte budget.
    static func texture(_ image: CGImage) -> SKTexture {
        if let t = textures.object(forKey: image) { return t }
        let t = SKTexture(cgImage: image)
        textures.setObject(t, forKey: image, cost: RobotArt.cost(image))
        return t
    }

    /// Drops the standalone texture of an image that is now drawn from the atlas.
    static func forgetTexture(_ image: CGImage) { textures.removeObject(forKey: image) }

    /// Whether a standalone texture for `image` is cached. For tests.
    static func hasStandaloneTexture(_ image: CGImage) -> Bool { textures.object(forKey: image) != nil }

    /// Shows `image` on `node`, from the atlas once it is packed there.
    private func bind(_ node: SKSpriteNode, _ image: CGImage) {
        sources[ObjectIdentifier(node)] = (node, image)
        node.texture = art.atlas.texture(for: image)
    }

    /// Re-asks the atlas for every sprite's texture (the scene calls this when the atlas `version` changes),
    /// so freshly packed images move onto the shared page and batch with the rest.
    func rebindTextures() {
        for (_, s) in sources { s.node.texture = art.atlas.texture(for: s.image) }
    }

    // MARK: Face

    func setFace(_ f: RobotFace) {
        guard f != face else { return }
        face = f
        applyFace()
    }

    private func applyFace() {
        bind(eyes, art.image(.eyes(face)))
        eyes.alpha = face == .calm ? 0.75 : 1
        eyes.removeAction(forKey: "idle")
        eyes.yScale = 1
        if face == .focused || face == .calm { startIdle("eyes") }
    }

    // MARK: Room actions

    func setAction(_ a: Activity, waitingLong: Bool = false) {
        guard a != action || waitingLong != self.waitingLong else { return }
        action = a
        self.waitingLong = waitingLong
        for n in prop.children { sources[ObjectIdentifier(n)] = nil }
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
            n.removeAction(forKey: "act")
            n.removeAction(forKey: "idle")
            rest[name]?.apply(to: n)
        }
        pod.isHidden = a != .sleeping
        if a == .sleeping {
            float.setScale(RobotMotion.sleepingFloatScale)
            float.position = RobotMotion.sleepingFloatPosition
        }
        for name in reset where !replaced.contains(name) { startIdle(name) }
        touched = now

        for (i, p) in RobotMotion.props(a).enumerated() { prop.addChild(makeProp(p, z: CGFloat(i) * 0.0001)) }
        for (part, action) in acts {
            (parts[part] ?? prop.childNode(withName: part))?.run(action, withKey: "act")
        }
    }

    private func startIdle(_ name: String) {
        guard let a = idle[name], let n = parts[name] else { return }
        n.run(a, withKey: "idle")
    }

    private func makeProp(_ p: RobotMotion.Prop, z: CGFloat) -> SKSpriteNode {
        let image: CGImage, size: CGSize
        switch p.art {
        case let .emoji(s, sz):
            image = art.emoji(s, size: sz)
            size = ArtKit.labelSize(s, size: sz, weight: .regular)
        case .doorSign:
            image = art.doorSign()
            size = CGSize(width: 16, height: 14)
        }
        let n = SKSpriteNode(texture: nil, size: size)
        bind(n, image)
        n.name = p.name
        n.position = RobotMotion.robotPoint(p.at)
        n.zPosition = z
        if let tint = p.tint {
            n.color = tint
            n.colorBlendFactor = 1
        }
        return n
    }

    // MARK: Labels

    func setBubble(_ text: String?, color: NSColor, pulse: Bool) {
        let sig = "\(String(describing: text))|\(color)|\(pulse)"
        guard sig != lastBubble else { return }
        lastBubble = sig
        bubbleText = text
        bubbleColor = color
        bubblePulse = pulse
        bubbleGlow.removeAction(forKey: "pulse")
        bubbleGlow.alpha = 0
        guard let text else { bubble.isHidden = true; return }
        bubble.isHidden = false
        // Old bubble centre: design y 2 for the sprout / hard hat wearers, 6 otherwise (no headroom added).
        placeBubble()
        let size = RobotArt.bubbleSize(text)
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

    func setName(_ s: String) {
        guard s != lastName else { return }
        lastName = s
        let small = look.kind == .sub || look.kind == .contractor
        bind(nameSprite, art.name(s, small: small, stripe: look.rank?.stripe))
        nameSprite.size = RobotArt.nameImageSize(s, small: small)
    }

    func setLarkBadge(_ on: Bool) { lark.isHidden = !on }

    // MARK: Re-baking

    /// Redraws this robot in place with a new look (its rank changed in Settings): same node, position, room,
    /// motion, face, action and bubble; only the head, torso, head overlay, bubble anchor and name stripe change.
    func setLook(_ new: RobotLook) {
        guard new != look else { return }
        look = new
        for (node, p, pivot) in [(head, RobotPart.head(new), Self.neck), (torso, .torso(new), Self.feet)] {
            node.size = RobotArt.frame(p).size
            node.anchorPoint = RobotArt.anchorPoint(p, design: pivot)
            bind(node, art.image(p))
        }
        if new.hasHeadOverlay {
            let p = RobotPart.headOverlay(new)
            headOverlay.size = RobotArt.frame(p).size
            headOverlay.anchorPoint = RobotArt.anchorPoint(p, design: Self.neck)
            headOverlay.position = .zero   // pivot and origin are both the neck
            headOverlay.zPosition = Z.headOverlay - Z.head
            bind(headOverlay, art.image(p))
            headOverlay.isHidden = false
        } else {
            sources[ObjectIdentifier(headOverlay)] = nil
            headOverlay.texture = nil
            headOverlay.isHidden = true
        }
        if bubbleText != nil { placeBubble() }
        if let n = lastName { lastName = nil; setName(n) }   // the stripe colour follows the rank
    }

    /// A fresh copy of this robot drawn with `art` (e.g. after a backing scale change): same look, idle
    /// phase, face, action, name, bubble, badge, scale, position, z and alpha. Extra children the scene
    /// hung on this robot are not copied.
    func rebaked(with art: RobotArt) -> RobotSprite {
        let r = RobotSprite(look: look, teamColor: teamColor, art: art, phase: phase)
        if let n = lastName { r.setName(n) }
        r.setFace(face)
        r.setAction(action, waitingLong: waitingLong)
        r.setBubble(bubbleText, color: bubbleColor, pulse: bubblePulse)
        r.setLarkBadge(!lark.isHidden)
        r.setRobotScale(robotScale)
        r.position = position
        r.zPosition = zPosition
        r.fade = fade
        r.setDimmed(dimmed)
        r.name = name
        return r
    }

    // MARK: Hover / dim / scale

    static let dimmedAlpha: CGFloat = 0.18

    /// The scene's fade-in/out factor (1 = fully visible). Dimming multiplies with it, so neither clobbers the other.
    var fade: CGFloat = 1 { didSet { applyAlpha() } }
    /// Hover highlight: everyone but the highlighted team dims to `dimmedAlpha`.
    private(set) var dimmed = false

    func setDimmed(_ d: Bool) {
        dimmed = d
        applyAlpha()
    }

    private func applyAlpha() { alpha = fade * (dimmed ? Self.dimmedAlpha : 1) }

    func setRobotScale(_ s: CGFloat) {
        robotScale = s
        setScale(s)
    }

    /// The old `hit()` box: the 60×84 canvas at the robot's scale, standing on `position`, in scene coordinates.
    var hitRect: CGRect {
        let s = robotScale
        let r = CGRect(x: position.x - 30 * s, y: position.y, width: 60 * s, height: 84 * s)
        guard let parent, let scene, parent !== scene else { return r }
        let a = parent.convert(r.origin, to: scene), b = parent.convert(CGPoint(x: r.maxX, y: r.maxY), to: scene)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
