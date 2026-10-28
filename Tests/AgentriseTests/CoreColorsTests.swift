// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import Agentrise

@Suite struct CoreColorsTests {
    @Test func stripeColorsAreBuiltFromTheirHex() {
        for r in Rank.allCases { #expect(r.stripe == NSColor(hex: r.stripeHex)) }
        #expect(Rank.seniorDirector.stripeHex == 0xFFCF3F)
    }

    @Test func teamColorsAreBuiltFromTheirHex() {
        #expect(Team.colors == Team.hexes.map { NSColor(hex: $0) })
        #expect(Team.color(-1) == Team.colors[7])
        #expect(Team.color(8) == Team.colors[0])
    }
}
