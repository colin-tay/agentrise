// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// The Windows app shell (Windows only): the Direct2D display bakes nothing in steady state and re-bakes once per dpi
// change, a second instance defers to the first, the panel draws only on change, and paths with spaces and Chinese
// characters work.

#if os(Windows)
import Testing
import Foundation
import WinSDK
@testable import Agentrise
@testable import AgentriseScene
@testable import AgentriseWinArt
@testable import AgentriseWin
import TowerKit

private func busy(_ id: String, team: Int) -> Session {
    var s = Session(id: id, title: "任务 \(id)", source: .desktop(hostSessionId: nil), rank: .seniorEngineer, status: .working,
                    activity: .coding, teamIndex: team, statusSince: Date(), lastActivityAt: Date())
    s.subs = ["x": SubAgent(id: "x", type: "Explore", activity: .searching, startedAt: Date())]
    return s
}

private func waiting(_ id: String, team: Int) -> Session {
    var s = busy(id, team: team)
    s.status = .waiting
    s.waitingSummary = "要不要合并？"
    return s
}

/// A fresh directory under the temp dir whose name has a space and Chinese characters.
private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ar 测试 \(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let frame: TimeInterval = 1.0 / 60

@Suite struct D2DDisplayTests {
    /// Review Focus 1: with everyone in place, frames only step tweens and blit — no bake, no drawing, no upload.
    @Test func steadyStateDoesNotBakeOnWindows() {
        D2DArtBackend.joinCOM()
        let model = TowerSceneModel(size: CGSize(width: 1200, height: 800), scale: 1, art: D2DArtBackend.shared)
        let display = D2DDisplay(model: model)
        let surface = D2DSurface(offscreenWidth: 1200, height: 800, scale: 1)
        model.setHeader(TowerCounts(working: 5))
        model.render([], animated: false)
        model.render((0..<5).map { busy("s\($0)", team: $0) }, animated: true)
        #expect(display.frame(dt: frame, on: surface))
        for _ in 0..<120 { display.frame(dt: frame, on: surface) }
        let bakes = model.bakeCount, draws = display.drawCount, uploads = display.uploadCount
        #expect(bakes > 0 && draws > 0 && uploads > 0)
        for _ in 0..<600 { display.frame(dt: frame, on: surface) }
        #expect(model.bakeCount == bakes)
        #expect(display.drawCount == draws)
        #expect(display.uploadCount == uploads)
        // Something was drawn over the background.
        let bg = D2DDisplay.background
        let px = surface.pixelsBGRA() ?? []
        let want: [Int] = [Int(bg.b * 255), Int(bg.g * 255), Int(bg.r * 255)]   // BGRA
        var differing = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            for k in 0..<3 where abs(Int(px[i + k]) - want[k]) > 8 {
                differing += 1
                break
            }
        }
        #expect(differing > px.count / 4 / 4, "only \(differing) pixels differ from the background")
    }

    /// Review Focus 2: a new scale re-bakes everything once; the frames after it bake nothing.
    @Test func dpiChangeRebakesOnce() {
        D2DArtBackend.joinCOM()
        let size = CGSize(width: 1200, height: 800)
        let model = TowerSceneModel(size: size, scale: 1, art: D2DArtBackend.shared)
        let display = D2DDisplay(model: model)
        let surface = D2DSurface(offscreenWidth: 1200, height: 800, scale: 1)
        model.resize(to: size, scale: 1)
        model.setHeader(TowerCounts(working: 3))
        model.render((0..<3).map { busy("s\($0)", team: $0) }, animated: false)
        for _ in 0..<60 { display.frame(dt: frame, on: surface) }
        let before = model.bakeCount, drawsBefore = display.drawCount
        model.resize(to: size, scale: 1.5)
        surface.resize(pixelWidth: 1800, pixelHeight: 1200, scale: 1.5)
        #expect(display.frame(dt: frame, on: surface))
        let after = model.bakeCount, drawsAfter = display.drawCount
        #expect(after > before)
        #expect(after - before <= before, "one round of bakes: \(after - before) after \(before) for the first")
        #expect(drawsAfter > drawsBefore)
        for _ in 0..<120 { display.frame(dt: frame, on: surface) }
        #expect(model.bakeCount == after)
        #expect(display.drawCount == drawsAfter)
        #expect(surface.pixelWidth == 1800 && surface.pixelHeight == 1200)
    }

    /// A failed upload (here: every bitmap over the target's maximum size) is remembered: later frames don't bake,
    /// tint or try it again, and the failure is counted once.
    @Test func failedUploadsAreNotRetriedEveryFrame() {
        D2DArtBackend.joinCOM()
        let model = TowerSceneModel(size: CGSize(width: 600, height: 400), scale: 1, art: D2DArtBackend.shared)
        let display = D2DDisplay(model: model)
        let surface = D2DSurface(offscreenWidth: 600, height: 400, scale: 1)
        surface.maximumBitmapSizeOverride = 8
        model.setHeader(TowerCounts(working: 3))
        model.render((0..<3).map { busy("s\($0)", team: $0) }, animated: false)
        for _ in 0..<60 { display.frame(dt: frame, on: surface) }
        let bakes = model.bakeCount, draws = display.drawCount, tints = display.tintCount
        let failures = display.uploadFailures, uploads = display.uploadCount
        #expect(failures > 0)
        #expect(draws == 0, "a drawing over the maximum size is refused before it is baked")
        #expect(tints == 0, "an image over the maximum size is refused before it is tinted")
        for _ in 0..<120 { display.frame(dt: frame, on: surface) }
        #expect(model.bakeCount == bakes)
        #expect(display.drawCount == draws)
        #expect(display.tintCount == tints)
        #expect(display.uploadFailures == failures)
        #expect(display.uploadCount == uploads)
    }

    /// The offscreen snapshot is the window's content: opaque, its size in pixels.
    @Test func snapshotIsTheScene() throws {
        D2DArtBackend.joinCOM()
        let model = TowerSceneModel(size: CGSize(width: 600, height: 400), scale: 1.5, art: D2DArtBackend.shared)
        let display = D2DDisplay(model: model)
        model.render([busy("a", team: 1)], animated: false)
        model.step(dt: 0)
        let shot = try #require(display.snapshot(pixelWidth: 900, pixelHeight: 600, scale: 1.5))
        #expect(shot.width == 900 && shot.height == 600)
        #expect(shot.rgba.count == 900 * 600 * 4)
        #expect(stride(from: 3, to: shot.rgba.count, by: 4).allSatisfy { shot.rgba[$0] == 255 })
    }
}

