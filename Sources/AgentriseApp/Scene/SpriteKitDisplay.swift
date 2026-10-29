// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import SpriteKit
import Agentrise
import AgentriseScene
import AgentriseMacArt

/// Shows a `TowerSceneModel` with SpriteKit. Every frame (`update`) it steps the model and then mirrors its
/// `SceneNode` tree into SpriteKit nodes: an `SKSpriteNode` per sprite, an `SKNode` per plain node, an
/// `SKShapeNode` per tether. SpriteKit runs no actions and holds no state of its own; it only draws.
///
/// Textures: robot parts and LEDs come from the model's atlas (`AtlasTextures`: one texture per page, uploaded
/// when the page changes, and a sub-texture per image); drawings (`ArtDrawing`: the building, header, tooltip,
/// report card) are drawn once each straight into a raw-data texture, which SpriteKit frees after the upload.
final class SpriteKitDisplay: SKScene {
    let model: TowerSceneModel
    /// The model's layout changed because the view's size did.
    var onLayout: ((BuildingLayout) -> Void)?

    private var lastUpdate: TimeInterval?
    let atlasTextures = AtlasTextures()

    /// One SpriteKit node per model node, by the model node's identity. It holds its model node (a mirror
    /// lives only while the node is in the tree; one that wasn't reached by a sync is dropped).
    private final class Mirror {
        let node: SceneNode
        let sk: SKNode
        let sprite: SKSpriteNode?
        let shape: SKShapeNode?
        let tether: TowerSceneModel.Tether?
        /// The SpriteKit parent it was added to.
        var parent: ObjectIdentifier?
        var name: String?
        var isHidden = false
        var image: BakedImage?
        var drawing: ArtDrawing?
        var color: Color?
        var atlasStamp = -1
        /// What was last handed to SpriteKit (which keeps `Float`s, so its getters never equal the model's
        /// `Double`s): only changes are written.
        var position = CGPoint(x: CGFloat.nan, y: .nan)
        var zPosition = CGFloat.nan, alpha = CGFloat.nan, xScale = CGFloat.nan, yScale = CGFloat.nan, zRotation = CGFloat.nan
        var size = CGSize(width: CGFloat.nan, height: .nan), anchorPoint = CGPoint(x: CGFloat.nan, y: .nan)
        var colorBlendFactor = CGFloat.nan
        var seen = 0
        init(node: SceneNode, sk: SKNode, tether: TowerSceneModel.Tether?) {
            self.node = node
            self.sk = sk
            sprite = sk as? SKSpriteNode
            shape = sk as? SKShapeNode
            self.tether = tether
        }
    }
    private var mirrors: [ObjectIdentifier: Mirror] = [:]
    private var generation = 0
    /// Textures of drawings, by drawing identity (a drawing shared by several nodes, like the report card, is
    /// drawn once).
    private var drawn: [ObjectIdentifier: (drawing: ArtDrawingRef, texture: SKTexture)] = [:]
    private struct ArtDrawingRef { weak var drawing: ArtDrawing? }
    /// How many drawing textures the display holds (for tests).
    var heldDrawingTextures: Int { drawn.count }
    /// Whether the display holds a texture for `d` (for tests).
    func holdsTexture(of d: ArtDrawing) -> Bool { drawn[ObjectIdentifier(d)]?.drawing.drawing === d }
    /// How many drawings were rendered into textures (for tests).
    private(set) var drawCount = 0

    init(model: TowerSceneModel) {
        self.model = model
        super.init(size: model.size)
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = NSColor(hex: 0x0A0E26)
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Size and scale

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard size.width >= 1, size.height >= 1, size != model.size else { return }
        model.resize(to: size, scale: model.scale)
        onLayout?(model.geo)
    }

    /// The backing scale of the hosting window changed: the model re-bakes the building and every robot.
    func backingScaleChanged(_ scale: CGFloat) { model.resize(to: model.size, scale: scale) }

