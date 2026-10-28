// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit

/// What the app model needs from the operating system. macOS: `MacPlatform` in the app.
package protocol PlatformServices: AnyObject {
    /// macOS: `CFFIXED_USER_HOME`-aware like `FileManager.homeDirectoryForCurrentUser`; Windows: `%USERPROFILE%`.
    var homeDirectory: URL { get }
    /// `TowerPaths.supportDir()`.
    var supportDirectory: URL { get }
    /// Where the hook socket listens: `TowerPaths.socketPath()`.
    var socketPath: String { get }
    /// False only when the process is known to be gone (unknown or no permission counts as running).
    func isRunning(_ pid: Int32) -> Bool
    /// Brings the session's app forward; false when it can't be found (the model then shows a toast).
    func openSession(_ link: SessionLink) -> Bool
}

/// The few switches the app model reads and writes (macOS: `UserDefaults`, same keys as before).
package protocol SettingsStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

/// When and where the app model's work runs. Injected so tests can drive time by hand.
package protocol TowerScheduler: AnyObject {
    /// Runs `work` on the main thread soon (the socket calls back on its own thread).
    func onMain(_ work: @escaping () -> Void)
    /// Runs `work` on the main thread after `seconds`.
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void)
    /// Runs `work` on the main thread every `seconds`, for as long as the app runs.
    func every(_ seconds: TimeInterval, _ work: @escaping () -> Void)
    /// Runs `work` off the main thread (file reads that may take a while).
    func inBackground(_ work: @escaping () -> Void)
}

/// The main dispatch queue and run loop, as the macOS app has always used them.
package final class MainQueueScheduler: TowerScheduler {
    package init() {}

    package func onMain(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    package func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    package func every(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        let t = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in work() }
        t.tolerance = 2
    }

    package func inBackground(_ work: @escaping () -> Void) { DispatchQueue.global(qos: .utility).async(execute: work) }
}
