// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
import AgentriseScene

/// `TowerScheduler` on the Win32 message loop: Foundation's `Timer` and the main dispatch queue need a run loop
/// that a Win32 message loop doesn't pump. A message-only window owned by the UI thread receives the work:
/// `onMain` posts a message (from any thread), `after` and `every` are `SetTimer` timers (`WM_TIMER`), so every
/// callback runs on the UI thread, also inside modal loops (a window drag, a menu, a message box).
package final class Win32Scheduler: TowerScheduler {
    private var hwnd: HWND!
    private let uiThread = GetCurrentThreadId()
    private let lock = NSLock()
    private var queue: [() -> Void] = []
    private var timers: [UInt: (repeats: Bool, work: () -> Void)] = [:]
    private var nextTimer: UInt = 1
    private static let runQueue = Win.appMessage + 1
    static let className = "AgentriseScheduler"

    /// Must be made on the UI thread.
    package init() {
        WindowRoutes.registerClass(Self.className)
        WindowRoutes.pending = { [unowned self] _, msg, w, _ in self.handle(msg, w) }
        hwnd = withWide(Self.className) { cls in
            CreateWindowExW(0, cls, nil, 0, 0, 0, 0, 0, Win.hwndMessage, nil, moduleHandle, nil)
        }
        WindowRoutes.pending = nil
        precondition(hwnd != nil, "CreateWindowExW(message-only) failed: \(GetLastError())")
    }

    private var onUIThread: Bool { GetCurrentThreadId() == uiThread }

    package func onMain(_ work: @escaping () -> Void) {
        lock.lock()
        queue.append(work)
        lock.unlock()
        PostMessageW(hwnd, Self.runQueue, 0, 0)
    }

    package func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) { schedule(seconds, repeats: false, work) }

    package func every(_ seconds: TimeInterval, _ work: @escaping () -> Void) { schedule(seconds, repeats: true, work) }

    package func inBackground(_ work: @escaping () -> Void) { DispatchQueue.global(qos: .utility).async(execute: work) }

    /// How many timers are pending (tests).
    package var pendingTimers: Int { timers.count }

    private func schedule(_ seconds: TimeInterval, repeats: Bool, _ work: @escaping () -> Void) {
        // A timer belongs to the thread that owns the window.
        guard onUIThread else { return onMain { [weak self] in self?.schedule(seconds, repeats: repeats, work) } }
        let id = nextTimer
        nextTimer += 1
        timers[id] = (repeats, work)
        SetTimer(hwnd, UINT_PTR(id), UINT(max(1, (seconds * 1000).rounded())), nil)
    }

    private func handle(_ msg: UINT, _ w: WPARAM) -> LRESULT? {
        switch msg {
        case Self.runQueue:
            lock.lock()
            let work = queue
            queue.removeAll()
            lock.unlock()
            for item in work { item() }
            return 0
        case UINT(WM_TIMER):
            let id = UInt(w)
            guard let t = timers[id] else { KillTimer(hwnd, UINT_PTR(w)); return 0 }
            if !t.repeats {
                KillTimer(hwnd, UINT_PTR(w))
                timers[id] = nil
            }
            t.work()
            return 0
        default:
            return nil
        }
    }

    /// Runs posted work and due timers until `done` holds or `timeout` passes (tests, and the smoke paths that wait
    /// without a window). True when `done` held.
    @discardableResult
    package func pump(until done: () -> Bool, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        var msg = MSG()
        while !done() {
            let left = end.timeIntervalSinceNow
            if left <= 0 { return false }
            _ = MsgWaitForMultipleObjects(0, nil, false, DWORD(min(left, 0.05) * 1000), Win.allInput)
            while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
        }
        return true
    }
}
#endif
