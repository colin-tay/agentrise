// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import SpriteKit
import AgentriseScene

/// A runtime texture atlas for baked robot images, so SpriteKit can draw many robots' parts in one
/// batch instead of one draw call per part.
///
/// Images arrive one at a time (names and bubbles are open-ended strings), so packing is deferred:
/// `texture(for:)` hands out a standalone texture for an image it hasn't packed yet and queues it;
/// `commit()` packs the queue into the pages, re-uploads the pages that changed and bumps `version`.
/// Whoever holds atlas textures re-asks `texture(for:)` when `version` changes (`RobotSprite.rebindTextures`).
///
/// Pixels are copied unchanged (same colour space and alpha format as `CGArtBackend` bakes) with a transparent
/// gutter around entries (1 px to the page edge, 2 px between neighbours), so a packed image samples like
/// its standalone texture. Images that don't fit in an empty page stay standalone.
///
/// Pages keep no bitmap: a commit re-renders each changed page from its entries' source images into a
/// temporary buffer and uploads it as a raw-data texture, which SpriteKit frees once it is on the GPU
/// (`CGArtBackend.texture(pixels:width:height:)`), so a page costs its GPU copy only. A page's texture is only as
/// tall as its filled shelves (rounded up to `rowStep` rows), so the last, partly filled page doesn't hold
/// a full page of empty pixels. (Smaller square pages would waste as little, but robots' parts then spread
/// over more pages and SpriteKit draws them in many more batches.)
///
/// When every page is full, the atlas starts over (`reset`) with the image that didn't fit; images still on
/// screen are queued again on the next rebind and repacked. To avoid resetting on every frame when the
/// images in use simply don't all fit, a commit right after a reset doesn't reset again: what doesn't fit
/// then stays standalone ("overflow") until the next reset.
final class TextureAtlas {
    /// Page edge in pixels.
    let pageSize: Int
    /// The atlas never grows past this many pages (see the reset rule above).
    let maxPages: Int
    /// A page texture's height is its filled height rounded up to a multiple of this.
    let rowStep: Int
    static let gutter = 2

    private(set) var version = 0

    private final class Page {
        var texture: SKTexture?
        var shelfX = 0, shelfY = 0, shelfHeight = 0
        var dirty = false
        /// Rows in `texture` (≤ `pageSize`).
        var textureHeight = 0
        /// What the page holds, so it can be drawn again when entries are added.
        var placed: [(image: BakedImage, rect: CGRect)] = []
    }

    private struct Entry {
        let page: Int
        let rect: CGRect          // pixels, CG (bottom-left) origin
        /// Not kept alive by the entry: the open page's `placed` list holds its images (it is drawn again on
        /// the next add), while a full page is never drawn again and needs none. Whoever shows an image holds it.
        weak var image: BakedImage?
        var texture: SKTexture?
    }

