// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
@testable import AgentriseScene
@testable import Agentrise

@Suite struct CoreColorsTests {
    @Test func stripeColorsAreBuiltFromTheirHex() {
        for r in Rank.allCases { #expect(r.stripe == Color(hex: r.stripeHex)) }
        #expect(Rank.seniorDirector.stripeHex == 0xFFCF3F)
        #expect(Rank.seniorDirector.stripe == Color(hex: "#FFCF3F"))
        #expect(Color(hex: "ffcf3f") == Color(r: 255.0 / 255, g: 207.0 / 255, b: 63.0 / 255))
        #expect(Color(hex: 0xFFCF3F).withAlpha(0.5).a == 0.5)
    }

    @Test func teamColorsAreBuiltFromTheirHex() {
        #expect(Team.colors == Team.hexes.map { Color(hex: $0) })
        #expect(Team.color(-1) == Team.colors[7])
        #expect(Team.color(8) == Team.colors[0])
    }
}