@Suite struct PanelRendererTests {
    private func state(_ sessions: [Session]) -> TowerPanelState {
        var s = TowerPanelState()
        let entries = sessions.map(PanelEntry.init)
        s.waiting = entries.filter { $0.status == .waiting }
        s.working = entries.filter { $0.status == .working }
        s.counts = TowerCounts(working: s.working.count, waiting: s.waiting.count)
        return s
    }

    /// The panel is drawn again only when something it shows changed.
    @Test func panelDrawsOnlyOnChange() {
        let panel = PanelRenderer()
        let geo = BuildingLayout.make(size: CGSize(width: 1200, height: 800))
        panel.layout(geo, scale: 1)
        let both = state([waiting("w", team: 0), busy("b", team: 1)])
        panel.update(both)
        panel.prepare()
        #expect(panel.drawCount == 1)
        #expect(panel.node.drawing != nil && panel.node.size == geo.panel.size)
        panel.prepare()
        panel.update(both)
        panel.prepare()
        panel.layout(geo, scale: 1)
        panel.prepare()
        #expect(panel.drawCount == 1)
        panel.hovered = "b"
        panel.prepare()
        #expect(panel.drawCount == 2)
        panel.hovered = "b"
        panel.prepare()
        panel.update(state([waiting("w", team: 0)]))
        panel.prepare()
        #expect(panel.drawCount == 3)
        panel.layout(geo, scale: 2)
        panel.prepare()
        #expect(panel.drawCount == 4)
    }

    /// Clicking a card opens its session; hovering a row reports it; the sleepers toggle redraws the panel.
    @Test func panelHitsCardsAndRows() {
        let panel = PanelRenderer()
        let geo = BuildingLayout.make(size: CGSize(width: 1200, height: 800))
        panel.layout(geo, scale: 1)
        panel.update(state([waiting("w", team: 0), busy("b", team: 1)]))
        panel.prepare()
        var opened: [String] = [], hovered: [String?] = []
        panel.onOpen = { opened.append($0) }
        panel.onHover = { hovered.append($0) }
        // The first card sits right under the title.
        let card = CGPoint(x: geo.panel.minX + 40, y: geo.panel.minY + 45)
        #expect(panel.hit(at: card) == .session("w"))
        panel.click(at: card)
        #expect(opened == ["w"])
        panel.hover(at: card)
        panel.hover(at: CGPoint(x: geo.panel.minX + 5, y: geo.panel.maxY - 2))
        #expect(hovered == ["w", nil])
        #expect(panel.hit(at: CGPoint(x: geo.panel.minX - 5, y: geo.panel.midY)) == nil)
    }

    @Test func ages() {
        let now = Date()
        #expect(PanelRenderer.age(since: now.addingTimeInterval(-30), now: now) == "刚刚")
        #expect(PanelRenderer.age(since: now.addingTimeInterval(-5 * 60), now: now) == "5 分钟")
        #expect(PanelRenderer.age(since: now.addingTimeInterval(-125 * 60), now: now) == "2 小时")
    }
}

