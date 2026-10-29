// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// Windows integration (Task 13): paths and liveness, atomic writes that survive child processes, start at login,
// the hook helper's copy in bin\, installing hooks, the settings window, and starting codex app-server.

#if os(Windows)
import Testing
import Foundation
import WinSDK
@testable import Agentrise
@testable import AgentriseScene
@testable import AgentriseWin
import TowerKit

/// A fresh directory under the temp dir whose name has a space and Chinese characters.
private func scratchDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ar 测试 \(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The build directory (`agentrise-hook.exe` and `Agentrise.exe` are there).
private func buildDir() throws -> URL { try agentriseExe().deletingLastPathComponent() }

/// The directory on PATH that has the Swift runtime (`swiftCore.dll`), as on a development machine or CI.
private func toolchainRuntimeDir() -> URL? {
    let path = ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
    return path.split(separator: ";").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("swiftCore.dll").path) }
}

/// Runs everything at once, on the calling thread.
private final class InlineScheduler: TowerScheduler {
    func onMain(_ work: @escaping () -> Void) { work() }
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {}
    func every(_ seconds: TimeInterval, _ work: @escaping () -> Void) {}
    func inBackground(_ work: @escaping () -> Void) { work() }
}

/// Runs `inBackground` work only when the test says so (`drain`), and `onMain` work right after it.
private final class QueuedScheduler: TowerScheduler {
    private var queue: [() -> Void] = []
    func onMain(_ work: @escaping () -> Void) { work() }
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {}
    func every(_ seconds: TimeInterval, _ work: @escaping () -> Void) {}
    func inBackground(_ work: @escaping () -> Void) { queue.append(work) }
    var pending: Int { queue.count }
    func drain() { while !queue.isEmpty { queue.removeFirst()() } }
}

/// A source directory with a copy of the real `agentrise-hook.exe` and a stand-in for one runtime DLL it imports
/// (any bytes: `RuntimeFiles` finds it by name next to the exe), so `HookHelperFiles` has an exe and a DLL to copy.
private func hookWithOneDll() throws -> (src: URL, dll: String) {
    let src = try scratchDir()
    let hook = try buildDir().appendingPathComponent(HookHelperFiles.hookExe)
    try FileManager.default.copyItem(at: hook, to: src.appendingPathComponent(HookHelperFiles.hookExe))
    let dll = try #require(PEImports.dlls(in: Data(contentsOf: hook))?.first { RuntimeFiles.isRuntimeName($0.lowercased()) })
    try Data("runtime v1".utf8).write(to: src.appendingPathComponent(dll))
    return (src, dll)
}

private let powershell = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"

