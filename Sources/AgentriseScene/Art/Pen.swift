// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The system UI font's weights the art uses (SF on macOS, Segoe UI on Windows).
package enum FontWeight: Hashable, Sendable { case regular, medium, semibold, bold, heavy, black }

package struct FontSpec: Hashable, Sendable {
    package var size: CGFloat
    package var weight: FontWeight
    package init(size: CGFloat, weight: FontWeight) { self.size = size; self.weight = weight }
}

/// A shadow under a piece of text, computed from the text as a whole (one transparency layer).
/// `blur` is in points, like `Pen.shadowed`.
package struct TextShadow {
    package var offset: CGSize
    package var blur: CGFloat
    package var color: Color
    package init(offset: CGSize, blur: CGFloat, color: Color) { self.offset = offset; self.blur = blur; self.color = color }
}

/// A run of text in one font and colour. Runs follow each other in one layout (a run may start with "\n").
package struct TextRun: Hashable, Sendable {
    package var text: String
    package var font: FontSpec
    package var color: Color
    package init(_ text: String, font: FontSpec, color: Color) { self.text = text; self.font = font; self.color = color }
}

/// Measures laid-out text: both a `Pen` (while baking) and an `ArtBackend` (outside a bake) can.
package protocol TextMeasuring {
    /// The size of `runs` laid out centred, wrapped at `maxWidth` (`.infinity`: never), at most `maxLines` lines
    /// (0: no limit). Not rounded.
    func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize
}

extension TextMeasuring {
    package func measure(_ s: String, font: FontSpec, maxWidth: CGFloat, maxLines: Int) -> CGSize {
        measure([TextRun(s, font: font, color: Color(r: 1, g: 1, b: 1))], maxWidth: maxWidth, maxLines: maxLines)
    }
}

/// Drawing commands for the art recipes, implemented by each platform's backend (`CGPen` on macOS, `D2DPen` on
/// Windows). Coordinates are points, origin at the top-left, y down; the backend multiplies by `scale`.
/// Antialiasing is always on.
package protocol Pen: AnyObject, TextMeasuring {
    /// Pixels per point.
    var scale: CGFloat { get }

    /// Fills `p` (non-zero winding).
    func fill(_ p: ArtPath, _ c: Color)
    /// Strokes `p` centred on the path, with round caps and joins.
    func stroke(_ p: ArtPath, _ c: Color, width: CGFloat)
    /// Paints a linear gradient from `from` to `to` inside `p`. `locations` nil spreads the colours evenly.
    /// With `extend`, the end colours carry on past the end points; without, nothing is painted where a pixel's
    /// centre lies before `from` or past `to`.
    func linearGradient(_ p: ArtPath, colors: [Color], locations: [CGFloat]?, from: CGPoint, to: CGPoint, extend: Bool)
    /// Everything `body` draws casts a shadow: `offset` in points (y down), `blur` in points, as a Core Animation
    /// `shadowRadius` (the backend scales it: `ArtKit.shadowBlur` on macOS). Each drawing command inside casts
    /// its own shadow; wrap `body` in `layer` to shadow the drawing as a whole.
    func shadowed(offset: CGSize, blur: CGFloat, color: Color, _ body: () -> Void)
    /// Paints only the shadow `fill(p, …)` would cast with a zero offset (the fill itself is not drawn): a glow.
    func glow(_ p: ArtPath, blur: CGFloat, color: Color)
    /// Draws `body` into a transparent layer, then composites the layer with `alpha` (and the current shadow).
    func layer(alpha: CGFloat, _ body: () -> Void)
    /// Draws each command in `body` with its alpha multiplied by `alpha`, on its own (Core Graphics' global
    /// alpha; overlapping commands are not flattened first, unlike `layer(alpha:)`).
    func faded(alpha: CGFloat, _ body: () -> Void)
    /// Draws `body` clipped to `p` (antialiased).
    func clipped(to p: ArtPath, _ body: () -> Void)
    /// Draws `body` with its coordinates moved by `offset` points (shadow offsets are not moved).
    func translated(by offset: CGSize, _ body: () -> Void)
    /// Draws `runs` centred horizontally and top-aligned in `rect`, wrapping at its width, at most `maxLines`
    /// lines (0: no limit). Only lines that fit whole within `rect`'s height are drawn (the first always is, as
    /// AppKit draws), but nothing is clipped to `rect`. With `shadow`, the text is drawn in a layer that casts it.
    func text(_ runs: [TextRun], shadow: TextShadow?, in rect: CGRect, maxLines: Int)
    /// Draws `runs` as one left-aligned line from the top-left corner of `rect` (the platform's natural layout,
    /// no centring). With `truncatesTail`, text wider than `rect` is cut with an ellipsis; without, it is laid out
    /// as it comes (wrapping at the width, which callers make wide enough). Lines are kept or dropped by `rect`'s
    /// height as in `text`; nothing is clipped to `rect`.
    func textLine(_ runs: [TextRun], in rect: CGRect, truncatesTail: Bool)
    /// A colour emoji (or any glyph) at `size` points, its label box (`ArtKit.labelSize`, regular weight)
    /// centred on `center`.
    func emoji(_ s: String, size: CGFloat, center: CGPoint)
    /// Whether text drawn from now on in this bake is font-smoothed (macOS stem darkening; on by default).
    /// The building art turns it off, as its old `CATextLayer`s were not dilated.
    func setFontSmoothing(_ on: Bool)
}

extension Pen {
    /// A gradient whose end colours carry on past its end points (what `CAGradientLayer` does).
    package func linearGradient(_ p: ArtPath, colors: [Color], locations: [CGFloat]?, from: CGPoint, to: CGPoint) {
        linearGradient(p, colors: colors, locations: locations, from: from, to: to, extend: true)
    }

    /// One run of text; see `text(_:shadow:in:maxLines:)`.
    package func text(_ s: String, font: FontSpec, color: Color, shadow: TextShadow?, in rect: CGRect, maxLines: Int) {
        text([TextRun(s, font: font, color: color)], shadow: shadow, in: rect, maxLines: maxLines)
    }
}

/// Bakes bitmaps by running art recipes against a platform `Pen`.
package protocol ArtBackend: TextMeasuring {
    /// A transparent bitmap of `ArtKit.pixelSize(size, scale:)` pixels with `draw`'s drawing (points, y down).
    func bake(size: CGSize, scale: CGFloat, _ draw: (Pen) -> Void) -> BakedImage
    /// The image's pixels: premultiplied RGBA, sRGB, rows top first, `pixelWidth × 4` bytes per row.
    func rgba(_ img: BakedImage) -> [UInt8]
}
