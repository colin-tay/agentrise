// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit
@testable import AgentriseApp
@testable import AgentriseScene

@Suite struct MacPlatformTests {
    @Test func probeSeesLiveAndExitedProcesses() throws {
        #expect(MacPlatform.isRunning(getpid()))
        #expect(MacPlatform().isRunning(getpid()))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        #expect(!MacPlatform.isRunning(p.processIdentifier))
        #expect(!MacPlatform().isRunning(p.processIdentifier))
    }

    /// Same home and paths as before the move: `CFFIXED_USER_HOME` still redirects them.
    @Test func pathsFollowTheFixedHome() {
        let p = MacPlatform()
        #expect(p.homeDirectory == FileManager.default.homeDirectoryForCurrentUser)
        #expect(p.supportDirectory == TowerPaths.supportDir())
        #expect(p.socketPath == TowerPaths.socketPath())
    }
}