/// `powershell -NoProfile -EncodedCommand <script>` (base64 UTF-16LE: no quoting to get wrong).
private func powershellLine(_ script: String) -> String {
    var bytes: [UInt8] = []
    for u in script.utf16 { bytes.append(UInt8(u & 0xFF)); bytes.append(UInt8(u >> 8)) }
    return "\"\(powershell)\" -NoProfile -NonInteractive -EncodedCommand \(Data(bytes).base64EncodedString())"
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
        let dir = try scratchDir()
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
    /// Spec §5.7 / decision 7: a nonexistent pid is not running; pid 0 is not; this process is.
    @Test func isRunningRules() throws {
        #expect(WinPlatform.isRunning(Int32(bitPattern: GetCurrentProcessId())))
        #expect(!WinPlatform.isRunning(0))
        #expect(!WinPlatform.isRunning(-4))
        // Pids are multiples of 4; this one is far above anything Windows hands out.
        #expect(!WinPlatform.isRunning(0x7FFF_FFFC))
        // The System process (pid 4) can't be opened for this query by a normal user, or can and is alive: running.
        #expect(WinPlatform.isRunning(4))
        // Exit code 259 is STILL_ACTIVE's value: a process that exited with it is still gone (review Minor 2).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        p.arguments = ["/c", "exit", "259"]
        try p.run()
        let pid = p.processIdentifier
        p.waitUntilExit()
        #expect(p.terminationStatus == 259)
        #expect(!WinPlatform.isRunning(pid))
    }

    /// Review I1: our own process, with its real creation time, against a session `startedAt` just after it (kept, even
    /// with a nonsense `procStart`, which isn't read) and one an hour earlier (a reused pid: dropped). No `startedAt`, or
    /// no creation time, falls back to `isRunning`.
    @Test func isSameProcessComparesCreationWithStartedAt() throws {
        let me = Int32(bitPattern: GetCurrentProcessId())
        let created = ProcessStart.date(fileTime: try #require(Jump.creationTime(UInt32(bitPattern: me))))
        let justAfter = ProcessStart(startedAt: created + 0.5)
        let hourEarlier = ProcessStart(startedAt: created - 3600)
        #expect(WinPlatform.isSameProcess(pid: me, start: justAfter))
        #expect(!WinPlatform.isSameProcess(pid: me, start: hourEarlier))
        #expect(!WinPlatform(paths: AppPaths(dataDir: nil)).isSameProcess(pid: me, start: hourEarlier))
        // Read from a registry file: procStart plays no part.
        let o: [String: Any] = ["startedAt": (created.timeIntervalSince1970 + 0.5) * 1000, "procStart": "garbage", "procStartFt": "1"]
        #expect(WinPlatform.isSameProcess(pid: me, start: ProcessStart(registry: o)))
        #expect(WinPlatform.isSameProcess(pid: me, start: nil))
        #expect(WinPlatform.isSameProcess(pid: me, start: ProcessStart(registry: ["procStart": "garbage"])))
        // Unknown creation time (access denied): only liveness counts.
        #expect(WinPlatform.isSameProcess(pid: me, start: hourEarlier, creation: { _ in nil }))
        // Gone is gone, whatever the start time.
        #expect(!WinPlatform.isSameProcess(pid: 0x7FFF_FFFC, start: justAfter))
    }

    @Test func dataDirKeepsAgentsInside() {
        let dir = "C:\\Users\\张 三\\ar 测试"
        let paths = AppPaths(dataDir: dir, environment: ["CLAUDE_CONFIG_DIR": "C:\\elsewhere", "CODEX_HOME": "C:\\cx"])
        #expect(nativePath(paths.claudeSettings) == dir + "\\.claude\\settings.json")
        #expect(nativePath(paths.codexHooks) == dir + "\\.codex\\hooks.json")
        #expect(nativePath(paths.binDir) == dir + "\\Agentrise\\bin")
        #expect(nativePath(paths.ranksFile) == dir + "\\Agentrise\\ranks.json")
        let platform = WinPlatform(paths: paths)
        #expect(nativePath(platform.claudeDirectory) == dir + "\\.claude")
        #expect(nativePath(SessionRegistry.dir(claudeDir: platform.claudeDirectory)) == dir + "\\.claude\\sessions")
    }

    @Test func agentDirsHonourTheEnvironment() {
        let env = ["USERPROFILE": "C:\\Users\\u", "LOCALAPPDATA": "C:\\Users\\u\\AppData\\Local",
                   "CLAUDE_CONFIG_DIR": "D:\\cfg", "CODEX_HOME": "D:\\cx"]
        let paths = AppPaths(dataDir: nil, environment: env)
        #expect(nativePath(paths.claudeDir) == "D:\\cfg")
        #expect(nativePath(paths.codexHome) == "D:\\cx")
        // Review M5: the model reads Codex's session index from the same place the hooks go.
        #expect(nativePath(WinPlatform(paths: paths).codexHome) == "D:\\cx")
        let plain = AppPaths(dataDir: nil, environment: ["USERPROFILE": "C:\\Users\\u", "LOCALAPPDATA": "C:\\Users\\u\\AppData\\Local"])
        #expect(nativePath(plain.claudeSettings) == "C:\\Users\\u\\.claude\\settings.json")
        #expect(nativePath(plain.codexHooks) == "C:\\Users\\u\\.codex\\hooks.json")
        #expect(nativePath(plain.binDir) == "C:\\Users\\u\\AppData\\Local\\Agentrise\\bin")
    }

    @Test func optionsForHooksAndRetry() {
        let o = AppOptions.parse(["Agentrise.exe", "--data-dir", "D:\\x", "--install-hooks", "claude", "--retry-ms", "250"])
        #expect(o.installHooks == .claude)
        #expect(o.retry == 0.25)
        #expect(AppOptions.parse(["Agentrise.exe", "--install-hooks", "codex"]).installHooks == .codex)
        #expect(AppOptions.parse(["Agentrise.exe", "--install-hooks", "vim"]).installHooks == nil)
        #expect(AppOptions.parse(["Agentrise.exe"]).retry == 2)
        #expect(AppOptions.parse(["Agentrise.exe", "--open-settings"]).openSettings)
        #expect(!AppOptions.parse(["Agentrise.exe"]).openSettings)
        let r = AppOptions.parse(["Agentrise.exe", "--print-runtime-files", "D:\\o.txt", "--search-dir", "C:\\a b", "--search-dir", "C:\\c"])
        #expect(r.printRuntimeFiles == "D:\\o.txt")
        #expect(r.searchDirs == ["C:\\a b", "C:\\c"])
        #expect(AppOptions.parse(["Agentrise.exe"]).searchDirs.isEmpty)
    }
}

@Suite struct SafeFileTests {
    /// Decision 2: Foundation's atomic write fails with error 32 when a child spawned meanwhile inherits its temporary
    /// file's handle (Task 10). `SafeFile` writes with a non-inheritable handle: hundreds of writes while another
    /// thread keeps spawning children never fail.
    ///
    /// The control is Task 10's CI run 40844013498: the same loop with Foundation's `.atomic` write failed 383 of 400
    /// times with error 32. (No disabled copy of that test is kept here.)
    @Test func writesSurviveConcurrentChildren() throws {
        let dir = try scratchDir()
        let file = dir.appendingPathComponent("settings.json")
        let stop = NSLock()
        var done = false
        var children: [Process] = []
        let finished = DispatchSemaphore(value: 0)
        let spawner = Thread {
            while true {
                stop.lock(); let d = done; stop.unlock()
                if d { break }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
                p.arguments = ["/c", "ping", "-n", "2", "127.0.0.1", ">NUL"]   // lives about a second
                if (try? p.run()) != nil { stop.lock(); children.append(p); stop.unlock() }
                Thread.sleep(forTimeInterval: 0.005)
            }
            finished.signal()
        }
        spawner.start()
        defer {
            stop.lock(); done = true; stop.unlock()
            finished.wait()
            for p in children { p.waitUntilExit() }
        }
        for i in 0..<300 {
            let data = Data("{\"n\": \(i), \"pad\": \"\(String(repeating: "x", count: i))\"}\n".utf8)
            try SafeFile.write(data, to: file)
            #expect(try Data(contentsOf: file) == data)
        }
        stop.lock(); let spawned = children.count; stop.unlock()
        #expect(spawned > 10, "the spawner barely ran (\(spawned))")
        // No temporary files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
    }

    @Test func writeReplacesAndReportsFailures() throws {
        let dir = try scratchDir()
        let file = dir.appendingPathComponent("中文 名.json")
        try SafeFile.write(Data("a".utf8), to: file)
        try SafeFile.write(Data("bb".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "bb")
        #expect(throws: SafeFile.Failure.self) { try SafeFile.write(Data("x".utf8), to: dir.appendingPathComponent("no such dir\\f.json")) }
    }
}

@Suite(.serialized) struct AutostartTests {
    /// The Run key's value, round-tripped under a key of the test's own (never the real Run key).
    @Test func setAndClearTheRunValue() throws {
        let key = "Software\\AgentriseTest-\(UUID().uuidString)"
        defer { _ = withWideTest(key) { RegDeleteTreeW(Autostart.currentUser, $0) } ; _ = withWideTest(key) { RegDeleteKeyW(Autostart.currentUser, $0) } }
        let exe = "C:\\Users\\张 三\\Agentrise\\Agentrise.exe"
        let a = Autostart(keyPath: key, exePath: exe)
        #expect(Autostart.runKey == "Software\\Microsoft\\Windows\\CurrentVersion\\Run")
        #expect(Autostart.valueName == "Agentrise")
        #expect(!a.isEnabled)
        try a.set(true)
        #expect(a.value == "\"\(exe)\"")
        #expect(a.isEnabled)
        // Moved elsewhere: the old value is not this exe.
        #expect(!Autostart(keyPath: key, exePath: "D:\\Agentrise.exe").isEnabled)
        try a.set(false)
        #expect(a.value == nil)
        #expect(!a.isEnabled)
        try a.set(false)   // already off: fine
        #expect(FileManager.default.fileExists(atPath: Autostart.currentExe()))   // the test runner's own image
    }
}

private func withWideTest<R>(_ s: String, _ body: (UnsafePointer<WCHAR>) -> R) -> R { s.withCString(encodedAs: UTF16.self, body) }

@Suite struct HookHelperTests {
    /// The import table of the real hook: the Swift runtime when the toolchain's directory is searched, never system DLLs.
    @Test func importsOfTheHook() throws {
        let hook = try buildDir().appendingPathComponent("agentrise-hook.exe")
        let names = try #require(PEImports.dlls(in: try Data(contentsOf: hook)))
        #expect(names.contains { $0.lowercased() == "kernel32.dll" })
        #expect(names.contains { $0.lowercased().hasPrefix("swift") || $0.lowercased().hasPrefix("foundation") })
        #expect(PEImports.dlls(in: Data("not a PE".utf8)) == nil)
        let runtime = try #require(toolchainRuntimeDir(), "no swiftCore.dll on PATH")
        let files = RuntimeFiles.closure(of: [hook], searchDirs: [runtime])
        let lower = files.map { $0.lastPathComponent.lowercased() }
        #expect(lower.first == "agentrise-hook.exe")
        #expect(lower.contains("swiftcore.dll"))
        #expect(!lower.contains("kernel32.dll"))
        #expect(Set(lower).count == lower.count)
        // Next to the exe only (how the app copies it): whatever is there, the hook is first.
        #expect(RuntimeFiles.closure(of: [hook], searchDirs: [hook.deletingLastPathComponent()]).first == hook)
    }

    /// The copy in bin\: made, left alone when equal, replaced when different, and replaced even while it runs.
    @Test func syncCopiesReplacesAndCopesWithARunningHook() throws {
        let src = try scratchDir()
        let bin = try scratchDir().appendingPathComponent("bin")
        // A stand-in "hook": any exe (cmd.exe), which this test can keep running from bin\.
        let cmd = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        try FileManager.default.copyItem(at: cmd, to: src.appendingPathComponent(HookHelperFiles.hookExe))
        let helper = HookHelperFiles(sourceDir: src, binDir: bin)
        #expect(try helper.refreshIfInstalled() == nil)   // nothing installed yet
        var r = try helper.sync()
        #expect(r.copied == [HookHelperFiles.hookExe])
        #expect(try helper.sync().upToDate)
        #expect(try helper.refreshIfInstalled()?.upToDate == true)

        // The installed copy is running (a hook mid-event) when the app brings a new version.
        let running = Process()
        running.executableURL = helper.installed
        running.arguments = ["/c", "ping", "-n", "5", "127.0.0.1", ">NUL"]
        try running.run()
        defer { running.terminate() }
        let newer = try Data(contentsOf: cmd) + Data("version 2".utf8)
        try newer.write(to: helper.source)
        r = try #require(try helper.refreshIfInstalled())
        #expect(r.copied == [HookHelperFiles.hookExe])
        #expect(r.locked.isEmpty)
        #expect(try Data(contentsOf: helper.installed) == newer)
        running.waitUntilExit()
        // The old copy moved aside is cleaned up on a later run (once Windows has let go of the exited image).
        var left: [String] = []
        for _ in 0..<40 {
            _ = try helper.sync()
            left = try FileManager.default.contentsOfDirectory(atPath: bin.path)
            if left == [HookHelperFiles.hookExe] { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(left == [HookHelperFiles.hookExe])
    }

    /// Review Important 1: a replace that fails after the old exe was moved aside moves it back, and a later try works.
    @Test func failedReplaceRollsBack() throws {
        let src = try scratchDir()
        let bin = try scratchDir().appendingPathComponent("bin")
        let old = Data("old hook".utf8), new = Data("new hook".utf8)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try new.write(to: src.appendingPathComponent(HookHelperFiles.hookExe))
        var helper = HookHelperFiles(sourceDir: src, binDir: bin)
        try old.write(to: helper.installed)
        // Moving the new copy in fails (the replace and, after the old one was moved aside, the move into its place).
        var failing = HookHelperFiles.FileOps()
        let real = failing.move
        var asideMoves = 0
        failing.move = { from, to, replace in
            if from.contains(".new-") { return false }
            if to.contains(".old-") { asideMoves += 1 }
            return real(from, to, replace)
        }
        helper.ops = failing
        let r = try #require(try helper.refreshIfInstalled())
        #expect(r.locked == [HookHelperFiles.hookExe] && r.copied.isEmpty)
        #expect(asideMoves == 1)   // it did get as far as moving the old one aside
        #expect(try Data(contentsOf: helper.installed) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path) == [HookHelperFiles.hookExe])
        // The retry, with working file operations.
        helper.ops = HookHelperFiles.FileOps()
        #expect(try helper.refreshIfInstalled()?.copied == [HookHelperFiles.hookExe])
        #expect(try Data(contentsOf: helper.installed) == new)
    }

    /// A crash between moving the old exe aside and moving the new one in: the next run puts the old one back first.
    @Test func crashMidReplaceIsRecovered() throws {
        let src = try scratchDir()
        let bin = try scratchDir().appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: src.appendingPathComponent(HookHelperFiles.hookExe))
        let helper = HookHelperFiles(sourceDir: src, binDir: bin)
        try Data("old".utf8).write(to: bin.appendingPathComponent(HookHelperFiles.hookExe + ".old-1234abcd"))
        #expect(helper.wasInstalled)
        #expect(try helper.refreshIfInstalled()?.copied == [HookHelperFiles.hookExe])
        #expect(try String(contentsOf: helper.installed, encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path) == [HookHelperFiles.hookExe])
    }

    /// Review M3: the DLLs are replaced first and the exe last, only once every DLL is current. A DLL in use keeps the
    /// old exe too, and both show as stale until a later sync brings them up to date.
    @Test func exeIsReplacedLastAndOnlyWhenEveryDllIsCurrent() throws {
        let (src, dll) = try hookWithOneDll()
        var helper = HookHelperFiles(sourceDir: src, binDir: try scratchDir().appendingPathComponent("bin"))
        #expect(helper.files().map(\.lastPathComponent) == [HookHelperFiles.hookExe, dll])
        #expect(try helper.sync().copied == [dll, HookHelperFiles.hookExe])
        #expect(helper.staleFiles().isEmpty)
        let oldExe = try Data(contentsOf: helper.installed)
        // A new version, while a running hook holds the DLL (it can't be replaced, nor moved aside).
        try (oldExe + Data("v2".utf8)).write(to: helper.source)
        try Data("runtime v2".utf8).write(to: src.appendingPathComponent(dll))
        var failing = HookHelperFiles.FileOps()
        let real = failing.move
        failing.move = { from, to, replace in
            (from.hasSuffix(dll) || from.contains(dll + ".new-")) ? false : real(from, to, replace)
        }
        helper.ops = failing
        let r = try helper.sync()
        #expect(r.copied.isEmpty)
        #expect(r.locked == [dll, HookHelperFiles.hookExe])
        #expect(try Data(contentsOf: helper.installed) == oldExe)   // the exe waits for its DLL
        #expect(helper.staleFiles() == [HookHelperFiles.hookExe, dll])
        helper.ops = HookHelperFiles.FileOps()
        #expect(try helper.sync().copied == [dll, HookHelperFiles.hookExe])
        #expect(helper.staleFiles().isEmpty)
    }

    /// Review M2: syncs from several threads at once (the start-up refresh and a Settings install) don't trip over each
    /// other's temporary files: none reports a file as locked, and bin\ ends up with exactly the current files.
    @Test func concurrentSyncsDoNotInterfere() throws {
        let (src, dll) = try hookWithOneDll()
        let helper = HookHelperFiles(sourceDir: src, binDir: try scratchDir().appendingPathComponent("bin"))
        _ = try helper.sync()
        let results = NSLock()
        var locked: [[String]] = []
        for round in 0..<4 {
            try Data("runtime \(round)".utf8).write(to: src.appendingPathComponent(dll))
            DispatchQueue.concurrentPerform(iterations: 6) { _ in
                let r = (try? helper.sync())?.locked ?? ["threw"]
                results.lock(); locked.append(r); results.unlock()
            }
        }
        #expect(locked.allSatisfy { $0.isEmpty })
        #expect(helper.staleFiles().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: helper.binDir.path).sorted() == [HookHelperFiles.hookExe, dll].sorted())
    }

    @Test func missingHelperIsReported() throws {
        let helper = HookHelperFiles(sourceDir: try scratchDir(), binDir: try scratchDir())
        #expect(throws: InstallerError.self) { try helper.sync() }
    }
}

@Suite struct WinHookInstallerTests {
    /// Installing into a data directory (never the real home): the helper lands in bin\, settings.json and hooks.json
    /// get Agentrise's Windows entries pointing at it, a second install adds nothing, and the backup is written.
    @Test func installsClaudeAndCodexUnderTheDataDir() throws {
        let data = try scratchDir()
        let paths = AppPaths(dataDir: nativePath(data))
        let installer = WinHookInstaller(paths: paths, sourceDir: try buildDir())
        #expect(!installer.isInstalled(.claude))
        let preview = try installer.preview(.claude)
        #expect(preview.contains("--agent"))
        #expect(!FileManager.default.fileExists(atPath: paths.claudeSettings.path))   // a preview writes nothing
        #expect(try installer.install(.claude) == nil)   // no previous file: no backup
        #expect(FileManager.default.fileExists(atPath: paths.binDir.appendingPathComponent("agentrise-hook.exe").path))
        let backup = try #require(try installer.install(.claude))
        #expect(backup.lastPathComponent.hasPrefix("settings.json.agentrise-backup-"))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as? [String: Any])
        let stop = try #require((obj["hooks"] as? [String: [[String: Any]]])?["Stop"])
        #expect(stop.count == 1)
        let h = try #require((stop.first?["hooks"] as? [[String: Any]])?.first)
        #expect(h["command"] as? String == nativePath(data) + "\\Agentrise\\bin\\agentrise-hook.exe")
        #expect(h["args"] as? [String] == ["--agent", "claude"])

        #expect(throws: WinHookInstaller.CodexMissing.self) { try installer.install(.codex) }   // no .codex yet
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        try installer.install(.codex)
        let cx = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.codexHooks)) as? [String: Any])
        let ch = try #require(((cx["hooks"] as? [String: [[String: Any]]])?["Stop"]?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(ch["commandWindows"] as? String == "& '\(nativePath(data))\\Agentrise\\bin\\agentrise-hook.exe' --agent codex")
        try installer.uninstall(.claude)
        try installer.uninstall(.codex)
        #expect(!installer.isInstalled(.claude) && !installer.isInstalled(.codex))
    }

    /// `--install-hooks codex` without Codex on the machine: refused (exit 2), and `.codex` is not created.
    @Test func cliRefusesCodexWhenAbsent() throws {
        let data = try scratchDir()
        #expect(try run(try agentriseExe(), ["--data-dir", nativePath(data), "--install-hooks", "codex"], timeout: 30) == 2)
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent(".codex").path))
        let log = try String(contentsOf: data.appendingPathComponent("Agentrise").appendingPathComponent("agentrise.log"), encoding: .utf8)
        #expect(log.contains("这台电脑上没有 Codex"))
    }

    /// `--print-runtime-files` (the release workflow's check against the packaging script): the real Agentrise.exe
    /// writes its closure with the hook's, the exes first, the Swift runtime found through `--search-dir`.
    @Test func cliPrintsTheRuntimeFiles() throws {
        let out = try scratchDir().appendingPathComponent("runtime files.txt")
        let runtime = try #require(toolchainRuntimeDir(), "no swiftCore.dll on PATH")
        #expect(try run(try agentriseExe(), ["--print-runtime-files", nativePath(out), "--search-dir", nativePath(runtime)],
                        timeout: 30) == 0)
        let all = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
        let lines = all.filter { !$0.hasPrefix("system ") && !$0.hasPrefix("missing ") }
        let names = lines.map { $0.split(separator: "\\").last.map(String.init)?.lowercased() ?? "" }
        let system = all.filter { $0.hasPrefix("system ") }.map { $0.dropFirst(7).lowercased() }
        #expect(system.contains("kernel32.dll"))
        #expect(!all.contains { $0.hasPrefix("missing ") })
        #expect(names.prefix(2) == ["agentrise.exe", "agentrise-hook.exe"])
        #expect(names.contains("swiftcore.dll"))
        #expect(names.contains("foundation.dll"))
        #expect(!names.contains("kernel32.dll"))
        #expect(Set(names).count == names.count)
        let expected = RuntimeFilesCommandLine.files(appDir: try buildDir(), exe: try agentriseExe(), searchDirs: [nativePath(runtime)])
        #expect(names == expected.map { $0.lastPathComponent.lowercased() })
    }

    /// An import found in no search directory that isn't Windows' own is reported as missing, with its importer: a
    /// copy of the hook whose `swiftCore.dll` import is renamed `swiftCorX.dll` (same length). Windows' own imports
    /// (kernel32, api-ms-win-*) are `system`; a Swift or VC++ runtime name never is, even if System32 has a copy.
    @Test func unresolvedImportsAreMissingUnlessWindowsOwn() throws {
        let dir = try scratchDir()
        var bytes = [UInt8](try Data(contentsOf: try buildDir().appendingPathComponent("agentrise-hook.exe")))
        let from = Array("swiftCore.dll".utf8), to = Array("swiftCorX.dll".utf8)
        var patched = 0
        var i = 0
        while i + from.count <= bytes.count {
            if bytes[i..<i + from.count].elementsEqual(from) { bytes.replaceSubrange(i..<i + from.count, with: to); patched += 1 }
            i += 1
        }
        #expect(patched > 0)
        let fake = dir.appendingPathComponent("agentrise-hook.exe")
        try Data(bytes).write(to: fake)
        let runtime = try #require(toolchainRuntimeDir(), "no swiftCore.dll on PATH")
        let r = RuntimeFiles.resolve(of: [fake], searchDirs: [dir, runtime])
        #expect(r.missing["swiftCorX.dll"] == "agentrise-hook.exe")
        #expect(r.system.contains { $0.lowercased() == "kernel32.dll" })
        #expect(r.missing.count == 1)
        #expect(RuntimeFiles.isSystem("api-ms-win-crt-runtime-l1-1-0.dll", systemDir: RuntimeFiles.systemDirectory()))
        #expect(RuntimeFiles.isSystem("KERNEL32.dll", systemDir: RuntimeFiles.systemDirectory()))
        #expect(!RuntimeFiles.isSystem("VCRUNTIME140.dll", systemDir: RuntimeFiles.systemDirectory()))
        #expect(!RuntimeFiles.isSystem("swiftCore.dll", systemDir: RuntimeFiles.systemDirectory()))
        #expect(!RuntimeFiles.isSystem("nothing-like-this.dll", systemDir: RuntimeFiles.systemDirectory()))
        // The closure itself is unchanged: what was found.
        #expect(RuntimeFiles.closure(of: [fake], searchDirs: [dir, runtime]) == r.files)
    }

    /// The installed hook really runs from bin\ and reaches the app's socket path (exec form: no shell, the path has a
    /// space and Chinese characters).
    @Test func installedHookRunsFromBin() throws {
        let data = try scratchDir()
        let paths = AppPaths(dataDir: nativePath(data))
        let installer = WinHookInstaller(paths: paths, sourceDir: try buildDir())
        try installer.install(.claude)
        let p = Process()
        p.executableURL = installer.helper.installed
        p.arguments = ["--agent", "claude"]
        var env = ProcessInfo.processInfo.environment
        env["LOCALAPPDATA"] = nativePath(data)
        p.environment = env
        let input = Pipe()
        p.standardInput = input
        try p.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"s1","cwd":"C:\\w"}"#.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)   // the hook never fails the agent, even with nobody listening
    }
}

