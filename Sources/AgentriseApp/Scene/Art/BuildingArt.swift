// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import SpriteKit
import Agentrise
import AgentriseScene

/// The building baked into bitmaps — `6535b39`'s Core Animation drawing code (`drawBuilding()/decorate()/roomBox()`)
/// moved onto CGContext. Everything here is static; the elevator cab and the server-room LEDs are
/// separate sprites so SpriteKit can move and blink them.
enum BuildingArt {
    private static let blue = NSColor(hex: 0x7CC4FF)

    // MARK: Background

    /// Gradient sky, floor slabs, rooms with their decorations and the elevator shaft, in a `layout.size`
    /// image at `scale` pixels per point (the old layer tree, minus the cab, the LEDs and the shaft label).
    static func background(_ layout: BuildingLayout, scale: CGFloat) -> SKTexture {
        ArtKit.texture(size: layout.size, scale: scale) { ctx in
            ctx.setShouldAntialias(true)
            ctx.setShouldSmoothFonts(false)   // CATextLayer text is not dilated
            sky(layout.size, ctx)
            floors(layout, scale: scale, ctx)
            for room in Room.allCases {
                for r in layout.rooms[room] ?? [] {
                    switch room {
                    case .ceoOffice:
                        roomBox(r, title: room.title, border: NSColor(hex: 0xFFC95C, alpha: 0.75), fill: NSColor(hex: 0xFFC95C, alpha: 0.07), titleColor: NSColor(hex: 0xFFD98A), ctx)
                        let door = CGRect(x: r.maxX - 34, y: r.minY + 16, width: 22, height: min(34, r.height - 24))
                        glowBorder(door, radius: 4, width: 2, color: NSColor(hex: 0xFFC95C), glow: 8, scale: scale, ctx)
                    case .pantry:
                        roomBox(r, title: room.title, border: NSColor(hex: 0x6FF0A8, alpha: 0.45), fill: NSColor(hex: 0x6FF0A8, alpha: 0.05), titleColor: NSColor(hex: 0x8FF0BB), ctx)
                    case .sleepPods:
                        roomBox(r, title: r == layout.rooms[room]?.first ? room.title : "", border: NSColor(hex: 0x968CFF, alpha: 0.4), fill: NSColor(hex: 0x5A50C8, alpha: 0.08), titleColor: NSColor(hex: 0xB8B0FF), ctx)
                    default:
                        roomBox(r, title: room.title, border: blue.withAlphaComponent(0.3), fill: blue.withAlphaComponent(0.04), titleColor: NSColor(hex: 0xB9C6FF), ctx)
                    }
                    decorate(room, r, scale: scale, ctx)
                }
            }
            shaft(layout, ctx)
        }
    }

    /// Server-room rack LED positions (centres, layout coordinates, y down) with their colour and blink half-period.
    static func ledSpecs(_ layout: BuildingLayout) -> [(center: CGPoint, color: NSColor, period: TimeInterval)] {
        var out: [(CGPoint, NSColor, TimeInterval)] = []
        let colors = [NSColor(hex: 0x66FF66), NSColor(hex: 0x77CCFF), NSColor(hex: 0xFFCC66)]
        for r in layout.rooms[.serverRoom] ?? [] {
            for i in 0..<2 {
                let rack = rackFrame(r, i)
                for j in 0..<3 {
                    let led = CGRect(x: rack.minX + 4, y: rack.minY + 5 + CGFloat(j) * 9, width: 4, height: 4)
                    out.append((CGPoint(x: led.midX, y: led.midY), colors[j], 0.5 + Double(j) * 0.2))
                }
            }
        }
        return out
    }

