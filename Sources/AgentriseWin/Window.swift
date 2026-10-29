// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK

/// Where the window was, in `<support>\window.json`: its normal (restored) frame in screen pixels.
package struct WindowPlacement: Codable, Equatable {
    package var x, y, width, height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    package static func load(_ file: URL) -> WindowPlacement? {
        guard let d = try? Data(contentsOf: file), let p = try? JSONDecoder().decode(WindowPlacement.self, from: d),
              p.width > 0, p.height > 0 else { return nil }
        return p
    }

    package func save(_ file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: file, options: .atomic)
    }

    var rect: RECT { RECT(left: LONG(x), top: LONG(y), right: LONG(x + width), bottom: LONG(y + height)) }

    /// Enough of it lies on some monitor to grab it (a monitor may have been unplugged), like the macOS check.
    package var isOnScreen: Bool {
        var r = rect
        guard let m = MonitorFromRect(&r, DWORD(MONITOR_DEFAULTTONULL)) else { return false }
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        guard GetMonitorInfoW(m, &info).boolValue else { return false }
        let w = info.rcWork
        let iw = min(w.right, r.right) - max(w.left, r.left), ih = min(w.bottom, r.bottom) - max(w.top, r.top)
        return iw >= 100 && ih >= 100
    }
}

/// The tower window: a standard title bar (resizable, minimisable), Per-Monitor V2 DPI aware, at least the macOS
/// minimum size (420 × 520 points at the window's dpi), optionally always on top. It owns no drawing: it reports
/// size, dpi, pointer and visibility changes to `TowerWindow.Events`, and the app draws into it with Direct2D.
/// Closing it only hides it (the app lives on in the tray, as the macOS app lives on in the menu bar).
package final class TowerWindow {
    package static let className = "AgentriseTowerWindow"
    /// The macOS window's `minSize`, in points.
    package static let minimumSize = CGSize(width: 420, height: 520)
    /// The macOS window's first size, in points.
    package static let defaultSize = CGSize(width: 1280, height: 800)

    package private(set) var hwnd: HWND!
    private let style = DWORD(0x00CF_0000)   // WS_OVERLAPPEDWINDOW (a macro of macros)
    private let exStyle = DWORD(WS_EX_APPWINDOW)
    private var trackingLeave = false

    /// What the window reports. Points are client DIPs (top-left origin), the layout's coordinates.
    package struct Events {
        package var resized: (_ pixelWidth: Int, _ pixelHeight: Int, _ scale: CGFloat) -> Void = { _, _, _ in }
        package var pointer: (CGPoint?) -> Void = { _ in }
        package var click: (CGPoint) -> Void = { _ in }
        package var wheel: (CGPoint, CGFloat, _ horizontal: Bool) -> Void = { _, _, _ in }
        package var paint: () -> Void = {}
        /// Entering (true) or leaving (false) a modal move/size loop.
        package var sizeMove: (Bool) -> Void = { _ in }
        package var moved: () -> Void = {}
        /// Any other message (tray callbacks, WM_COMMAND, the show request): nil when not handled.
        package var other: (UINT, WPARAM, LPARAM) -> LRESULT? = { _, _, _ in nil }
        package init() {}
    }
    package var events = Events()

    package init(title: String, placement: WindowPlacement?, clientSize: CGSize?, alwaysOnTop: Bool) {
        WindowRoutes.registerClass(Self.className)
        WindowRoutes.pending = { [unowned self] hwnd, msg, w, l in self.handle(hwnd, msg, w, l) }
        let frame = placement.flatMap { $0.isOnScreen ? $0.rect : nil } ?? defaultFrame(clientSize: clientSize)
        hwnd = withWide(Self.className) { cls in
            withWide(title) { t in
                CreateWindowExW(exStyle, cls, t, style, frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top,
                                nil, nil, moduleHandle, nil)
            }
        }
        WindowRoutes.pending = nil
        precondition(hwnd != nil, "CreateWindowExW failed: \(GetLastError())")
        // A remembered frame was saved at its monitor's dpi; a requested client size is in points.
        if placement == nil || !(placement!.isOnScreen), let clientSize { setClientSize(points: clientSize) }
        setAlwaysOnTop(alwaysOnTop)
    }

    /// The default frame: the requested (or macOS default) client size in points at the primary monitor's dpi, no
    /// larger than 90% of its work area, centred on it.
    private func defaultFrame(clientSize: CGSize?) -> RECT {
        var work = RECT()
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &work, 0)
        let dpi = GetDpiForSystem()
        let scale = CGFloat(dpi) / 96
        let size = clientSize ?? Self.defaultSize
        var r = RECT(left: 0, top: 0, right: LONG(size.width * scale), bottom: LONG(size.height * scale))
        AdjustWindowRectExForDpi(&r, style, false, exStyle, dpi)
        let ww = work.right - work.left, wh = work.bottom - work.top
        var w = r.right - r.left, h = r.bottom - r.top
        if clientSize == nil {
            w = min(w, ww * 9 / 10)
            h = min(h, wh * 9 / 10)
        }
        let x = work.left + max(0, (ww - w) / 2), y = work.top + max(0, (wh - h) / 2)
        return RECT(left: x, top: y, right: x + w, bottom: y + h)
    }

    /// Makes the client area `points` big at the window's current dpi.
    package func setClientSize(points: CGSize) {
        let dpi = GetDpiForWindow(hwnd)
        let scale = CGFloat(dpi) / 96
        var r = RECT(left: 0, top: 0, right: LONG(points.width * scale), bottom: LONG(points.height * scale))
        AdjustWindowRectExForDpi(&r, style, false, exStyle, dpi)
        SetWindowPos(hwnd, nil, 0, 0, r.right - r.left, r.bottom - r.top, UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
    }

    package var scale: CGFloat { CGFloat(GetDpiForWindow(hwnd)) / 96 }

    package var clientPixels: (width: Int, height: Int) {
        var r = RECT()
        GetClientRect(hwnd, &r)
        return (Int(r.right - r.left), Int(r.bottom - r.top))
    }

    /// The normal (restored) frame, also while minimised or maximised.
    package var placement: WindowPlacement {
        var wp = WINDOWPLACEMENT()
        wp.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
        GetWindowPlacement(hwnd, &wp)
        // rcNormalPosition is in workspace coordinates; for a window without WS_EX_TOOLWINDOW on the primary taskbar
        // side this differs from the screen by the taskbar. GetWindowRect is exact for a normal window.
        if !IsIconic(hwnd).boolValue && !IsZoomed(hwnd).boolValue {
            var r = RECT()
            GetWindowRect(hwnd, &r)
            return WindowPlacement(x: Int(r.left), y: Int(r.top), width: Int(r.right - r.left), height: Int(r.bottom - r.top))
        }
        let r = wp.rcNormalPosition
        return WindowPlacement(x: Int(r.left), y: Int(r.top), width: Int(r.right - r.left), height: Int(r.bottom - r.top))
    }

    package var isVisible: Bool { IsWindowVisible(hwnd).boolValue }
    package var isMinimized: Bool { IsIconic(hwnd).boolValue }

    package func show() {
        ShowWindow(hwnd, IsIconic(hwnd).boolValue ? SW_RESTORE : SW_SHOW)
        SetForegroundWindow(hwnd)
    }

    package func hide() { ShowWindow(hwnd, SW_HIDE) }

    package func setAlwaysOnTop(_ on: Bool) {
        SetWindowPos(hwnd, on ? Win.hwndTopmost : Win.hwndNoTopmost, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
    }

    package func setIcons(small: HICON?, big: HICON?) {
        if let small { SendMessageW(hwnd, UINT(WM_SETICON), WPARAM(ICON_SMALL), LPARAM(Int(bitPattern: UnsafeMutableRawPointer(small)))) }
        if let big { SendMessageW(hwnd, UINT(WM_SETICON), WPARAM(ICON_BIG), LPARAM(Int(bitPattern: UnsafeMutableRawPointer(big)))) }
    }

    private func point(_ l: LPARAM) -> CGPoint {
        let s = scale
        return CGPoint(x: CGFloat(xParam(l)) / s, y: CGFloat(yParam(l)) / s)
    }

    private func handle(_ hwnd: HWND, _ msg: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT? {
        switch msg {
        case UINT(WM_GETMINMAXINFO):
            guard let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(l)) else { return nil }
            let dpi = GetDpiForWindow(hwnd)
            let s = CGFloat(dpi == 0 ? 96 : dpi) / 96
            var r = RECT(left: 0, top: 0, right: LONG(Self.minimumSize.width * s), bottom: LONG(Self.minimumSize.height * s))
            AdjustWindowRectExForDpi(&r, style, false, exStyle, dpi == 0 ? 96 : dpi)
            info.pointee.ptMinTrackSize = POINT(x: r.right - r.left, y: r.bottom - r.top)
            return 0
        case UINT(WM_SIZE):
            guard w != WPARAM(SIZE_MINIMIZED) else { return 0 }
            events.resized(loWord(l), hiWord(l), scale)
            return 0
        case Win.dpiChanged:
            // Per-Monitor V2: take the suggested frame; the WM_SIZE it causes carries the new scale.
            if let r = UnsafePointer<RECT>(bitPattern: Int(l))?.pointee {
                SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            let (pw, ph) = clientPixels
            events.resized(pw, ph, CGFloat(loWord(w)) / 96)
            return 0
        case UINT(WM_ERASEBKGND):
            return 1
        case UINT(WM_PAINT):
            var ps = PAINTSTRUCT()
            BeginPaint(hwnd, &ps)
            EndPaint(hwnd, &ps)
            events.paint()
            return 0
        case UINT(WM_MOUSEMOVE):
            if !trackingLeave {
                var t = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE), hwndTrack: hwnd, dwHoverTime: 0)
                trackingLeave = TrackMouseEvent(&t).boolValue
            }
            events.pointer(point(l))
            return 0
        case Win.mouseLeave:
            trackingLeave = false
            events.pointer(nil)
            return 0
        case UINT(WM_LBUTTONDOWN):
            events.click(point(l))
            return 0
        case Win.mouseWheel, Win.mouseHWheel:
            var p = POINT(x: LONG(xParam(l)), y: LONG(yParam(l)))   // screen coordinates
            ScreenToClient(hwnd, &p)
            let s = scale
            // A notch is 120; wheel down (negative) scrolls the content down, wheel right scrolls it right.
            let notches = CGFloat(wheelDelta(w)) / 120
            events.wheel(CGPoint(x: CGFloat(p.x) / s, y: CGFloat(p.y) / s), msg == Win.mouseWheel ? -notches : notches,
                         msg == Win.mouseHWheel)
            return 0
        case UINT(WM_ENTERSIZEMOVE):
            events.sizeMove(true)
            return 0
        case UINT(WM_EXITSIZEMOVE):
            events.sizeMove(false)
            events.moved()
            return 0
        case UINT(WM_CLOSE):
            hide()
            events.moved()
            return 0
        default:
            return events.other(msg, w, l)
        }
    }
}
#endif
