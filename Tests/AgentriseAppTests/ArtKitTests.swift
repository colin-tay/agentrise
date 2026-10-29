// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import AppKit
import SpriteKit
@testable import AgentriseApp
@testable import Agentrise
@testable import AgentriseScene
import AgentriseMacArt

/// `CGArtBackend`'s bitmaps and textures. (`ArtKit`'s measures are tested in `AgentriseSceneTests.ArtKitTests`.)
@Suite struct ArtKitTests {
    /// Redraws an image into a plain RGBA bitmap, so images with different row layouts compare by pixels.
    private func pixels(_ img: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGArtBackend.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: img.width * img.height * 4))
    }

    /// A drawing that is not symmetric and has translucent pixels: a gradient and a marker in the top-left corner.
    private func draw(_ ctx: CGContext) {
        let g = CGGradient(colorsSpace: CGArtBackend.colorSpace, colors: [NSColor(hex: 0xFF5A00, alpha: 0.2).cgColor, NSColor(hex: 0x1A80FF, alpha: 0.9).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 30, y: 17), options: [])
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 6, height: 3))
    }

    /// The data-backed texture (no retained CGImage) holds exactly the pixels `CGArtBackend.image` bakes.
    @Test func textureMatchesImagePixels() {
        let size = CGSize(width: 30.3, height: 17), scale: CGFloat = 2.5
        let image = CGArtBackend.image(size: size, scale: scale, draw)
        let texture = CGArtBackend.texture(size: size, scale: scale, draw)
        #expect(texture.size() == CGSize(width: image.width, height: image.height))
        let same = pixels(texture.cgImage()) == pixels(image)   // a Bool: a failing array comparison would print it all
        #expect(same)
    }

    /// A baked image, its raw-data texture and `rgba` all hold the same pixels, top row first.
    @Test func bakedImageTextureAndRGBAAgree() {
        let backend = CGArtBackend.shared
        let img = backend.bake(size: CGSize(width: 30.3, height: 17), scale: 2.5) { pen in
            pen.linearGradient(.rect(CGRect(x: 0, y: 0, width: 31, height: 17)), colors: [Color(hex: 0xFF5A00, alpha: 0.2), Color(hex: 0x1A80FF, alpha: 0.9)],
                               locations: [0, 1], from: .zero, to: CGPoint(x: 30, y: 17), extend: false)
            pen.fill(.rect(CGRect(x: 0, y: 0, width: 6, height: 3)), Color(r: 1, g: 1, b: 1))
        }
        #expect(img.pixelWidth == 76 && img.pixelHeight == 43 && img.scale == 2.5)
        let rgba = backend.rgba(img)
        #expect(rgba == pixels(img.cgImage))
        #expect(Array(rgba[0..<4]) == [255, 255, 255, 255])   // the marker is in the top-left corner
        let same = pixels(CGArtBackend.texture(img).cgImage()) == rgba
        #expect(same)
    }

    /// `maxLines` cuts the text after that many lines; 0 keeps them all.
    @Test func textMeasuresAndCutsLines() {
        let backend = CGArtBackend.shared
        let font = FontSpec(size: 11, weight: .semibold)
        let one = backend.measure("第一行", font: font, maxWidth: .infinity, maxLines: 0)
        let two = backend.measure("第一行\n第二行", font: font, maxWidth: .infinity, maxLines: 0)
        let cut = backend.measure("第一行\n第二行", font: font, maxWidth: .infinity, maxLines: 1)
        #expect(two.height > one.height)
        #expect(cut.height == one.height)
    }
}
