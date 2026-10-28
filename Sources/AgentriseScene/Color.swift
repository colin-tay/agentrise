// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

/// A platform-neutral colour: sRGB components in 0…1, not premultiplied. Each renderer converts it to its
/// own colour type (`NSColor(_:)` on macOS).
package struct Color: Hashable, Sendable {
    package var r, g, b, a: Double

    package init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `0xRRGGBB`, each channel divided by 255 — the same arithmetic as the old `NSColor(hex:alpha:)`.
    package init(hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255, a: alpha)
    }

    /// `"RRGGBB"`, `"#RRGGBB"` or `"0xRRGGBB"` (either case), parsed into `init(hex: UInt32)`.
    /// Anything that is not six hex digits gives opaque black.
    package init(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        else if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits = digits.dropFirst(2) }
        let value = digits.count == 6 ? UInt32(digits, radix: 16) : nil
        self.init(hex: value ?? 0)
    }

    package func withAlpha(_ a: Double) -> Color { Color(r: r, g: g, b: b, a: a) }
}
