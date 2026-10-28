// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A bitmap the display draws itself, straight into its own texture memory, once per instance: the recipe
/// instead of the pixels. Used for big or one-off bitmaps (the building background, the cab, the shaft label,
/// the header, the tooltip, the report card), so no CPU copy of their pixels outlives the upload (a baked
/// `BakedImage` would keep one, plus a transient copy into the texture).
///
/// Identity matters: a display draws a new instance once and keeps its texture while the instance lives; the
/// model makes a new instance whenever the picture changes.
package final class ArtDrawing {
    /// Points.
    package let size: CGSize
    /// Pixels per point.
    package let scale: CGFloat
    /// The recipe: points, origin top-left, y down.
    package let draw: (Pen) -> Void

    package init(size: CGSize, scale: CGFloat, draw: @escaping (Pen) -> Void) {
        self.size = size
        self.scale = scale
        self.draw = draw
    }

    /// The bitmap's size in pixels (`ArtKit.pixelSize`).
    package var pixelSize: (width: Int, height: Int) { ArtKit.pixelSize(size, scale: scale) }

    /// Bakes it with `backend` (tests, and displays that can't draw into their textures directly).
    package func bake(with backend: ArtBackend) -> BakedImage { backend.bake(size: size, scale: scale, draw) }
}
