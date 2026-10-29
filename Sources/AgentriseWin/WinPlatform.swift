// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
import TowerKit
import Agentrise
import AgentriseScene

/// Where the app keeps and reads its files. Normally `%USERPROFILE%` and `%LOCALAPPDATA%\Agentrise`; with
/// `--data-dir <dir>` both live under `<dir>` (CI and local test runs never touch the real `~/.claude`): the home is
/// `<dir>` and the support directory is `<dir>\Agentrise`, which is what `TowerPaths` (and so `agentrise-hook.exe`)
/// computes when `LOCALAPPDATA` is `<dir>`, so a hook run with that variable sends to this instance's socket.
///
/// Claude Code's config dir is `%CLAUDE_CONFIG_DIR%` when set, else `<home>\.claude` (facts §1, §3); Codex's is
/// `%CODEX_HOME%`, else `<home>\.codex` (facts §4). With `--data-dir` neither variable is read: both are under `<dir>`.
package struct AppPaths {
    package let home: URL
    package let support: URL
    /// `TowerPaths.socketPath` for the same environment (what the hook computes).
    package let socketPath: String
    /// Claude Code's config directory (`sessions\`, `projects\`, `settings.json`).
    package let claudeDir: URL
    /// Codex's home (`hooks.json`, `session_index.jsonl`).
    package let codexHome: URL

    package init(dataDir: String?, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let dataDir, !dataDir.isEmpty {
            var dir = dataDir
            while dir.count > 3, dir.hasSuffix("\\") || dir.hasSuffix("/") { dir.removeLast() }
            home = URL(fileURLWithPath: dir, isDirectory: true)
            support = TowerPaths.supportDir(environment: ["LOCALAPPDATA": dir])
            socketPath = TowerPaths.socketPath(environment: ["LOCALAPPDATA": dir])
            claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
            codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        } else {
            let profile = environment.first { $0.key.uppercased() == "USERPROFILE" }?.value
            home = profile.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            support = TowerPaths.supportDir(environment: environment)
            socketPath = TowerPaths.socketPath(environment: environment)
            claudeDir = HookPlan.claudeConfigDir(env: environment, home: home)
            codexHome = HookPlan.codexHome(env: environment, home: home)
        }
    }

    package var windowFile: URL { support.appendingPathComponent("window.json") }
    package var settingsFile: URL { support.appendingPathComponent("settings.json") }
    package var logFile: URL { support.appendingPathComponent("agentrise.log") }
    package var ranksFile: URL { support.appendingPathComponent("ranks.json") }
    /// Where the hook helper and its DLLs are copied (`%LOCALAPPDATA%\Agentrise\bin`, spec §5.9).
    package var binDir: URL { support.appendingPathComponent("bin", isDirectory: true) }
    package var claudeSettings: URL { claudeDir.appendingPathComponent("settings.json") }
    package var codexHooks: URL { codexHome.appendingPathComponent("hooks.json") }
}

/// `C:\…` with backslashes and no trailing separator, as Win32 and `TowerPaths` spell paths (the URL's file-system
/// representation).
package func nativePath(_ url: URL) -> String { SafeFile.nativePath(of: url) }

/// The Windows side of `PlatformServices`.
package final class WinPlatform: PlatformServices {
    package let paths: AppPaths
    package var jump = Jump()

    package init(paths: AppPaths) { self.paths = paths }

    package var homeDirectory: URL { paths.home }
    package var supportDirectory: URL { paths.support }
    package var socketPath: String { paths.socketPath }
    package var claudeDirectory: URL { paths.claudeDir }
    package var ranksFile: URL { paths.ranksFile }
    package var codexHome: URL { paths.codexHome }

    package func isRunning(_ pid: Int32) -> Bool { Self.isRunning(pid) }

    package func isSameProcess(pid: Int32, start: ProcessStart?) -> Bool { Self.isSameProcess(pid: pid, start: start) }

    /// Running, and (when the registry recorded a start time) created when the registry says: Windows hands a dead
    /// process's id to a new one soon, so a stale `<pid>.json` would otherwise stay "alive" (facts §1, note 1). A
    /// creation time we can't read (access denied) or a start we can't parse leaves only `isRunning`.
    package static func isSameProcess(pid: Int32, start: ProcessStart?, creation: (UInt32) -> UInt64? = Jump.creationTime) -> Bool {
        guard isRunning(pid) else { return false }
        guard let start, let created = creation(UInt32(bitPattern: pid)) else { return true }
        return start.matches(creation: created) ?? true
    }

    /// False only when the process is known to be gone: no process has that id any more, or it has exited. A process
    /// we may not open (access denied) or any other error counts as running, like `kill(pid, 0)` on macOS. Exited is
    /// "its handle is signalled", not `GetExitCodeProcess == STILL_ACTIVE` (a process that exited with 259 would
    /// look alive). A process that grants the query but not `SYNCHRONIZE` falls back to its exit code.
    package static func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let query = DWORD(PROCESS_QUERY_LIMITED_INFORMATION)
        if let h = OpenProcess(query | DWORD(0x0010_0000) /* SYNCHRONIZE */, false, DWORD(bitPattern: pid)) {
            defer { CloseHandle(h) }
            return WaitForSingleObject(h, 0) != 0   // WAIT_OBJECT_0: exited; WAIT_TIMEOUT or WAIT_FAILED: running
        }
        guard GetLastError() != DWORD(ERROR_INVALID_PARAMETER) else { return false }   // no such process
        guard let h = OpenProcess(query, false, DWORD(bitPattern: pid)) else { return true }   // denied or unknown
        defer { CloseHandle(h) }
        var code: DWORD = 0
        guard GetExitCodeProcess(h, &code) else { return true }
        return code == Win.stillActive
    }

    /// Spec §5.8: a desktop session's `claude://` link, else the window of the terminal that runs the agent. False
    /// (the model's "can't locate" toast) when neither can be found.
    package func openSession(_ link: SessionLink) -> Bool { jump.open(link) }
}

/// The app model's switches (and the shell's own, like "always on top"), in `<support>\settings.json`.
package final class JSONSettingsStore: SettingsStore {
    private let file: URL
    private var values: [String: Bool]

    package init(file: URL) {
        self.file = file
        values = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
    }

    package func bool(forKey key: String) -> Bool { values[key] ?? false }

    package func set(_ value: Bool, forKey key: String) {
        guard values[key] != value else { return }
        values[key] = value
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(values) { try? SafeFile.write(data, to: file) }
    }
}
#endif
