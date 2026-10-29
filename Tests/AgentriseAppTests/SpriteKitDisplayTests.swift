// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import AppKit
import SpriteKit
import Metal
@testable import AgentriseApp
@testable import Agentrise
@testable import AgentriseScene
import AgentriseMacArt

/// The SpriteKit display of a `TowerSceneModel`, stepped headlessly with `SKRenderer`.
@MainActor
@Suite struct SpriteKitDisplayTests {
    private let size = CGSize(width: 1200, height: 800)

    @MainActor private final class Rig {
        let model: TowerSceneModel
        let display: SpriteKitDisplay
        let renderer = SKRenderer(device: MTLCreateSystemDefaultDevice()!)
        private var time: TimeInterval = 1000

        init(size: CGSize, scale: CGFloat = 2) {
            model = TowerSceneModel(size: size, scale: scale, art: CGArtBackend.shared)
            display = SpriteKitDisplay(model: model)
            display.scaleMode = .fill   // the view-less renderer would otherwise resize the scene to nothing
            renderer.scene = display
            renderer.update(atTime: time)
        }

        /// Runs `seconds` of 1/60 s frames.
        func run(_ seconds: TimeInterval) {
            for _ in 0..<max(1, Int((seconds * 60).rounded())) {
                time += 1.0 / 60
                renderer.update(atTime: time)
            }
        }

        func sk(_ n: SceneNode?) -> SKNode? { n.flatMap { display.skNode(for: $0) } }
    }

    /// SpriteKit keeps node properties as `Float`s.
    private func same(_ a: CGFloat, _ b: CGFloat) -> Bool { a == CGFloat(Float(b)) }

    private func session(_ id: String, team: Int = 0, subs: [String] = []) -> Session {
        var s = Session(id: id, title: "任务 \(id)", source: .desktop(hostSessionId: nil), rank: .seniorEngineer, status: .working,
                        activity: .coding, teamIndex: team, statusSince: Date(), lastActivityAt: Date())
        s.subs = Dictionary(uniqueKeysWithValues: subs.map { ($0, SubAgent(id: $0, type: "Explore", activity: .coding, startedAt: Date())) })
        return s
    }

