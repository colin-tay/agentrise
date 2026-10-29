// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
import TowerKit
import Agentrise
import AgentriseScene

/// What the Windows Settings window does, without the window (tests drive it directly). The same sections and words
/// as macOS Settings, minus Bark and the desk chime (spec §5.6) and the cc-connect (飞书) switch (a macOS-only
/// feature, spec §2): Claude Code and Codex hooks (preview first, a backup before every write), the model ranks, and
/// start at login. Switches live in the app's settings store under the macOS keys (`codexSeen`).
///
/// Installing copies the hook helper (about 25 MB of DLLs on a first install), so it runs off the UI thread; the hook
/// buttons are disabled meanwhile (`installing`).
package final class SettingsController {
    package let installer: WinHookInstaller
    package let settings: SettingsStore
    private let scheduler: TowerScheduler
    package var autostart: Autostart
    package let ranksFile: URL
    /// Saved ranks are in `RankBook.current`; the app re-ranks its robots.
    package var onRanksSaved: () -> Void = {}
    /// Anything shown changed (statuses, busy, installed).
    package var onChange: () -> Void = {}
    /// Trusts / untrusts Agentrise's Codex hooks through `codex app-server`, off the UI thread, reporting back on it.
    package var runTrust: (@escaping (Result<Int, Error>) -> Void) -> Void
    package var runUntrust: (@escaping (Result<Int, Error>) -> Void) -> Void
    /// An install left the hook helper in `bin\` not current (a file in use): the app retries the copy later.
    package var onHelperStale: () -> Void = {}

    package private(set) var claudeInstalled = false
    package private(set) var codexInstalled = false
    package private(set) var hookStatus = ""
    package private(set) var codexStatus = ""
    package private(set) var rankStatus = ""
    /// Next to the start-at-login checkbox: why it couldn't be changed.
    package private(set) var autostartStatus = ""
    package private(set) var codexBusy = false
    /// A hook install is running (in the background).
    package private(set) var installing = false
    /// Files of the hook helper in `bin\` that aren't the app's (in use when it tried to replace them): the hooks are
    /// written but may not run until the copy catches up.
    package private(set) var helperStale: [String] = []

    package init(installer: WinHookInstaller, settings: SettingsStore, scheduler: TowerScheduler,
                 autostart: Autostart = Autostart(), ranksFile: URL) {
        self.installer = installer
        self.settings = settings
        self.scheduler = scheduler
        self.autostart = autostart
        self.ranksFile = ranksFile
        let paths = installer.paths
        func background(_ work: @escaping (CodexAppServer) throws -> Int) -> (@escaping (Result<Int, Error>) -> Void) -> Void {
            { done in
                scheduler.inBackground {
                    let r = Result { try CodexAppServer.withLocal(paths: paths, work) }
                    scheduler.onMain { done(r) }
                }
            }
        }
        runTrust = background { try $0.trustAgentriseHooks() }
        runUntrust = background { try $0.untrustAgentriseHooks() }
        reload()
        checkHelper()
    }

    /// Re-reads whether the installed hook helper is current (in the background; it compares every byte).
    package func checkHelper() {
        let helper = installer.helper
        scheduler.inBackground { [scheduler] in
            let stale = helper.wasInstalled ? helper.staleFiles() : []
            scheduler.onMain { [weak self] in
                guard let self, self.helperStale != stale else { return }
                self.helperStale = stale
                self.changed()
            }
        }
    }

    /// What the app's own retry of the helper copy found.
    package func noteHelper(_ r: HookHelperFiles.Result) {
        guard helperStale != r.locked else { return }
        helperStale = r.locked
        changed()
    }

    /// Re-reads what is installed.
    package func reload() {
        claudeInstalled = installer.isInstalled(.claude)
        codexInstalled = installer.isInstalled(.codex)
    }

    package static let newSessionNote = "新开一个 Codex 会话才会带上这个 hook，已经开着的会话不会。"
    package static let codexManualHint = "请在 Codex 里输入 /hooks，确认 Agentrise 的 hook。" + newSessionNote
    package static let trustQuestion = "Codex 要求信任这个 hook 才会运行。要我替你确认吗？"
    package static let helperPendingNote = "；hook 程序有文件正在使用，还没更新完，稍后会自动重试"

    package var codexPresent: Bool { installer.codexPresent }

    /// The status next to "Claude Code"; `ok` shows it green.
    /// Installed but the helper in `bin\` isn't current: not shown as working.
    package var claudeState: (text: String, ok: Bool) {
        if !claudeInstalled { return ("Hooks 未安装", false) }
        return helperStale.isEmpty ? ("✓ Hooks 已安装", true) : ("Hooks 已安装，hook 程序待更新", false)
    }

    package var codexState: (text: String, ok: Bool) {
        if !codexPresent && !codexInstalled { return ("未发现 Codex", false) }
        if !codexInstalled { return ("未安装", false) }
        if !helperStale.isEmpty { return ("已安装，hook 程序待更新", false) }
        return settings.bool(forKey: HookPlan.codexSeenKey) ? ("✓ 已生效", true) : ("已安装待信任", false)
    }

    // MARK: Claude Code

    /// The settings.json to confirm, or nil (the failure is in `hookStatus`).
    package func previewClaude() -> String? { attempt(\.hookStatus) { try installer.preview(.claude) } }

    /// Installs in the background; `done` (on the UI thread) says whether the hooks were written.
    package func installClaude(then done: @escaping (Bool) -> Void = { _ in }) { install(.claude, status: \.hookStatus, then: done) }

    package func uninstallClaude() {
        attempt(\.hookStatus) {
            try installer.uninstall(.claude)
            hookStatus = "已卸载"
        }
    }

    // MARK: Codex

    package func previewCodex() -> String? { attempt(\.codexStatus) { try installer.preview(.codex) } }

    /// Writes hooks.json in the background; `done` (on the UI thread) is true when it did (the window then asks
    /// `trustQuestion`).
    package func installCodex(then done: @escaping (Bool) -> Void = { _ in }) { install(.codex, status: \.codexStatus, then: done) }

    private func install(_ agent: AgentKind, status: ReferenceWritableKeyPath<SettingsController, String>,
                         then done: @escaping (Bool) -> Void) {
        guard !installing else { done(false); return }
        installing = true
        self[keyPath: status] = "正在安装…"
        changed()
        let installer = installer
        scheduler.inBackground { [scheduler] in
            let r = Result { try installer.installReporting(agent) }
            scheduler.onMain { [weak self] in
                guard let self else { return }
                self.installing = false
                switch r {
                case .success(let (backup, helper)):
                    self.helperStale = helper.locked
                    self[keyPath: status] = "已安装" + (backup.map { "，备份在 \($0.lastPathComponent)" } ?? "")
                        + (helper.locked.isEmpty ? "" : Self.helperPendingNote)
                    if !helper.locked.isEmpty { self.onHelperStale() }
                case .failure(let error):
                    self[keyPath: status] = "失败：\(error.localizedDescription)"
                }
                self.changed()
                if case .success = r { done(true) } else { done(false) }
            }
        }
    }

    package func trustCodex() {
        codexBusy = true
        codexStatus = "正在请 Codex 确认…"
        changed()
        runTrust { [weak self] r in
            guard let self else { return }
            self.codexBusy = false
            switch r {
            case .success(let n): self.codexStatus = (n > 0 ? "✓ 已替你确认 \(n) 条 hook。" : "✓ Agentrise 的 hook 已经被信任。") + Self.newSessionNote
            case .failure: self.codexStatus = Self.codexManualHint
            }
            self.changed()
        }
    }

    package func declineTrust() {
        codexStatus = Self.codexManualHint
        changed()
    }

    package func uninstallCodex() {
        let removed = attempt(\.codexStatus) { try installer.uninstall(.codex); return true } ?? false
        guard removed else { return }
        settings.set(false, forKey: HookPlan.codexSeenKey)
        codexBusy = true
        codexStatus = "hook 已删除，正在清理信任记录…"
        changed()
        runUntrust { [weak self] r in
            guard let self else { return }
            self.codexBusy = false
            switch r {
            case .success(let n): self.codexStatus = n > 0 ? "已卸载" : "hook 已删除。"
            case .failure(let error):
                if case CodexRPCError.binaryNotFound = error {
                    self.codexStatus = "hook 已删除；找不到 codex，信任记录留在 Codex 里，它们不再起作用。"
                } else {
                    self.codexStatus = "hook 已删除；信任记录没能清掉，它们不再起作用。"
                }
            }
            self.changed()
        }
    }

    // MARK: Ranks

    package static let rankNote = "关键词不区分大小写；匹配顺序：资深总监、高级专家、校招生，都没匹配上的算高级工程师。"

    package static func keywordPrompt(_ r: Rank) -> String {
        r == .seniorEngineer ? "关键词（其余模型都算这档）" : "模型名包含的关键词，逗号分隔"
    }

    /// Saves names and keywords (`rows[rank] = (name, keywords)`); the book as saved, or nil (see `rankStatus`).
    @discardableResult
    package func saveRanks(_ rows: [Rank: (name: String, keywords: String)]) -> RankBook? {
        var book = RankBook.current
        for r in Rank.ranksTopDown { book.set(r, name: rows[r]?.name ?? "", keywordText: rows[r]?.keywords ?? "") }
        do {
            try book.save(to: ranksFile)
            RankBook.current = book
            onRanksSaved()
            rankStatus = "✓ 已保存"
            changed()
            return book
        } catch {
            rankStatus = "保存失败：\(error.localizedDescription)"
            changed()
            return nil
        }
    }

    // MARK: Other

    package var autostartOn: Bool { autostart.isEnabled }

    package func setAutostart(_ on: Bool) {
        do {
            try autostart.set(on)
            autostartStatus = ""
        } catch { autostartStatus = error.localizedDescription }
        changed()
    }

    // MARK: -

    private func changed() {
        reload()
        onChange()
    }

    /// Runs `body`; a failure goes to `status` as "失败：…". Always refreshes what is installed.
    @discardableResult
    private func attempt<T>(_ status: ReferenceWritableKeyPath<SettingsController, String>, _ body: () throws -> T) -> T? {
        defer { changed() }
        do { return try body() } catch {
            self[keyPath: status] = "失败：\(error.localizedDescription)"
            return nil
        }
    }
}

