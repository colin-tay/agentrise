// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT
//
// Renders every `ComparisonScenes` scene with this platform's art backend (Core Graphics on macOS, Direct2D on
// Windows) and writes each as `<out>/<scene>.png`. CI runs it on both platforms and stitches the pairs side by
// side (scripts/side-by-side.py).

import Foundation
import AgentriseScene
#if os(macOS)
import AgentriseMacArt
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#elseif os(Windows)
import AgentriseWinArt
#endif

#if os(macOS)
let backend: ArtBackend = CGArtBackend.shared

/// Writes opaque RGBA rows (top first) as a PNG.
func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGArtBackend.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}
#elseif os(Windows)
let backend: ArtBackend = D2DArtBackend.shared

func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
    try D2DArtBackend.shared.writePNG(rgba: rgba, width: width, height: height, to: url.path)
}
#endif

guard CommandLine.arguments.count == 2 else {
    print("usage: ArtGallery <output directory>")
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for scene in ComparisonScenes.all {
    let start = Date()
    let picture = ComparisonScenes.compose(scene.draw(backend), backend: backend)
    let file = out.appendingPathComponent("\(scene.name).png")
    try writePNG(picture.rgba, width: picture.width, height: picture.height, to: file)
    print("ArtGallery: \(file.lastPathComponent) \(picture.width)×\(picture.height) px (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")
}