    /// A 4×4 pt dot (the old LED layer, cornerRadius 2).
    static func led(color: NSColor, scale: CGFloat) -> CGImage {
        ArtKit.image(size: CGSize(width: 4, height: 4), scale: scale) { ctx in
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    // MARK: Cab

    /// The cab's body (old layer: shaft width − 8 by 40, centred 14 pt above the floor stop).
    static func cabBody(_ layout: BuildingLayout) -> CGSize { CGSize(width: layout.elevator.width - 8, height: 40) }
    /// Transparent border around the body that leaves room for the glow.
    static let cabMargin: CGFloat = 20

    static func cab(_ layout: BuildingLayout, scale: CGFloat) -> SKTexture {
        let body = cabBody(layout), m = cabMargin
        let size = CGSize(width: body.width + 2 * m, height: body.height + 2 * m)
        return ArtKit.texture(size: size, scale: scale) { ctx in
            let r = CGRect(x: m, y: m, width: body.width, height: body.height)
            ctx.setShadow(offset: .zero, blur: ArtKit.shadowBlur(radius: 8, scale: scale), color: blue.withAlphaComponent(0.9).cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            box(r, radius: 6, border: blue, borderWidth: 1, fill: blue.withAlphaComponent(0.25), ctx)
            ctx.endTransparencyLayer()
        }
    }

    // MARK: Pieces

    private static func sky(_ size: CGSize, _ ctx: CGContext) {
        let colors = [NSColor(hex: 0x0A0E26), NSColor(hex: 0x111640), NSColor(hex: 0x16124A)].map(\.cgColor) as CFArray
        let g = CGGradient(colorsSpace: ArtKit.colorSpace, colors: colors, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func floors(_ L: BuildingLayout, scale: CGFloat, _ ctx: CGContext) {
        for (f, r) in L.floors.sorted(by: { $0.key < $1.key }) {
            let edge = f == 0 ? NSColor(hex: 0x4A3F9E) : NSColor(hex: 0x3A4596)
            // The slab's hard shadow (shadowRadius 0, offset +5 in the old flipped layer tree) lands 5 pt above it.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 5 * scale), blur: 0, color: NSColor(hex: 0x1C2350).cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            box(r, radius: 11, border: edge, borderWidth: 1,
                fill: (f == 0 ? NSColor(hex: 0x120E30) : NSColor(hex: 0x141A3F)).withAlphaComponent(0.92), ctx)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            // The floor tag: rounded at its top-left and bottom-right corners only.
            let tag = CGRect(x: r.minX, y: r.minY, width: 24, height: 15)
            let radius: CGFloat = 6
            let p = CGMutablePath()
            p.move(to: CGPoint(x: tag.minX + radius, y: tag.minY))
            p.addLine(to: CGPoint(x: tag.maxX, y: tag.minY))
            p.addLine(to: CGPoint(x: tag.maxX, y: tag.maxY - radius))
            p.addArc(tangent1End: CGPoint(x: tag.maxX, y: tag.maxY), tangent2End: CGPoint(x: tag.maxX - radius, y: tag.maxY), radius: radius)
            p.addLine(to: CGPoint(x: tag.minX, y: tag.maxY))
            p.addLine(to: CGPoint(x: tag.minX, y: tag.minY + radius))
            p.addArc(tangent1End: CGPoint(x: tag.minX, y: tag.minY), tangent2End: CGPoint(x: tag.minX + radius, y: tag.minY), radius: radius)
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(edge.cgColor)
            ctx.fillPath()
            ArtKit.drawLabel(f == 0 ? "B1" : "\(f)F", size: 9, color: NSColor(hex: 0xDFE6FF), weight: .bold, center: CGPoint(x: tag.midX, y: tag.midY), ctx: ctx)
        }
    }

    /// A layer-like box: background clipped to the corner radius, border drawn inside the bounds.
    private static func box(_ r: CGRect, radius: CGFloat, border: NSColor?, borderWidth: CGFloat, fill: NSColor?, _ ctx: CGContext) {
        let rad = min(radius, min(r.width, r.height) / 2)
        if let fill {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        if let border, borderWidth > 0 {
            let inner = r.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
            let ir = max(0, rad - borderWidth / 2)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: ir, cornerHeight: ir, transform: nil))
            ctx.setStrokeColor(border.cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.strokePath()
        }
    }

    /// A border-only box whose Core Animation shadow follows the border's alpha: the glow is the
    /// shadow of the stroke itself (see `ArtKit.blurPerShadowRadius`).
    private static func glowBorder(_ r: CGRect, radius: CGFloat, width: CGFloat, color: NSColor, glow: CGFloat, scale: CGFloat, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: ArtKit.shadowBlur(radius: glow, scale: scale), color: color.cgColor)
        box(r, radius: radius, border: color, borderWidth: width, fill: nil, ctx)
        ctx.restoreGState()
    }

    private static func roomBox(_ r: CGRect, title: String, border: NSColor, fill: NSColor, titleColor: NSColor, _ ctx: CGContext) {
        box(r, radius: 8, border: border, borderWidth: 1, fill: fill, ctx)
        guard !title.isEmpty else { return }
        let size = ArtKit.labelSize(title, size: 10.5, weight: .semibold)
        ArtKit.drawLabel(title, size: 10.5, color: titleColor, weight: .semibold,
                         center: CGPoint(x: r.minX + 7 + size.width / 2, y: r.minY + 4 + size.height / 2), ctx: ctx)
    }

    private static func rackFrame(_ r: CGRect, _ i: Int) -> CGRect {
        CGRect(x: r.maxX - 22 - CGFloat(i) * 18, y: r.minY + 6, width: 12, height: min(40, r.height - 12))
    }

    private static func decorate(_ room: Room, _ r: CGRect, scale: CGFloat, _ ctx: CGContext) {
        switch room {
        case .archive:
            let shelf = CGRect(x: r.minX + 8, y: r.minY + 20, width: r.width - 16, height: 12)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: shelf, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.clip()
            ctx.setAlpha(0.7)
            // Repeating 16×12 tile: 6 pt 3A4596, 3 pt 6B5BD6, 5 pt 2C3A7A, 2 pt gap.
            var x = shelf.minX
            while x < shelf.maxX {
                for (dx, w, hex) in [(0.0, 6.0, 0x3A4596), (6.0, 3.0, 0x6B5BD6), (9.0, 5.0, 0x2C3A7A)] as [(CGFloat, CGFloat, UInt32)] {
                    ctx.setFillColor(NSColor(hex: hex).cgColor)
                    ctx.fill(CGRect(x: x + dx, y: shelf.minY, width: w, height: shelf.height))
                }
                x += 16
            }
            ctx.restoreGState()
        case .meeting:
            let table = CGRect(x: r.midX - r.width * 0.25, y: r.minY + 22, width: r.width * 0.5, height: 12)
            box(table, radius: 6, border: NSColor(hex: 0x4A56A8), borderWidth: 1, fill: NSColor(hex: 0x22295A), ctx)
        case .whiteboard:
            box(CGRect(x: r.maxX - 44, y: r.minY + 6, width: 36, height: 22), radius: 2, border: nil, borderWidth: 0,
                fill: NSColor(hex: 0xEEEEFF, alpha: 0.75), ctx)
        case .intel:
            let globe = CGRect(x: r.maxX - 32, y: r.minY + 5, width: 22, height: 22)
            glowBorder(globe, radius: 11, width: 1, color: NSColor(hex: 0x77CCFF), glow: 6, scale: scale, ctx)
        case .serverRoom:
            for i in 0..<2 {
                box(rackFrame(r, i), radius: 2, border: nil, borderWidth: 0, fill: NSColor(hex: 0x1B2147), ctx)
            }
        case .mailroom:
            let tube = CGRect(x: r.maxX - 22, y: r.minY, width: 12, height: min(44, r.height - 8))
            box(tube, radius: 6, border: NSColor(hex: 0x4C5FD0), borderWidth: 1.5, fill: blue.withAlphaComponent(0.08), ctx)
        case .desks:
            let count = max(2, Int(r.width / 70))
            for i in 0..<count {
                let w = (r.width - 20) / CGFloat(count)
                let d = CGRect(x: r.minX + 10 + CGFloat(i) * w + w * 0.2, y: r.maxY - 12, width: w * 0.6, height: 6)
                box(d, radius: 2, border: nil, borderWidth: 0, fill: NSColor(hex: 0x2A3470), ctx)
            }
        default:
            break
        }
    }

    private static func shaft(_ L: BuildingLayout, _ ctx: CGContext) {
        let r = L.elevator
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.clip()
        let colors = [blue.withAlphaComponent(0.12), NSColor(hex: 0xB48CFF, alpha: 0.12)].map(\.cgColor) as CFArray
        let g = CGGradient(colorsSpace: ArtKit.colorSpace, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
        ctx.restoreGState()
        box(r, radius: 8, border: NSColor(hex: 0x6A78D8), borderWidth: 1, fill: nil, ctx)
    }

    // MARK: Elevator label

    /// The shaft's "电梯" label, centred on the shaft's midpoint. It is a separate sprite because the old
    /// label layer sat above the travelling cab.
    static let elevatorLabelText = "电梯"
    static var elevatorLabelSize: CGSize { ArtKit.labelSize(elevatorLabelText, size: 9, weight: .semibold) }

    static func elevatorLabel(scale: CGFloat) -> SKTexture {
        let size = elevatorLabelSize
        return ArtKit.texture(size: size, scale: scale) { ctx in
            ctx.setShouldSmoothFonts(false)
            ArtKit.drawLabel(elevatorLabelText, size: 9, color: NSColor(hex: 0x8F9BE0), weight: .semibold,
                             center: CGPoint(x: size.width / 2, y: size.height / 2), ctx: ctx)
        }
    }
}