/// The Settings window's controls and where they go, in DIPs (scaled by the window's dpi).
package enum SettingsLayout {
    package enum Kind { case group, label, state, button, edit, check, note }

    package struct Control {
        package let id: Int32
        package let kind: Kind
        package let text: String
        package let frame: (x: Int32, y: Int32, w: Int32, h: Int32)
    }

    package static let claudeState: Int32 = 102, claudeButton: Int32 = 103
    package static let codexState: Int32 = 105, codexButton: Int32 = 106
    package static let hookStatus: Int32 = 107
    package static let rankName: Int32 = 110, rankWords: Int32 = 120   // + the rank's row (0…3)
    package static let rankSave: Int32 = 131, rankStatus: Int32 = 132
    package static let autostart: Int32 = 141, autostartStatus: Int32 = 143

    package static let clientSize = (width: Int32(520), height: Int32(440))

    package static let controls: [Control] = {
        var c: [Control] = [
            Control(id: 100, kind: .group, text: "Agent 接入", frame: (12, 8, 496, 130)),
            Control(id: 101, kind: .label, text: "Claude Code", frame: (28, 36, 100, 20)),
            Control(id: claudeState, kind: .state, text: "", frame: (132, 36, 240, 20)),
            Control(id: claudeButton, kind: .button, text: "", frame: (388, 32, 104, 26)),
            Control(id: 104, kind: .label, text: "Codex", frame: (28, 68, 100, 20)),
            Control(id: codexState, kind: .state, text: "", frame: (132, 68, 240, 20)),
            Control(id: codexButton, kind: .button, text: "", frame: (388, 64, 104, 26)),
            Control(id: hookStatus, kind: .note, text: "", frame: (28, 96, 464, 36)),
            Control(id: 109, kind: .group, text: "模型职级", frame: (12, 146, 496, 222)),
        ]
        for (i, _) in Rank.ranksTopDown.enumerated() {
            let y = Int32(172 + i * 30)
            c.append(Control(id: rankName + Int32(i), kind: .edit, text: "", frame: (28, y, 110, 24)))
            c.append(Control(id: rankWords + Int32(i), kind: .edit, text: "", frame: (146, y, 346, 24)))
        }
        c += [
            Control(id: 130, kind: .note, text: SettingsController.rankNote, frame: (28, 294, 464, 32)),
            Control(id: rankSave, kind: .button, text: "保存", frame: (28, 330, 80, 26)),
            Control(id: rankStatus, kind: .label, text: "", frame: (116, 334, 376, 20)),
            Control(id: 140, kind: .group, text: "其他", frame: (12, 378, 496, 52)),
            Control(id: autostart, kind: .check, text: "开机自动启动", frame: (28, 402, 140, 20)),
            Control(id: autostartStatus, kind: .label, text: "", frame: (176, 404, 316, 20)),
        ]
        return c
    }()

    /// A DIP length at `dpi`.
    package static func scaled(_ v: Int32, dpi: UInt32) -> Int32 { MulDiv(v, Int32(dpi), 96) }

    /// Every control's frame in pixels at `dpi`.
    package static func frames(dpi: UInt32) -> [Int32: RECT] {
        var out: [Int32: RECT] = [:]
        for c in controls {
            let x = scaled(c.frame.x, dpi: dpi), y = scaled(c.frame.y, dpi: dpi)
            out[c.id] = RECT(left: x, top: y, right: x + scaled(c.frame.w, dpi: dpi), bottom: y + scaled(c.frame.h, dpi: dpi))
        }
        return out
    }
}

