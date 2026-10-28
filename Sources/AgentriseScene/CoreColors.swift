// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Agentrise

extension Rank {
    /// Color of the light strip on the robot's body.
    package var stripe: Color { Color(hex: stripeHex) }
}

extension Team {
    package static let colors: [Color] = hexes.map { Color(hex: $0) }
    package static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}
