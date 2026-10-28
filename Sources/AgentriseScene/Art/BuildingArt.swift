// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Agentrise

/// The building baked into bitmaps — `6535b39`'s Core Animation drawing code (`drawBuilding()/decorate()/roomBox()`)
/// replayed on a `Pen`. Everything here is static; the elevator cab and the server-room LEDs are
/// separate sprites so the scene can move and blink them.
package enum BuildingArt {
    private static let blue = Color(hex: 0x7CC4FF)

    // MARK: Background

    /// Gradient sky, floor slabs, rooms with their decorations and the elevator shaft, in a `layout.size`
    /// image at `scale` pixels per point (the old layer tree, minus the cab, the LEDs and the shaft label).
    package static func background(_ layout: BuildingLayout, scale: CGFloat, backend: ArtBackend) -> BakedImage {
        backend.bake(size: layout.size, scale: scale) { pen in
            pen.setFontSmoothing(false)   // CATextLayer text is not dilated
            sky(layout.size, pen)
            floors(layout, pen)
            for room in Room.allCases {
                for r in layout.rooms[room] ?? [] {
                    switch room {
                    case .ceoOffice:
                        roomBox(r, title: room.title, border: Color(hex: 0xFFC95C, alpha: 0.75), fill: Color(hex: 0xFFC95C, alpha: 0.07), titleColor: Color(hex: 0xFFD98A), pen)
                        let door = CGRect(x: r.maxX - 34, y: r.minY + 16, width: 22, height: min(34, r.height - 24))
                        glowBorder(door, radius: 4, width: 2, color: Color(hex: 0xFFC95C), glow: 8, pen)
                    case .pantry:
                        roomBox(r, title: room.title, border: Color(hex: 0x6FF0A8, alpha: 0.45), fill: Color(hex: 0x6FF0A8, alpha: 0.05), titleColor: Color(hex: 0x8FF0BB), pen)
                    case .sleepPods:
                        roomBox(r, title: r == layout.rooms[room]?.first ? room.title : "", border: Color(hex: 0x968CFF, alpha: 0.4), fill: Color(hex: 0x5A50C8, alpha: 0.08), titleColor: Color(hex: 0xB8B0FF), pen)
                    default:
                        roomBox(r, title: room.title, border: blue.withAlpha(0.3), fill: blue.withAlpha(0.04), titleColor: Color(hex: 0xB9C6FF), pen)
                    }
                    decorate(room, r, pen)
                }
            }
            shaft(layout, pen)
        }
    }

    /// Server-room rack LED positions (centres, layout coordinates, y down) with their colour and blink half-period.
    package static func ledSpecs(_ layout: BuildingLayout) -> [(center: CGPoint, color: Color, period: TimeInterval)] {
        var out: [(CGPoint, Color, TimeInterval)] = []
        let colors = [Color(hex: 0x66FF66), Color(hex: 0x77CCFF), Color(hex: 0xFFCC66)]
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
    package static func led(color: Color, scale: CGFloat, backend: ArtBackend) -> BakedImage {
        backend.bake(size: CGSize(width: 4, height: 4), scale: scale) { pen in
            pen.fill(.ellipse(in: CGRect(x: 0, y: 0, width: 4, height: 4)), color)
        }
    }

    // MARK: Cab

    /// The cab's body (old layer: shaft width − 8 by 40, centred 14 pt above the floor stop).
    package static func cabBody(_ layout: BuildingLayout) -> CGSize { CGSize(width: layout.elevator.width - 8, height: 40) }
    /// Transparent border around the body that leaves room for the glow.
    package static let cabMargin: CGFloat = 20

    package static func cab(_ layout: BuildingLayout, scale: CGFloat, backend: ArtBackend) -> BakedImage {
        let body = cabBody(layout), m = cabMargin
        let size = CGSize(width: body.width + 2 * m, height: body.height + 2 * m)
        return backend.bake(size: size, scale: scale) { pen in
            let r = CGRect(x: m, y: m, width: body.width, height: body.height)
            pen.shadowed(offset: .zero, blur: 8, color: blue.withAlpha(0.9)) {
                pen.layer(alpha: 1) {
                    box(r, radius: 6, border: blue, borderWidth: 1, fill: blue.withAlpha(0.25), pen)
                }
            }
        }
    }

    // MARK: Pieces

    private static func sky(_ size: CGSize, _ pen: Pen) {
        // The old gradient filled the whole bitmap unclipped: the path reaches past every edge.
        pen.linearGradient(.rect(CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)), colors: [Color(hex: 0x0A0E26), Color(hex: 0x111640), Color(hex: 0x16124A)],
                           locations: [0, 0.5, 1], from: .zero, to: CGPoint(x: 0, y: size.height))
    }

    private static func floors(_ L: BuildingLayout, _ pen: Pen) {
        for (f, r) in L.floors.sorted(by: { $0.key < $1.key }) {
            let edge = f == 0 ? Color(hex: 0x4A3F9E) : Color(hex: 0x3A4596)
            // The slab's hard shadow (shadowRadius 0, offset +5 in the old flipped layer tree) lands 5 pt above it.
            pen.shadowed(offset: CGSize(width: 0, height: -5), blur: 0, color: Color(hex: 0x1C2350)) {
                pen.layer(alpha: 1) {
                    box(r, radius: 11, border: edge, borderWidth: 1,
                        fill: (f == 0 ? Color(hex: 0x120E30) : Color(hex: 0x141A3F)).withAlpha(0.92), pen)
                }
            }
            // The floor tag: rounded at its top-left and bottom-right corners only.
            let tag = CGRect(x: r.minX, y: r.minY, width: 24, height: 15)
            let radius: CGFloat = 6
            var p = ArtPath()
            p.move(to: CGPoint(x: tag.minX + radius, y: tag.minY))
            p.line(to: CGPoint(x: tag.maxX, y: tag.minY))
            p.line(to: CGPoint(x: tag.maxX, y: tag.maxY - radius))
            p.arc(tangent1End: CGPoint(x: tag.maxX, y: tag.maxY), tangent2End: CGPoint(x: tag.maxX - radius, y: tag.maxY), radius: radius)
            p.line(to: CGPoint(x: tag.minX, y: tag.maxY))
            p.line(to: CGPoint(x: tag.minX, y: tag.minY + radius))
            p.arc(tangent1End: CGPoint(x: tag.minX, y: tag.minY), tangent2End: CGPoint(x: tag.minX + radius, y: tag.minY), radius: radius)
            p.close()
            pen.fill(p, edge)
            ArtKit.drawLabel(f == 0 ? "B1" : "\(f)F", font: FontSpec(size: 9, weight: .bold), color: Color(hex: 0xDFE6FF),
                             center: CGPoint(x: tag.midX, y: tag.midY), pen: pen)
        }
    }

    /// A layer-like box: background clipped to the corner radius, border drawn inside the bounds.
    private static func box(_ r: CGRect, radius: CGFloat, border: Color?, borderWidth: CGFloat, fill: Color?, _ pen: Pen) {
        let rad = min(radius, min(r.width, r.height) / 2)
        if let fill { pen.fill(.roundedRect(r, radius: rad), fill) }
        if let border, borderWidth > 0 {
            let inner = r.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
            let ir = max(0, rad - borderWidth / 2)
            // Round joins draw like the old default (miter) joins here: every corner is an arc (ir > 0).
            pen.stroke(.roundedRect(inner, radius: ir), border, width: borderWidth)
        }
    }

    /// A border-only box whose Core Animation shadow follows the border's alpha: the glow is the
    /// shadow of the stroke itself (see `ArtKit.blurPerShadowRadius`).
    private static func glowBorder(_ r: CGRect, radius: CGFloat, width: CGFloat, color: Color, glow: CGFloat, _ pen: Pen) {
        pen.shadowed(offset: .zero, blur: glow, color: color) {
            box(r, radius: radius, border: color, borderWidth: width, fill: nil, pen)
        }
    }

    private static func roomBox(_ r: CGRect, title: String, border: Color, fill: Color, titleColor: Color, _ pen: Pen) {
        box(r, radius: 8, border: border, borderWidth: 1, fill: fill, pen)
        guard !title.isEmpty else { return }
        let font = FontSpec(size: 10.5, weight: .semibold)
        let size = ArtKit.labelSize(title, font: font, using: pen)
        ArtKit.drawLabel(title, font: font, color: titleColor,
                         center: CGPoint(x: r.minX + 7 + size.width / 2, y: r.minY + 4 + size.height / 2), pen: pen)
    }

    private static func rackFrame(_ r: CGRect, _ i: Int) -> CGRect {
        CGRect(x: r.maxX - 22 - CGFloat(i) * 18, y: r.minY + 6, width: 12, height: min(40, r.height - 12))
    }

    private static func decorate(_ room: Room, _ r: CGRect, _ pen: Pen) {
        switch room {
        case .archive:
            let shelf = CGRect(x: r.minX + 8, y: r.minY + 20, width: r.width - 16, height: 12)
            pen.clipped(to: .roundedRect(shelf, radius: 2)) {
                // Repeating 16×12 tile: 6 pt 3A4596, 3 pt 6B5BD6, 5 pt 2C3A7A, 2 pt gap; each strip at 0.7.
                // (Not 0.7 in the colours: at partly covered pixels that rounds differently.)
                pen.faded(alpha: 0.7) {
                    var x = shelf.minX
                    while x < shelf.maxX {
                        for (dx, w, hex) in [(0.0, 6.0, 0x3A4596), (6.0, 3.0, 0x6B5BD6), (9.0, 5.0, 0x2C3A7A)] as [(CGFloat, CGFloat, UInt32)] {
                            pen.fill(.rect(CGRect(x: x + dx, y: shelf.minY, width: w, height: shelf.height)), Color(hex: hex))
                        }
                        x += 16
                    }
                }
            }
        case .meeting:
            let table = CGRect(x: r.midX - r.width * 0.25, y: r.minY + 22, width: r.width * 0.5, height: 12)
            box(table, radius: 6, border: Color(hex: 0x4A56A8), borderWidth: 1, fill: Color(hex: 0x22295A), pen)
        case .whiteboard:
            box(CGRect(x: r.maxX - 44, y: r.minY + 6, width: 36, height: 22), radius: 2, border: nil, borderWidth: 0,
                fill: Color(hex: 0xEEEEFF, alpha: 0.75), pen)
        case .intel:
            let globe = CGRect(x: r.maxX - 32, y: r.minY + 5, width: 22, height: 22)
            glowBorder(globe, radius: 11, width: 1, color: Color(hex: 0x77CCFF), glow: 6, pen)
        case .serverRoom:
            for i in 0..<2 {
                box(rackFrame(r, i), radius: 2, border: nil, borderWidth: 0, fill: Color(hex: 0x1B2147), pen)
            }
        case .mailroom:
            let tube = CGRect(x: r.maxX - 22, y: r.minY, width: 12, height: min(44, r.height - 8))
            box(tube, radius: 6, border: Color(hex: 0x4C5FD0), borderWidth: 1.5, fill: blue.withAlpha(0.08), pen)
        case .desks:
            let count = max(2, Int(r.width / 70))
            for i in 0..<count {
                let w = (r.width - 20) / CGFloat(count)
                let d = CGRect(x: r.minX + 10 + CGFloat(i) * w + w * 0.2, y: r.maxY - 12, width: w * 0.6, height: 6)
                box(d, radius: 2, border: nil, borderWidth: 0, fill: Color(hex: 0x2A3470), pen)
            }
        default:
            break
        }
    }

    private static func shaft(_ L: BuildingLayout, _ pen: Pen) {
        let r = L.elevator
        pen.linearGradient(.roundedRect(r, radius: 8), colors: [blue.withAlpha(0.12), Color(hex: 0xB48CFF, alpha: 0.12)], locations: [0, 1],
                           from: CGPoint(x: 0, y: r.minY), to: CGPoint(x: 0, y: r.maxY), extend: false)
        box(r, radius: 8, border: Color(hex: 0x6A78D8), borderWidth: 1, fill: nil, pen)
    }

    // MARK: Elevator label

    /// The shaft's "电梯" label, centred on the shaft's midpoint. It is a separate sprite because the old
    /// label layer sat above the travelling cab.
    package static let elevatorLabelText = "电梯"
    private static let elevatorLabelFont = FontSpec(size: 9, weight: .semibold)
    package static func elevatorLabelSize(_ m: TextMeasuring) -> CGSize { ArtKit.labelSize(elevatorLabelText, font: elevatorLabelFont, using: m) }

    package static func elevatorLabel(scale: CGFloat, backend: ArtBackend) -> BakedImage {
        let size = elevatorLabelSize(backend)
        return backend.bake(size: size, scale: scale) { pen in
            pen.setFontSmoothing(false)
            ArtKit.drawLabel(elevatorLabelText, font: elevatorLabelFont, color: Color(hex: 0x8F9BE0),
                             center: CGPoint(x: size.width / 2, y: size.height / 2), pen: pen)
        }
    }
}