/// Window styles and control messages, spelled out (several are macros Swift imports awkwardly).
private enum S {
    static let child: DWORD = 0x4000_0000, visible: DWORD = 0x1000_0000, tabStop: DWORD = 0x0001_0000
    static let caption: DWORD = 0x00C0_0000, sysMenu: DWORD = 0x0008_0000, minimizeBox: DWORD = 0x0002_0000
    static let popup: DWORD = 0x8000_0000, vScroll: DWORD = 0x0020_0000, hScroll: DWORD = 0x0010_0000, thickFrame: DWORD = 0x0004_0000
    static let exControlParent: DWORD = 0x0001_0000, exClientEdge: DWORD = 0x0000_0200, exAppWindow: DWORD = 0x0004_0000
    static let exDlgModalFrame: DWORD = 0x0000_0001
    static let groupBox: DWORD = 0x7, pushButton: DWORD = 0x0, defPushButton: DWORD = 0x1, autoCheckBox: DWORD = 0x3
    static let ssNoPrefix: DWORD = 0x80
    static let esAutoHScroll: DWORD = 0x80, esAutoVScroll: DWORD = 0x40, esMultiline: DWORD = 0x4, esReadOnly: DWORD = 0x800
    static let setFont = UINT(0x0030), getCheck = UINT(0x00F0), setCheck = UINT(0x00F1)
    static let setCueBanner = UINT(0x1501), setLimitText = UINT(0x00C5), ctlColorStatic = UINT(0x0138)
    static let close = UINT(0x0010), destroy = UINT(0x0002), command = UINT(0x0111)
    static let useDefault = Int32.min   // CW_USEDEFAULT
    static let btnFace: Int32 = 15      // COLOR_BTNFACE
}

