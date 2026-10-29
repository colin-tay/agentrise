// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation

/// The cc-connect (Feishu bridge) switch.
/// Off by default: only users who run cc-connect turn it on in Settings.
package enum CCConnectIndex {
    /// The switch's key in the app's settings store (macOS: the standard defaults).
    package static let enabledKey = "feishuBridge"

    package static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
