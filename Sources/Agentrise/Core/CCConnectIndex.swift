// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation

/// The cc-connect (Feishu bridge) switch.
/// Off by default: only users who run cc-connect turn it on in Settings.
enum CCConnectIndex {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "feishuBridge") }
        set { UserDefaults.standard.set(newValue, forKey: "feishuBridge") }
    }
}
