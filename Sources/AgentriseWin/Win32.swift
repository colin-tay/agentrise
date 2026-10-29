// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT
//
// Small Win32 helpers the shell shares: UTF-16 strings, the message-parameter macros Swift doesn't import, and the
// window procedure that routes every message to the Swift object that owns the window.

#if os(Windows)
import Foundation
import WinSDK

/// Calls `body` with a NUL-terminated UTF-16 copy of `s` (every Win32 call here is a W call).
@discardableResult
func withWide<R>(_ s: String, _ body: (UnsafePointer<WCHAR>) -> R) -> R {
    s.withCString(encodedAs: UTF16.self) { body($0) }
}

/// The low and high words of a message parameter (`LOWORD`, `HIWORD`).
func loWord<T: BinaryInteger>(_ v: T) -> Int { Int(UInt64(truncatingIfNeeded: v) & 0xFFFF) }
func hiWord<T: BinaryInteger>(_ v: T) -> Int { Int((UInt64(truncatingIfNeeded: v) >> 16) & 0xFFFF) }

/// `GET_X_LPARAM` / `GET_Y_LPARAM`: signed client (or screen) coordinates.
func xParam<T: BinaryInteger>(_ v: T) -> Int { Int(Int16(truncatingIfNeeded: UInt64(truncatingIfNeeded: v) & 0xFFFF)) }
func yParam<T: BinaryInteger>(_ v: T) -> Int { Int(Int16(truncatingIfNeeded: (UInt64(truncatingIfNeeded: v) >> 16) & 0xFFFF)) }

/// `GET_WHEEL_DELTA_WPARAM`.
func wheelDelta<T: BinaryInteger>(_ w: T) -> Int { yParam(w) }

/// `MAKEINTRESOURCEW`.
func intResource(_ id: Int) -> UnsafePointer<WCHAR>? { UnsafePointer<WCHAR>(bitPattern: id) }

/// Window messages and values Swift imports awkwardly (macros with casts) or not at all.
enum Win {
    static let appMessage = UINT(0x8000)                        // WM_APP
    static let dpiChanged = UINT(0x02E0)                        // WM_DPICHANGED
    static let mouseLeave = UINT(0x02A3)                        // WM_MOUSELEAVE
    static let mouseWheel = UINT(0x020A)                        // WM_MOUSEWHEEL
    static let mouseHWheel = UINT(0x020E)                       // WM_MOUSEHWHEEL
    static let hwndTopmost = HWND(bitPattern: -1)
    static let hwndNoTopmost = HWND(bitPattern: -2)
    static let hwndMessage = HWND(bitPattern: -3)
    static let dpiAwarenessPerMonitorV2 = DPI_AWARENESS_CONTEXT(bitPattern: -4)
    static let arrowCursor = 32512                              // IDC_ARROW
    static let handCursor = 32649                               // IDC_HAND
    static let allInput = DWORD(0x04FF)                         // QS_ALLINPUT
    static let stillActive = DWORD(259)                         // STILL_ACTIVE
}

/// The process's module handle (`hInstance`).
let moduleHandle: HINSTANCE? = GetModuleHandleW(nil)

/// Routes a window's messages to the Swift object that owns it. A handler returns nil for "not handled"
/// (`DefWindowProcW` then runs). Only touched on the UI thread.
enum WindowRoutes {
    typealias Handler = (HWND, UINT, WPARAM, LPARAM) -> LRESULT?
    static var handlers: [Int: Handler] = [:]
    /// Claimed by the next window created: messages sent during `CreateWindowExW` (WM_NCCREATE, WM_GETMINMAXINFO…)
    /// already reach their handler.
    static var pending: Handler?

    static func key(_ hwnd: HWND) -> Int { Int(bitPattern: UnsafeMutableRawPointer(hwnd)) }

    /// Registers a window class whose procedure is `route`. Registering the same name twice is harmless.
    static func registerClass(_ name: String, cursor: Int = Win.arrowCursor) {
        withWide(name) { cls in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
            wc.lpfnWndProc = route
            wc.hInstance = moduleHandle
            wc.hCursor = LoadCursorW(nil, intResource(cursor))
            wc.lpszClassName = cls
            _ = RegisterClassExW(&wc)
        }
    }

    static func remove(_ hwnd: HWND) { handlers[key(hwnd)] = nil }
}

private func route(_ hwnd: HWND?, _ msg: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT {
    guard let hwnd else { return DefWindowProcW(hwnd, msg, w, l) }
    let k = WindowRoutes.key(hwnd)
    if WindowRoutes.handlers[k] == nil, let p = WindowRoutes.pending {
        WindowRoutes.handlers[k] = p
        WindowRoutes.pending = nil
    }
    if let h = WindowRoutes.handlers[k], let r = h(hwnd, msg, w, l) { return r }
    return DefWindowProcW(hwnd, msg, w, l)
}

/// Appends a line to `<support dir>\agentrise.log` (a GUI program has no console; CI prints the file).
package enum Log {
    package static var file: URL?
    private static let lock = NSLock()

    package static func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\r\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: file)
        }
    }
}
#endif
