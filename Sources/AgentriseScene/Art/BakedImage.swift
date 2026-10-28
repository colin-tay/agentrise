// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A bitmap baked once by an art backend. Identity matters: the atlas keys on the instance.
/// `native` is the backend's own image (a `CGImage` on macOS, the Windows bitmap object on Windows).
package final class BakedImage {
    package let pixelWidth: Int, pixelHeight: Int, scale: CGFloat
    package let native: AnyObject

    package init(pixelWidth: Int, pixelHeight: Int, scale: CGFloat, native: AnyObject) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.native = native
    }
}
