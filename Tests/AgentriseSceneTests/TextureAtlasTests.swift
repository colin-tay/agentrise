// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import AgentriseScene

/// Images whose pixels are plain byte arrays: `rgba` hands back what the image was made with.
final class PixelImages: ArtBackend {
    final class Pixels { let bytes: [UInt8]; init(_ b: [UInt8]) { bytes = b } }

    func bake(size: CGSize, scale: CGFloat, _ draw: (Pen) -> Void) -> BakedImage {
        let (w, h) = ArtKit.pixelSize(size, scale: scale)
        return BakedImage(pixelWidth: w, pixelHeight: h, scale: scale, native: Pixels([UInt8](repeating: 0, count: w * h * 4)))
    }

    func rgba(_ img: BakedImage) -> [UInt8] { (img.native as! Pixels).bytes }

    func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize { .zero }

    /// A w×h image with a distinct colour per seed and a white marker in its top-left corner, so misplaced or
    /// flipped pixels show. A fresh object every call: the atlas keys images by identity.
    func image(_ w: Int, _ h: Int, seed: Int = 0) -> BakedImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let marker = x < 9 && y < 4
                bytes[i] = marker ? 255 : UInt8(seed % 7 * 30)
                bytes[i + 1] = marker ? 255 : UInt8(seed % 5 * 40)
                bytes[i + 2] = marker ? 255 : UInt8(seed % 3 * 60)
                bytes[i + 3] = marker ? 255 : 153
            }
        }
        return BakedImage(pixelWidth: w, pixelHeight: h, scale: 1, native: Pixels(bytes))
    }
}

/// The atlas's packing (portable; the macOS display's page textures are checked in `SpriteKitDisplayTests`).
@Suite struct TextureAtlasTests {
    private let pixels = PixelImages()
    private func image(_ w: Int, _ h: Int, seed: Int = 0) -> BakedImage { pixels.image(w, h, seed: seed) }

