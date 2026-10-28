// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import CoreGraphics
import SpriteKit
@testable import AgentriseApp
@testable import Agentrise
@testable import AgentriseScene

@MainActor
@Suite struct TextureAtlasTests {
    /// A solid w×h image (a fresh object every call: the atlas keys images by identity).
    private func image(_ w: Int, _ h: Int) -> BakedImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGArtBackend.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return baked(ctx.makeImage()!)
    }

    private func baked(_ img: CGImage) -> BakedImage {
        BakedImage(pixelWidth: img.width, pixelHeight: img.height, scale: 1, native: img)
    }

    @Test func packsOnCommit() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1)
        let a = image(20, 10)
        // Before the commit: the shared standalone texture, queued.
        #expect(atlas.texture(for: a) === RobotSprite.texture(a))
        #expect(!atlas.isPacked(a))
        #expect(atlas.version == 0)
        #expect(atlas.commit())
        #expect(atlas.version == 1)
        #expect(atlas.isPacked(a))
        let t = atlas.texture(for: a)
        #expect(t !== RobotSprite.texture(a))
        let r = t.textureRect()
        #expect(abs(r.width * 64 - 20) < 1e-6 && abs(r.height * 64 - 10) < 1e-6)
        #expect(atlas.texture(for: a) === t)          // cached until the page is re-uploaded
    }

    @Test func commitWithoutNewImagesKeepsVersion() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1)
        #expect(!atlas.commit())
        #expect(atlas.version == 0)
        let a = image(8, 8)
        _ = atlas.texture(for: a)
        _ = atlas.texture(for: a)                      // queued once
        #expect(atlas.commit())
        _ = atlas.texture(for: a)                      // already packed: nothing to do
        #expect(!atlas.commit())
        #expect(atlas.version == 1)
    }

    @Test func entriesKeepMarginAndSpacing() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1)
        let images = (0..<4).map { _ in image(20, 20) }
        for i in images { _ = atlas.texture(for: i) }
        atlas.commit()
        let rects = images.compactMap { atlas.placement(of: $0)?.rect }
        #expect(rects.count == 4)
        // Two per 22 px cell row: (1, 1), (23, 1), then the next row.
        #expect(rects[0] == CGRect(x: 1, y: 1, width: 20, height: 20))
        #expect(rects[1] == CGRect(x: 23, y: 1, width: 20, height: 20))
        #expect(rects[2] == CGRect(x: 1, y: 23, width: 20, height: 20))
        let page = CGRect(x: 0, y: 0, width: 64, height: 64)
        for (i, a) in rects.enumerated() {
            #expect(page.insetBy(dx: 1, dy: 1).contains(a))             // ≥ 1 px to the page edge
            for b in rects[(i + 1)...] {
                // ≥ 2 px apart: grown by 1 px each, they may touch but not overlap.
                let ga = a.insetBy(dx: -1, dy: -1), gb = b.insetBy(dx: -1, dy: -1)
                let overlaps = ga.minX < gb.maxX && gb.minX < ga.maxX && ga.minY < gb.maxY && gb.minY < ga.maxY
                #expect(!overlaps, "\(a) and \(b) are closer than 2 px")
            }
        }
    }

    @Test func fullPageResetsAndInUseImagesComeBack() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1)
        // 30×30 + gutter = 32: four fill the page.
        let first = (0..<4).map { _ in image(30, 30) }
        for i in first { _ = atlas.texture(for: i) }
        atlas.commit()
        #expect(first.allSatisfy(atlas.isPacked))

        // A fifth doesn't fit: the atlas starts over with it.
        let e = image(30, 30)
        _ = atlas.texture(for: e)
        #expect(atlas.commit())
        #expect(atlas.version == 2)
        #expect(atlas.isPacked(e))
        #expect(!first.contains(where: atlas.isPacked))

        // A rebind asks for the old ones again: they are standalone, queued, and packed on the next commit
        // as far as they fit. Right after a reset the atlas doesn't reset again; the one left over stays standalone.
        for i in first { #expect(atlas.texture(for: i) === RobotSprite.texture(i)) }
        #expect(atlas.commit())
        #expect(first.prefix(3).allSatisfy(atlas.isPacked))
        #expect(atlas.isPacked(e))
        #expect(!atlas.isPacked(first[3]))
        _ = atlas.texture(for: first[3])                // overflow: not queued again
        #expect(!atlas.commit())

        // The next image that doesn't fit may reset again, which also lets the overflow back in.
        let f = image(30, 30)
        _ = atlas.texture(for: f)
        #expect(atlas.commit())
        #expect(atlas.isPacked(f))
        #expect(!atlas.isPacked(e))
        _ = atlas.texture(for: first[3])
        #expect(atlas.commit())
        #expect(atlas.isPacked(first[3]))
    }

    @Test func imagesLargerThanAPageStayStandalone() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1)
        let wide = image(63, 10), tall = image(10, 63), fits = image(62, 62)
        #expect(atlas.texture(for: wide) === RobotSprite.texture(wide))
        #expect(atlas.texture(for: tall) === RobotSprite.texture(tall))
        #expect(!atlas.commit())                       // never queued
        #expect(!atlas.isPacked(wide) && !atlas.isPacked(tall))
        _ = atlas.texture(for: fits)
        #expect(atlas.commit())
        #expect(atlas.placement(of: fits)?.rect == CGRect(x: 1, y: 1, width: 62, height: 62))
    }

    /// A w×h image with a distinct colour per call and an asymmetric marker, so misplaced or flipped pixels show.
    private func marked(_ w: Int, _ h: Int, _ seed: Int) -> BakedImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGArtBackend.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: CGFloat(seed % 7) / 7, green: CGFloat(seed % 5) / 5, blue: CGFloat(seed % 3) / 3, alpha: 0.6))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 4, width: 9, height: 4))        // top-left corner
        return baked(ctx.makeImage()!)
    }

    private func pixels(_ img: BakedImage) -> [UInt8] { pixels(img.cgImage) }

    private func pixels(_ img: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGArtBackend.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: img.width * img.height * 4))
    }

    /// The default atlas: three 2048-wide pages, each texture only as tall as its filled shelves (in 256-row steps).
    @Test func pageTexturesAreOnlyAsTallAsTheirShelves() {
        let atlas = TextureAtlas()
        #expect(atlas.pageSize == 2048 && atlas.maxPages == 3 && atlas.rowStep == 256)
        let led = marked(10, 10, 1)
        _ = atlas.texture(for: led)
        atlas.commit()
        #expect(atlas.pageTextureSize(0) == CGSize(width: 2048, height: 256))
        let r = atlas.texture(for: led).textureRect()
        #expect(abs(r.height * 256 - 10) < 1e-6 && abs(r.width * 2048 - 10) < 1e-6)
        // A 300 px tall image opens a second shelf on top of the first (12 px): 12 + 302 = 314 rows → 512.
        _ = atlas.texture(for: marked(2040, 300, 2))
        atlas.commit()
        #expect(atlas.pageTextureSize(0) == CGSize(width: 2048, height: 512))
        let same = pixels(atlas.texture(for: led).cgImage()) == pixels(led)
        #expect(same)
    }

    /// Images added over several commits fill shelves and spill onto a second page; every packed image,
    /// including ones packed by earlier commits on a page that was re-rendered (and grew) since, samples its own pixels.
    @Test func incrementalAddsAcrossPagesKeepEveryImagesPixels() {
        let atlas = TextureAtlas()
        var images: [BakedImage] = []
        for batch in 0..<4 {
            for i in 0..<12 {
                // Mostly robot-part sized, plus one big image per batch so the first page runs out.
                let img = i == 0 ? marked(1000, 700, batch) : marked(150, 210, batch * 12 + i)
                images.append(img)
                _ = atlas.texture(for: img)
            }
            #expect(atlas.commit())
        }
        #expect(images.allSatisfy(atlas.isPacked))
        #expect(Set(images.compactMap { atlas.placement(of: $0)?.page }) == [0, 1])
        #expect(atlas.pageTextureSize(0) != nil)
        #expect((atlas.pageTextureSize(1)?.height ?? 2048) < 2048)
        for img in images {
            let t = atlas.texture(for: img)
            #expect(t.size() == CGSize(width: img.pixelWidth, height: img.pixelHeight))
            let same = pixels(t.cgImage()) == pixels(img)   // a Bool: a failing array comparison would print megabytes
            #expect(same, "page \(atlas.placement(of: img)?.page ?? -1) rect \(atlas.placement(of: img)?.rect ?? .zero)")
        }
    }

    /// Filling every page resets the atlas, and what is still asked for packs again from scratch.
    @Test func fullDefaultAtlasResetsAndRepacks() {
        let atlas = TextureAtlas()
        let big = (0..<12).map { marked(1000, 1000, $0) }           // four per page
        for i in big { _ = atlas.texture(for: i) }
        atlas.commit()
        #expect(Set(big.compactMap { atlas.placement(of: $0)?.page }) == [0, 1, 2])
        let extra = marked(1000, 1000, 99)
        _ = atlas.texture(for: extra)
        #expect(atlas.commit())
        #expect(atlas.placement(of: extra)?.page == 0)
        #expect(!big.contains(where: atlas.isPacked))
        for i in big.prefix(3) { _ = atlas.texture(for: i) }        // still on screen: queued again
        #expect(atlas.commit())
        #expect(big.prefix(3).allSatisfy(atlas.isPacked))
        #expect(atlas.pageTextureSize(0) == CGSize(width: 2048, height: 2048))   // all four on the first page again
        #expect(atlas.pageTextureSize(1) == nil)
        for img in [extra] + big.prefix(3) {
            let same = pixels(atlas.texture(for: img).cgImage()) == pixels(img)
            #expect(same)
        }
    }

    /// Packed images move off their standalone textures (GPU copies), and only the open page keeps its images
    /// alive (it is drawn again when entries are added); a full page lets go of images nobody shows any more.
    @Test func onlyTheOpenPageKeepsImagesAlive() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 2)
        weak var gone: BakedImage?
        var kept: BakedImage? = image(30, 30)
        do {
            let a = image(30, 30)
            gone = a
            _ = atlas.texture(for: a)
            _ = atlas.texture(for: kept!)
            #expect(RobotSprite.hasStandaloneTexture(a))
            atlas.commit()
            #expect(!RobotSprite.hasStandaloneTexture(a))
            #expect(atlas.isPacked(a))
        }
        #expect(gone != nil)                              // page 0 is still open
        // Page 0 holds four; two more open page 1, so page 0 is full.
        let more = (0..<4).map { _ in image(30, 30) }
        for i in more { _ = atlas.texture(for: i) }
        atlas.commit()
        #expect(atlas.placement(of: more[3])?.page == 1)
        #expect(gone == nil)                              // nobody shows it and page 0 needn't draw it again
        #expect(atlas.isPacked(kept!))                    // still held by its owner: still packed
        // Once its owner lets go too, nothing keeps it: the entry is stale and the image is freed.
        weak var keptWeak = kept
        kept = nil
        #expect(keptWeak == nil)
        #expect(more.allSatisfy(atlas.isPacked))          // the rest is unaffected
    }
}
