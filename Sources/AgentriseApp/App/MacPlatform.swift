// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import TowerKit
import AgentriseScene

/// The Mac side of `PlatformServices`.
final class MacPlatform: PlatformServices {
    /// `CFFIXED_USER_HOME`-aware, so test and local runs can point the app at a temporary home.
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    var supportDirectory: URL { TowerPaths.supportDir(home: homeDirectory) }
    var socketPath: String { TowerPaths.socketPath(home: homeDirectory) }

    func isRunning(_ pid: Int32) -> Bool { Self.isRunning(pid) }

    /// False only when the process is known to be gone (no permission to signal it still counts as running).
    static func isRunning(_ pid: Int32) -> Bool { !(kill(pid, 0) == -1 && errno == ESRCH) }

    func openSession(_ link: SessionLink) -> Bool {
        switch link {
        case .desktop(let url):
            NSWorkspace.shared.open(url)   // as before: a link the system can't open shows no toast
            return true
        case .terminal(let bundle):
            if let b = bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
                app.activate()
            } else if let t = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first {
                t.activate()
            } else { return false }
            return true
        }
    }
}

/// The app model's switches live in the standard defaults, under the keys they always had.
extension UserDefaults: SettingsStore {}
