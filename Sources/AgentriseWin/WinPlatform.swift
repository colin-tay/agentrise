// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
import TowerKit
import AgentriseScene

/// Where the app keeps and reads its files. Normally `%USERPROFILE%` and `%LOCALAPPDATA%\Agentrise`; with
/// `--data-dir <dir>` both live under `<dir>` (CI and local test runs never touch the real `~/.claude`): the home is
/// `<dir>` and the support directory is `<dir>\Agentrise`, which is what `TowerPaths` (and so `agentrise-hook.exe`)
/// computes when `LOCALAPPDATA` is `<dir>`, so a hook run with that variable sends to this instance's socket.
package struct AppPaths {
    package let home: URL
    package let support: URL
    /// `TowerPaths.socketPath` for the same environment (what the hook computes).
    package let socketPath: String

    package init(dataDir: String?, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let dataDir, !dataDir.isEmpty {
            var dir = dataDir
            while dir.count > 3, dir.hasSuffix("\\") || dir.hasSuffix("/") { dir.removeLast() }
            home = URL(fileURLWithPath: dir, isDirectory: true)
            support = TowerPaths.supportDir(environment: ["LOCALAPPDATA": dir])
            socketPath = TowerPaths.socketPath(environment: ["LOCALAPPDATA": dir])
        } else {
            let profile = environment.first { $0.key.uppercased() == "USERPROFILE" }?.value
            home = profile.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            support = TowerPaths.supportDir(environment: environment)
            socketPath = TowerPaths.socketPath(environment: environment)
        }
    }

    package var windowFile: URL { support.appendingPathComponent("window.json") }
    package var settingsFile: URL { support.appendingPathComponent("settings.json") }
    package var logFile: URL { support.appendingPathComponent("agentrise.log") }
}

/// `C:\…` with backslashes and no trailing separator, as Win32 and `TowerPaths` spell paths (the URL's file-system
/// representation).
package func nativePath(_ url: URL) -> String {
    var p = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    p = p.replacingOccurrences(of: "/", with: "\\")
    while p.count > 3, p.hasSuffix("\\") { p.removeLast() }
    return p
}

/// The Windows side of `PlatformServices`: minimal working versions for now (Task 13 hardens them and adds jumping
/// back to a session).
package final class WinPlatform: PlatformServices {
    package let paths: AppPaths

    package init(paths: AppPaths) { self.paths = paths }

    package var homeDirectory: URL { paths.home }
    package var supportDirectory: URL { paths.support }
    package var socketPath: String { paths.socketPath }

    package func isRunning(_ pid: Int32) -> Bool { Self.isRunning(pid) }

    /// False only when the process is known to be gone: no process has that id any more, or it has exited. A process
    /// we may not open (access denied) or any other error counts as running, like `kill(pid, 0)` on macOS.
    package static func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        guard let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(bitPattern: pid)) else {
            return GetLastError() != DWORD(ERROR_INVALID_PARAMETER)   // no such process
        }
        defer { CloseHandle(h) }
        var code: DWORD = 0
        guard GetExitCodeProcess(h, &code) else { return true }
        return code == Win.stillActive
    }

    /// Jumping back to a session is Task 13: until then every jump reports "not found", which shows the model's toast.
    package func openSession(_ link: SessionLink) -> Bool { false }
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
        try? enc.encode(values).write(to: file, options: .atomic)
    }
}
#endif
