// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics

enum DoorSide { case left, right }

enum TowerOrientation { case landscape, portrait
    static func of(_ size: CGSize) -> TowerOrientation { size.width >= size.height * 1.1 ? .landscape : .portrait }
}

/// Geometry of the building in a top-left-origin coordinate space.
struct BuildingLayout {
    let size: CGSize
    let orientation: TowerOrientation
    let header: CGRect
    let panel: CGRect
    let building: CGRect
    let floors: [Int: CGRect]
    let rooms: [Room: [CGRect]]
    let elevator: CGRect
    /// Robot scale for this window size (1 = 60x70 pt robot).
    let unit: CGFloat

    /// The floor whose slab band contains `p.y`; between/outside floors, the vertically nearest one.
    func floorOf(_ p: CGPoint) -> Int {
        func gap(_ r: CGRect) -> CGFloat { p.y < r.minY ? r.minY - p.y : (p.y > r.maxY ? p.y - r.maxY : 0) }
        return floors.min { (gap($0.value), $0.key) < (gap($1.value), $1.key) }?.key ?? 2
    }

    func elevatorStop(floor: Int) -> CGPoint {
        let f = floors[floor] ?? .zero
        return CGPoint(x: elevator.midX, y: f.maxY - 18)
    }

    /// Waiting point just outside the shaft on the given side, standing on the floor slab.
    func elevatorDoor(floor: Int, side: DoorSide) -> CGPoint {
        let f = floors[floor] ?? .zero
        let x = side == .left ? elevator.minX - 14 : elevator.maxX + 14
        return CGPoint(x: x, y: f.maxY - 18)
    }

    func doorSide(for p: CGPoint) -> DoorSide { p.x < elevator.midX ? .left : .right }

    static func make(size: CGSize) -> BuildingLayout {
        let o = TowerOrientation.of(size)
        let pad: CGFloat = 12
        let header = CGRect(x: 0, y: 0, width: size.width, height: 34)
        var panel: CGRect
        var building: CGRect
        if o == .landscape {
            let bw = max(300, size.width * 0.72)
            building = CGRect(x: pad, y: header.maxY + 8, width: bw - pad * 1.5, height: size.height - header.maxY - 8 - pad)
            panel = CGRect(x: building.maxX + pad, y: header.maxY + 8, width: size.width - building.maxX - pad * 2, height: building.height)
        } else {
            panel = CGRect(x: pad, y: header.maxY + 6, width: size.width - pad * 2, height: 64)
            building = CGRect(x: pad, y: panel.maxY + 8, width: size.width - pad * 2, height: size.height - panel.maxY - 8 - pad)
        }
        // Floors: 3F, 2F, 1F equal; B1 a bit shorter.
        let gap: CGFloat = 12
        let weights: [(Int, CGFloat)] = [(3, 0.92), (2, 1.32), (1, 1), (0, 0.72)]
        let total = weights.reduce(0) { $0 + $1.1 }
        let usable = building.height - gap * 3
        var y = building.minY
        var floors: [Int: CGRect] = [:]
        for (f, w) in weights {
            let h = usable * w / total
            floors[f] = CGRect(x: building.minX, y: y, width: building.width, height: h)
            y += h + gap
        }
        let ew = max(34, building.width * (o == .landscape ? 0.07 : 0.1))
        let elevator = CGRect(x: building.midX - ew / 2, y: building.minY, width: ew, height: building.height)
        let inset: CGFloat = 10
        func halves(_ f: CGRect) -> (CGRect, CGRect) {
            let top = f.minY + 18, h = f.height - 18 - inset
            let l = CGRect(x: f.minX + inset, y: top, width: elevator.minX - inset - f.minX - inset, height: h)
            let r = CGRect(x: elevator.maxX + inset, y: top, width: f.maxX - inset - elevator.maxX - inset, height: h)
            return (l, r)
        }
        func split(_ r: CGRect, _ fraction: CGFloat) -> (CGRect, CGRect) {
            let g: CGFloat = 8
            if o == .landscape {
                let w1 = (r.width - g) * fraction
                return (CGRect(x: r.minX, y: r.minY, width: w1, height: r.height),
                        CGRect(x: r.minX + w1 + g, y: r.minY, width: r.width - w1 - g, height: r.height))
            } else {
                let h1 = (r.height - g) * fraction
                return (CGRect(x: r.minX, y: r.minY, width: r.width, height: h1),
                        CGRect(x: r.minX, y: r.minY + h1 + g, width: r.width, height: r.height - h1 - g))
            }
        }
        var rooms: [Room: [CGRect]] = [:]
        let (l3, r3) = halves(floors[3]!)
        rooms[.meeting] = [l3]; rooms[.ceoOffice] = [r3]
        let (l2, r2) = halves(floors[2]!)
        rooms[.desks] = [l2]
        let (wb, intel) = split(r2, 0.48)
        rooms[.whiteboard] = [wb]; rooms[.intel] = [intel]
        let (l1, r1) = halves(floors[1]!)
        let (arch, pantry) = split(l1, 0.5)
        let (mail, server) = split(r1, 0.45)
        rooms[.archive] = [arch]; rooms[.pantry] = [pantry]; rooms[.mailroom] = [mail]; rooms[.serverRoom] = [server]
        let (l0, r0) = halves(floors[0]!)
        rooms[.sleepPods] = [l0, r0]
        let unit = max(0.5, min(1.25, floors[1]!.height / 150))
        return BuildingLayout(size: size, orientation: o, header: header, panel: panel, building: building,
                              floors: floors, rooms: rooms, elevator: elevator, unit: unit)
    }
}