@Suite(.serialized) struct SettingsWindowTests {
    private func controller(_ data: URL) throws -> (SettingsController, AppPaths, JSONSettingsStore) {
        let paths = AppPaths(dataDir: nativePath(data))
        let settings = JSONSettingsStore(file: paths.settingsFile)
        let c = SettingsController(installer: WinHookInstaller(paths: paths, sourceDir: try buildDir()), settings: settings,
                                   scheduler: InlineScheduler(),
                                   autostart: Autostart(keyPath: "Software\\AgentriseTest-\(UUID().uuidString)", exePath: "C:\\x.exe"),
                                   ranksFile: paths.ranksFile)
        c.runTrust = { $0(.success(12)) }
        c.runUntrust = { $0(.failure(CodexRPCError.binaryNotFound)) }
        return (c, paths, settings)
    }

    @Test func hooksPreviewThenWriteThenRemove() throws {
        let data = try scratchDir()
        let (c, paths, settings) = try controller(data)
        var changes = 0
        c.onChange = { changes += 1 }
        #expect(c.claudeState.text == "Hooks 未安装" && !c.claudeState.ok)
        let preview = try #require(c.previewClaude())
        #expect(preview.contains("agentrise-hook.exe"))
        #expect(!FileManager.default.fileExists(atPath: paths.claudeSettings.path))
        c.installClaude()
        #expect(c.claudeInstalled)
        #expect(c.claudeState.text == "✓ Hooks 已安装" && c.claudeState.ok)
        #expect(c.hookStatus == "已安装")
        c.uninstallClaude()
        #expect(!c.claudeInstalled)
        #expect(c.hookStatus == "已卸载")

        #expect(c.codexState.text == "未发现 Codex")
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        #expect(c.codexState.text == "未安装")
        #expect(c.previewCodex() != nil)
        var codexWritten = false
        c.installCodex { codexWritten = $0 }
        #expect(codexWritten)
        #expect(c.codexState.text == "已安装待信任")
        c.trustCodex()
        #expect(c.codexStatus == "✓ 已替你确认 12 条 hook。" + SettingsController.newSessionNote)
        settings.set(true, forKey: HookPlan.codexSeenKey)
        #expect(c.codexState.text == "✓ 已生效" && c.codexState.ok)
        c.uninstallCodex()
        #expect(!settings.bool(forKey: HookPlan.codexSeenKey))
        #expect(c.codexStatus == "hook 已删除；找不到 codex，信任记录留在 Codex 里，它们不再起作用。")
        #expect(!c.codexBusy)
        #expect(changes > 5)
    }

