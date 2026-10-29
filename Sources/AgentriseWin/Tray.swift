// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
import Agentrise
import AgentriseScene
import AgentriseWinArt

/// The text of the tray icon's "等你" badge: none at 0, the number up to 99, then "99+".
package enum TrayBadge {
    package static func text(waiting: Int) -> String? {
        guard waiting > 0 else { return nil }
        return waiting > 99 ? "99+" : "\(waiting)"
    }

    /// The tray icon's hover text: the full counts, like the macOS status item's title.
    package static func tip(_ c: TowerCounts) -> String { "等你 \(c.waiting) · 完成 \(c.done)" }
}

/// The tray (and window) icon, drawn with `Pen`: a small tower with lit windows and, with a badge text, a red pill
/// with the count in its top-right corner. `dimmed` is the second picture the tray alternates with while it flashes.
package enum TrayIconArt {
    /// The design canvas, in points.
    package static let canvas = CGSize(width: 16, height: 16)

    package static func draw(badge: String?, dimmed: Bool, pen: Pen) {
        let body = {
            let tower = CGRect(x: 3, y: 2.5, width: 9, height: 12.5)
            pen.fill(.roundedRect(tower, radius: 1.5), Color(hex: 0x2E3B8F))
            pen.stroke(.roundedRect(tower.insetBy(dx: 0.5, dy: 0.5), radius: 1), Color(hex: 0x9FB3FF), width: 1)
            var antenna = ArtPath()
            antenna.move(to: CGPoint(x: 7.5, y: 0.5))
            antenna.line(to: CGPoint(x: 7.5, y: 2.5))
            pen.stroke(antenna, Color(hex: 0x9FB3FF), width: 1)
            for row in 0..<3 {
                for col in 0..<2 {
                    let lit = (row + col) % 2 == 0
                    let r = CGRect(x: 5 + CGFloat(col) * 3.2, y: 5 + CGFloat(row) * 3.2, width: 1.9, height: 1.9)
                    pen.fill(.rect(r), lit ? Color(hex: 0xFFC95C) : Color(hex: 0x6FF0A8))
                }
            }
            if let badge {
                let font = FontSpec(size: badge.count > 2 ? 6 : 7.5, weight: .bold)
                let t = pen.measure(badge, font: font, maxWidth: .infinity, maxLines: 1)
                let h: CGFloat = 9, w = max(h, ceil(t.width) + 3)
                let pill = CGRect(x: canvas.width - w, y: 0, width: w, height: h)
                pen.fill(.roundedRect(pill, radius: h / 2), Color(hex: 0xE5484D))
                pen.text(badge, font: font, color: Color(r: 1, g: 1, b: 1), shadow: nil,
                         in: CGRect(x: pill.minX, y: pill.midY - t.height / 2, width: pill.width, height: t.height + 1), maxLines: 1)
            }
        }
        if dimmed { pen.layer(alpha: 0.25, body) } else { body() }
    }

    /// The icon as an `HICON` of `pixels` × `pixels` (the caller destroys it).
    package static func icon(badge: String?, dimmed: Bool, pixels: Int) -> HICON? {
        let scale = CGFloat(pixels) / canvas.width
        let image = D2DArtBackend.shared.bake(size: canvas, scale: scale) { draw(badge: badge, dimmed: dimmed, pen: $0) }
        return makeIcon(bgra: image.wicImage.pixelsBGRA(), width: image.pixelWidth, height: image.pixelHeight)
    }

    /// An `HICON` from premultiplied BGRA rows (top first). Icon bitmaps take straight alpha.
    static func makeIcon(bgra: [UInt8], width: Int, height: Int) -> HICON? {
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = LONG(width)
        info.bmiHeader.biHeight = -LONG(height)   // top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)
        var bits: UnsafeMutableRawPointer?
        guard let color = CreateDIBSection(nil, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else { return nil }
        defer { DeleteObject(color) }
        let px = bits.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in stride(from: 0, to: min(bgra.count, width * height * 4), by: 4) {
            let a = bgra[i + 3]
            px[i + 3] = a
            for k in 0..<3 {
                px[i + k] = a == 0 ? 0 : UInt8(min(255, (Int(bgra[i + k]) * 255 + Int(a) / 2) / Int(a)))
            }
        }
        guard let mask = CreateBitmap(Int32(width), Int32(height), 1, 1, nil) else { return nil }
        defer { DeleteObject(mask) }
        var ii = ICONINFO(fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color)
        return CreateIconIndirect(&ii)
    }
}

/// The tray icon (`Shell_NotifyIconW`): the "等你" count as a badge, the full counts as its hover text, a flash when a
/// session starts waiting on you (two pictures alternating for 3 s, like the macOS status item's blink), and the
/// right-click menu of the macOS status item (spec §5.6): show the window, always on top, about, settings, quit.
package final class Tray {
    package enum Command: Int { case show = 1, alwaysOnTop, about, settings, quit }

    /// The message the icon sends its window (`uCallbackMessage`).
    package static let callbackMessage = Win.appMessage + 10
    /// Explorer restarted: the icon must be added again.
    package static let taskbarCreated: UINT = withWide("TaskbarCreated") { RegisterWindowMessageW($0) }

    private let hwnd: HWND
    private let scheduler: TowerScheduler
    private var counts = TowerCounts()
    private var icons: [String: HICON] = [:]
    private var flashStep = 0
    private var flashGeneration = 0
    private var added = false

    /// The flash: picture changes this often, this many times (3 s).
    package static let flashInterval: TimeInterval = 0.375
    package static let flashSteps = 8

    package var isAlwaysOnTop: () -> Bool = { false }
    package var onCommand: ((Command) -> Void)?

    package init(window: HWND, scheduler: TowerScheduler) {
        hwnd = window
        self.scheduler = scheduler
    }

    deinit {
        remove()
        for (_, i) in icons { DestroyIcon(i) }
    }

    /// Adds the icon (again, after Explorer restarted).
    package func add() {
        var nid = data()
        nid.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP) | 0x80   // NIF_SHOWTIP
        nid.uCallbackMessage = Self.callbackMessage
        nid.hIcon = currentIcon()
        setTip(&nid)
        added = Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
        nid.uVersion = 4   // NOTIFYICON_VERSION_4
        _ = Shell_NotifyIconW(DWORD(NIM_SETVERSION), &nid)
        if !added { Log.write("Shell_NotifyIconW(NIM_ADD) failed") }
    }

    package func remove() {
        guard added else { return }
        var nid = data()
        _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
        added = false
    }

    package func update(_ c: TowerCounts) {
        guard c.waiting != counts.waiting || c.done != counts.done else { return }
        counts = c
        refresh()
    }

    /// A session started waiting on you.
    package func flash() {
        flashGeneration += 1
        let generation = flashGeneration
        flashStep = 0
        func step() {
            guard generation == flashGeneration else { return }
            flashStep += 1
            refresh()
            if flashStep < Self.flashSteps { scheduler.after(Self.flashInterval, step) }
        }
        refresh()
        scheduler.after(Self.flashInterval, step)
    }

    /// Whether the dimmed picture shows (odd steps of a flash; the last step shows the plain one).
    private var dimmed: Bool { flashStep < Self.flashSteps && flashStep % 2 == 1 }

    private func refresh() {
        guard added else { return }
        var nid = data()
        nid.uFlags = UINT(NIF_ICON | NIF_TIP) | 0x80
        nid.hIcon = currentIcon()
        setTip(&nid)
        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
    }

    /// The display scale changed (the taskbar's monitor, or the displays were rearranged): draw the icon at the new
    /// notification-area size.
    package func dpiChanged() { refresh() }

    /// The notification area's dpi: the taskbar's (on the primary monitor), else the system's.
    static func notificationAreaDpi() -> UINT {
        if let taskbar = withWide("Shell_TrayWnd", { FindWindowW($0, nil) }) {
            let dpi = GetDpiForWindow(taskbar)
            if dpi > 0 { return dpi }
        }
        return GetDpiForSystem()
    }

    /// The tray icon's edge in pixels: the system's small-icon size at the notification area's dpi.
    package static func iconPixels() -> Int { max(16, Int(GetSystemMetricsForDpi(SM_CXSMICON, notificationAreaDpi()))) }

    private func currentIcon() -> HICON? {
        let badge = TrayBadge.text(waiting: counts.waiting)
        let px = Self.iconPixels()
        let prefix = "\(badge ?? "")|\(px)|"
        let key = prefix + "\(dimmed)"
        if let i = icons[key] { return i }
        guard let i = TrayIconArt.icon(badge: badge, dimmed: dimmed, pixels: px) else { return nil }
        // Keep only the current count's two pictures at the current size.
        for (k, old) in icons where !k.hasPrefix(prefix) { DestroyIcon(old); icons[k] = nil }
        icons[key] = i
        return i
    }

    private func data() -> NOTIFYICONDATAW {
        var nid = NOTIFYICONDATAW()
        nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = hwnd
        nid.uID = 1
        return nid
    }

    private func setTip(_ nid: inout NOTIFYICONDATAW) {
        let tip = Array(TrayBadge.tip(counts).utf16.prefix(127)) + [0]
        withUnsafeMutableBytes(of: &nid.szTip) { raw in
            let p = raw.bindMemory(to: WCHAR.self)
            for (i, c) in tip.enumerated() where i < p.count { p[i] = c }
        }
    }

    // MARK: Messages

    package enum Action: Equatable { case menu, show }

    /// What a NOTIFYICON_VERSION_4 callback event does. Under v4 the shell sends WM_RBUTTONUP and then
    /// WM_CONTEXTMENU for a right-click, WM_LBUTTONUP and then NIN_SELECT for a left-click: only the second of each
    /// pair acts (as Microsoft's NotificationIcon sample does), so each click does one thing. NIN_KEYSELECT is the
    /// keyboard's select (Enter or Space on the focused icon).
    package static func action(forEvent event: UINT) -> Action? {
        switch event {
        case UINT(WM_CONTEXTMENU): return .menu
        case UINT(WM_USER), UINT(WM_USER + 1): return .show   // NIN_SELECT, NIN_KEYSELECT
        default: return nil
        }
    }

    /// The icon's callback (NOTIFYICON_VERSION_4: the event in the low word of `l`, the anchor point in `w`).
    package func handle(_ w: WPARAM, _ l: LPARAM) {
        switch Self.action(forEvent: UINT(loWord(l))) {
        case .menu: showMenu(at: POINT(x: LONG(xParam(w)), y: LONG(yParam(w))))
        case .show: onCommand?(.show)
        case nil: break
        }
    }

    /// The right-click menu; its choice comes back to the window as WM_COMMAND (`command(_:)`).
    private func showMenu(at p: POINT) {
        guard let m = CreatePopupMenu() else { return }
        defer { DestroyMenu(m) }
        func item(_ c: Command, _ title: String, checked: Bool = false) {
            withWide(title) { _ = AppendMenuW(m, UINT(MF_STRING) | (checked ? UINT(MF_CHECKED) : 0), UINT_PTR(c.rawValue), $0) }
        }
        item(.show, "显示 Agentrise")
        item(.alwaysOnTop, "窗口置顶", checked: isAlwaysOnTop())
        item(.about, "关于 Agentrise")
        item(.settings, "设置…")
        _ = AppendMenuW(m, UINT(MF_SEPARATOR), 0, nil)
        item(.quit, "退出")
        var at = p
        if at.x == 0 && at.y == 0 { GetCursorPos(&at) }
        SetForegroundWindow(hwnd)   // so the menu closes when clicked away
        _ = TrackPopupMenu(m, UINT(TPM_RIGHTBUTTON), at.x, at.y, 0, hwnd, nil)
        PostMessageW(hwnd, UINT(WM_NULL), 0, 0)
    }

    /// WM_COMMAND from the menu.
    package func command(_ id: Int) {
        if let c = Command(rawValue: id) { onCommand?(c) }
    }
}
#endif
