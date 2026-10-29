// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
import TowerKit
import Agentrise
import AgentriseScene
import AgentriseWinArt

package enum AppInfo {
    /// `CFBundleShortVersionString` of the macOS app.
    package static let version = "1.0"
    package static let repository = "https://github.com/colin-tay/agentrise"
}

/// `Agentrise.exe --install-hooks claude|codex`: what Settings does after its preview, without asking. For Codex it
/// then asks `codex app-server` to trust the hooks, if Codex is on the machine. Returns the exit code.
package enum HookCommandLine {
    package static func run(_ agent: AgentKind, paths: AppPaths, sourceDir: URL = HookHelperFiles.appDir()) -> Int32 {
        let installer = WinHookInstaller(paths: paths, sourceDir: sourceDir)
        do {
            let backup = try installer.install(agent)
            Log.write("install-hooks \(agent.rawValue): \(SafeFile.nativePath(of: installer.file(agent).url)) written"
                      + (backup.map { ", backup \($0.lastPathComponent)" } ?? ", no previous file")
                      + "; helper \(installer.helper.hookPath)")
        } catch {
            Log.write("install-hooks \(agent.rawValue) failed: \(error.localizedDescription)")
            return error is WinHookInstaller.CodexMissing ? 2 : 1
        }
        if agent == .codex {
            do {
                let n = try CodexAppServer.withLocal(paths: paths) { try $0.trustAgentriseHooks() }
                Log.write("install-hooks codex: trusted \(n) hooks")
            } catch {
                Log.write("install-hooks codex: not trusted (\(error.localizedDescription)); run /hooks in Codex")
            }
        }
        return 0
    }
}

/// `Agentrise.exe --print-runtime-files <out.txt> [--search-dir <dir>]...`: writes (UTF-8, one per line) what
/// `RuntimeFiles.resolve` finds for `Agentrise.exe` and the `agentrise-hook.exe` next to it, searching the exe's own
/// directory and then each `--search-dir` in order: each file's full path, then `system <name>` for each import that
/// is Windows' own, then `missing <name> <importer>` for each import found nowhere. The release workflow checks this
/// against the packaging script's `dumpbin` closure (the installed hook copies its DLLs with the same function).
/// Returns 0, 3 when an import is missing, 1 when it couldn't write the list.
package enum RuntimeFilesCommandLine {
    package static func resolution(appDir: URL = HookHelperFiles.appDir(), exe: URL = URL(fileURLWithPath: Autostart.currentExe()),
                                   searchDirs: [String]) -> RuntimeFiles.Resolution {
        let hook = appDir.appendingPathComponent(HookHelperFiles.hookExe)
        let dirs = [appDir] + searchDirs.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return RuntimeFiles.resolve(of: [exe, hook], searchDirs: dirs)
    }

    package static func files(appDir: URL = HookHelperFiles.appDir(), exe: URL = URL(fileURLWithPath: Autostart.currentExe()),
                              searchDirs: [String]) -> [URL] {
        resolution(appDir: appDir, exe: exe, searchDirs: searchDirs).files
    }

    package static func lines(_ r: RuntimeFiles.Resolution) -> [String] {
        r.files.map { SafeFile.nativePath(of: $0) } + r.system.map { "system \($0)" }
            + r.missing.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { "missing \($0.key) \($0.value)" }
    }

    package static func run(out: String, searchDirs: [String]) -> Int32 {
        let appDir = HookHelperFiles.appDir()
        guard FileManager.default.fileExists(atPath: appDir.appendingPathComponent(HookHelperFiles.hookExe).path) else {
            return 1
        }
        let r = resolution(appDir: appDir, searchDirs: searchDirs)
        let text = lines(r).map { $0 + "\n" }.joined()
        do { try Data(text.utf8).write(to: URL(fileURLWithPath: out)) } catch { return 1 }
        return r.missing.isEmpty ? 0 : 3
    }
}

