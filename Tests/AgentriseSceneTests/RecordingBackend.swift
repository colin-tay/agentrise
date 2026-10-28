// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import AgentriseScene

/// An `ArtBackend` that draws nothing: each bake records the `Pen` commands it received, so tests can check
/// sizes, caching and what a recipe asked for on any platform. Text measures `0.5 × size` per character by
/// `1.25 × size` per line.
final class RecordingBackend: ArtBackend {
    /// What a baked image holds as its `native` object.
    final class Recording { var commands: [String] = [] }

    private(set) var bakes = 0

    func bake(size: CGSize, scale: CGFloat, _ draw: (Pen) -> Void) -> BakedImage {
        bakes += 1
        let pen = RecordingPen(scale: scale)
        draw(pen)
        let (w, h) = ArtKit.pixelSize(size, scale: scale)
        return BakedImage(pixelWidth: w, pixelHeight: h, scale: scale, native: pen.recording)
    }

    func rgba(_ img: BakedImage) -> [UInt8] { [UInt8](repeating: 0, count: img.pixelWidth * img.pixelHeight * 4) }

    func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize {
        Self.measure(runs)
    }

    static func measure(_ runs: [TextRun]) -> CGSize {
        var lines: [(width: CGFloat, height: CGFloat)] = [(0, 0)]
        for r in runs {
            for (i, part) in r.text.components(separatedBy: "\n").enumerated() {
                if i > 0 { lines.append((0, 0)) }
                lines[lines.count - 1].width += CGFloat(part.count) * r.font.size * 0.5
                lines[lines.count - 1].height = max(lines[lines.count - 1].height, r.font.size * 1.25)
            }
        }
        return CGSize(width: lines.map(\.width).max() ?? 0, height: lines.map(\.height).reduce(0, +))
    }

    static func commands(_ img: BakedImage) -> [String] { (img.native as! Recording).commands }
}

final class RecordingPen: Pen {
    let scale: CGFloat
    let recording = RecordingBackend.Recording()

    init(scale: CGFloat) { self.scale = scale }

    private func log(_ s: String) { recording.commands.append(s) }
    private func describe(_ p: ArtPath) -> String { "\(p.elements)" }

    func fill(_ p: ArtPath, _ c: Color) { log("fill \(describe(p)) \(c)") }
    func stroke(_ p: ArtPath, _ c: Color, width: CGFloat) { log("stroke \(describe(p)) \(c) \(width)") }
    func linearGradient(_ p: ArtPath, colors: [Color], locations: [CGFloat]?, from: CGPoint, to: CGPoint, extend: Bool) {
        log("gradient \(describe(p)) \(colors) \(String(describing: locations)) \(from) \(to) \(extend)")
    }
    func shadowed(offset: CGSize, blur: CGFloat, color: Color, _ body: () -> Void) {
        log("shadow \(offset) \(blur) \(color) {"); body(); log("}")
    }
    func glow(_ p: ArtPath, blur: CGFloat, color: Color) { log("glow \(describe(p)) \(blur) \(color)") }
    func layer(alpha: CGFloat, _ body: () -> Void) { log("layer \(alpha) {"); body(); log("}") }
    func faded(alpha: CGFloat, _ body: () -> Void) { log("faded \(alpha) {"); body(); log("}") }
    func clipped(to p: ArtPath, _ body: () -> Void) { log("clip \(describe(p)) {"); body(); log("}") }
    func translated(by offset: CGSize, _ body: () -> Void) { log("translate \(offset) {"); body(); log("}") }
    func text(_ runs: [TextRun], shadow: TextShadow?, in rect: CGRect, maxLines: Int) {
        log("text \(runs.map(\.text)) \(String(describing: shadow)) \(rect) \(maxLines)")
    }
    func textLine(_ runs: [TextRun], in rect: CGRect, truncatesTail: Bool) {
        log("line \(runs.map(\.text)) \(rect) \(truncatesTail)")
    }
    func emoji(_ s: String, size: CGFloat, center: CGPoint) { log("emoji \(s) \(size) \(center)") }
    func setFontSmoothing(_ on: Bool) { log("smoothing \(on)") }
    func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize { RecordingBackend.measure(runs) }
}
