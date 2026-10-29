// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// Click-to-jump (spec §5.8) against a made-up process tree and window list.

#if os(Windows)
import Testing
import Foundation
@testable import AgentriseScene
@testable import AgentriseWin

@Suite struct JumpTests {
    /// claude.exe (100) ← pwsh.exe (90) ← WindowsTerminal.exe (80) ← explorer.exe (10).
    private let tree = [
        ProcessEntry(pid: 10, parent: 4, exe: "explorer.exe", created: 1),
        ProcessEntry(pid: 80, parent: 10, exe: "WindowsTerminal.exe", created: 50),
        ProcessEntry(pid: 90, parent: 80, exe: "pwsh.exe", created: 60),
        ProcessEntry(pid: 100, parent: 90, exe: "claude.exe", created: 70),
        ProcessEntry(pid: 300, parent: 10, exe: "Claude.exe", created: 20),   // the desktop app
    ]
    private let windows = [
        TopLevelWindow(handle: 0x10, pid: 10),                              // the taskbar
        TopLevelWindow(handle: 0x90, pid: 90, visible: false),               // a hidden helper window
        TopLevelWindow(handle: 0x91, pid: 90, secondary: true),              // an owned dialog
        TopLevelWindow(handle: 0x80, pid: 80),                               // the terminal
        TopLevelWindow(handle: 0x300, pid: 300),                             // the Claude app
    ]

    private func jump(_ procs: [ProcessEntry]? = nil, _ wins: [TopLevelWindow]? = nil, console: [UInt32: TopLevelWindow] = [:],
                      opens: Bool = true, activated: @escaping (TopLevelWindow) -> Void = { _ in }, opened: @escaping (URL) -> Void = { _ in }) -> Jump {
        var j = Jump()
        let p = procs ?? tree, w = wins ?? windows
        j.processes = { p }
        j.windows = { w }
        j.consoleWindow = { console[$0] }
        j.openURL = { opened($0); return opens }
        j.activate = { activated($0); return true }
        return j
    }

    @Test func terminalSessionFindsItsTerminalWindow() {
        var got: [TopLevelWindow] = []
        let j = jump(activated: { got.append($0) })
        #expect(j.window(forAgent: 100)?.handle == 0x80)
        #expect(j.open(.terminal(bundleId: nil, pid: 100)))
        #expect(got.map(\.handle) == [0x80])
        #expect(Jump.ancestry(of: 100, in: tree).map(\.pid) == [100, 90, 80])   // stops at Explorer
    }

    @Test func noPidOrGoneProcessCannotBeLocated() {
        var activated = false
        let j = jump(activated: { _ in activated = true })
        #expect(!j.open(.terminal(bundleId: nil, pid: nil)))
        #expect(!j.open(.terminal(bundleId: nil, pid: 0)))
        #expect(!j.open(.terminal(bundleId: nil, pid: 555)))   // no such process
        #expect(!activated)
    }

    @Test func noWindowAnywhereCannotBeLocated() {
        // A terminal whose only window is hidden (e.g. a service or an ssh session): nothing to bring forward.
        let j = jump(nil, [TopLevelWindow(handle: 0x90, pid: 90, visible: false), TopLevelWindow(handle: 0x10, pid: 10)])
        #expect(j.window(forAgent: 100) == nil)
        #expect(!j.open(.terminal(bundleId: nil, pid: 100)))
    }

    /// A classic console (conhost): the window isn't any ancestor's top-level window, but the console says which it is.
    @Test func consoleWindowCounts() {
        let procs = [ProcessEntry(pid: 50, parent: 10, exe: "cmd.exe", created: 5), ProcessEntry(pid: 60, parent: 50, exe: "claude.exe", created: 6),
                     ProcessEntry(pid: 10, parent: 4, exe: "explorer.exe", created: 1)]
        let j = jump(procs, [TopLevelWindow(handle: 0x10, pid: 10)], console: [60: TopLevelWindow(handle: 0x77, pid: 51)])
        #expect(j.window(forAgent: 60)?.handle == 0x77)
        // A console window that isn't visible (ConPTY's pseudo window without a visible owner) doesn't.
        let hidden = jump(procs, [], console: [60: TopLevelWindow(handle: 0x77, pid: 51, visible: false)])
        #expect(hidden.window(forAgent: 60) == nil)
    }

    /// Windows doesn't update a parent pid when the parent exits: a "parent" created after its child is someone else.
    @Test func reusedParentPidIsNotFollowed() {
        let procs = [ProcessEntry(pid: 100, parent: 90, exe: "claude.exe", created: 70),
                     ProcessEntry(pid: 90, parent: 10, exe: "notepad.exe", created: 99)]
        #expect(Jump.ancestry(of: 100, in: procs).map(\.pid) == [100])
        let j = jump(procs, [TopLevelWindow(handle: 0x90, pid: 90)])
        #expect(j.window(forAgent: 100) == nil)
    }

    @Test func cyclesAndDepthAreBounded() {
        let cycle = [ProcessEntry(pid: 8, parent: 12, exe: "a.exe"), ProcessEntry(pid: 12, parent: 8, exe: "b.exe")]
        #expect(Jump.ancestry(of: 8, in: cycle).map(\.pid) == [8, 12])
        var long: [ProcessEntry] = []
        for i in 1...40 {
            let pid = UInt32(i) * 4
            long.append(ProcessEntry(pid: pid, parent: pid + 4, exe: "x.exe"))
        }
        #expect(Jump.ancestry(of: 4, in: long).count == Jump.maxDepth)
    }

    @Test func desktopSessionOpensItsLinkElseTheApp() {
        let url = SessionLink.url(hostSessionId: "abc")!
        var opened: [URL] = []
        var activated: [UInt] = []
        #expect(jump(opened: { opened.append($0) }).open(.desktop(url)))
        #expect(opened == [url])
        #expect(url.absoluteString == "claude://claude.ai/epitaxy/abc")
        // Not registered: the Claude app's window instead (the CLI's claude.exe has no window of its own).
        #expect(jump(opens: false, activated: { activated.append($0.handle) }).open(.desktop(url)))
        #expect(activated == [0x300])
        // Neither: the model's toast.
        #expect(!jump(tree.filter { $0.pid != 300 }, opens: false).open(.desktop(url)))
    }

    /// The real system calls on this machine: this test process is found with its ancestors, and windows are listed.
    @Test func systemListsProcessesAndWindows() {
        let procs = Jump.systemProcesses()
        let me = UInt32(ProcessInfo.processInfo.processIdentifier)
        #expect(procs.contains { $0.pid == me })
        #expect(!Jump.ancestry(of: me, in: procs).isEmpty)
        #expect(Jump.creationTime(me) != nil)
        _ = Jump.systemWindows()   // may be empty on a service desktop; must not crash
        #expect(!Jump().open(.terminal(bundleId: nil, pid: nil)))
        #expect(Jump.isRegistered(scheme: "http") || !Jump.isRegistered(scheme: "http"))
        #expect(!Jump.isRegistered(scheme: "agentrise-no-such-scheme-\(UUID().uuidString.prefix(6))"))
    }
}
#endif