    @Test func badSettingsFileIsLeftAlone() throws {
        let data = try scratchDir()
        let (c, paths, _) = try controller(data)
        try FileManager.default.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: paths.claudeSettings)
        #expect(c.previewClaude() == nil)
        #expect(c.hookStatus == "失败：settings.json 不是有效的 JSON，没有改动它")
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == "not json")
    }

    /// Review M4: an install runs in the background; meanwhile the status says so, the hook buttons are disabled and a
    /// second install is refused. Review M3: a helper file still in use shows as "待更新", not as installed.
    @Test func installRunsInTheBackgroundAndReportsAStaleHelper() throws {
        let data = try scratchDir()
        let paths = AppPaths(dataDir: nativePath(data))
        let (src, dll) = try hookWithOneDll()
        var installer = WinHookInstaller(paths: paths, sourceDir: src)
        let scheduler = QueuedScheduler()
        let c = SettingsController(installer: installer, settings: JSONSettingsStore(file: paths.settingsFile), scheduler: scheduler,
                                   autostart: Autostart(keyPath: "Software\\AgentriseTest-\(UUID().uuidString)", exePath: "C:\\x.exe"),
                                   ranksFile: paths.ranksFile)
        scheduler.drain()   // the helper check at start
        var done: [Bool] = []
        c.installClaude { done.append($0) }
        #expect(c.installing && c.hookStatus == "正在安装…")
        #expect(!FileManager.default.fileExists(atPath: paths.claudeSettings.path))   // nothing written on the UI thread
        let w = SettingsWindow(controller: c, near: nil)
        defer { w.close() }
        #expect(!IsWindowEnabled(w.control(SettingsLayout.claudeButton)!))
        c.installCodex { done.append($0) }   // refused while the first runs
        #expect(done == [false])
        scheduler.drain()
        #expect(done == [false, true])
        #expect(!c.installing && c.hookStatus == "已安装")
        #expect(c.claudeState.text == "✓ Hooks 已安装" && c.claudeState.ok)
        #expect(IsWindowEnabled(w.control(SettingsLayout.claudeButton)!))

        // A new version whose DLL is in use: the hooks are written, but the helper isn't current.
        try Data("runtime v2".utf8).write(to: src.appendingPathComponent(dll))
        var failing = HookHelperFiles.FileOps()
        let real = failing.move
        failing.move = { from, to, replace in from.contains(dll) ? false : real(from, to, replace) }
        installer.helper.ops = failing
        let c2 = SettingsController(installer: installer, settings: JSONSettingsStore(file: paths.settingsFile), scheduler: scheduler,
                                    autostart: Autostart(keyPath: "Software\\AgentriseTest-\(UUID().uuidString)", exePath: "C:\\x.exe"),
                                    ranksFile: paths.ranksFile)
        scheduler.drain()
        #expect(c2.helperStale == [dll])   // found by the check at start
        #expect(c2.claudeState.text == "Hooks 已安装，hook 程序待更新" && !c2.claudeState.ok)
        var retried = false
        c2.onHelperStale = { retried = true }
        c2.uninstallClaude()
        c2.installClaude()
        scheduler.drain()
        #expect(c2.helperStale == [dll])   // the exe is unchanged: only the DLL is behind
        #expect(c2.hookStatus.hasSuffix(SettingsController.helperPendingNote))
        #expect(c2.claudeState.text == "Hooks 已安装，hook 程序待更新" && !c2.claudeState.ok)
        #expect(retried)
        // The app's retry got through.
        c2.noteHelper(HookHelperFiles.Result(copied: [dll, HookHelperFiles.hookExe]))
        #expect(c2.claudeState.text == "✓ Hooks 已安装" && c2.claudeState.ok)
    }

    @Test func ranksAndAutostart() throws {
        let saved = RankBook.current
        defer { RankBook.current = saved }
        let data = try scratchDir()
        let (c, paths, settings) = try controller(data)
        var reranked = false
        c.onRanksSaved = { reranked = true }
        let book = try #require(c.saveRanks([.seniorDirector: ("总监", "fable, 5.5"), .seniorExpert: ("", "opus"),
                                             .seniorEngineer: ("", ""), .newGrad: ("", "haiku")]))
        #expect(reranked && c.rankStatus == "✓ 已保存")
        #expect(book.title(.seniorDirector) == "总监")
        #expect(RankBook.load(from: paths.ranksFile) == book)
        #expect(!c.autostartOn)
        c.setAutostart(true)
        #expect(c.autostartOn)
        c.setAutostart(false)
        #expect(!c.autostartOn)
        // Review M6: cc-connect (飞书) is macOS-only (spec §2): no switch for it on Windows.
        #expect(!SettingsLayout.controls.contains { $0.text.contains("cc-connect") || $0.text.contains("飞书") })
        #expect(!settings.bool(forKey: "feishuBridge"))
    }

    @Test func layoutScalesWithDpi() {
        let at96 = SettingsLayout.frames(dpi: 96), at144 = SettingsLayout.frames(dpi: 144)
        #expect(at96.count == SettingsLayout.controls.count)
        for (id, r) in at96 {
            let s = at144[id]!
            #expect(s.left == r.left * 3 / 2 && s.top == r.top * 3 / 2, "\(id)")
            #expect(r.right <= SettingsLayout.clientSize.width && r.bottom <= SettingsLayout.clientSize.height, "\(id)")
        }
        // No two controls overlap except a control inside its group box.
        let groups = Set(SettingsLayout.controls.filter { $0.kind == .group }.map(\.id))
        let rects = at96.filter { !groups.contains($0.key) }
        for (a, ra) in rects { for (b, rb) in rects where a < b {
            let overlap = ra.left < rb.right && rb.left < ra.right && ra.top < rb.bottom && rb.top < ra.bottom
            #expect(!overlap, "\(a) and \(b) overlap")
        } }
    }

    /// The real window (never shown): every control exists and shows the controller's state.
    @Test func windowShowsTheState() throws {
        let data = try scratchDir()
        let (c, _, _) = try controller(data)
        let w = SettingsWindow(controller: c, near: nil)
        defer { w.close() }
        for control in SettingsLayout.controls { #expect(w.control(control.id) != nil, "\(control.id)") }
        func text(_ id: Int32) -> String {
            let h = w.control(id)!
            var buf = [WCHAR](repeating: 0, count: 256)
            let n = GetWindowTextW(h, &buf, 256)
            return String(decoding: buf.prefix(Int(n)), as: UTF16.self)
        }
        #expect(text(SettingsLayout.claudeButton) == "安装 Hooks")
        #expect(text(SettingsLayout.claudeState) == "Hooks 未安装")
        #expect(text(SettingsLayout.rankName) == RankBook.current.title(.seniorDirector))
        c.installClaude()
        #expect(text(SettingsLayout.claudeButton) == "卸载 Hooks")
        #expect(text(SettingsLayout.hookStatus) == "已安装")
        #expect(PreviewDialog.editText("{\n  \"a\": 1\r\n}") == "{\r\n  \"a\": 1\r\n}")
    }
}