    /// The image's pixels as the page holds them at its placement (`pages`: each page's pixels, read once, as a
    /// display uploads them; nil reads the page now).
    private func crop(_ atlas: TextureAtlas, _ img: BakedImage, pages: [(width: Int, height: Int, rgba: [UInt8])]? = nil) -> [UInt8]? {
        guard let (page, rect) = atlas.placement(of: img), let p = pages?[page] ?? atlas.pagePixels(page) else { return nil }
        var out: [UInt8] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let row = (y * p.width + Int(rect.minX)) * 4
            out += p.rgba[row..<(row + Int(rect.width) * 4)]
        }
        return out
    }

    @Test func packsOnCommit() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1, backend: pixels)
        let a = image(20, 10)
        // Before the commit: queued, not packed.
        atlas.want(a)
        #expect(!atlas.isPacked(a))
        #expect(atlas.placement(of: a) == nil)
        #expect(atlas.version == 0)
        #expect(atlas.commit())
        #expect(atlas.version == 1)
        #expect(atlas.isPacked(a))
        let r = atlas.placement(of: a)?.rect
        #expect(r?.width == 20 && r?.height == 10)
    }

    @Test func commitWithoutNewImagesKeepsVersion() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1, backend: pixels)
        #expect(!atlas.commit())
        #expect(atlas.version == 0)
        let a = image(8, 8)
        atlas.want(a)
        atlas.want(a)                                   // queued once
        #expect(atlas.commit())
        atlas.want(a)                                   // already packed: nothing to do
        #expect(!atlas.commit())
        #expect(atlas.version == 1)
    }

    @Test func entriesKeepMarginAndSpacing() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1, backend: pixels)
        let images = (0..<4).map { _ in image(20, 20) }
        for i in images { atlas.want(i) }
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
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1, backend: pixels)
        // 30×30 + gutter = 32: four fill the page.
        let first = (0..<4).map { _ in image(30, 30) }
        for i in first { atlas.want(i) }
        atlas.commit()
        #expect(first.allSatisfy(atlas.isPacked))

        // A fifth doesn't fit: the atlas starts over with it.
        let e = image(30, 30)
        atlas.want(e)
        #expect(atlas.commit())
        #expect(atlas.version == 2)
        #expect(atlas.isPacked(e))
        #expect(!first.contains(where: atlas.isPacked))

        // A rebind asks for the old ones again: they are queued and packed on the next commit as far as they
        // fit. Right after a reset the atlas doesn't reset again; the one left over stays standalone.
        for i in first { atlas.want(i) }
        #expect(atlas.commit())
        #expect(first.prefix(3).allSatisfy(atlas.isPacked))
        #expect(atlas.isPacked(e))
        #expect(!atlas.isPacked(first[3]))
        atlas.want(first[3])                            // overflow: not queued again
        #expect(!atlas.commit())

        // The next image that doesn't fit may reset again, which also lets the overflow back in.
        let f = image(30, 30)
        atlas.want(f)
        #expect(atlas.commit())
        #expect(atlas.isPacked(f))
        #expect(!atlas.isPacked(e))
        atlas.want(first[3])
        #expect(atlas.commit())
        #expect(atlas.isPacked(first[3]))
    }

    @Test func imagesLargerThanAPageStayStandalone() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 1, backend: pixels)
        let wide = image(63, 10), tall = image(10, 63), fits = image(62, 62)
        atlas.want(wide)
        atlas.want(tall)
        #expect(!atlas.commit())                       // never queued
        #expect(!atlas.isPacked(wide) && !atlas.isPacked(tall))
        atlas.want(fits)
        #expect(atlas.commit())
        #expect(atlas.placement(of: fits)?.rect == CGRect(x: 1, y: 1, width: 62, height: 62))
    }

    /// The default atlas: three 2048-wide pages, each only as tall as its filled shelves (in 256-row steps).
    @Test func pagesAreOnlyAsTallAsTheirShelves() {
        let atlas = TextureAtlas(backend: pixels)
        #expect(atlas.pageSize == 2048 && atlas.maxPages == 3 && atlas.rowStep == 256)
        let led = image(10, 10, seed: 1)
        atlas.want(led)
        atlas.commit()
        #expect(atlas.pagePixels(0).map { [$0.width, $0.height] } == [2048, 256])
        #expect(atlas.pagePixels(0)?.rgba.count == 2048 * 256 * 4)
        // A 300 px tall image opens a second shelf below the first (12 px): 12 + 302 = 314 rows → 512.
        atlas.want(image(2040, 300, seed: 2))
        atlas.commit()
        #expect(atlas.pagePixels(0).map { [$0.width, $0.height] } == [2048, 512])
        let same = crop(atlas, led) == pixels.rgba(led)
        #expect(same)
    }

    /// Images added over several commits fill shelves and spill onto a second page; every packed image,
    /// including ones packed by earlier commits on a page that was re-rendered (and grew) since, keeps its own pixels.
    @Test func incrementalAddsAcrossPagesKeepEveryImagesPixels() {
        let atlas = TextureAtlas(backend: pixels)
        var images: [BakedImage] = []
        for batch in 0..<4 {
            for i in 0..<12 {
                // Mostly robot-part sized, plus one big image per batch so the first page runs out.
                let img = i == 0 ? image(1000, 700, seed: batch) : image(150, 210, seed: batch * 12 + i)
                images.append(img)
                atlas.want(img)
            }
            #expect(atlas.commit())
        }
        #expect(images.allSatisfy(atlas.isPacked))
        #expect(Set(images.compactMap { atlas.placement(of: $0)?.page }) == [0, 1])
        #expect(atlas.pageCount == 2)
        let pages = (0..<atlas.pageCount).compactMap { atlas.pagePixels($0) }
        #expect(pages.count == 2)
        #expect((pages.last?.height ?? 2048) < 2048)
        for img in images {
            let same = crop(atlas, img, pages: pages) == pixels.rgba(img)   // a Bool: a failing array comparison would print megabytes
            #expect(same, "page \(atlas.placement(of: img)?.page ?? -1) rect \(atlas.placement(of: img)?.rect ?? .zero)")
        }
    }

    /// Filling every page resets the atlas, and what is still asked for packs again from scratch.
    @Test func fullDefaultAtlasResetsAndRepacks() {
        let atlas = TextureAtlas(backend: pixels)
        let big = (0..<12).map { image(1000, 1000, seed: $0) }      // four per page
        for i in big { atlas.want(i) }
        atlas.commit()
        #expect(Set(big.compactMap { atlas.placement(of: $0)?.page }) == [0, 1, 2])
        let extra = image(1000, 1000, seed: 99)
        atlas.want(extra)
        #expect(atlas.commit())
        #expect(atlas.placement(of: extra)?.page == 0)
        #expect(!big.contains(where: atlas.isPacked))
        for i in big.prefix(3) { atlas.want(i) }                    // still on screen: queued again
        #expect(atlas.commit())
        #expect(big.prefix(3).allSatisfy(atlas.isPacked))
        #expect(atlas.pagePixels(0)?.height == 2048)                // all four on the first page again
        #expect(atlas.pageCount == 1)
        #expect(atlas.pagePixels(1) == nil)
        for img in [extra] + big.prefix(3) {
            let same = crop(atlas, img) == pixels.rgba(img)
            #expect(same)
        }
    }

    /// Page revisions say which pages a display must upload again: only the ones a commit changed.
    @Test func revisionsCountOnlyChangedPages() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 2, backend: pixels)
        for _ in 0..<4 { atlas.want(image(30, 30)) }
        atlas.commit()
        let r0 = atlas.pageRevision(0)
        atlas.want(image(30, 30))                                   // opens page 1
        atlas.commit()
        #expect(atlas.pageRevision(0) == r0)
        #expect(atlas.pageRevision(1) > 0)
    }

    /// Only the open page keeps its images alive (it is drawn again when entries are added); a full page lets go
    /// of images nobody shows any more once its pixels have been read.
    @Test func onlyTheOpenPageKeepsImagesAlive() {
        let atlas = TextureAtlas(pageSize: 64, maxPages: 2, backend: pixels)
        weak var gone: BakedImage?
        var kept: BakedImage? = image(30, 30)
        do {
            let a = image(30, 30)
            gone = a
            atlas.want(a)
            atlas.want(kept!)
            atlas.commit()
            #expect(atlas.isPacked(a))
            _ = atlas.pagePixels(0)                       // the display uploads it
        }
        #expect(gone != nil)                              // page 0 is still open
        // Page 0 holds four; two more open page 1, so page 0 is full.
        let more = (0..<4).map { _ in image(30, 30) }
        for i in more { atlas.want(i) }
        atlas.commit()
        #expect(atlas.placement(of: more[3])?.page == 1)
        for i in 0..<atlas.pageCount { _ = atlas.pagePixels(i) }
        #expect(gone == nil)                              // nobody shows it and page 0 needn't draw it again
        #expect(atlas.isPacked(kept!))                    // still held by its owner: still packed
        // Once its owner lets go too, nothing keeps it: the entry is stale and the image is freed.
        weak var keptWeak = kept
        kept = nil
        #expect(keptWeak == nil)
        #expect(more.allSatisfy(atlas.isPacked))          // the rest is unaffected
    }
}
