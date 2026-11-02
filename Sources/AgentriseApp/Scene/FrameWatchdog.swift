// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation

/// Notices an SKView that stopped drawing. When the displays wake and reconfigure, SpriteKit sometimes stops
/// delivering frames to a view that is visible and not paused (its display link is gone), and nothing brings
/// them back until the displays change again. Pausing and resuming the view builds a new display link.
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