    // MARK: Frames

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdate.map { currentTime - $0 } ?? 0
        lastUpdate = currentTime
        model.step(dt: dt)
        sync()
        relieve(after: dt)
    }

    /// Mirrors the model's tree into SpriteKit (properties, textures, structure). Only what changed is written.
    func sync() {
        generation += 1
        reached = 0
        if atlasTextures.update(model.atlas) { scheduleRelief() }
        let tethers = model.tethers.isEmpty ? [:] : Dictionary(model.tethers.map { (ObjectIdentifier($0.node), $0) }, uniquingKeysWith: { a, _ in a })
        syncChildren(of: model.root, into: self, id: ObjectIdentifier(self), tethers: tethers)
        // Every mirror was reached: nothing left the tree.
        if reached != mirrors.count {
            for (k, m) in mirrors where m.seen != generation {
                if m.drawing != nil { dropsDrawing = true }
                m.sk.removeFromParent()
                mirrors[k] = nil
            }
        }
        // Textures of drawings nothing shows any more go now (a background is 8–33 MB at 2×), not at the next
        // drawing change: by here every mirror has let go of the drawings it replaced.
        if dropsDrawing {
            dropsDrawing = false
            drawn = drawn.filter { $0.value.drawing.drawing != nil }
        }
    }

    /// A mirror let go of a drawing during the sync in progress.
    private var dropsDrawing = false

    /// Mirrors reached by the sync in progress.
    private var reached = 0

    private func syncChildren(of node: SceneNode, into parent: SKNode, id parentID: ObjectIdentifier,
                              tethers: [ObjectIdentifier: TowerSceneModel.Tether]) {
        for c in node.children {
            let m = mirror(for: c, tethers: tethers)
            m.seen = generation
            reached += 1
            if m.parent != parentID {
                m.sk.removeFromParent()
                parent.addChild(m.sk)
                m.parent = parentID
            }
            apply(c, to: m)
            if !c.children.isEmpty { syncChildren(of: c, into: m.sk, id: ObjectIdentifier(m.sk), tethers: tethers) }
        }
    }

    private func mirror(for n: SceneNode, tethers: [ObjectIdentifier: TowerSceneModel.Tether]) -> Mirror {
        let id = ObjectIdentifier(n)
        if let m = mirrors[id], m.node === n { return m }
        mirrors[id]?.sk.removeFromParent()
        let tether = tethers[id]
        let sk: SKNode
        if let tether {
            let shape = SKShapeNode()
            shape.strokeColor = NSColor(tether.color)
            shape.lineWidth = 2
            shape.glowWidth = 2
            sk = shape
        } else if n.isSprite {
            sk = SKSpriteNode(texture: nil, size: n.size)
        } else {
            sk = SKNode()
        }
        let m = Mirror(node: n, sk: sk, tether: tether)
        mirrors[id] = m
        return m
    }

    private func apply(_ n: SceneNode, to m: Mirror) {
        let sk = m.sk
        if m.name != n.name { m.name = n.name; sk.name = n.name }
        if m.position != n.position { m.position = n.position; sk.position = n.position }
        if m.zPosition != n.zPosition { m.zPosition = n.zPosition; sk.zPosition = n.zPosition }
        if m.alpha != n.alpha { m.alpha = n.alpha; sk.alpha = n.alpha }
        if m.xScale != n.xScale { m.xScale = n.xScale; sk.xScale = n.xScale }
        if m.yScale != n.yScale { m.yScale = n.yScale; sk.yScale = n.yScale }
        if m.zRotation != n.zRotation { m.zRotation = n.zRotation; sk.zRotation = n.zRotation }
        if m.isHidden != n.isHidden { m.isHidden = n.isHidden; sk.isHidden = n.isHidden }
        if let sprite = m.sprite {
            // SpriteKit's `size` setter takes the scaled size (the scales were set above).
            if m.size != n.size, n.xScale != 0, n.yScale != 0 {
                m.size = n.size
                sprite.size = CGSize(width: n.size.width * n.xScale, height: n.size.height * n.yScale)
            }
            if m.anchorPoint != n.anchorPoint { m.anchorPoint = n.anchorPoint; sprite.anchorPoint = n.anchorPoint }
            if m.colorBlendFactor != n.colorBlendFactor { m.colorBlendFactor = n.colorBlendFactor; sprite.colorBlendFactor = n.colorBlendFactor }
            if n.color != m.color { m.color = n.color; sprite.color = n.color.map { NSColor($0) } ?? .white }
            bindTexture(n, m, sprite)
        } else if let shape = m.shape, let t = m.tether,
                  let c = model.tetherCurve(from: t.bossKey, to: t.key) {
            // Rebuilt every frame, so the line follows robots that are walking or riding.
            shape.path = Self.tetherPath(c, phase: t.phase)
        }
    }

    private func bindTexture(_ n: SceneNode, _ m: Mirror, _ sprite: SKSpriteNode) {
        if let img = n.image {
            guard m.image !== img || m.atlasStamp != atlasTextures.stamp || m.drawing != nil else { return }
            sprite.texture = atlasTextures.texture(for: img)
            m.image = img
            if m.drawing != nil { dropsDrawing = true }
            m.drawing = nil
            m.atlasStamp = atlasTextures.stamp
        } else if let d = n.drawing {
            guard m.drawing !== d || m.image != nil else { return }
            sprite.texture = texture(of: d)
            if m.drawing != nil { dropsDrawing = true }
            m.drawing = d
            m.image = nil
        } else if m.image != nil || m.drawing != nil || sprite.texture != nil {
            sprite.texture = nil
            m.image = nil
            if m.drawing != nil { dropsDrawing = true }
            m.drawing = nil
        }
    }

    /// The drawing's texture, drawn on first use straight into raw texture memory (no CPU copy outlives the upload).
    private func texture(of d: ArtDrawing) -> SKTexture {
        let id = ObjectIdentifier(d)
        if let hit = drawn[id], hit.drawing.drawing === d { return hit.texture }
        let t = CGArtBackend.texture(size: d.size, scale: d.scale) { ctx in d.draw(CGPen(ctx: ctx, scale: d.scale)) }
        drawn[id] = (ArtDrawingRef(drawing: d), t)
        drawCount += 1
        scheduleRelief()
        return t
    }

    /// The SpriteKit node showing a model node (tests).
    func skNode(for n: SceneNode) -> SKNode? { mirrors[ObjectIdentifier(n)].flatMap { $0.node === n && $0.seen == generation ? $0.sk : nil } }

    // MARK: Tethers

    private static let dash: [CGFloat] = [6, 6]

    /// A tether's quad curve, dashed at `phase` (the old `lineDashPhase`).
    static func tetherPath(_ c: (from: CGPoint, control: CGPoint, to: CGPoint), phase: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: c.from)
        path.addQuadCurve(to: c.to, control: c.control)
        // Dash phases are periodic; keep ours positive.
        let period = dash.reduce(0, +)
        var ph = phase.truncatingRemainder(dividingBy: period)
        if ph < 0 { ph += period }
        return path.copy(dashingWithPhase: ph, lengths: dash)
    }

    // MARK: Memory relief

    /// Seconds until memory freed by uploaded textures goes back to the system (nil = nothing pending).
    private var reliefDue: TimeInterval?
    /// A texture was made after `reliefDue` was armed.
    private var reliefRearm = false
    /// How many reliefs ran. For tests.
    private(set) var reliefRuns = 0
    /// Textures made from raw pixels free them once SpriteKit has uploaded them (on a later render), but malloc
    /// keeps big freed blocks cached (and counted in the footprint) until asked to let go: do that `reliefDelay`
    /// after an upload. During a burst (a live resize redraws the background every frame) it runs at most once
    /// per `reliefDelay`, and once more after the burst, so the last upload's pixels are returned too.
    /// (Cheap: well under 1 ms.)
    private func scheduleRelief() {
        if reliefDue == nil { reliefDue = Self.reliefDelay } else { reliefRearm = true }
    }
    static let reliefDelay: TimeInterval = 0.5

    private func relieve(after dt: TimeInterval) {
        guard let due = reliefDue else { return }
        reliefDue = due - dt
        if due - dt <= 0 {
            CGArtBackend.releaseFreedPixels()
            reliefRuns += 1
            // Textures made while this one was pending may not have been uploaded (and freed) yet: once more.
            reliefDue = reliefRearm ? Self.reliefDelay : nil
            reliefRearm = false
        }
    }
}