@Suite struct CodexLaunchTests {
    /// A shim whose path cmd can't quote (`%` expands even inside quotes) is not used; `&`, a space and Chinese are fine.
    @Test func shimPathsCmdCanCarry() {
        #expect(CodexLaunch.cmdCanQuote("C:\\R&D\\npm\\codex.cmd"))
        #expect(CodexLaunch.cmdCanQuote("C:\\Users\\张 三\\npm\\codex.cmd"))
        #expect(!CodexLaunch.cmdCanQuote("C:\\x%PATH%y\\codex.cmd"))
        for dir in ["C:\\R&D", "C:\\Users\\张 三\\npm"] {
            #expect(CodexLaunch.locate(env: ["PATH": dir], isFile: { $0 == dir + "\\codex.cmd" }) == .cmdShim(dir + "\\codex.cmd"))
        }
        let bad = "C:\\x%PATH%y"
        #expect(CodexLaunch.locate(env: ["PATH": bad], isFile: { $0 == bad + "\\codex.cmd" }) == nil)
    }

    @Test func locatePrefersARealExe() {
        let env = ["Path": "C:\\Tools;C:\\Users\\u\\AppData\\Roaming\\npm", "LOCALAPPDATA": "C:\\Users\\u\\AppData\\Local",
                   "USERPROFILE": "C:\\Users\\u", "APPDATA": "C:\\Users\\u\\AppData\\Roaming"]
        let standalone = "C:\\Users\\u\\AppData\\Local\\Programs\\OpenAI\\Codex\\bin\\codex.exe"
        let shim = "C:\\Users\\u\\AppData\\Roaming\\npm\\codex.cmd"
        let vendored = "C:\\Users\\u\\AppData\\Roaming\\npm\\node_modules\\@openai\\codex\\node_modules\\@openai\\codex-win32-x64\\vendor\\x86_64-pc-windows-msvc\\bin\\codex.exe"
        #expect(CodexLaunch.locate(env: env, isFile: { $0 == "C:\\Tools\\codex.exe" || $0 == standalone }) == .exe("C:\\Tools\\codex.exe"))
        #expect(CodexLaunch.locate(env: env, isFile: { $0 == standalone || $0 == shim }) == .exe(standalone))
        #expect(CodexLaunch.locate(env: env, isFile: { $0 == vendored || $0 == shim }) == .exe(vendored))
        #expect(CodexLaunch.locate(env: env, isFile: { $0 == shim }) == .cmdShim(shim))
        #expect(CodexLaunch.locate(env: env, isFile: { _ in false }) == nil)
    }

