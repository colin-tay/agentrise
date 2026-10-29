// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// The tray icon (Windows only): the "等你" badge text, the hover text, and the icon drawn with `Pen`.

#if os(Windows)
import Testing
import Foundation
import WinSDK
@testable import Agentrise
@testable import AgentriseScene
@testable import AgentriseWinArt
@testable import AgentriseWin

@Suite struct TrayTests {
    @Test func trayBadgeText() {
        #expect(TrayBadge.text(waiting: 0) == nil)
        #expect(TrayBadge.text(waiting: 1) == "1")
        #expect(TrayBadge.text(waiting: 9) == "9")
        #expect(TrayBadge.text(waiting: 10) == "10")
        #expect(TrayBadge.text(waiting: 99) == "99")
        #expect(TrayBadge.text(waiting: 100) == "99+")
        #expect(TrayBadge.text(waiting: 1234) == "99+")
    }

    @Test func trayTipHasTheFullCounts() {
        #expect(TrayBadge.tip(TowerCounts(working: 4, waiting: 2, done: 3)) == "等你 2 · 完成 3")
    }

    /// The premultiplied RGBA of pixel (`x`, `y`).
    private func pixel(_ img: BakedImage, _ x: Int, _ y: Int) -> [Int] {
        let px = D2DArtBackend.shared.rgba(img), i = (y * img.pixelWidth + x) * 4
        return px[i..<i + 4].map(Int.init)
    }

    /// The badge is a red pill in the top-right corner; without a count that corner stays empty, and the dimmed
    /// picture (the flash's second one) is fainter.
    @Test func trayIconDrawsTheBadge() {
        let art = TrayIconArt.self
        let badged = D2DArtBackend.shared.bake(size: art.canvas, scale: 2) { art.draw(badge: "3", dimmed: false, pen: $0) }
        let plain = D2DArtBackend.shared.bake(size: art.canvas, scale: 2) { art.draw(badge: nil, dimmed: false, pen: $0) }
        let dimmed = D2DArtBackend.shared.bake(size: art.canvas, scale: 2) { art.draw(badge: nil, dimmed: true, pen: $0) }
        #expect(badged.pixelWidth == 32 && badged.pixelHeight == 32)
        let corner = pixel(badged, 30, 9)   // inside the pill, right of the digit
        #expect(corner[3] == 255 && corner[0] > 200 && corner[1] < 120, "badge pixel \(corner)")
        #expect(pixel(plain, 30, 9)[3] == 0)
        let body = pixel(plain, 8, 26), faint = pixel(dimmed, 8, 26)
        #expect(body[3] == 255 && faint[3] < 120, "body \(body), dimmed \(faint)")
    }

    @Test func trayIconMakesAnHICON() {
        let icon = TrayIconArt.icon(badge: "12", dimmed: false, pixels: 32)
        #expect(icon != nil)
        if let icon { DestroyIcon(icon) }
    }
}
#endif