/// The SpriteKit side of a `TextureAtlas`: one texture per page (re-uploaded when the page's revision changes),
/// a sub-texture per packed image, and a standalone texture for an image that isn't packed (yet).
final class AtlasTextures {
    private weak var atlas: TextureAtlas?
    private var version = -1
    /// Changes whenever packed textures may have changed (new pages, a new atlas): rebind then.
    private(set) var stamp = 0
    private var pages: [(revision: Int, height: Int, texture: SKTexture)] = []
    private var subTextures: [ObjectIdentifier: SKTexture] = [:]

    /// Takes up the atlas's changes: uploads the pages that changed. True when anything was uploaded.
    @discardableResult
    func update(_ atlas: TextureAtlas) -> Bool {
        if atlas !== self.atlas {
            self.atlas = atlas
            version = -1
            pages.removeAll()
        }
        guard atlas.version != version else { return false }
        version = atlas.version
        stamp += 1
        subTextures.removeAll()
        var uploaded = false
        let count = atlas.pageCount
        if pages.count > count { pages.removeLast(pages.count - count) }
        for i in 0..<count {
            let revision = atlas.pageRevision(i)
            if i < pages.count, pages[i].revision == revision { continue }
            guard let (w, h) = atlas.pageDimensions(i) else { continue }
            let bytes = w * h * 4
            let buffer = calloc(bytes, 1)!
            atlas.drawPage(i, into: UnsafeMutableRawBufferPointer(start: buffer, count: bytes))
            let texture = CGArtBackend.texture(pixels: NSData(bytesNoCopy: buffer, length: bytes, freeWhenDone: true) as Data, width: w, height: h)
            let page = (revision, h, texture)
            if i < pages.count { pages[i] = page } else { pages.append(page) }
            uploaded = true
        }
        return uploaded
    }