    /// Every model node has a SpriteKit twin with the same state: sprites as `SKSpriteNode`s with a texture,
    /// plain nodes as `SKNode`s, nested the same way.
    @Test func mirrorsTheModelTree() {
        let r = Rig(size: size)
        r.model.setHeader(TowerCounts(working: 1))
        r.model.render([session("a", subs: ["x"])], animated: false)
        r.run(0.5)
        var checked = 0
        func walk(_ n: SceneNode, _ parent: SKNode) {
            for c in n.children {
                guard let sk = r.sk(c) else { Issue.record("no SpriteKit node for \(c.name ?? "?")"); continue }
                #expect(sk.parent === parent)
                #expect(sk.name == c.name && sk.isHidden == c.isHidden)
                #expect(same(sk.position.x, c.position.x) && same(sk.position.y, c.position.y) && same(sk.zPosition, c.zPosition))
                #expect(same(sk.alpha, c.alpha) && same(sk.xScale, c.xScale) && same(sk.yScale, c.yScale) && same(sk.zRotation, c.zRotation))
                if c.isSprite {
                    let sprite = sk as? SKSpriteNode
                    // SpriteKit reports the scaled size.
                    #expect(sprite.map { abs($0.size.width - c.size.width * c.xScale) < 1e-3 && abs($0.size.height - c.size.height * c.yScale) < 1e-3 } == true,
                            "\(c.name ?? "?"): \(String(describing: sprite?.size)) vs \(c.size)")
                    #expect(sprite.map { same($0.anchorPoint.x, c.anchorPoint.x) && same($0.anchorPoint.y, c.anchorPoint.y) } == true)
                    #expect((sprite?.texture != nil) == (c.image != nil || c.drawing != nil), "\(c.name ?? "?")")
                } else {
                    #expect(!(sk is SKSpriteNode))
                }
                checked += 1
                walk(c, sk)
            }
        }
        walk(r.model.root, r.display)
        #expect(checked > 50)
        // The halo's team colour reaches SpriteKit.
        let halo = r.sk(r.model.robot("s:a")?.root.childNode(withName: ".//halo")) as? SKSpriteNode
        let team = Team.color(0), tint = Color(halo!.color)
        #expect(halo?.colorBlendFactor == 1)
        #expect(abs(tint.r - team.r) < 1e-6 && abs(tint.g - team.g) < 1e-6 && abs(tint.b - team.b) < 1e-6)
    }

    /// Robots that leave the model leave SpriteKit too.
    @Test func removedNodesLeaveSpriteKit() {
        let r = Rig(size: size)
        r.model.render([session("a", subs: ["x"])], animated: false)
        r.run(0.1)
        let sub = r.model.robot("a:a:x")!
        let sk = r.sk(sub.root)
        #expect(sk?.parent != nil)
        r.model.render([session("a")], animated: false)
        r.run(0.1)
        #expect(sk?.parent == nil)
        #expect(r.sk(sub.root) == nil)
    }

    /// Robot parts and LEDs draw from the atlas pages (sub-textures), also after a scale change gives the model a
    /// new atlas.
    @Test func robotPartsAndLedsDrawFromAtlasPages() {
        let r = Rig(size: size, scale: 2.4)
        r.model.render([session("a")], animated: false)
        r.run(0.05)
        func onAtlas() -> Bool {
            guard let rig = r.model.robot("s:a"), let torso = rig.root.childNode(withName: ".//torso"),
                  let sprite = r.sk(torso) as? SKSpriteNode, let image = torso.image else { return false }
            return r.display.atlasTextures.isPacked(image) && sprite.texture === r.display.atlasTextures.texture(for: image)
                && sprite.texture!.textureRect().width < 1
        }
        func ledsOnAtlas() -> Bool {
            let leds = r.model.root.childNode(withName: "leds")!.children
            return !leds.isEmpty && leds.allSatisfy { led in
                (r.sk(led) as? SKSpriteNode)?.texture.map { $0.textureRect().width < 1 } == true
            }
        }
        #expect(onAtlas())
        #expect(ledsOnAtlas())
        r.display.backingScaleChanged(1.6)
        r.run(0.05)
        #expect(r.model.robot("s:a")?.art.scale == 2)
        #expect(onAtlas())
        #expect(ledsOnAtlas())
    }

    /// The highlighted team's tethers are dashed 2 pt shapes with a 2 pt glow in the team colour, drawn from
    /// the model's curve at the model's dash phase, following the robots.
    @Test func tethersAreDashedShapesFromTheModel() {
        let r = Rig(size: size)
        r.model.render([session("a", subs: ["x", "y"]), session("b", team: 1)], animated: false)
        r.model.highlight("a")
        r.run(0.3)
        let tethers = r.model.tethers
        #expect(tethers.count == 2)
        for t in tethers {
            let shape = r.sk(t.node) as? SKShapeNode
            #expect(shape?.parent === r.sk(r.model.root.childNode(withName: "tethers")))
            #expect(shape?.glowWidth == 2 && shape?.lineWidth == 2)
            #expect(shape?.strokeColor == NSColor(Team.color(0)))
            let c = r.model.tetherCurve(from: t.bossKey, to: t.key)!
            #expect(shape?.path == SpriteKitDisplay.tetherPath(c, phase: t.phase))
            #expect(shape?.path?.boundingBoxOfPath.isEmpty == false)
        }
        r.model.highlight(nil)
        r.run(1.0 / 60)
        #expect(r.sk(r.model.root.childNode(withName: "tethers"))?.children.isEmpty == true)
    }

    /// Drawings (the building, the header, the tooltip) are drawn into a texture once each: frames draw none.
    @Test func drawingsAreDrawnOncePerCopy() {
        let r = Rig(size: size)
        r.model.setHeader(TowerCounts(working: 1))
        r.model.render([session("a")], animated: false)
        r.run(0.1)
        let header = r.sk(r.model.root.childNode(withName: "header")) as? SKSpriteNode
        let first = header?.texture
        #expect(first != nil)
        let drawn = r.display.drawCount
        r.model.setHeader(TowerCounts(working: 1))
        r.run(1)
        #expect(r.display.drawCount == drawn)
        #expect(header?.texture === first)
        r.model.setHeader(TowerCounts(working: 2))
        r.run(1.0 / 60)
        #expect(r.display.drawCount == drawn + 1)
        #expect(header?.texture !== first)
    }

    /// A replaced drawing's texture goes in the same sync (a full-window background is 8–33 MB at 2×), as does a
    /// drawing whose node left the tree (the tooltip).
    @Test func replacedDrawingsReleaseTheirTexturesAtOnce() {
        let r = Rig(size: size)
        r.model.render([session("a")], animated: false)
        r.run(0.1)
        let held = r.display.heldDrawingTextures
        weak var oldBackground = r.model.root.childNode(withName: "background")?.drawing
        weak var oldCab = r.model.root.childNode(withName: "cab")?.drawing
        #expect(oldBackground.map(r.display.holdsTexture) == true)
        // A new size re-bakes the background, the cab and the shaft label.
        r.model.resize(to: CGSize(width: 1100, height: 760), scale: 2)
        r.run(1.0 / 60)
        #expect(oldBackground == nil && oldCab == nil)
        #expect(r.display.heldDrawingTextures == held)
        // The tooltip's texture goes when the tooltip does.
        let foot = r.model.transit.position(of: "s:a")!
        r.model.hover(at: CGPoint(x: foot.x, y: foot.y - 30))
        r.run(1.0 / 60)
        #expect(r.display.heldDrawingTextures == held + 1)
        r.model.hover(at: nil)
        r.run(1.0 / 60)
        #expect(r.display.heldDrawingTextures == held)
    }

    /// Textures made while a relief is pending get one more relief after it, so the last upload of a burst
    /// (a live resize redraws every frame) is returned to the system too; a quiet scene runs none.
    @Test func reliefRunsOnceMoreAfterABurst() {
        let r = Rig(size: size)
        r.run(SpriteKitDisplay.reliefDelay + 0.1)
        let start = r.display.reliefRuns                 // the initial drawings'
        r.model.setHeader(TowerCounts(working: 1))       // arms the relief
        r.run(0.3)
        r.model.setHeader(TowerCounts(working: 2))       // drawn while it is pending
        r.run(0.3)
        #expect(r.display.reliefRuns == start + 1)
        r.run(SpriteKitDisplay.reliefDelay + 0.1)
        #expect(r.display.reliefRuns == start + 2)      // once more, for the second header
        r.run(2)
        #expect(r.display.reliefRuns == start + 2)      // then nothing until the next upload
    }

    // MARK: Atlas textures

    /// A w×h image with a distinct colour per call and an asymmetric marker, so misplaced or flipped pixels show.
    private func marked(_ w: Int, _ h: Int, _ seed: Int) -> BakedImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGArtBackend.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: CGFloat(seed % 7) / 7, green: CGFloat(seed % 5) / 5, blue: CGFloat(seed % 3) / 3, alpha: 0.6))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 4, width: 9, height: 4))        // top-left corner
        let img = ctx.makeImage()!
        return BakedImage(pixelWidth: img.width, pixelHeight: img.height, scale: 1, native: img)
    }

    private func pixels(_ img: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGArtBackend.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: img.width * img.height * 4))
    }

    /// Images added over several commits fill shelves and spill onto a second page; every packed image's
    /// sub-texture, including ones on a page that was re-uploaded (and grew) since, samples its own pixels,
    /// and each page texture is only as tall as its shelves.
    @Test func atlasSubTexturesSampleTheirImages() {
        let atlas = TextureAtlas(backend: CGArtBackend.shared)
        let textures = AtlasTextures()
        var images: [BakedImage] = []
        for batch in 0..<4 {
            for i in 0..<12 {
                let img = i == 0 ? marked(1000, 700, batch) : marked(150, 210, batch * 12 + i)
                images.append(img)
                atlas.want(img)
            }
            #expect(atlas.commit())
            #expect(textures.update(atlas))
        }
        #expect(images.allSatisfy(textures.isPacked))
        #expect(textures.pageTextureSize(0) != nil)
        #expect((textures.pageTextureSize(1)?.height ?? 2048) < 2048)
        for img in images {
            let t = textures.texture(for: img)
            #expect(t.size() == CGSize(width: img.pixelWidth, height: img.pixelHeight))
            let same = pixels(t.cgImage()) == pixels(img.cgImage)   // a Bool: a failing array comparison would print megabytes
            #expect(same, "page \(atlas.placement(of: img)?.page ?? -1) rect \(atlas.placement(of: img)?.rect ?? .zero)")
        }
        // A small first page: one 256-row step.
        let small = TextureAtlas(backend: CGArtBackend.shared), smallTextures = AtlasTextures()
        let led = marked(10, 10, 1)
        small.want(led)
        small.commit()
        smallTextures.update(small)
        #expect(smallTextures.pageTextureSize(0) == CGSize(width: 2048, height: 256))
        let same = pixels(smallTextures.texture(for: led).cgImage()) == pixels(led.cgImage)
        #expect(same)
    }

    /// Until an image is packed it shows on a standalone texture; once packed, that copy (a GPU texture) goes.
    @Test func packedImagesDropTheirStandaloneTextures() {
        let atlas = TextureAtlas(backend: CGArtBackend.shared)
        let textures = AtlasTextures()
        let a = marked(30, 30, 3)
        textures.update(atlas)
        let standalone = textures.texture(for: a)
        #expect(standalone === AtlasTextures.texture(a))
        #expect(AtlasTextures.hasStandaloneTexture(a))
        atlas.want(a)
        atlas.commit()
        textures.update(atlas)
        #expect(textures.texture(for: a) !== standalone)
        #expect(!AtlasTextures.hasStandaloneTexture(a))
    }
}
