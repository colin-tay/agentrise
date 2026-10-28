// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import AgentriseScene

extension NSColor {
    convenience init(_ c: Color) {
        self.init(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// The colour's sRGB components (converted to sRGB first when it lives in another colour space).
    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? ns
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }
}