/// The system's message font at `dpi` (its size and weight), in Microsoft YaHei UI: the text is Simplified Chinese,
/// and Segoe UI's font links on a non-Chinese Windows mix several CJK fonts in one line (as the panel's text falls
/// back to YaHei too, spec §5.1).
private func messageFont(dpi: UInt32) -> HFONT? {
    var m = NONCLIENTMETRICSW()
    m.cbSize = UINT(MemoryLayout<NONCLIENTMETRICSW>.size)
    guard SystemParametersInfoForDpi(UINT(SPI_GETNONCLIENTMETRICS), m.cbSize, &m, 0, dpi) else { return nil }
    withUnsafeMutableBytes(of: &m.lfMessageFont.lfFaceName) { raw in
        let units = raw.bindMemory(to: UInt16.self)
        let name = Array("Microsoft YaHei UI".utf16).prefix(units.count - 1)
        for (i, u) in name.enumerated() { units[i] = u }
        units[name.count] = 0
    }
    return CreateFontIndirectW(&m.lfMessageFont)
}

private func createControl(_ cls: String, _ text: String, style: DWORD, exStyle: DWORD = 0, id: Int32, parent: HWND) -> HWND? {
    withWide(cls) { c in
        withWide(text) { t in
            CreateWindowExW(exStyle, c, t, style, 0, 0, 10, 10, parent, HMENU(bitPattern: Int(id)), moduleHandle, nil)
        }
    }
}