enum SlotAllocator {
    /// Grid positions (bottom-center of each robot) inside the room rects.
    /// Shrinks down to minScale when crowded; never overlaps.
    static func slots(in rects: [CGRect], count: Int, base: CGSize, minCellWidth: CGFloat = 0, minScale: CGFloat = 0.42) -> (points: [CGPoint], scale: CGFloat) {
        guard count > 0, !rects.isEmpty else { return ([], 1) }
        var scale: CGFloat = 1
        while true {
            let cw = max(base.width * 1.3, minCellWidth) * scale, ch = base.height * scale * 1.18 + 22 * scale
            var pts: [CGPoint] = []
            for r in rects {
                let inner = CGRect(x: r.minX + 6, y: r.minY + 30 * scale, width: r.width - 12, height: r.height - 30 * scale - 18 * scale)
                let cols = Int(inner.width / cw), rows = Int((inner.height + ch * 0.25) / ch)   // 0 = robot doesn't fit yet
                // Fill from the bottom row up so robots stand on the floor.
                guard cols > 0, rows > 0 else { continue }
                for row in 0..<rows {
                    for col in 0..<cols {
                        let used = CGFloat(cols) * cw
                        let x = inner.minX + (inner.width - used) / 2 + cw * (CGFloat(col) + 0.5)
                        let y = inner.maxY - CGFloat(row) * ch
                        pts.append(CGPoint(x: x, y: y))
                    }
                }
            }
            // Interleave rects (left/right halves) so both sides fill evenly.
            if pts.count >= count || scale <= minScale {
                if pts.isEmpty { pts = rects.map { CGPoint(x: $0.midX, y: $0.maxY) } }
                if pts.count < count { // over capacity even at min scale: wrap around (slight overlap is unavoidable)
                    var extra: [CGPoint] = []
                    var i = 0
                    while pts.count + extra.count < count { let p = pts[i % pts.count]; extra.append(CGPoint(x: p.x + 8, y: p.y - 6)); i += 1 }
                    pts += extra
                }
                return (Array(pts.prefix(count)), scale)
            }
            scale -= 0.05
        }
    }
}
