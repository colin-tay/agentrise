// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Combine
import TowerKit
import ImageIO

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let vm = TowerViewModel()
    lazy var controller = TowerController(vm: vm)
    var window: NSWindow!
    var building: (NSView & TowerDisplay)!
    var panelHost: NSHostingView<PanelView>!
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop")

    func applicationDidFinishLaunching(_ note: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        building = TowerView(frame: frame)
        panelHost = NSHostingView(rootView: PanelView(vm: vm, onOpen: { [weak self] in self?.controller.open(sessionId: $0) },
                                                      onHover: { [weak self] id in self?.vm.hovered = id; self?.building.highlight(id) }))
        let container = NSView(frame: building.frame)
        building.autoresizingMask = [.width, .height]
        container.addSubview(building)
        container.addSubview(panelHost)
        building.onLayout = { [weak self] l in
            guard let self else { return }
            // AppKit's y axis is bottom-up; the layout's is top-down.
            let r = l.panel
            self.panelHost.frame = NSRect(x: r.minX, y: container.bounds.height - r.maxY, width: r.width, height: r.height)
            if self.vm.orientation != l.orientation { self.vm.orientation = l.orientation }
        }
        building.onClickSession = { [weak self] in self?.controller.open(sessionId: $0) }
        building.onHoverSession = { [weak self] in self?.vm.hovered = $0 }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Agentrise"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(hex: 0x0A0E26)
        window.contentView = container
        window.minSize = NSSize(width: 420, height: 520)
        // Dev/tests: `--frame x,y,w,h` (screen coordinates, w and h > 0) places the window there with frame
        // autosave off for the whole run, so a test instance never reads or overwrites the user's saved position.
        let devFrame = Self.devFrame(CommandLine.arguments)
        if devFrame == nil {
            // AppKit's frame autosave restores the size but moves the window to the main screen, so the
            // window's frame is kept under our own key and applied directly.
            if let r = Self.savedFrame(UserDefaults.standard), Self.isOnScreen(r, screens: NSScreen.screens.map(\.frame)) {
                window.setFrame(r, display: false)
            } else {
                window.center()
            }
        }
        window.delegate = self
        window.level = alwaysOnTop ? .floating : .normal
        window.collectionBehavior = [.fullScreenAuxiliary]
        if let i = CommandLine.arguments.firstIndex(of: "--size"), i + 1 < CommandLine.arguments.count {
            let p = CommandLine.arguments[i + 1].split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { window.setContentSize(NSSize(width: p[0], height: p[1])) }
        }
        if let f = devFrame { window.setFrame(f, display: true) }
        window.makeKeyAndOrderFront(nil)
        savesFrame = devFrame == nil

        controller.building = building
        controller.onNewWaiting = { [weak self] in self?.blinkStatusItem() }
        controller.start()
        setUpStatusItem()
        setUpMenu()
        vm.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusTitle() } }.store(in: &bag)
        if CommandLine.arguments.contains("--settings") { openSettings() }
        // Debug: `kill -USR1 <pid>` writes a snapshot of the window to the support dir.
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.writeSnapshot() }
        src.resume()
        snapshotSource = src
        // Debug/tests (only with `--frame`): `kill -USR2 <pid>` drags the window's width down and back in
        // frame-sized steps, like a live resize, keeping its origin.
        if devFrame != nil {
            signal(SIGUSR2, SIG_IGN)
            let r = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
            r.setEventHandler { [weak self] in self?.resizeSweep() }
            r.resume()
            resizeSource = r
        }
    }

    private var snapshotSource: DispatchSourceSignal?
    private var resizeSource: DispatchSourceSignal?

    static let frameKey = "towerWindowFrame"
    /// Off for `--frame` test runs, so they never overwrite the user's position.
    private var savesFrame = false

    /// The saved window frame; falls back to AppKit's old autosave string ("x y w h …") once.
    static func savedFrame(_ d: UserDefaults) -> NSRect? {
        if let s = d.string(forKey: frameKey) {
            let r = NSRectFromString(s)
            return r.width > 0 && r.height > 0 ? r : nil
        }
        guard let s = d.string(forKey: "NSWindow Frame AgentriseMain") else { return nil }
        let p = s.split(separator: " ").compactMap { Double($0) }
        guard p.count >= 4, p[2] > 0, p[3] > 0 else { return nil }
        return NSRect(x: p[0], y: p[1], width: p[2], height: p[3])
    }

    /// Enough of the window lies on some screen to grab it (a screen may have been unplugged).
    static func isOnScreen(_ r: NSRect, screens: [NSRect]) -> Bool {
        screens.contains { s in let i = s.intersection(r); return i.width >= 100 && i.height >= 100 }
    }

    private func saveFrame() {
        guard savesFrame else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { if !window.inLiveResize { saveFrame() } }

    /// `--frame x,y,w,h`: exactly four numbers, positive width and height.
    static func devFrame(_ args: [String]) -> NSRect? {
        guard let i = args.firstIndex(of: "--frame"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: ",", omittingEmptySubsequences: false)
        let p = parts.map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 4, let x = p[0], let y = p[1], let w = p[2], let h = p[3], w > 0, h > 0 else { return nil }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// 40 steps 16 ms apart: width −5 pt per step for 20 steps, then back.
    private func resizeSweep() {
        let start = window.frame
        for i in 1...40 {
            let dw = CGFloat(i <= 20 ? i : 40 - i) * 5
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16 * i)) { [weak self] in
                guard let w = self?.window else { return }
                w.setFrame(NSRect(x: start.minX, y: start.minY, width: start.width - dw, height: start.height), display: true)
            }
        }
    }

    func writeSnapshot() {
        guard let view = window.contentView else { return }
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if let scene = building.snapshot() { ctx.draw(scene, in: CGRect(origin: .zero, size: size)) }
        if let rep = panelHost.bitmapImageRepForCachingDisplay(in: panelHost.bounds) {
            panelHost.cacheDisplay(in: panelHost.bounds, to: rep)
            if let img = rep.cgImage { ctx.draw(img, in: panelHost.frame) }
        }
        let dump = vm.sessions.map { "\($0.id) | \($0.title) | \($0.source) | \($0.status) | \($0.activity) | cwd=\($0.cwd ?? "-")" }.joined(separator: "\n")
        try? dump.write(to: TowerPaths.supportDir().appendingPathComponent("sessions.txt"), atomically: true, encoding: .utf8)
        guard let image = ctx.makeImage() else { return }
        let url = TowerPaths.supportDir().appendingPathComponent("snapshot.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private var bag = Set<AnyCancellable>()

    func windowDidChangeOcclusionState(_ notification: Notification) {
        building.setOccluded(!window.occlusionState.contains(.visible))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { controller.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "显示 Agentrise", action: #selector(showWindow), keyEquivalent: "")
        let top = NSMenuItem(title: "窗口置顶", action: #selector(toggleTop(_:)), keyEquivalent: "")
        top.state = alwaysOnTop ? .on : .off
        menu.addItem(top)
        menu.addItem(withTitle: "关于 Agentrise", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        let c = vm.counts
        let s = NSMutableAttributedString(string: "🏢 ", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        s.append(NSAttributedString(string: "等你 \(c.waiting)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: c.waiting > 0 ? .bold : .regular),
                                                                              .foregroundColor: c.waiting > 0 ? NSColor(hex: 0xE0A02C) : NSColor.labelColor]))
        s.append(NSAttributedString(string: " · 完成 \(c.done)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]))
        statusItem?.button?.attributedTitle = s
    }

    private func blinkStatusItem() {
        guard let b = statusItem?.button else { return }
        for i in 0..<6 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.35) { b.alphaValue = i % 2 == 0 ? 0.2 : 1 } }
    }

    private func setUpMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Agentrise", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Agentrise", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        NSApp.mainMenu = main
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The standard About panel: icon, version and copyright from Info.plist, plus a link to the repository.
    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let s = Bundle.main.object(forInfoDictionaryKey: "AgentriseRepositoryURL") as? String, let url = URL(string: s) {
            let centered = NSMutableParagraphStyle(); centered.alignment = .center
            options[.credits] = NSAttributedString(string: "\(url.host ?? "")\(url.path)", attributes: [
                .link: url, .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: centered])
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc func toggleTop(_ item: NSMenuItem) {
        alwaysOnTop.toggle()
        UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop")
        item.state = alwaysOnTop ? .on : .off
        window.level = alwaysOnTop ? .floating : .normal
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Agentrise 设置"
            w.contentView = NSHostingView(rootView: SettingsView(onSaved: { [weak self] in self?.controller.reloadBarkConfig() },
                                                           onRanksSaved: { [weak self] in self?.controller.reloadRanks() }))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

if CommandLine.arguments.contains("--install-hooks") || CommandLine.arguments.contains("--uninstall-hooks") {
    do {
        if CommandLine.arguments.contains("--install-hooks") {
            let b = try HookInstaller.install()
            print("installed; backup: \(b?.path ?? "none")")
        } else { try HookInstaller.uninstall(); print("uninstalled") }
        exit(0)
    } catch { print("failed: \(error.localizedDescription)"); exit(1) }
}
// `--bark-selftest <key32> <iv16> <text>` prints the ciphertext for comparing with openssl.
if let i = CommandLine.arguments.firstIndex(of: "--bark-selftest"), CommandLine.arguments.count >= i + 4 {
    let a = CommandLine.arguments
    print(BarkCrypto.encrypt(Data(a[i + 3].utf8), key: a[i + 1], iv: a[i + 2]) ?? "nil")
    exit(0)
}
// `--bark-config <deviceKey|-> <encKey|-> <iv|->` stores Bark settings in the app's keychain.
if let i = CommandLine.arguments.firstIndex(of: "--bark-config"), CommandLine.arguments.count >= i + 4 {
    var c = BarkConfig.load()
    let a = Array(CommandLine.arguments[(i + 1)...(i + 3)])
    if a[0] != "-" { c.deviceKey = a[0] }
    if a[1] != "-" { c.encryptionKey = a[1] }
    if a[2] != "-" { c.iv = a[2] }
    c.save()
    print("saved; device key set: \(!c.deviceKey.isEmpty), encrypted: \(c.encrypts)")
    if CommandLine.arguments.contains("--test") {
        let sem = DispatchSemaphore(value: 0)
        Task { do { try await BarkClient.send(BarkMessage(body: "测试推送：Agentrise 已连上你的 iPhone"), config: c); print("test push sent") } catch { print("push failed: \(error.localizedDescription)") }; sem.signal() }
        sem.wait()
    }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