/// The command line. Besides normal launches, for CI and local smoke runs:
/// - `--data-dir <dir>`: home and support directory under `<dir>` (see `AppPaths`);
/// - `--screenshot <file.png> [--after <seconds>]`: after `seconds` (default 8), writes the window's content (rendered
///   offscreen by `D2DDisplay`) as a PNG and exits with 0 (1 when it couldn't);
/// - `--smoke-second`: only the single-instance check: with an instance running, signal it and exit 0; with none,
///   exit 3 (nothing to defer to) without opening a window;
/// - `--retry-ms <n>`: how long a second instance looks for the first one's window (default 2000);
/// - `--size <w>x<h>`: the window's client size in points (like the macOS `--size`);
/// - `--open-settings`: opens the Settings window at start (CI's desktop capture shows it);
/// - `--install-hooks claude|codex`: installs that agent's hooks without asking (no preview; the backup is still
///   written), logs the result and exits 0 (1 on failure, 2 for Codex when Codex isn't on this machine: its home is
///   never created). Runs whether or not Agentrise is running.
/// - `--print-runtime-files <out.txt> [--search-dir <dir>]...`: writes the runtime file list (`RuntimeFilesCommandLine`)
///   and exits 0 (3 when an import is missing, 1 when it couldn't write), right after DPI awareness and OLE are set up
///   and before the data directory and the log: it creates neither.
package struct AppOptions: Equatable {
    package var dataDir: String?
    package var screenshot: String?
    package var screenshotAfter: TimeInterval = 8
    package var smokeSecond = false
    package var retry: TimeInterval = 2
    package var size: CGSize?
    package var installHooks: AgentKind?
    package var openSettings = false
    package var printRuntimeFiles: String?
    package var searchDirs: [String] = []

    package init() {}

    package static func parse(_ args: [String]) -> AppOptions {
        var o = AppOptions()
        var i = 1
        func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
        while i < args.count {
            switch args[i] {
            case "--data-dir": o.dataDir = value(); i += 1
            case "--screenshot": o.screenshot = value(); i += 1
            case "--after": if let v = value().flatMap(TimeInterval.init) { o.screenshotAfter = v }; i += 1
            case "--smoke-second": o.smokeSecond = true
            case "--retry-ms": if let v = value().flatMap(Double.init), v >= 0 { o.retry = v / 1000 }; i += 1
            case "--open-settings": o.openSettings = true
            case "--install-hooks": o.installHooks = value().flatMap(AgentKind.init(rawValue:)); i += 1
            case "--print-runtime-files": o.printRuntimeFiles = value(); i += 1
            case "--search-dir": if let v = value() { o.searchDirs.append(v) }; i += 1
            case "--size":
                let p = (value() ?? "").split(separator: "x").compactMap { Double($0) }
                if p.count == 2, p[0] > 0, p[1] > 0 { o.size = CGSize(width: p[0], height: p[1]) }
                i += 1
            default: break
            }
            i += 1
        }
        return o
    }
}

