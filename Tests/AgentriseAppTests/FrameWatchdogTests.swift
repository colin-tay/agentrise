// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import AgentriseApp

/// When the tower view restarts a SpriteKit display link that stopped delivering frames.
@Suite struct FrameWatchdogTests {
    private let stall = FrameWatchdog.stallAfter

    /// Feeds the watchdog one check per `(now, lastFrame, due)` and returns its answers in order.
    private func answers(_ w: inout FrameWatchdog, _ checks: [(now: TimeInterval, lastFrame: TimeInterval?, due: Bool)]) -> [Bool] {
        checks.map { w.shouldRestart(lastFrame: $0.lastFrame, framesDue: $0.due, now: $0.now) }
    }

    @Test func framesFlowingNeverRestart() {
        var w = FrameWatchdog()
        let got = answers(&w, stride(from: 100.0, through: 120, by: 1).map { ($0, $0 - 0.016, true) })
        #expect(!got.contains(true))
    }

    @Test func noFramesWhileDueRestartsAfterTheStallTime() {
        var w = FrameWatchdog()
        let got = answers(&w, [(100, 100, true), (100 + stall, 100, true), (100 + stall + 0.5, 100, true)])
        #expect(got == [false, false, true])
    }

    /// Paused or covered: no frames are expected, however old the last one.
    @Test func noFramesDueNeverRestart() {
        var w = FrameWatchdog()
        let got = answers(&w, stride(from: 100.0, through: 200, by: 1).map { ($0, 0, false) })
        #expect(!got.contains(true))
    }

    /// A view just unpaused after hours hasn't drawn yet: it gets the full stall time from now, not from its last frame.
    @Test func becomingDueStartsTheClockAfresh() {
        var w = FrameWatchdog()
        let got = answers(&w, [(5000, 0, false), (5001, 0, true), (5001 + stall, 0, true), (5001 + stall + 0.5, 0, true)])
        #expect(got == [false, false, false, true])
    }

    /// Still stalled after a restart: the next waits the stall time again, so a long stall retries without spinning.
    @Test func restartsAreSpacedByTheStallTime() {
        var w = FrameWatchdog()
        let got = answers(&w, [(100, 0, true), (100 + stall + 0.5, 0, true), (100 + stall + 1.5, 0, true), (100 + 2 * stall + 1, 0, true)])
        #expect(got == [false, true, false, true])
    }

    @Test func framesResumingAfterARestartStopTheRestarts() {
        var w = FrameWatchdog()
        let stalled = answers(&w, [(100, 0, true), (100 + stall + 0.5, 0, true)])
        let resumed = answers(&w, stride(from: 105.0, through: 120, by: 1).map { ($0, $0 - 0.016, true) })
        #expect(stalled == [false, true])
        #expect(!resumed.contains(true))
    }
}