    @Test func commandLines() {
        let exe = CodexLaunch.exe("C:\\Program Files\\codex.exe").commandLine(["app-server"])
        #expect(exe.application == "C:\\Program Files\\codex.exe")
        #expect(exe.line == "\"C:\\Program Files\\codex.exe\" app-server")
        let shim = CodexLaunch.cmdShim("C:\\Users\\张 三\\npm\\codex.cmd").commandLine(["app-server"], comSpec: "C:\\WINDOWS\\system32\\cmd.exe")
        #expect(shim.application == "C:\\WINDOWS\\system32\\cmd.exe")
        #expect(shim.line == "\"C:\\WINDOWS\\system32\\cmd.exe\" /d /v:off /s /c \"\"C:\\Users\\张 三\\npm\\codex.cmd\" \"app-server\"\"")
        // cmd's metacharacters stay inside the quotes.
        let rd = CodexLaunch.cmdShim("C:\\R&D (x)\\a^b|c\\codex.cmd").commandLine(["app-server"], comSpec: "C:\\WINDOWS\\system32\\cmd.exe")
        #expect(rd.line == "\"C:\\WINDOWS\\system32\\cmd.exe\" /d /v:off /s /c \"\"C:\\R&D (x)\\a^b|c\\codex.cmd\" \"app-server\"\"")
        #expect(CodexProcess.quoted("a\\b c\\") == "\"a\\b c\\\\\"")
        #expect(CodexProcess.quoted("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(CodexProcess.quoted("") == "\"\"")
    }
}

