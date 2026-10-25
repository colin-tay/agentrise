// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import AppKit
import SpriteKit
@testable import Agentrise

@Suite struct ArtKitTests {
    /// Redraws an image into a plain RGBA bitmap, so images with different row layouts compare by pixels.
    private func pixels(_ img: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: ArtKit.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: img.width * img.height * 4))
    }

    /// A drawing that is not symmetric and has translucent pixels: a gradient and a marker in the top-left corner.
    private func draw(_ ctx: CGContext) {
        let g = CGGradient(colorsSpace: ArtKit.colorSpace, colors: [NSColor(hex: 0xFF5A00, alpha: 0.2).cgColor, NSColor(hex: 0x1A80FF, alpha: 0.9).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 30, y: 17), options: [])
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 6, height: 3))
    }

    /// The data-backed texture (no retained CGImage) holds exactly the pixels `ArtKit.image` bakes.
    @Test func textureMatchesImagePixels() {
        let size = CGSize(width: 30.3, height: 17), scale: CGFloat = 2.5
        let image = ArtKit.image(size: size, scale: scale, draw)
        let texture = ArtKit.texture(size: size, scale: scale, draw)
        #expect(texture.size() == CGSize(width: image.width, height: image.height))
        let same = pixels(texture.cgImage()) == pixels(image)   // a Bool: a failing array comparison would print it all
        #expect(same)
    }
}