private func setText(_ hwnd: HWND?, _ s: String) {
    guard let hwnd else { return }
    if text(of: hwnd) != s { _ = withWide(s) { SetWindowTextW(hwnd, $0) } }
}

private func text(of hwnd: HWND?) -> String {
    guard let hwnd else { return "" }
    let n = GetWindowTextLengthW(hwnd)
    var buf = [WCHAR](repeating: 0, count: Int(n) + 1)
    let got = GetWindowTextW(hwnd, &buf, Int32(buf.count))
    return String(decoding: buf.prefix(Int(got)), as: UTF16.self)
}

/// The Settings window: Win32 controls (comctl32 v6 visual styles come from the manifest), laid out in DIPs and
/// re-laid out with a new font when it moves to a monitor of another dpi. Tab, Enter and Esc work through
/// `IsDialogMessageW` in the app's message loop (`dialogMessage`).
package final class SettingsWindow {
    package static let className = "AgentriseSettingsWindow"
    package private(set) var hwnd: HWND!
    package let controller: SettingsController
    /// After the window is gone.
    package var onClose: () -> Void = {}
    private var controls: [Int32: HWND] = [:]
    private var font: HFONT?
    private let style = S.caption | S.sysMenu | S.minimizeBox
    private let exStyle = S.exControlParent | S.exAppWindow

    package init(controller: SettingsController, near: HWND?) {
        self.controller = controller
        WindowRoutes.registerClass(Self.className, background: HBRUSH(bitPattern: Int(S.btnFace) + 1))
        WindowRoutes.pending = { [unowned self] h, m, w, l in self.handle(h, m, w, l) }
        hwnd = withWide(Self.className) { cls in
            withWide("Agentrise 设置") { t in
                CreateWindowExW(exStyle, cls, t, style, S.useDefault, S.useDefault, 100, 100, nil, nil, moduleHandle, nil)
            }
        }
        WindowRoutes.pending = nil
        precondition(hwnd != nil, "CreateWindowExW (settings) failed: \(GetLastError())")
        createControls()
        place(near: near)
        layout()
        fillRanks()
        refresh()
        controller.onChange = { [weak self] in self?.refresh() }
    }

    package func show() {
        ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW)
        SetForegroundWindow(hwnd)
    }

    package func close() { DestroyWindow(hwnd) }

    /// For the app's message loop: true when the message was a dialog-navigation key for this window.
    package func dialogMessage(_ msg: inout MSG) -> Bool { IsDialogMessageW(hwnd, &msg) }

    package func control(_ id: Int32) -> HWND? { controls[id] }

    // MARK: Building

    private func createControls() {
        for c in SettingsLayout.controls {
            let h: HWND?
            switch c.kind {
            case .group: h = createControl("BUTTON", c.text, style: S.child | S.visible | S.groupBox, id: c.id, parent: hwnd)
            case .label, .state, .note:
                h = createControl("STATIC", c.text, style: S.child | S.visible | S.ssNoPrefix, id: c.id, parent: hwnd)
            case .button:
                h = createControl("BUTTON", c.text, style: S.child | S.visible | S.tabStop | S.pushButton, id: c.id, parent: hwnd)
            case .check:
                h = createControl("BUTTON", c.text, style: S.child | S.visible | S.tabStop | S.autoCheckBox, id: c.id, parent: hwnd)
            case .edit:
                h = createControl("EDIT", c.text, style: S.child | S.visible | S.tabStop | S.esAutoHScroll,
                                  exStyle: S.exClientEdge, id: c.id, parent: hwnd)
            }
            if let h { controls[c.id] = h }
        }
        for (i, r) in Rank.ranksTopDown.enumerated() {
            guard let words = controls[SettingsLayout.rankWords + Int32(i)] else { continue }
            _ = withWide(SettingsController.keywordPrompt(r)) { SendMessageW(words, S.setCueBanner, 1, LPARAM(Int(bitPattern: $0))) }
            if r == .seniorEngineer { EnableWindow(words, false) }
        }
    }

    /// Centred on the work area of the monitor `near` is on (the tower window's), at that monitor's dpi.
    private func place(near: HWND?) {
        let monitor = MonitorFromWindow(near ?? hwnd, DWORD(MONITOR_DEFAULTTONEAREST))
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        guard GetMonitorInfoW(monitor, &info) else { return }
        let w = info.rcWork
        // Move onto that monitor first (WM_DPICHANGED re-lays out if its dpi differs), then size and centre.
        SetWindowPos(hwnd, nil, w.left + 40, w.top + 40, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        let size = windowSize(dpi: GetDpiForWindow(hwnd))
        SetWindowPos(hwnd, nil, w.left + max(0, (w.right - w.left - size.cx) / 2), w.top + max(0, (w.bottom - w.top - size.cy) / 2),
                     size.cx, size.cy, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }

    private func windowSize(dpi: UINT) -> SIZE {
        var r = RECT(left: 0, top: 0, right: SettingsLayout.scaled(SettingsLayout.clientSize.width, dpi: dpi),
                     bottom: SettingsLayout.scaled(SettingsLayout.clientSize.height, dpi: dpi))
        AdjustWindowRectExForDpi(&r, style, false, exStyle, dpi)
        return SIZE(cx: r.right - r.left, cy: r.bottom - r.top)
    }

    /// Positions and fonts for the window's current dpi.
    private func layout() {
        let dpi = GetDpiForWindow(hwnd)
        let old = font
        font = messageFont(dpi: dpi)
        for (id, r) in SettingsLayout.frames(dpi: dpi) {
            guard let h = controls[id] else { continue }
            SetWindowPos(h, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            SendMessageW(h, S.setFont, WPARAM(UInt(bitPattern: Int(bitPattern: font.map { UnsafeMutableRawPointer($0) }))), 1)
        }
        if let old { DeleteObject(old) }
    }

    private func fillRanks() {
        for (i, r) in Rank.ranksTopDown.enumerated() {
            setText(controls[SettingsLayout.rankName + Int32(i)], RankBook.current.title(r))
            setText(controls[SettingsLayout.rankWords + Int32(i)], RankBook.current.keywordText(r))
        }
    }

    /// Shows the controller's state.
    package func refresh() {
        guard let hwnd, IsWindow(hwnd) else { return }
        let c = controller
        setText(controls[SettingsLayout.claudeState], c.claudeState.text)
        setText(controls[SettingsLayout.claudeButton], c.claudeInstalled ? "卸载 Hooks" : "安装 Hooks")
        setText(controls[SettingsLayout.codexState], c.codexState.text)
        setText(controls[SettingsLayout.codexButton], c.codexInstalled ? "卸载 Hook" : "安装 Hook")
        if let b = controls[SettingsLayout.claudeButton] { EnableWindow(b, !c.installing) }
        if let b = controls[SettingsLayout.codexButton] { EnableWindow(b, !c.installing && !c.codexBusy && (c.codexPresent || c.codexInstalled)) }
        setText(controls[SettingsLayout.hookStatus], [c.hookStatus, c.codexStatus].filter { !$0.isEmpty }.joined(separator: "\r\n"))
        setText(controls[SettingsLayout.rankStatus], c.rankStatus)
        check(SettingsLayout.autostart, c.autostartOn)
        setText(controls[SettingsLayout.autostartStatus], c.autostartStatus)
        for id in [SettingsLayout.claudeState, SettingsLayout.codexState] { if let h = controls[id] { InvalidateRect(h, nil, true) } }
    }

    private func check(_ id: Int32, _ on: Bool) {
        guard let h = controls[id] else { return }
        SendMessageW(h, S.setCheck, WPARAM(on ? 1 : 0), 0)
    }

    private func isChecked(_ id: Int32) -> Bool {
        guard let h = controls[id] else { return false }
        return SendMessageW(h, S.getCheck, 0, 0) == 1
    }

    // MARK: Messages

    private func handle(_ hwnd: HWND, _ msg: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT? {
        switch msg {
        case S.command:
            command(Int32(loWord(w)), notification: hiWord(w))
            return 0
        case S.ctlColorStatic:
            let target = HWND(bitPattern: Int(l))
            let ok: Bool
            if target == controls[SettingsLayout.claudeState] { ok = controller.claudeState.ok }
            else if target == controls[SettingsLayout.codexState] { ok = controller.codexState.ok }
            else { return nil }
            guard let dc = HDC(bitPattern: UInt(w)) else { return nil }
            SetTextColor(dc, ok ? 0x003E_8E1E : 0x0006_73D9)   // COLORREF 0x00BBGGRR: green, orange
            SetBkMode(dc, TRANSPARENT)
            return LRESULT(Int(bitPattern: UnsafeMutableRawPointer(GetSysColorBrush(S.btnFace))))
        case Win.dpiChanged:
            let dpi = UINT(hiWord(w))
            let suggested = UnsafePointer<RECT>(bitPattern: Int(l))?.pointee
            let size = windowSize(dpi: dpi)
            SetWindowPos(hwnd, nil, suggested?.left ?? 0, suggested?.top ?? 0, size.cx, size.cy,
                         UINT(SWP_NOZORDER | SWP_NOACTIVATE) | (suggested == nil ? UINT(SWP_NOMOVE) : 0))
            layout()
            return 0
        case S.close:
            DestroyWindow(hwnd)
            return 0
        case S.destroy:
            WindowRoutes.remove(hwnd)
            controller.onChange = {}
            if let font { DeleteObject(font) }
            font = nil
            self.hwnd = nil
            onClose()
            return 0
        default:
            return nil
        }
    }

    private func command(_ id: Int32, notification: Int) {
        guard notification == 0 else { return }   // BN_CLICKED
        let c = controller
        switch id {
        case SettingsLayout.claudeButton:
            guard !c.installing else { return }
            if c.claudeInstalled { c.uninstallClaude(); return }
            guard let preview = c.previewClaude() else { return }
            if PreviewDialog.run(owner: hwnd, file: "settings.json", text: preview) { c.installClaude() }
        case SettingsLayout.codexButton:
            guard !c.installing else { return }
            if c.codexInstalled { c.uninstallCodex(); return }
            guard let preview = c.previewCodex() else { return }
            guard PreviewDialog.run(owner: hwnd, file: "hooks.json", text: preview) else { return }
            c.installCodex { [weak self] ok in
                guard ok, let self, let hwnd = self.hwnd, IsWindow(hwnd) else { return }
                let yes = withWide(SettingsController.trustQuestion) { q in
                    withWide("Codex") { MessageBoxW(hwnd, q, $0, UINT(MB_YESNO | MB_ICONQUESTION)) }
                } == IDYES
                if yes { c.trustCodex() } else { c.declineTrust() }
            }
        case SettingsLayout.rankSave:
            var rows: [Rank: (name: String, keywords: String)] = [:]
            for (i, r) in Rank.ranksTopDown.enumerated() {
                rows[r] = (text(of: controls[SettingsLayout.rankName + Int32(i)]), text(of: controls[SettingsLayout.rankWords + Int32(i)]))
            }
            if c.saveRanks(rows) != nil { fillRanks() }
        case SettingsLayout.autostart:
            c.setAutostart(isChecked(SettingsLayout.autostart))
        default:
            break
        }
    }
}

/// "确认前请检查写入后的 <file>：" with the whole file, read-only, and 确认并写入 / 取消. Modal to `owner`: returns
/// true only for 确认并写入 (Enter); 取消, Esc and closing return false. Nothing is written before it returns true.
package enum PreviewDialog {
    package static let className = "AgentrisePreviewDialog"
    private static let ok: Int32 = 1, cancel: Int32 = 2   // IDOK / IDCANCEL, which IsDialogMessageW sends for Enter / Esc

    /// The edit control's text: Windows line ends.
    package static func editText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    package static func run(owner: HWND?, file: String, text: String) -> Bool {
        WindowRoutes.registerClass(className, background: HBRUSH(bitPattern: Int(S.btnFace) + 1))
        var result: Bool?
        WindowRoutes.pending = { h, m, w, _ in
            switch m {
            case S.command:
                let id = Int32(loWord(w))
                if id == ok { result = true } else if id == cancel { result = false }
                return 0
            case S.close:
                result = false
                return 0
            case S.destroy:
                // Destroyed from outside (quitting from the tray while it is open): the modal loop ends, nothing is written.
                result = result ?? false
                WindowRoutes.remove(h)
                return 0
            default:
                return nil
            }
        }
        let style = S.popup | S.caption | S.sysMenu
        let exStyle = S.exControlParent | S.exDlgModalFrame
        let dlg = withWide(className) { cls in
            withWide("预览：\(file)") { t in CreateWindowExW(exStyle, cls, t, style, S.useDefault, S.useDefault, 100, 100, owner, nil, moduleHandle, nil) }
        }
        WindowRoutes.pending = nil
        guard let dlg else { return false }
        let dpi = owner.map { GetDpiForWindow($0) } ?? GetDpiForSystem()
        func px(_ v: Int32) -> Int32 { SettingsLayout.scaled(v, dpi: dpi) }
        let font = messageFont(dpi: dpi)
        let fontParam = WPARAM(UInt(bitPattern: Int(bitPattern: font.map { UnsafeMutableRawPointer($0) })))
        let items: [(String, String, DWORD, DWORD, Int32, (Int32, Int32, Int32, Int32))] = [
            ("STATIC", "确认前请检查写入后的 \(file)：", S.child | S.visible | S.ssNoPrefix, 0, 10, (12, 10, 616, 20)),
            ("EDIT", "", S.child | S.visible | S.tabStop | S.esMultiline | S.esReadOnly | S.vScroll | S.hScroll | S.esAutoVScroll | S.esAutoHScroll,
             S.exClientEdge, 11, (12, 34, 616, 380)),
            ("BUTTON", "确认并写入", S.child | S.visible | S.tabStop | S.defPushButton, 0, ok, (418, 424, 120, 28)),
            ("BUTTON", "取消", S.child | S.visible | S.tabStop | S.pushButton, 0, cancel, (546, 424, 82, 28)),
        ]
        var edit: HWND?
        for (cls, t, st, ex, id, f) in items {
            guard let h = createControl(cls, t, style: st, exStyle: ex, id: id, parent: dlg) else { continue }
            SetWindowPos(h, nil, px(f.0), px(f.1), px(f.2), px(f.3), UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            SendMessageW(h, S.setFont, fontParam, 1)
            if id == 11 { edit = h }
        }
        if let edit {
            SendMessageW(edit, S.setLimitText, 0, 0)
            setText(edit, editText(text))
        }
        // Centre on the owner, at the owner's dpi.
        var r = RECT(left: 0, top: 0, right: px(640), bottom: px(464))
        AdjustWindowRectExForDpi(&r, style, false, exStyle, dpi)
        var o = RECT()
        if let owner { GetWindowRect(owner, &o) }
        let w = r.right - r.left, h = r.bottom - r.top
        SetWindowPos(dlg, nil, o.left + (o.right - o.left - w) / 2, max(o.top, o.top + (o.bottom - o.top - h) / 2), w, h,
                     UINT(SWP_NOZORDER))
        if let owner { EnableWindow(owner, false) }
        ShowWindow(dlg, SW_SHOW)
        SetFocus(GetDlgItem(dlg, ok))

        var msg = MSG()
        var quit = false
        while result == nil {
            let got = GetMessageW(&msg, nil, 0, 0)
            if msg.message == UINT(WM_QUIT) || !got { quit = true; break }
            if !IsDialogMessageW(dlg, &msg) {
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
        }
        if quit { PostQuitMessage(Int32(truncatingIfNeeded: msg.wParam)) }   // for the app's own loop
        if let owner {
            EnableWindow(owner, true)
            SetActiveWindow(owner)
        }
        DestroyWindow(dlg)
        if let font { DeleteObject(font) }
        return result ?? false
    }
}
#endif
