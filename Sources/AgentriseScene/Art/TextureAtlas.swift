// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Packs baked robot images into a few big pages, so a display can draw many robots' parts in one batch
/// instead of one draw call per part. The packing is portable; uploading the pages is the display's job.
///
/// Images arrive one at a time (names and bubbles are open-ended strings), so packing is deferred: `want(_:)`
/// queues an image that isn't packed yet; `commit()` packs the queue into the pages and bumps `version` (and the
/// revision of each page it changed). Until then a display shows the image on its own. Whoever shows atlas
/// images asks for them again when `version` changes (`RobotRig.requeue`), which brings images back after a reset.
///
/// Entries keep a transparent gutter (1 px to the page edge, 2 px between neighbours), so a packed image
/// samples like a standalone one. Images that don't fit in an empty page are never packed.
///
/// Pages keep no bitmap: `pagePixels(_:)` (or `drawPage(_:into:)`) renders a page from its entries' images
/// (`ArtBackend.rgba`) when a display uploads it. A page is only as tall as its filled shelves (rounded up to
/// `rowStep` rows), so the last, partly filled page doesn't hold a full page of empty pixels. Only the open
/// (last) page keeps its images alive for good, as it is drawn again when entries are added; a full page lets
/// go of its images once its pixels have been read after its last change.
///
/// When every page is full, the atlas starts over (`reset`) with the image that didn't fit; images still on
/// screen are queued again on the next requeue and repacked. To avoid resetting on every frame when the
/// images in use simply don't all fit, a commit right after a reset doesn't reset again: what doesn't fit
/// then stays standalone ("overflow") until the next reset.
package final class TextureAtlas {
    /// Page edge in pixels.
    package let pageSize: Int
    /// The atlas never grows past this many pages (see the reset rule above).
    package let maxPages: Int
    /// A page's height is its filled height rounded up to a multiple of this.
    package let rowStep: Int
    package static let gutter = 2

    private let backend: ArtBackend
    package private(set) var version = 0

    private final class Page {
        var shelfX = 0, shelfY = 0, shelfHeight = 0
        /// New (unique across the atlas's life) after every commit that adds to the page.
        var revision = 0
        /// Changed by the commit in progress.
        var dirty = false
        /// Changed since its pixels were last read.
        var unread = false
        /// What the page holds, so it can be drawn (again).
        var placed: [(image: BakedImage, rect: CGRect)] = []
    }

    private struct Entry {
        let page: Int
        let rect: CGRect          // pixels, top-left origin
        /// Not kept alive by the entry: the page's `placed` list holds its images while it may be drawn again.
        /// Whoever shows an image holds it.
        weak var image: BakedImage?
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
    private var nextRevision = 1

    package init(pageSize: Int = 2048, maxPages: Int = 3, rowStep: Int = 256, backend: ArtBackend) {
        self.pageSize = pageSize
        self.maxPages = maxPages
        self.rowStep = max(1, min(rowStep, pageSize))
        self.backend = backend
    }

    /// Queues `image` for the next `commit` unless it is packed already, can't fit, or overflowed.
    package func want(_ image: BakedImage) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(image: image)
        guard entry(image) == nil, fits(image), !overflow.contains(key), pendingSet.insert(key).inserted else { return }
        pending.append(key)
    }

    package func isPacked(_ image: BakedImage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entry(image) != nil
    }

    /// Where a packed image sits: page index and pixel rect (top-left origin, rows top first like `pagePixels`).
    package func placement(of img: BakedImage) -> (page: Int, rect: CGRect)? {
        lock.lock(); defer { lock.unlock() }
        return entry(img).map { ($0.page, $0.rect) }
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

    /// Packs the queued images; true (and a new `version`) when any page changed.
    @discardableResult
    package func commit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return false }
        let queue = pending
        pending.removeAll()
        pendingSet.removeAll()
        var didReset = false
        var changed = false
        for key in queue where entry(key.image) == nil {
            if pack(key) { changed = true; continue }
            if !didReset && !lastCommitReset {
                // Full: start over; images still on screen come back on the next requeue.
                reset()
                didReset = true
                changed = true
                if pack(key) { continue }
            }
            overflow.insert(key)
        }
        lastCommitReset = didReset
        guard changed else { return false }
        for page in pages where page.dirty {
            page.revision = nextRevision
            nextRevision += 1
            page.dirty = false
        }
        dropFullPagesImages()
        for (k, e) in entries where e.image == nil { entries[k] = nil }
        version += 1
        return true
    }

    /// Pages now in the atlas (a reset empties it).
    package var pageCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pages.count
    }

    /// Changes whenever a commit adds to page `i`: a display uploads the pages whose revision it hasn't seen.
    package func pageRevision(_ i: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return pages.indices.contains(i) ? pages[i].revision : -1
    }

    /// Page `i`'s size in pixels: `pageSize` wide, its filled shelves (rounded up to `rowStep`) tall.
    package func pageDimensions(_ i: Int) -> (width: Int, height: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard pages.indices.contains(i) else { return nil }
        return (pageSize, height(of: pages[i]))
    }

    /// Page `i`'s pixels: premultiplied RGBA, rows top first, `width × 4` bytes per row, transparent between
    /// entries. Reading a full page lets go of its images.
    package func pagePixels(_ i: Int) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let (w, h) = pageDimensions(i) else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { drawPage(i, into: $0) }
        return ok ? (w, h, rgba) : nil
    }

    /// Writes page `i` into `buffer` (at least `pageDimensions(i)` of RGBA, zeroed by the caller) — what
    /// `pagePixels` returns, without an intermediate array. False when the page doesn't exist or no longer holds
    /// its images (it was read since its last change).
    @discardableResult
    package func drawPage(_ i: Int, into buffer: UnsafeMutableRawBufferPointer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pages.indices.contains(i) else { return false }
        let page = pages[i]
        let h = height(of: page), rowBytes = pageSize * 4
        guard buffer.count >= rowBytes * h else { return false }
        // A full page that was read lets go of its images: it can't be drawn again.
        if page.placed.isEmpty && !page.unread && i < pages.count - 1 { return false }
        for p in page.placed {
            let w = p.image.pixelWidth, ih = p.image.pixelHeight
            let src = backend.rgba(p.image)
            guard src.count >= w * ih * 4 else { continue }
            let x = Int(p.rect.minX), y = Int(p.rect.minY)
            src.withUnsafeBytes { s in
                for row in 0..<ih {
                    let to = (y + row) * rowBytes + x * 4
                    buffer.baseAddress!.advanced(by: to).copyMemory(from: s.baseAddress!.advanced(by: row * w * 4), byteCount: w * 4)
                }
            }
        }
        page.unread = false
        dropFullPagesImages()
        return true
    }

    /// Full pages that were read since their last change won't be drawn again: their images can go.
    private func dropFullPagesImages() {
        for page in pages.dropLast() where !page.unread { page.placed.removeAll() }
    }

    private func height(of page: Page) -> Int {
        let filled = page.shelfY + page.shelfHeight
        return min(pageSize, max(1, (filled + rowStep - 1) / rowStep) * rowStep)
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
            p.unread = true
            entries[ObjectIdentifier(key.image)] = Entry(page: i, rect: rect, image: key.image)
            return true
        }
        if let last = pages.indices.last, place(in: last) { return true }
        guard pages.count < maxPages else { return false }
        pages.append(Page())
        return place(in: pages.count - 1)
    }
}
