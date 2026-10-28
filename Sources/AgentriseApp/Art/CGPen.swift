// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import AgentriseScene

/// `Pen` on a y-down Core Graphics bitmap context (see `CGArtBackend`). Every command is the Core Graphics call
/// sequence the art made before it was portable, so the baked pixels are the same.
final class CGPen: Pen {
    let ctx: CGContext
    let scale: CGFloat

    init(ctx: CGContext, scale: CGFloat) {
        self.ctx = ctx
        self.scale = scale
    }

    func fill(_ p: ArtPath, _ c: Color) {
        ctx.setFillColor(c.cgColor)
        // A lone rectangle goes through `fill(_:)`, as the old code did: its edge pixels round differently from a path's.
        if p.elements.count == 1, case let .rect(r) = p.elements[0] { return ctx.fill(r) }
        ctx.addPath(p.cgPath)
        ctx.fillPath()
    }

    func stroke(_ p: ArtPath, _ c: Color, width: CGFloat) {
        ctx.addPath(p.cgPath)
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    func linearGradient(_ p: ArtPath, colors: [Color], locations: [CGFloat]?, from: CGPoint, to: CGPoint, extend: Bool) {
        guard let g = CGGradient(colorsSpace: CGArtBackend.colorSpace, colors: colors.map(\.cgColor) as CFArray, locations: locations) else { return }
        ctx.saveGState()
        ctx.addPath(p.cgPath)
        ctx.clip()
        ctx.drawLinearGradient(g, start: from, end: to, options: extend ? [.drawsBeforeStartLocation, .drawsAfterEndLocation] : [])
        ctx.restoreGState()
    }

    func shadowed(offset: CGSize, blur: CGFloat, color: Color, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: deviceOffset(offset), blur: ArtKit.shadowBlur(radius: blur, scale: scale), color: color.cgColor)
        body()
        ctx.restoreGState()
    }

    /// Fills the path far off-canvas and offsets its shadow back into place.
    func glow(_ p: ArtPath, blur: CGFloat, color: Color) {
        let away: CGFloat = 4000
        ctx.saveGState()
        ctx.setShadow(offset: deviceOffset(CGSize(width: -away, height: 0)), blur: ArtKit.shadowBlur(radius: blur, scale: scale), color: color.cgColor)
        var t = CGAffineTransform(translationX: away, y: 0)
        if let moved = p.cgPath.copy(using: &t) { ctx.addPath(moved) }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    func layer(alpha: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        if alpha != 1 { ctx.setAlpha(alpha) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    func faded(alpha: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        body()
        ctx.restoreGState()
    }

    func clipped(to p: ArtPath, _ body: () -> Void) {
        ctx.saveGState()
        if p.elements.count == 1, case let .rect(r) = p.elements[0] {
            ctx.clip(to: r)   // the old name label's call (Core Graphics treats rectangles apart, as with `fill`)
        } else {
            ctx.addPath(p.cgPath)
            ctx.clip()
        }
        body()
        ctx.restoreGState()
    }

    func translated(by offset: CGSize, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: offset.width, y: offset.height)
        body()
        ctx.restoreGState()
    }

    func text(_ runs: [TextRun], shadow: TextShadow?, in rect: CGRect, maxLines: Int) {
        let s = CGArtBackend.attributed(runs, width: rect.width, maxLines: maxLines)
        guard let shadow else { return CGArtBackend.draw(s, in: rect, ctx: ctx) }
        shadowed(offset: shadow.offset, blur: shadow.blur, color: shadow.color) {
            layer(alpha: 1) { CGArtBackend.draw(s, in: rect, ctx: ctx) }
        }
    }

    func emoji(_ s: String, size: CGFloat, center: CGPoint) {
        ArtKit.drawLabel(s, font: FontSpec(size: size, weight: .regular), color: Color(r: 1, g: 1, b: 1), center: center, pen: self)
    }

    func setFontSmoothing(_ on: Bool) { ctx.setShouldSmoothFonts(on) }

    func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize {
        CGArtBackend.measure(runs, maxWidth: maxWidth, maxLines: maxLines)
    }

    /// Shadow offsets are in device pixels and y up: our CTM flips y but doesn't apply to them.
    private func deviceOffset(_ o: CGSize) -> CGSize { CGSize(width: o.width * scale, height: -o.height * scale) }
}

extension Color {
    var cgColor: CGColor { CGColor(colorSpace: CGArtBackend.colorSpace, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])! }
}

extension NSFont.Weight {
    init(_ w: FontWeight) {
        switch w {
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .black: self = .black
        }
    }
}

extension ArtPath {
    /// The Core Graphics path: a lone shape is made with its own `CGPath` initialiser, as the old code did.
    var cgPath: CGPath {
        if elements.count == 1 {
            switch elements[0] {
            case let .rect(r): return CGPath(rect: r, transform: nil)
            case let .roundedRect(r, radius): return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            case let .ellipse(r): return CGPath(ellipseIn: r, transform: nil)
            default: break
            }
        }
        let p = CGMutablePath()
        for e in elements {
            switch e {
            case let .move(q): p.move(to: q)
            case let .line(q): p.addLine(to: q)
            case let .quadCurve(q, c): p.addQuadCurve(to: q, control: c)
            case let .arc(c, r, a0, a1, cw): p.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: cw)
            case let .tangentArc(t1, t2, r): p.addArc(tangent1End: t1, tangent2End: t2, radius: r)
            case .close: p.closeSubpath()
            case let .rect(r): p.addRect(r)
            case let .roundedRect(r, radius): p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
            case let .ellipse(r): p.addEllipse(in: r)
            }
        }
        return p
    }
}