/// `Agentrise.exe` next to this test image (`swift build` puts it there): `AGENTRISE_EXE` if set, else the build
/// directory.
private func agentriseExe() throws -> URL {
    if let exe = ProcessInfo.processInfo.environment["AGENTRISE_EXE"], !exe.isEmpty { return URL(fileURLWithPath: exe) }
    final class Marker {}
    var starts = [Bundle(for: Marker.self).bundleURL]
    if let exe = Bundle.main.executableURL { starts.append(exe) }
    for start in starts {
        var dir = start.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("Agentrise.exe")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
    }
    throw ExeNotFound()
}

private struct ExeNotFound: Error, CustomStringConvertible {
    var description: String { "Agentrise.exe not found next to the test image; run `swift build` first (or set AGENTRISE_EXE)" }
}

/// Runs `exe` and waits up to `timeout`; the exit code, or nil when it still ran (it is then killed).
private func run(_ exe: URL, _ args: [String], timeout: TimeInterval) throws -> Int32? {
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    try p.run()
    let end = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
    guard !p.isRunning else { p.terminate(); return nil }
    return p.terminationStatus
}

@Suite(.serialized) struct SingleInstanceTests {
    /// Review Focus 5: while an instance holds the mutex, a second `Agentrise.exe` defers to it and exits 0 within 5 s.
    @Test func secondInstanceDefersToFirst() throws {
        let exe = try agentriseExe()
        let dir = try tempDir()
        var held = SingleInstance.acquire()
        #expect(held != nil, "another Agentrise holds \(SingleInstance.mutexName)")
        #expect(SingleInstance.acquire() == nil)   // the mutex decides: a second taker is refused
        let code = try run(exe, ["--smoke-second", "--data-dir", nativePath(dir)], timeout: 5)
        #expect(code == 0)
        // With no instance running, the same check finds none (exit 3) and opens no window.
        held = nil
        #expect(try run(exe, ["--smoke-second", "--data-dir", nativePath(dir)], timeout: 5) == 3)
        // The log went to the data directory, whose name has a space and Chinese characters.
        let log = try String(contentsOf: dir.appendingPathComponent("Agentrise").appendingPathComponent("agentrise.log"), encoding: .utf8)
        #expect(log.contains("smoke-second: another instance runs"))
        #expect(log.contains("smoke-second: no other instance"))
    }

    @Test func mutexNameIsPerUser() {
        let name = SingleInstance.mutexName
        #expect(name.hasPrefix("Local\\Agentrise-S-1-"))
        #expect(SingleInstance.currentUserSID().map { name.hasSuffix($0) } == true)
    }
}

@Suite struct WinPlatformTests {
    /// `--data-dir` puts home, support directory and socket under the directory, where the hook finds the socket
    /// through `LOCALAPPDATA` (Review Focus 3: a space and Chinese characters).
    @Test func dataDirWithSpacesAndChinese() {
        let dir = "C:\\Users\\张 三\\ar 测试"
        let paths = AppPaths(dataDir: dir + "\\")
        #expect(nativePath(paths.home) == dir)
        #expect(nativePath(paths.support) == dir + "\\Agentrise")
        #expect(paths.socketPath == TowerPaths.socketPath(environment: ["LOCALAPPDATA": dir]))
        #expect(paths.socketPath == dir + "\\Agentrise\\tower.sock")
        #expect(nativePath(paths.windowFile) == dir + "\\Agentrise\\window.json")
    }

    @Test func windowPlacementAndSettingsRoundTrip() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("window.json")
        let p = WindowPlacement(x: -1200, y: 40, width: 1300, height: 860)
        p.save(file)
        #expect(WindowPlacement.load(file) == p)
        let settings = JSONSettingsStore(file: dir.appendingPathComponent("settings.json"))
        settings.set(true, forKey: "alwaysOnTop")
        #expect(JSONSettingsStore(file: dir.appendingPathComponent("settings.json")).bool(forKey: "alwaysOnTop"))
        #expect(!settings.bool(forKey: "other"))
    }

    @Test func isRunningKnowsLiveAndGoneProcesses() throws {
        #expect(WinPlatform.isRunning(Int32(bitPattern: GetCurrentProcessId())))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        p.arguments = ["/c", "exit", "0"]
        try p.run()
        p.waitUntilExit()
        #expect(!WinPlatform.isRunning(p.processIdentifier))
        #expect(!WinPlatform.isRunning(0))
    }

    @Test func optionsParse() {
        let o = AppOptions.parse(["Agentrise.exe", "--data-dir", "D:\\a\\ar 测试", "--screenshot", "shot.png", "--after", "8",
                                  "--size", "1200x800"])
        #expect(o.dataDir == "D:\\a\\ar 测试")
        #expect(o.screenshot == "shot.png")
        #expect(o.screenshotAfter == 8)
        #expect(o.size == CGSize(width: 1200, height: 800))
        #expect(!o.smokeSecond)
        #expect(AppOptions.parse(["Agentrise.exe", "--smoke-second"]).smokeSecond)
    }
}
#endif