    /// Hashes a `BakedImage` by identity and keeps it alive (queued and overflow images).
    private struct Key: Hashable {
        let image: BakedImage
        static func == (a: Key, b: Key) -> Bool { a.image === b.image }
        func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(image)) }
    }

    private let lock = NSLock()
    private var pages: [Page] = []
    /// By image identity; an entry whose image is gone is stale (its pixels stay unused until the next reset).
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var pending: [Key] = []
    private var pendingSet: Set<Key> = []
    /// Didn't fit after a reset; standalone (and not queued again) until the next reset.
    private var overflow: Set<Key> = []
    private var lastCommitReset = false

    init(pageSize: Int = 2048, maxPages: Int = 3, rowStep: Int = 256) {
        self.pageSize = pageSize
        self.maxPages = maxPages
        self.rowStep = max(1, min(rowStep, pageSize))
    }

    /// The image's packed texture, or (until the next `commit`) a standalone one.
    func texture(for image: BakedImage) -> SKTexture {
        lock.lock(); defer { lock.unlock() }
        let key = Key(image: image)
        if let e = entry(image) {
            if let t = e.texture { return t }
            if let page = pages[e.page].texture {
                let t = SKTexture(rect: unitRect(e.rect, height: pages[e.page].textureHeight), in: page)
                entries[ObjectIdentifier(image)]?.texture = t
                return t
            }
        }
        if fits(image), !overflow.contains(key), pendingSet.insert(key).inserted {
            pending.append(key)
        }
        return RobotSprite.texture(image)
    }

    /// Whether `texture(for:)` would return a packed texture for this image.
    func isPacked(_ image: BakedImage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entry(image) != nil
    }

    /// Where a packed image sits: page index and pixel rect (bottom-left origin). For tests.
    func placement(of image: BakedImage) -> (page: Int, rect: CGRect)? {
        lock.lock(); defer { lock.unlock() }
        return entry(image).map { ($0.page, $0.rect) }
    }

    /// The live entry for `image`. A stale entry under the same identifier (its image was freed and the
    /// address reused) is dropped.
    private func entry(_ image: BakedImage) -> Entry? {
        let id = ObjectIdentifier(image)
        guard let e = entries[id] else { return nil }
        if e.image === image { return e }
        entries[id] = nil
        return nil
    }

    /// Small enough for an empty page, gutter included.
    private func fits(_ image: BakedImage) -> Bool {
        image.pixelWidth + Self.gutter <= pageSize && image.pixelHeight + Self.gutter <= pageSize
    }

    /// Packs the queued images; true (and a new `version`) when anything changed.
    @discardableResult
    func commit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return false }
        let queue = pending
        pending.removeAll()
        pendingSet.removeAll()
        var didReset = false
        for key in queue where entry(key.image) == nil {
            if pack(key) { continue }
            if !didReset && !lastCommitReset {
                // Full: start over; images still on screen come back on the next rebind.
                reset()
                didReset = true
                if pack(key) { continue }
            }
            overflow.insert(key)
        }
        lastCommitReset = didReset
        var uploaded: Set<Int> = []
        for (i, page) in pages.enumerated() where page.dirty {
            page.texture = render(page)
            page.dirty = false
            uploaded.insert(i)
        }
        // Only the last page takes new entries: the others let go of their images.
        for page in pages.dropLast() { page.placed.removeAll() }
        // Sub-textures of a re-uploaded page point at its old texture: make them again on demand.
        for (k, e) in entries {
            if e.image == nil { entries[k] = nil } else if uploaded.contains(e.page) { entries[k]?.texture = nil }
        }
        // Packed images draw from the atlas now: their standalone textures (GPU copies) can go.
        for key in queue where entry(key.image) != nil { RobotSprite.forgetTexture(key.image) }
        version += 1
        return true
    }

    /// Size in pixels of a page's current texture. For tests.
    func pageTextureSize(_ i: Int) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        guard pages.indices.contains(i), pages[i].texture != nil else { return nil }
        return CGSize(width: pageSize, height: pages[i].textureHeight)
    }

    /// Draws a page's entries into a fresh buffer, as tall as its shelves need, and hands it to SpriteKit
    /// (which frees it after the upload). Entries sit at the same CG (bottom-left origin) rects whatever the height.
    private func render(_ page: Page) -> SKTexture {
        let filled = page.shelfY + page.shelfHeight
        let height = min(pageSize, max(1, (filled + rowStep - 1) / rowStep) * rowStep)
        page.textureHeight = height
        let bytesPerRow = pageSize * 4, count = bytesPerRow * height
        let buffer = calloc(count, 1)!
        do {
            let ctx = CGContext(data: buffer, width: pageSize, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGArtBackend.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            for p in page.placed { ctx.draw(p.image.cgImage, in: p.rect) }
            ctx.flush()
        }
        return CGArtBackend.texture(pixels: NSData(bytesNoCopy: buffer, length: count, freeWhenDone: true) as Data, width: pageSize, height: height)
    }

    private func reset() {
        pages.removeAll()
        entries.removeAll()
        overflow.removeAll()
    }

    /// Shelf packing: fill rows left to right, open a new row (or page) when the image doesn't fit.
    private func pack(_ key: Key) -> Bool {
        let w = key.image.pixelWidth + Self.gutter, h = key.image.pixelHeight + Self.gutter
        func place(in i: Int) -> Bool {
            let p = pages[i]
            if p.shelfX + w > pageSize {
                p.shelfY += p.shelfHeight
                p.shelfX = 0
                p.shelfHeight = 0
            }
            guard p.shelfY + h <= pageSize else { return false }
            let rect = CGRect(x: p.shelfX + Self.gutter / 2, y: p.shelfY + Self.gutter / 2, width: key.image.pixelWidth, height: key.image.pixelHeight)
            p.placed.append((key.image, rect))
            p.shelfX += w
            p.shelfHeight = max(p.shelfHeight, h)
            p.dirty = true
            entries[ObjectIdentifier(key.image)] = Entry(page: i, rect: rect, image: key.image, texture: nil)
            return true
        }
        if let last = pages.indices.last, place(in: last) { return true }
        guard pages.count < maxPages else { return false }
        pages.append(Page())
        return place(in: pages.count - 1)
    }

    private func unitRect(_ r: CGRect, height: Int) -> CGRect {
        let w = CGFloat(pageSize), h = CGFloat(height)
        return CGRect(x: r.minX / w, y: r.minY / h, width: r.width / w, height: r.height / h)
    }
}
