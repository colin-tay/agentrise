// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation

/// Notices a tower view that stopped drawing: visible and not paused, yet no frames for a while (a display link
/// that died when the displays woke or changed). The view then starts a new display link.
struct FrameWatchdog {
    /// No frame for this long while frames are due is a stall; after a restart the next waits as long again.
    static let stallAfter: TimeInterval = 3

    /// When frames became due, or the last restart: a view just unpaused hasn't drawn yet.
    private var dueSince: TimeInterval?

    /// Whether to restart the view now. `lastFrame` is when the scene last updated, `framesDue` whether it
    /// should be drawing (in a visible window, not paused); times are system uptime.
    mutating func shouldRestart(lastFrame: TimeInterval?, framesDue: Bool, now: TimeInterval) -> Bool {
        guard framesDue else { dueSince = nil; return false }
        let since = max(dueSince ?? now, lastFrame ?? -.infinity)
        if dueSince == nil { dueSince = now }
        guard now - since > Self.stallAfter else { return false }
        dueSince = now
        return true
    }
}