/// The Windows app: wires the portable `TowerAppModel` and `TowerSceneModel` to the window, the Direct2D display,
/// the panel and the tray, and runs the frame loop.
///
/// Frames: while the window is visible, not minimised and not occluded, the loop drains messages and draws a frame;
/// `EndDraw` presents on the display's refresh, which paces the loop. Minimised or hidden, it sleeps in
/// `MsgWaitForMultipleObjects` until a message comes; fully covered (DXGI's occlusion status, through
/// `ID2D1HwndRenderTarget::CheckWindowState`), it draws one probe frame every 250 ms to learn when it is uncovered.
/// While paused the model renders without animation, as the macOS view does while SpriteKit is paused. During a
/// window drag or resize (a modal loop) a 16 ms timer keeps the frames coming.
package final class WinApp {
    package let options: AppOptions
    package let paths: AppPaths
    let scheduler: Win32Scheduler
    let settings: JSONSettingsStore
    package let scene: TowerSceneModel
    package let display: D2DDisplay
    package let panel: PanelRenderer
    package let model: TowerAppModel
    let window: TowerWindow
    let surface: D2DSurface
    let tray: Tray
    private let instance: SingleInstance

    private var running = true
    private var exitCode: Int32 = 0
    private var occluded = false
    private var inSizeMove = false
    private var lastFrame: Date?
    private var pointerInPanel = false
    private var windowIcons: [HICON] = []
    private var settingsWindow: SettingsWindow?
    private var hookRefreshFailing = false
    private static let alwaysOnTopKey = "alwaysOnTop"
    private static let sizeMoveTimer: UINT_PTR = 99
    private static let occludedProbe: DWORD = 250

    package init(options: AppOptions, paths: AppPaths, instance: SingleInstance) {
        self.options = options
        self.paths = paths
        self.instance = instance
        scheduler = Win32Scheduler()
        settings = JSONSettingsStore(file: paths.settingsFile)
        let onTop = settings.bool(forKey: Self.alwaysOnTopKey)
        // A screenshot run never reads or writes the user's window position.
        let placement = options.screenshot == nil ? WindowPlacement.load(paths.windowFile) : nil
        window = TowerWindow(title: "Agentrise", placement: placement, clientSize: options.size, alwaysOnTop: onTop)
        let (pw, ph) = window.clientPixels
        let scale = window.scale
        scene = TowerSceneModel(size: CGSize(width: CGFloat(pw) / scale, height: CGFloat(ph) / scale), scale: scale,
                                art: D2DArtBackend.shared)
        display = D2DDisplay(model: scene)
        surface = D2DSurface(window: window.hwnd, pixelWidth: pw, pixelHeight: ph, scale: scale)
        panel = PanelRenderer()
        scene.root.addChild(panel.node)
        panel.layout(scene.geo, scale: scale)
        model = TowerAppModel(platform: WinPlatform(paths: paths), scene: scene, settings: settings, scheduler: scheduler)
        tray = Tray(window: window.hwnd, scheduler: scheduler)
        // An elevated Agentrise still hears a normal second instance and a restarted Explorer (UIPI).
        for m in [SingleInstance.showMessage, Tray.taskbarCreated] {
            ChangeWindowMessageFilterEx(window.hwnd, m, DWORD(1) /* MSGFLT_ALLOW */, nil)
        }
        wire()
    }

    private var paused: Bool { !window.isVisible || window.isMinimized || occluded }

    private func wire() {
        display.beforeRender = { [unowned self] in self.panel.prepare() }
        model.renderAnimated = { [unowned self] in !self.paused }
        model.onPublish = { [unowned self] state in
            self.panel.update(state)
            self.tray.update(state.counts)
        }
        model.onEffects = { [unowned self] effects, sessions in
            // The macOS status item blinks for the same events (`TowerController.process`).
            for ef in effects {
                if case let .statusChanged(sid, _, to) = ef, to == .waiting, sessions[sid]?.isHidden == false { self.tray.flash() }
            }
        }
        scene.onClickSession = { [unowned self] in self.model.open(sessionId: $0) }
        scene.onHoverSession = { [unowned self] in self.panel.hovered = $0 }
        panel.onOpen = { [unowned self] in self.model.open(sessionId: $0) }
        panel.onHover = { [unowned self] id in
            self.panel.hovered = id
            self.scene.highlight(id)
        }
        tray.isAlwaysOnTop = { [unowned self] in self.settings.bool(forKey: Self.alwaysOnTopKey) }
        tray.onCommand = { [unowned self] in self.command($0) }

        var e = TowerWindow.Events()
        e.resized = { [unowned self] w, h, s in self.resized(w, h, s) }
        e.pointer = { [unowned self] in self.pointer($0) }
        e.click = { [unowned self] p in
            if self.panel.contains(p) { self.panel.click(at: p) } else { self.scene.click(at: p) }
        }
        e.wheel = { [unowned self] p, notches, _ in
            if self.panel.contains(p) { self.panel.scroll(notches: notches) }
        }
        e.paint = { [unowned self] in if !self.paused { self.drawFrame() } }
        e.sizeMove = { [unowned self] entering in
            self.inSizeMove = entering
            if entering { SetTimer(self.window.hwnd, Self.sizeMoveTimer, 16, nil) } else { KillTimer(self.window.hwnd, Self.sizeMoveTimer) }
        }
        e.moved = { [unowned self] in self.savePlacement() }
        e.dpiChanged = { [unowned self] in
            self.makeWindowIcons()
            self.tray.dpiChanged()
        }
        e.other = { [unowned self] msg, w, l in self.other(msg, w, l) }
        window.events = e
    }

    // MARK: Running

    /// Runs until "退出" (or the screenshot is written); returns the exit code.
    package func run() -> Int32 {
        makeWindowIcons()
        ShowWindow(window.hwnd, SW_SHOWNORMAL)
        let (pw, ph) = window.clientPixels
        resized(pw, ph, window.scale)
        model.start()
        tray.add()
        scheduler.every(60) { [weak self] in self?.panel.refreshAges() }
        if let shot = options.screenshot {
            scheduler.after(options.screenshotAfter) { [weak self] in self?.screenshot(to: shot) }
        } else {
            refreshHookHelper()
        }
        if options.openSettings { openSettings() }
        Log.write("running: \(pw)×\(ph) px at \(window.scale)×, socket \(paths.socketPath)")
        var msg = MSG()
        while running {
            while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
                if msg.message == UINT(WM_QUIT) { running = false; break }
                if let s = settingsWindow, s.dialogMessage(&msg) { continue }   // Tab, Enter, Esc in Settings
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
            guard running else { break }
            if !window.isVisible || window.isMinimized {
                lastFrame = nil
                _ = MsgWaitForMultipleObjects(0, nil, false, DWORD(INFINITE), Win.allInput)
            } else if occluded {
                lastFrame = nil
                if MsgWaitForMultipleObjects(0, nil, false, Self.occludedProbe, Win.allInput) == DWORD(WAIT_TIMEOUT) {
                    drawFrame()   // presents, so the occlusion status is fresh
                }
            } else {
                drawFrame()
            }
        }
        shutdown()
        return exitCode
    }

    /// The title bar's and Alt-Tab's icons at the window's dpi; the ones they replace are destroyed.
    private func makeWindowIcons() {
        let dpi = GetDpiForWindow(window.hwnd)
        let small = TrayIconArt.icon(badge: nil, dimmed: false, pixels: Int(GetSystemMetricsForDpi(SM_CXSMICON, dpi)))
        let big = TrayIconArt.icon(badge: nil, dimmed: false, pixels: Int(GetSystemMetricsForDpi(SM_CXICON, dpi)))
        window.setIcons(small: small, big: big)
        destroyWindowIcons()
        windowIcons = [small, big].compactMap { $0 }
    }

    private func destroyWindowIcons() {
        for i in windowIcons { DestroyIcon(i) }
        windowIcons = []
    }

    private func drawFrame() {
        let start = Date()
        let dt = lastFrame.map { start.timeIntervalSince($0) } ?? 0
        lastFrame = start
        guard display.frame(dt: dt, on: surface) else {
            // No target (it couldn't be made, or the device was just lost): don't spin while it can't draw.
            Sleep(50)
            return
        }
        occluded = surface.isOccluded
        // EndDraw waits for the refresh; if it didn't (no vsync on this display), don't spin.
        if !occluded, !inSizeMove, Date().timeIntervalSince(start) < 0.004 { Sleep(12) }
    }

    private func resized(_ w: Int, _ h: Int, _ s: CGFloat) {
        guard w > 0, h > 0, s > 0 else { return }
        surface.resize(pixelWidth: w, pixelHeight: h, scale: s)
        scene.resize(to: CGSize(width: CGFloat(w) / s, height: CGFloat(h) / s), scale: s)
        panel.layout(scene.geo, scale: s)
        if !paused { drawFrame() }
    }

    private func pointer(_ p: CGPoint?) {
        let inPanel = p.map { panel.contains($0) } ?? false
        if inPanel != pointerInPanel {
            pointerInPanel = inPanel
            if inPanel { scene.hover(at: nil) } else { panel.hover(at: nil) }
        }
        if inPanel { panel.hover(at: p) } else { scene.hover(at: p) }
    }

    private func other(_ msg: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT? {
        switch msg {
        case UINT(WM_TIMER) where UINT_PTR(w) == Self.sizeMoveTimer:
            drawFrame()
            return 0
        case Tray.callbackMessage:
            tray.handle(w, l)
            return 0
        case UINT(WM_COMMAND):
            tray.command(loWord(w))
            return 0
        case SingleInstance.showMessage:
            window.show()
            return 0
        case Tray.taskbarCreated:
            tray.add()
            return 0
        case UINT(WM_DISPLAYCHANGE), UINT(WM_SETTINGCHANGE):
            tray.dpiChanged()   // the taskbar's monitor or scale may have changed
            return nil
        case UINT(WM_DESTROY):
            return 0
        default:
            return nil
        }
    }

    private func command(_ c: Tray.Command) {
        switch c {
        case .show: window.show()
        case .alwaysOnTop:
            let on = !settings.bool(forKey: Self.alwaysOnTopKey)
            settings.set(on, forKey: Self.alwaysOnTopKey)
            window.setAlwaysOnTop(on)
        case .about: showAbout()
        case .settings: openSettings()
        case .quit: PostQuitMessage(0)
        }
    }

    /// "关于 Agentrise": version, repository and that this Windows build is experimental.
    private func showAbout() {
        let text = "Agentrise \(AppInfo.version)（实验性 Windows 版）\n\n用像素风办公楼里的机器人，显示 Claude Code 和 Codex 会话。\n\n\(AppInfo.repository)"
        let hwnd = window.hwnd
        withWide(text) { t in withWide("关于 Agentrise") { _ = MessageBoxW(hwnd, t, $0, UINT(MB_OK | MB_ICONINFORMATION)) } }
    }

    /// The settings window: hooks for Claude Code and Codex, ranks, start at login (the tray's "设置…").
    package func openSettings() {
        if let s = settingsWindow { s.show(); return }
        let controller = SettingsController(installer: WinHookInstaller(paths: paths), settings: settings, scheduler: scheduler,
                                            ranksFile: paths.ranksFile)
        controller.onRanksSaved = { [unowned self] in self.model.reloadRanks() }
        // An install that left a file in use: retry the copy like the start-up refresh does (unless that is retrying).
        controller.onHelperStale = { [unowned self] in if !self.hookRefreshFailing { self.refreshHookHelper() } }
        let s = SettingsWindow(controller: controller, near: window.hwnd)
        s.onClose = { [unowned self] in self.settingsWindow = nil }
        settingsWindow = s
        s.show()
    }

    /// After an upgrade the hook in `bin\` is the old one: copy the new one over it (only if it was installed). A
    /// hook running at that moment may keep a file locked, or the copy may fail; then it tries again with a growing
    /// pause (30 s, doubling, at most 10 min) until it succeeds or the app quits. Logged once when it starts failing
    /// and once when it succeeds.
    private func refreshHookHelper(pause: TimeInterval = 30) {
        let helper = WinHookInstaller(paths: paths).helper
        scheduler.inBackground { [scheduler] in
            let outcome = Swift.Result { try helper.refreshIfInstalled() }
            scheduler.onMain { [weak self] in
                guard let self else { return }
                var problem: String?
                switch outcome {
                case .success(nil): return
                case .success(let r?):
                    self.settingsWindow?.controller.noteHelper(r)
                    if !r.copied.isEmpty { Log.write("hook helper updated: \(r.copied.joined(separator: ", "))") }
                    if !r.locked.isEmpty { problem = "\(r.locked.joined(separator: ", ")) could not be replaced (in use?)" }
                case .failure(let e): problem = e.localizedDescription
                }
                guard let problem else {
                    if self.hookRefreshFailing { Log.write("hook helper: up to date after retrying") }
                    self.hookRefreshFailing = false
                    return
                }
                if !self.hookRefreshFailing { Log.write("hook helper: \(problem); trying again until it works") }
                self.hookRefreshFailing = true
                self.scheduler.after(pause) { [weak self] in self?.refreshHookHelper(pause: min(pause * 2, 600)) }
            }
        }
    }

    // MARK: Screenshot

    private func screenshot(to path: String) {
        let (pw, ph) = window.clientPixels
        let s = window.scale
        let w = pw > 0 ? pw : Int(scene.size.width * s), h = ph > 0 ? ph : Int(scene.size.height * s)
        guard let shot = display.snapshot(pixelWidth: w, pixelHeight: h, scale: s) else {
            Log.write("screenshot: rendering failed")
            exitCode = 1
            PostQuitMessage(1)
            return
        }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try D2DArtBackend.shared.writePNG(rgba: shot.rgba, width: shot.width, height: shot.height, to: path)
            Log.write("screenshot: \(shot.width)×\(shot.height) px → \(path); sessions \(model.visibleSessions.count), bakes \(scene.bakeCount), drawings \(display.drawCount), uploads \(display.uploadCount)")
        } catch {
            Log.write("screenshot: writing \(path) failed: \(error)")
            exitCode = 1
        }
        PostQuitMessage(exitCode)
    }

    // MARK: Quitting

    private func savePlacement() {
        guard options.screenshot == nil else { return }
        window.placement.save(paths.windowFile)
    }

    private func shutdown() {
        settingsWindow?.close()
        savePlacement()
        tray.remove()
        window.setIcons(small: nil, big: nil)
        destroyWindowIcons()
        // Not relied on: the mutex (released when the process ends) decides who runs, and the next instance replaces
        // the socket file whether or not this one removed it.
        model.stop()
        Log.write("quit (\(exitCode))")
    }
}

