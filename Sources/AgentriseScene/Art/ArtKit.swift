// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Shared measures and helpers of the art recipes. Everything the scene draws is baked once into a bitmap
/// (`ArtBackend.bake`) and then only moved around.
package enum ArtKit {
    /// The robot design canvas (60×70 body plus 14 pt of headroom), y down — the old `P()/R()` space.
    package static let robotCanvas = CGSize(width: 60, height: 84)

    /// The bitmap size in pixels for `size` points at `scale` (rounded up, at least 1×1).
    package static func pixelSize(_ size: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((size.width * scale - 1e-6).rounded(.up))), max(1, Int((size.height * scale - 1e-6).rounded(.up))))
    }

    // MARK: Labels shaped like the old `textLayer(...)`

    /// The bounds the old `textLayer(...)` gave a string: text width + 2 by `ceil(size × 1.3)`.
    package static func labelSize(_ s: String, font: FontSpec, using m: TextMeasuring) -> CGSize {
        let w = m.measure(s, font: font, maxWidth: .infinity, maxLines: 0).width
        return CGSize(width: ceil(w) + 2, height: ceil(font.size * 1.3))
    }

    /// Draws a `textLayer`-style label (centred text) whose box is centred on `center` (the old layer `position`).
    package static func drawLabel(_ s: String, font: FontSpec, color: Color, center: CGPoint, pen: Pen) {
        let box = labelSize(s, font: font, using: pen)
        let rect = CGRect(x: center.x - box.width / 2, y: center.y - box.height / 2, width: box.width, height: box.height)
        pen.text(s, font: font, color: color, shadow: nil, in: rect, maxLines: 0)
    }

    // MARK: Shadows

    /// Core Graphics shadow blur (device pixels) per point of Core Animation `shadowRadius`. Calibrated
    /// against `CALayer.render(in:)` of the old layers: 0.65 matches glow width and peak alpha.
    package static let blurPerShadowRadius: CGFloat = 0.65

    /// The Core Graphics blur that reproduces a CA `shadowRadius` at `scale`.
    package static func shadowBlur(radius: CGFloat, scale: CGFloat) -> CGFloat { radius * blurPerShadowRadius * scale }
}
