// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
import AgentriseScene

/// One process as Toolhelp lists it.
package struct ProcessEntry: Equatable {
    package var pid: UInt32
    package var parent: UInt32
    /// The image name (`claude.exe`).
    package var exe: String
    /// Creation time (FILETIME ticks), when the process could be opened.
    package var created: UInt64?

    package init(pid: UInt32, parent: UInt32, exe: String, created: UInt64? = nil) {
        self.pid = pid; self.parent = parent; self.exe = exe; self.created = created
    }
}

/// One top-level window as `EnumWindows` lists it.
package struct TopLevelWindow: Equatable {
    /// The `HWND`'s bits.
    package var handle: UInt
    package var pid: UInt32
    package var visible: Bool
    /// Owned (a dialog or tool palette of another window) or a tool window: never the one to bring forward.
    package var secondary: Bool

    package init(handle: UInt, pid: UInt32, visible: Bool = true, secondary: Bool = false) {
        self.handle = handle; self.pid = pid; self.visible = visible; self.secondary = secondary
    }
}

/// Click-to-jump on Windows (spec §5.8).
///
/// - A desktop-app session opens its `claude://claude.ai/epitaxy/<hostSessionId>` link (`ShellExecuteExW`, no UI), if
///   Windows knows the `claude` protocol (`HKEY_CLASSES_ROOT\claude`, the check Claude Code itself makes, facts §6).
///   Otherwise, or if opening fails, the Claude app's window is brought forward. Whether `epitaxy/<id>` reaches the
///   right session on Windows is unverified (facts §6): the author's trial checks it.
/// - A terminal session: from the agent's pid up its ancestors (Toolhelp), the first process with a visible, unowned
///   top-level window (`EnumWindows`); a console process's own console window (`AttachConsole` + `GetConsoleWindow`,
///   its root owner under ConPTY) counts too. The walk stops at Explorer (its windows are the taskbar and desktop), at
///   a parent created after its child (a reused pid), at a cycle, and after 16 steps. Windows Terminal with several
///   tabs only comes forward as a window, not at the tab.
/// - Nothing found (no pid, process gone, no window): false, and the model shows its "can't locate" toast.
///
/// Every system call is an injectable function, so `JumpTests` drives it with a made-up process tree.
package struct Jump {
    package var processes: () -> [ProcessEntry] = Jump.systemProcesses
    package var windows: () -> [TopLevelWindow] = Jump.systemWindows
    package var consoleWindow: (UInt32) -> TopLevelWindow? = Jump.systemConsoleWindow
    /// Opens a URL; false when it couldn't (no handler registered, or the shell failed).
    package var openURL: (URL) -> Bool = Jump.systemOpen
    /// Restores (if minimised) and brings the window forward; flashes its taskbar button when Windows refuses.
    package var activate: (TopLevelWindow) -> Bool = Jump.systemActivate

    package init() {}

    package static let maxDepth = 16

    package func open(_ link: SessionLink) -> Bool {
        switch link {
        case .desktop(let url):
            if openURL(url) { return true }
            guard let w = claudeAppWindow() else { return false }
            return activate(w)
        case .terminal(_, let pid, let start):
            guard let pid, pid > 0, let w = window(forAgent: UInt32(pid), start: start) else { return false }
            return activate(w)
        }
    }

    /// The window that owns the agent `pid`'s terminal. With the registry's `start`, a `pid` created after the session
    /// started (plus the margin) is someone else (the agent exited and its id was reused): not followed.
    package func window(forAgent pid: UInt32, start: ProcessStart? = nil) -> TopLevelWindow? {
        let chain = Self.ancestry(of: pid, in: processes())
        guard let agent = chain.first else { return nil }   // the agent is gone
        if let start, let created = agent.created, !start.matches(creation: created) { return nil }
        let candidates = windows().filter { $0.visible && !$0.secondary }
        for p in chain {
            if let w = candidates.first(where: { $0.pid == p.pid }) { return w }
            if let w = consoleWindow(p.pid), w.visible, !w.secondary { return w }
        }
        return nil
    }

    /// The Claude desktop app's main window: a visible top-level window of a process named `claude.exe` (the CLI of
    /// the same name has no windows of its own; its console belongs to the terminal).
    package func claudeAppWindow() -> TopLevelWindow? {
        let claude = Set(processes().filter { $0.exe.lowercased() == "claude.exe" }.map(\.pid))
        return windows().first { $0.visible && !$0.secondary && claude.contains($0.pid) }
    }

    /// `pid` and its ancestors, nearest first.
    package static func ancestry(of pid: UInt32, in procs: [ProcessEntry], maxDepth: Int = maxDepth) -> [ProcessEntry] {
        var byPid: [UInt32: ProcessEntry] = [:]
        for p in procs { byPid[p.pid] = p }
        var chain: [ProcessEntry] = []
        var seen = Set<UInt32>()
        var next = byPid[pid]
        while let p = next, chain.count < maxDepth, p.pid != 0, seen.insert(p.pid).inserted {
            if p.exe.lowercased() == "explorer.exe" { break }
            if let child = chain.last, let a = p.created, let b = child.created, a > b { break }   // pid reused
            chain.append(p)
            next = byPid[p.parent]
        }
        return chain
    }

    // MARK: The system

    /// Every process (Toolhelp), with creation times where the process can be opened.
    package static func systemProcesses() -> [ProcessEntry] {
        guard let snap = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0), snap != INVALID_HANDLE_VALUE else { return [] }
        defer { CloseHandle(snap) }
        var out: [ProcessEntry] = []
        var e = PROCESSENTRY32W()
        e.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var more = Process32FirstW(snap, &e)
        while more {
            let name = withUnsafeBytes(of: e.szExeFile) { raw -> String in
                let units = raw.bindMemory(to: UInt16.self)
                let n = units.firstIndex(of: 0) ?? units.count
                return String(decoding: units.prefix(n), as: UTF16.self)
            }
            out.append(ProcessEntry(pid: e.th32ProcessID, parent: e.th32ParentProcessID, exe: name, created: creationTime(e.th32ProcessID)))
            more = Process32NextW(snap, &e)
        }
        return out
    }

    package static func creationTime(_ pid: UInt32) -> UInt64? {
        guard pid != 0, let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
        defer { CloseHandle(h) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(h, &created, &exited, &kernel, &user) else { return nil }
        return UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)
    }

    private final class WindowList { var handles: [HWND] = [] }

    /// Every top-level window, in z order.
    package static func systemWindows() -> [TopLevelWindow] {
        let list = WindowList()
        let ctx = Unmanaged.passUnretained(list).toOpaque()
        _ = EnumWindows({ hwnd, l in
            guard let hwnd, let p = UnsafeRawPointer(bitPattern: Int(l)) else { return true }
            Unmanaged<WindowList>.fromOpaque(p).takeUnretainedValue().handles.append(hwnd)
            return true
        }, LPARAM(Int(bitPattern: ctx)))
        return list.handles.map(describe)
    }

    static func describe(_ hwnd: HWND) -> TopLevelWindow {
        var pid: DWORD = 0
        GetWindowThreadProcessId(hwnd, &pid)
        let ex = GetWindowLongW(hwnd, GWL_EXSTYLE)
        let tool = ex & Int32(WS_EX_TOOLWINDOW) != 0
        return TopLevelWindow(handle: UInt(bitPattern: Int(bitPattern: UnsafeMutableRawPointer(hwnd))), pid: pid,
                              visible: IsWindowVisible(hwnd), secondary: tool || GetWindow(hwnd, UINT(GW_OWNER)) != nil)
    }

    /// The console window of a console process, if it has one (attached for a moment; a GUI process like Agentrise
    /// has no console of its own). Under ConPTY (Windows Terminal) the console's window is a hidden pseudo window
    /// owned by the terminal's: its root owner is the one to show.
    package static func systemConsoleWindow(_ pid: UInt32) -> TopLevelWindow? {
        guard GetConsoleWindow() == nil, AttachConsole(pid) else { return nil }
        let console = GetConsoleWindow()
        FreeConsole()
        guard let console else { return nil }
        let root = GetAncestor(console, UINT(GA_ROOTOWNER)) ?? console
        return describe(root)
    }

    package static func hwnd(_ w: TopLevelWindow) -> HWND? { HWND(bitPattern: w.handle) }

    package static func systemActivate(_ w: TopLevelWindow) -> Bool {
        guard let hwnd = hwnd(w), IsWindow(hwnd) else { return false }
        if IsIconic(hwnd) { ShowWindow(hwnd, SW_RESTORE) }
        // Agentrise is the foreground process (the user just clicked it), so it may hand the foreground on.
        AllowSetForegroundWindow(w.pid)
        if !SetForegroundWindow(hwnd) {
            var f = FLASHWINFO()
            f.cbSize = UINT(MemoryLayout<FLASHWINFO>.size)
            f.hwnd = hwnd
            f.dwFlags = DWORD(FLASHW_ALL | FLASHW_TIMERNOFG)
            f.uCount = 3
            FlashWindowEx(&f)
        }
        return true
    }

    /// `HKEY_CLASSES_ROOT` (a macro Swift doesn't import: `(HKEY)(ULONG_PTR)(LONG)0x80000000`).
    static let classesRoot = HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0000)))

    /// Whether Windows has a handler for `scheme` (Claude Code checks `HKEY_CLASSES_ROOT\claude` the same way).
    package static func isRegistered(scheme: String) -> Bool {
        var key: HKEY?
        let r = withWide(scheme) { RegOpenKeyExW(classesRoot, $0, 0, DWORD(0x2_0019) /* KEY_READ */, &key) }
        if r == ERROR_SUCCESS, let key { RegCloseKey(key) }
        return r == ERROR_SUCCESS
    }

    package static func systemOpen(_ url: URL) -> Bool {
        if let scheme = url.scheme, scheme != "http", scheme != "https", !isRegistered(scheme: scheme) { return false }
        var info = SHELLEXECUTEINFOW()
        info.cbSize = DWORD(MemoryLayout<SHELLEXECUTEINFOW>.size)
        info.fMask = ULONG(SEE_MASK_FLAG_NO_UI)
        info.nShow = SW_SHOWNORMAL
        return withWide("open") { verb in
            withWide(url.absoluteString) { file in
                info.lpVerb = verb
                info.lpFile = file
                return ShellExecuteExW(&info)
            }
        }
    }
}
#endif