    /// The image's packed sub-texture, or (while it isn't packed) a standalone one.
    func texture(for image: BakedImage) -> SKTexture {
        if let atlas, let (page, rect) = atlas.placement(of: image), page < pages.count {
            let id = ObjectIdentifier(image)
            if let t = subTextures[id] { return t }
            let p = pages[page], w = CGFloat(atlas.pageSize), h = CGFloat(p.height)
            // Page rows are top first; SpriteKit's texture rect has its origin at the bottom.
            let t = SKTexture(rect: CGRect(x: rect.minX / w, y: (h - rect.maxY) / h, width: rect.width / w, height: rect.height / h), in: p.texture)
            subTextures[id] = t
            Self.forgetTexture(image)   // packed: its standalone copy (a GPU texture) can go
            return t
        }
        return Self.texture(image)
    }

    /// Whether the image is drawn from a page.
    func isPacked(_ image: BakedImage) -> Bool {
        guard let atlas, let (page, _) = atlas.placement(of: image) else { return false }
        return page < pages.count
    }

    /// Size in pixels of a page's texture (tests).
    func pageTextureSize(_ i: Int) -> CGSize? { pages.indices.contains(i) ? pages[i].texture.size() : nil }

    // MARK: Standalone textures

    private static let textures: NSCache<BakedImage, SKTexture> = {
        let c = NSCache<BakedImage, SKTexture>()
        c.totalCostLimit = standaloneCostLimit
        return c
    }()

    /// Byte budget (`RobotArt.cost`) of the standalone texture cache. Packed images leave it, so it mostly
    /// holds images that don't fit in the atlas (overflow after a reset, oversized ones) and images waiting for
    /// the next commit; roomy enough that those aren't re-uploaded every time they are shown.
    static let standaloneCostLimit = 16 << 20

    /// One standalone SKTexture per baked image (keyed by the image itself, which the cache keeps alive),
    /// shared by all robots. Each costs its image's bytes on the GPU (and the image on the CPU), hence the budget.
    static func texture(_ image: BakedImage) -> SKTexture {
        if let t = textures.object(forKey: image) { return t }
        let t = SKTexture(cgImage: image.cgImage)
        textures.setObject(t, forKey: image, cost: RobotArt.cost(image))
        return t
    }

    static func forgetTexture(_ image: BakedImage) { textures.removeObject(forKey: image) }

    /// Whether a standalone texture for `image` is cached. For tests.
    static func hasStandaloneTexture(_ image: BakedImage) -> Bool { textures.object(forKey: image) != nil }
}