/// Startup checks written to the log: whether the manifest made the process Per-Monitor V2 DPI aware (asking for it
/// at run time then fails with ERROR_ACCESS_DENIED) and which comctl32 the process gets (6.x with the manifest).
package enum Startup {
    /// Makes the process Per-Monitor V2 aware if the manifest didn't; returns how it got there.
    package static func ensureDpiAwareness() -> String {
        let ok = SetProcessDpiAwarenessContext(Win.dpiAwarenessPerMonitorV2)
        let err = GetLastError()
        let v2 = AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(), Win.dpiAwarenessPerMonitorV2)
        if ok { return "per-monitor v2 set at run time (the manifest didn't)" }
        return err == DWORD(ERROR_ACCESS_DENIED) ? "per-monitor v2 \(v2 ? "yes" : "no"), from the manifest" : "dpi awareness unchanged (error \(err))"
    }

    /// The loaded comctl32's version ("6.16"), or nil.
    package static func comctl32Version() -> String? {
        typealias GetVersion = @convention(c) (UnsafeMutableRawPointer?) -> HRESULT
        guard let module = withWide("comctl32.dll", { LoadLibraryW($0) }), let proc = GetProcAddress(module, "DllGetVersion") else { return nil }
        let f = unsafeBitCast(proc, to: GetVersion.self)
        var info: [DWORD] = [20, 0, 0, 0, 0]   // DLLVERSIONINFO: cbSize, major, minor, build, platform
        guard info.withUnsafeMutableBytes({ f($0.baseAddress) }) >= 0 else { return nil }
        return "\(info[1]).\(info[2])"
    }
}
#endif
