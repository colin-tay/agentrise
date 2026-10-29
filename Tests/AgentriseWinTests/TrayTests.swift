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

    /// NOTIFYICON_VERSION_4: a right-click sends WM_RBUTTONUP then WM_CONTEXTMENU, a left-click WM_LBUTTONUP then
    /// NIN_SELECT. Each click must do exactly one thing: only WM_CONTEXTMENU opens the menu, only NIN_SELECT and
    /// NIN_KEYSELECT show the window, and every other event does nothing.
    @Test func trayCallbackMapsEachV4EventToOneAction() {
        let ninSelect = UINT(WM_USER), ninKeySelect = UINT(WM_USER + 1)
        #expect(Tray.action(forEvent: UINT(WM_CONTEXTMENU)) == .menu)
        #expect(Tray.action(forEvent: ninSelect) == .show)
        #expect(Tray.action(forEvent: ninKeySelect) == .show)
        let silent: [UINT] = [UINT(WM_RBUTTONUP), UINT(WM_RBUTTONDOWN), UINT(WM_LBUTTONUP), UINT(WM_LBUTTONDOWN),
                              UINT(WM_LBUTTONDBLCLK), UINT(WM_MOUSEMOVE),
                              UINT(WM_USER + 2), UINT(WM_USER + 3), UINT(WM_USER + 4), UINT(WM_USER + 5),   // NIN_BALLOON*
                              UINT(WM_USER + 6), UINT(WM_USER + 7)]                                           // NIN_POPUPOPEN/CLOSE
        for e in silent { #expect(Tray.action(forEvent: e) == nil, "event 0x\(String(e, radix: 16)) acts") }
        // A right-click's pair opens one menu; a left-click's pair shows the window once.
        #expect([UINT(WM_RBUTTONUP), UINT(WM_CONTEXTMENU)].compactMap(Tray.action(forEvent:)) == [.menu])
        #expect([UINT(WM_LBUTTONUP), ninSelect].compactMap(Tray.action(forEvent:)) == [.show])
    }

    @Test func trayIconSizeIsTheSmallIconMetric() {
        #expect(Tray.iconPixels() >= 16)
    }

    @Test func trayIconMakesAnHICON() {
        let icon = TrayIconArt.icon(badge: "12", dimmed: false, pixels: 32)
        #expect(icon != nil)
        if let icon { DestroyIcon(icon) }
    }
}
#endif
