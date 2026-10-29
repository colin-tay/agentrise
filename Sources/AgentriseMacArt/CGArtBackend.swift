// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import SpriteKit
import AgentriseScene

/// Bakes the portable art with Core Graphics: a premultiplied RGBA sRGB bitmap context, y down, drawn through
/// `CGPen`. `BakedImage.native` is the `CGImage`.
package final class CGArtBackend: ArtBackend {
    package static let shared = CGArtBackend()

    package static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    package func bake(size: CGSize, scale: CGFloat, _ draw: (Pen) -> Void) -> BakedImage {
        let image = Self.image(size: size, scale: scale) { ctx in draw(CGPen(ctx: ctx, scale: scale)) }
        return BakedImage(pixelWidth: image.width, pixelHeight: image.height, scale: scale, native: image)
    }

    package func rgba(_ img: BakedImage) -> [UInt8] {
        let w = img.pixelWidth, h = img.pixelHeight
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in Self.copyPixels(img.cgImage, into: buf.baseAddress!) }
        return bytes
    }

    package func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize {
        Self.measure(runs, maxWidth: maxWidth, maxLines: maxLines)
    }

    // MARK: Core Graphics bitmaps

    /// Renders `draw` into a transparent bitmap of `ArtKit.pixelSize(size, scale:)` pixels. The closure works in
    /// points with the origin at the top-left corner and y growing downwards.
    package static func image(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
        let (w, h) = ArtKit.pixelSize(size, scale: scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        prepare(ctx, height: h, scale: scale)
        draw(ctx)
        return ctx.makeImage()!
    }

    /// Like `image(...)`, but straight into a texture that keeps no CPU-side copy once it is on the GPU.
    ///
    /// `SKTexture(cgImage:)` retains the image (its whole bitmap) for the texture's lifetime. A texture made
    /// from raw data copies the bytes and frees its copy after the upload, so a big one-off bitmap (the
    /// building background is ~33 MB at 2×) only lives on the GPU. The pixels are the same: premultiplied
    /// RGBA in `colorSpace`, rows top-down. The freed memory may sit in malloc's cache until `releaseFreedPixels()`.
    package static func texture(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> SKTexture {
        let (w, h) = ArtKit.pixelSize(size, scale: scale)
        let bytesPerRow = w * 4, count = bytesPerRow * h
        let buffer = calloc(count, 1)!
        do {
            let ctx = CGContext(data: buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            prepare(ctx, height: h, scale: scale)
            draw(ctx)
            ctx.flush()
        }
        return texture(pixels: NSData(bytesNoCopy: buffer, length: count, freeWhenDone: true) as Data, width: w, height: h)
    }

    /// A raw-data texture of a baked image (see `texture(size:scale:_:)`): once the caller lets go of `img`,
    /// its pixels live only on the GPU.
    package static func texture(_ img: BakedImage) -> SKTexture {
        let w = img.pixelWidth, h = img.pixelHeight, count = w * h * 4
        let buffer = calloc(count, 1)!
        copyPixels(img.cgImage, into: buffer)
        return texture(pixels: NSData(bytesNoCopy: buffer, length: count, freeWhenDone: true) as Data, width: w, height: h)
    }

    /// A texture from premultiplied RGBA rows (top row first) in `colorSpace`; see `texture(size:scale:_:)`.
    package static func texture(pixels: Data, width: Int, height: Int) -> SKTexture {
        SKTexture(data: pixels, size: CGSize(width: width, height: height), flipped: true)
    }

    /// Hands memory freed by uploaded textures back to the system. Large freed blocks otherwise stay in
    /// malloc's cache and still count towards the process footprint. Cheap; call it a moment after uploads.
    package static func releaseFreedPixels() { _ = malloc_zone_pressure_relief(nil, 0) }

    private static func prepare(_ ctx: CGContext, height h: Int, scale: CGFloat) {
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
    }

    /// Copies `image` unchanged into `buffer` as tightly packed premultiplied RGBA rows, top row first.
    private static func copyPixels(_ image: CGImage, into buffer: UnsafeMutableRawPointer) {
        let w = image.width, h = image.height
        let ctx = CGContext(data: buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.flush()
    }

    // MARK: Text

    /// The system font in the art's weights.
    package static func font(_ f: FontSpec) -> NSFont { NSFont.systemFont(ofSize: f.size, weight: NSFont.Weight(f.weight)) }

    /// `runs` as one centred attributed string, cut after `maxLines` lines when laid out `width` wide (0: all).
    package static func attributed(_ runs: [TextRun], width: CGFloat, maxLines: Int) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for r in runs {
            text.append(NSAttributedString(string: r.text, attributes: [.font: font(r.font), .foregroundColor: NSColor(r.color)]))
        }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        guard maxLines > 0 else { return text }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width.isFinite ? width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var chars = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
        guard chars.length < text.length else { return text }
        // The kept lines end in the line break that started the next: drop it, or it lays out an empty line.
        let kept = text.string as NSString
        while chars.length > 0, CharacterSet.newlines.contains(Unicode.Scalar(kept.character(at: NSMaxRange(chars) - 1)) ?? " ") { chars.length -= 1 }
        return text.attributedSubstring(from: chars)
    }

    /// `runs` as a plain attributed string (natural alignment), cut with an ellipsis where it overflows when
    /// `truncatesTail`: what the header and the tooltip rows drew before the art went through `Pen`.
    package static func line(_ runs: [TextRun], truncatesTail: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for r in runs {
            text.append(NSAttributedString(string: r.text, attributes: [.font: font(r.font), .foregroundColor: NSColor(r.color)]))
        }
        if truncatesTail {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        }
        return text
    }

    package static func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize {
        let width = maxWidth.isFinite ? maxWidth : .greatestFiniteMagnitude
        return attributed(runs, width: width, maxLines: maxLines)
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
    }

    /// Draws an attributed string top-aligned in `rect`. `ctx` must be a y-down context.
    package static func draw(_ s: NSAttributedString, in rect: CGRect, ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        s.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension BakedImage {
    /// The Core Graphics image of an image baked by `CGArtBackend`.
    package var cgImage: CGImage { native as! CGImage }
}

extension RobotArt {
    /// Robot art baked with Core Graphics.
    package convenience init(scale: CGFloat) { self.init(scale: scale, backend: CGArtBackend.shared) }

    /// `shared(scale:backend:)` with Core Graphics.
    package static func shared(scale: CGFloat) -> RobotArt { shared(scale: scale, backend: CGArtBackend.shared) }
}