@Suite struct CodexProcessTests {
    /// Answers every request with its own id after a notification; `fail` gets a JSON-RPC error.
    private let echoServer = #"""
    $in = [Console]::In
    while (($l = $in.ReadLine()) -ne $null) {
      if ($l -match '"id":(\d+)') {
        $id = $Matches[1]
        [Console]::Out.WriteLine('{"jsonrpc":"2.0","method":"remoteControl/status/changed","params":{}}')
        if ($l -match '"method":"fail"') { [Console]::Out.WriteLine('{"jsonrpc":"2.0","id":' + $id + ',"error":{"code":-1,"message":"nope"}}') }
        else { [Console]::Out.WriteLine('{"jsonrpc":"2.0","id":' + $id + ',"result":{"echo":' + $id + '}}') }
        [Console]::Out.Flush()
      }
    }
    """#

    @Test func matchesResponsesById() throws {
        let rpc = try CodexProcess(application: powershell, commandLine: powershellLine(echoServer), timeout: 30)
        defer { rpc.close() }
        try rpc.handshake(version: "test")
        #expect(try rpc.call("hooks/list", [:])["echo"] as? Int == 2)
        #expect(throws: CodexRPCError.rpc("nope")) { try rpc.call("fail", [:]) }
        #expect(try rpc.call("config/read", [:])["echo"] as? Int == 4)
    }

    /// A server that never answers times out; closing ends it and, through the job, what it started.
    @Test func timesOutAndTheJobEndsTheTree() throws {
        let line = "C:\\Windows\\System32\\cmd.exe /d /s /c \"ping -n 60 127.0.0.1\""
        let rpc = try CodexProcess(application: "C:\\Windows\\System32\\cmd.exe", commandLine: line, timeout: 1.5)
        let start = Date()
        #expect(throws: CodexRPCError.timedOut) { try rpc.call("hooks/list", [:]) }
        #expect(Date().timeIntervalSince(start) < 5)
        let child = Jump.systemProcesses().first { $0.parent == rpc.pid && $0.exe.lowercased() == "ping.exe" }
        #expect(child != nil)
        rpc.close()
        let until = Date().addingTimeInterval(5)
        while Date() < until, WinPlatform.isRunning(Int32(bitPattern: rpc.pid)) || child.map({ WinPlatform.isRunning(Int32(bitPattern: $0.pid)) }) == true {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!WinPlatform.isRunning(Int32(bitPattern: rpc.pid)))
        if let child { #expect(!WinPlatform.isRunning(Int32(bitPattern: child.pid))) }
    }

    /// The cmd fallback really runs a shim in a directory named with `&`, parentheses, a space and Chinese.
    @Test func shimInAnAwkwardDirectoryRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("R&D (测试) \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shim = dir.appendingPathComponent("codex.cmd")
        // Answers request 1 whatever it is, and says which argument it got.
        try Data("@echo {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"arg\":\"%~1\"}}\r\n".utf8).write(to: shim)
        let rpc = try CodexProcess(launch: .cmdShim(nativePath(shim)), arguments: ["app-server"], timeout: 15)
        defer { rpc.close() }
        #expect(try rpc.call("initialize", [:])["arg"] as? String == "app-server")
    }

    @Test func reportsAServerThatExits() throws {
        let rpc = try CodexProcess(application: "C:\\Windows\\System32\\cmd.exe", commandLine: "cmd.exe /d /c exit 0", timeout: 10)
        defer { rpc.close() }
        #expect(throws: CodexRPCError.self) { try rpc.call("hooks/list", [:]) }
    }

    @Test func missingCodexIsReported() throws {
        let paths = AppPaths(dataDir: nativePath(try scratchDir()))
        #expect(throws: CodexRPCError.binaryNotFound) { try CodexAppServer.withLocal(paths: paths, locate: { nil }) { _ in 0 } }
    }
}
#endif
