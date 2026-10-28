// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import Agentrise

extension Rank {
    /// Color of the light strip on the robot's body.
    var stripe: NSColor { NSColor(hex: stripeHex) }
}

extension Team {
    static let colors: [NSColor] = hexes.map { NSColor(hex: $0) }
    static func color(_ i: Int) -> NSColor { colors[((i % colors.count) + colors.count) % colors.count] }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
