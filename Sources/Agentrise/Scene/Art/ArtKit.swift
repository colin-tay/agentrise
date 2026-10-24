import AppKit
import CoreGraphics
import SpriteKit

/// Bitmap baking helpers: everything the scene draws is rendered once with Core Graphics
/// into a `CGImage` and then only moved around by SpriteKit.
enum ArtKit {
    /// The robot design canvas (60×70 body plus 14 pt of headroom), y down — the old `P()/R()` space.
    static let robotCanvas = CGSize(width: 60, height: 84)

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Renders `draw` into a transparent bitmap of `size × scale` pixels. The closure works in
    /// points; with `flipped` (the default) the origin is the top-left corner and y grows downwards.
    static func image(size: CGSize, scale: CGFloat, flipped: Bool = true, _ draw: (CGContext) -> Void) -> CGImage {
        let (w, h) = pixelSize(size, scale: scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        prepare(ctx, height: h, scale: scale, flipped: flipped)
        draw(ctx)
        return ctx.makeImage()!
    }

    /// Like `image(...)`, but straight into a texture that keeps no CPU-side copy once it is on the GPU.
    ///
    /// `SKTexture(cgImage:)` retains the image (its whole bitmap) for the texture's lifetime. A texture made
    /// from raw data copies the bytes and frees its copy after the upload, so a big one-off bitmap (the
    /// building background is ~33 MB at 2×) only lives on the GPU. The pixels are the same: premultiplied
    /// RGBA in `colorSpace`, rows top-down (`flipped: true`). The freed memory may sit in malloc's cache
    /// until `releaseFreedPixels()`.
    static func texture(size: CGSize, scale: CGFloat, flipped: Bool = true, _ draw: (CGContext) -> Void) -> SKTexture {
        let (w, h) = pixelSize(size, scale: scale)
        let bytesPerRow = w * 4, count = bytesPerRow * h
        let buffer = calloc(count, 1)!
        do {
            let ctx = CGContext(data: buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            prepare(ctx, height: h, scale: scale, flipped: flipped)
            draw(ctx)
            ctx.flush()
        }
        return texture(pixels: NSData(bytesNoCopy: buffer, length: count, freeWhenDone: true) as Data, width: w, height: h)
    }

    /// A texture from premultiplied RGBA rows (top row first) in `colorSpace`; see `texture(size:scale:_:)`.
    static func texture(pixels: Data, width: Int, height: Int) -> SKTexture {
        SKTexture(data: pixels, size: CGSize(width: width, height: height), flipped: true)
    }

    /// Hands memory freed by uploaded textures back to the system. Large freed blocks otherwise stay in
    /// malloc's cache and still count towards the process footprint. Cheap; call it a moment after uploads.
    static func releaseFreedPixels() { _ = malloc_zone_pressure_relief(nil, 0) }

    private static func pixelSize(_ size: CGSize, scale: CGFloat) -> (Int, Int) {
        (max(1, Int((size.width * scale - 1e-6).rounded(.up))), max(1, Int((size.height * scale - 1e-6).rounded(.up))))
    }

    private static func prepare(_ ctx: CGContext, height h: Int, scale: CGFloat, flipped: Bool) {
        if flipped {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
        } else {
            ctx.scaleBy(x: scale, y: scale)
        }
    }

    /// Text on a transparent background, sized to the string's bounding box (wrapping at `maxWidth`).
    static func text(_ s: NSAttributedString, scale: CGFloat, maxWidth: CGFloat = 200) -> CGImage {
        let r = s.boundingRect(with: CGSize(width: maxWidth, height: 10_000), options: [.usesLineFragmentOrigin])
        let size = CGSize(width: max(1, ceil(r.width)), height: max(1, ceil(r.height)))
        return image(size: size, scale: scale) { ctx in
            draw(s, in: CGRect(origin: .zero, size: size), ctx: ctx)
        }
    }

    /// Draws an attributed string top-aligned in `rect`. `ctx` must be a y-down context.
    static func draw(_ s: NSAttributedString, in rect: CGRect, ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        s.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Labels shaped like the old `textLayer(...)`

    static func labelString(_ s: String, size: CGFloat, color: NSColor, weight: NSFont.Weight) -> NSAttributedString {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                          .foregroundColor: color, .paragraphStyle: para])
    }

    /// The bounds the old `textLayer(...)` gave a string: text width + 2 by `ceil(size × 1.3)`.
    static func labelSize(_ s: String, size: CGFloat, weight: NSFont.Weight) -> CGSize {
        let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)])
        return CGSize(width: ceil(attr.size().width) + 2, height: ceil(size * 1.3))
    }

    /// Draws a `textLayer`-style label whose box is centred on `center` (the old layer `position`).
    static func drawLabel(_ s: String, size: CGFloat, color: NSColor, weight: NSFont.Weight, center: CGPoint, ctx: CGContext) {
        let box = labelSize(s, size: size, weight: weight)
        let rect = CGRect(x: center.x - box.width / 2, y: center.y - box.height / 2, width: box.width, height: box.height)
        draw(labelString(s, size: size, color: color, weight: weight), in: rect, ctx: ctx)
    }

    // MARK: Shadows

    /// `CGContext.setShadow` blur (device pixels) per point of Core Animation `shadowRadius`. Calibrated
    /// against `CALayer.render(in:)` of the old layers: 0.65 matches glow width and peak alpha.
    static let blurPerShadowRadius: CGFloat = 0.65

    /// The CG blur that reproduces a CA `shadowRadius` at `scale`.
    static func shadowBlur(radius: CGFloat, scale: CGFloat) -> CGFloat { radius * blurPerShadowRadius * scale }

    /// Paints only the shadow of `path` (no fill): the path is filled far off-canvas and its shadow is
    /// offset back into place. Used where the glow must be a separate image (the pulsing bubble).
    static func glow(_ path: CGPath, color: NSColor, radius: CGFloat, opacity: CGFloat = 1, scale: CGFloat, ctx: CGContext) {
        let away: CGFloat = 4000
        ctx.saveGState()
        // Shadow offset and blur are in device pixels; x is not flipped by our CTM.
        ctx.setShadow(offset: CGSize(width: -away * scale, height: 0), blur: shadowBlur(radius: radius, scale: scale),
                      color: color.withAlphaComponent(color.alphaComponent * opacity).cgColor)
        var t = CGAffineTransform(translationX: away, y: 0)
        if let moved = path.copy(using: &t) { ctx.addPath(moved) }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
}
