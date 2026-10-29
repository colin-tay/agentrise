// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Agentrise

/// One picture in a comparison scene: baked images stacked at their places, as the scene would show them at rest.
package struct ComparisonTile {
    package struct Layer {
        package let image: BakedImage
        /// The image's top-left corner in the tile, in points.
        package let origin: CGPoint
        /// Multiplies the image's colour, like a sprite's `color` at `colorBlendFactor` 1 (the halo's team colour).
        package let tint: Color?
    }

    /// Points.
    package let size: CGSize
    package let layers: [Layer]

    package init(size: CGSize, layers: [(BakedImage, CGPoint, Color?)]) {
        self.size = size
        self.layers = layers.map { Layer(image: $0.0, origin: $0.1, tint: $0.2) }
    }

    /// A tile of one image.
    package init(_ image: BakedImage) {
        self.init(size: CGSize(width: CGFloat(image.pixelWidth) / image.scale, height: CGFloat(image.pixelHeight) / image.scale),
                  layers: [(image, .zero, nil)])
    }
}

/// Fixed scenes every platform's art backend renders the same way (`ArtGallery`), so CI can put the macOS and
/// Windows pictures side by side. Each scene's tiles are laid out in a grid over the window's background colour.
package enum ComparisonScenes {
    /// Pixels per point of every scene (both platforms render at 2×, so the pictures line up).
    package static let scale: CGFloat = 2

    package static let all: [(name: String, draw: (ArtBackend) -> [ComparisonTile])] = [
        ("1-building-landscape", { building(CGSize(width: 1200, height: 800), $0) }),
        ("2-building-portrait", { building(CGSize(width: 700, height: 1100), $0) }),
        ("3-bosses", bosses),
        ("4-labels", labels),
        ("5-emoji", emoji),
    ]

    // MARK: Scenes

    /// The background with the LEDs, the shaft label and the cab at the ground floor, as the scene stacks them.
    private static func building(_ size: CGSize, _ backend: ArtBackend) -> [ComparisonTile] {
        let layout = BuildingLayout.make(size: size)
        var layers: [(BakedImage, CGPoint, Color?)] = [(BuildingArt.background(layout, scale: scale, backend: backend), .zero, nil)]
        var leds: [Color: BakedImage] = [:]
        for spec in BuildingArt.ledSpecs(layout) {
            let led = leds[spec.color] ?? BuildingArt.led(color: spec.color, scale: scale, backend: backend)
            leds[spec.color] = led
            layers.append((led, CGPoint(x: spec.center.x - 2, y: spec.center.y - 2), nil))
        }
        let ground = layout.floors.keys.min() ?? 0
        let stop = layout.elevatorStop(floor: ground), cab = BuildingArt.cabSize(layout)
        layers.append((BuildingArt.cab(layout, scale: scale, backend: backend),
                       CGPoint(x: stop.x - cab.width / 2, y: stop.y - 14 - cab.height / 2), nil))
        let label = BuildingArt.elevatorLabelSize(backend)
        layers.append((BuildingArt.elevatorLabel(scale: scale, backend: backend),
                       CGPoint(x: layout.elevator.midX - label.width / 2, y: layout.elevator.midY - label.height / 2), nil))
        return [ComparisonTile(size: size, layers: layers)]
    }

    /// Three bosses of different rank, team and face, each with its name plate, assembled from the parts at rest.
    private static func bosses(_ backend: ArtBackend) -> [ComparisonTile] {
        let art = RobotArt(scale: scale, backend: backend)
        let cast: [(Rank, Int, RobotFace, Bool, String)] = [
            (.seniorDirector, 0, .happy, true, "修复登录"), (.seniorEngineer, 1, .waiting, false, "Review PR"),
            (.newGrad, 2, .error, false, "写单测")]
        return cast.map { rank, team, face, lark, title in
            let look = RobotLook(kind: .boss(rank), teamIndex: team, larkSession: lark)
            let name = "\(Team.glyph(team)) \(title)\n\(rank.title)"
            let nameSize = art.nameImageSize(name, small: false)
            // The halo's frame (80 pt wide, from x −10) is the widest part.
            let width = max(80, nameSize.width), height = max(96, 82 - RobotArt.namePadding + nameSize.height)
            let o = CGPoint(x: (width - 60) / 2, y: 0)   // the robot canvas's origin in the tile
            func at(_ part: RobotPart) -> CGPoint {
                let f = art.frame(part)
                return CGPoint(x: o.x + f.minX, y: o.y + f.minY)
            }
            var parts: [RobotPart] = [.halo, .ears, .head(look), .eyes(face)]
            if look.hasHeadOverlay { parts.append(.headOverlay(look)) }
            parts += [.ring, .leftHand, .rightHand, .torso(look)]
            if lark { parts.append(.larkBadge) }
            var layers = parts.map { (art.image($0), at($0), $0 == .halo ? look.teamColor : nil) }
            layers.insert((art.name(name, small: false, stripe: rank.stripe),
                           CGPoint(x: o.x + 30 - nameSize.width / 2, y: 82 - RobotArt.namePadding), nil), at: parts.firstIndex(of: .torso(look))! + 1)
            return ComparisonTile(size: CGSize(width: width, height: height), layers: layers)
        }
    }

    /// Name plates (Chinese, a cut-off long name, small labels), every bubble with its glow, the door sign, the
    /// header line and a tooltip with a truncated row.
    private static func labels(_ backend: ArtBackend) -> [ComparisonTile] {
        let art = RobotArt(scale: scale, backend: backend)
        func bossName(_ title: String, team: Int, rank: Rank) -> String {
            let t = title.count > 9 ? String(title.prefix(8)) + "…" : title
            return "\(Team.glyph(team)) \(t)\n\(rank.title)"
        }
        var tiles = [
            ComparisonTile(art.name(bossName("修复登录", team: 0, rank: .seniorDirector), small: false, stripe: Rank.seniorDirector.stripe)),
            ComparisonTile(art.name("⚡ 修复登录", small: false, stripe: nil)),
            ComparisonTile(art.name(bossName("重构整个支付网关的回调处理逻辑", team: 1, rank: .seniorEngineer), small: false,
                                    stripe: Rank.seniorEngineer.stripe)),
            ComparisonTile(art.name("✚ 一个特别特别特别特别特别特别长的名字", small: false, stripe: nil)),
            ComparisonTile(art.name("Explore", small: true, stripe: nil)),
            ComparisonTile(art.name("外包·跑一遍完整的测试套件", small: true, stripe: nil)),
        ]
        let bubbles: [(String, Color, Bool)] = [
            ("等你回复", Color(hex: 0xFFC95C), true), ("✓ 做完了", Color(hex: 0x1F8F57), false), ("出错了", Color(hex: 0xD84545), true),
            (Activity.coding.label, Color(hex: 0x24477A), false), ("等你回复\n第二行", Color(hex: 0xFFC95C), true)]
        for (text, color, glows) in bubbles {
            let body = art.bubble(text, color: color), pad = RobotArt.bubbleGlowPadding
            let size = art.bubbleSize(text)
            var layers: [(BakedImage, CGPoint, Color?)] = []
            if glows { layers.append((art.bubbleGlow(text, color: color), .zero, nil)) }
            layers.append((body, CGPoint(x: pad, y: pad), nil))
            tiles.append(ComparisonTile(size: CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad), layers: layers))
        }
        tiles.append(ComparisonTile(art.doorSign()))

        // The header (one line of runs, `textLine`) and a tooltip whose long row is cut with an ellipsis.
        var runs: [TextRun] = []
        func add(_ t: String, _ c: Color, bold: Bool = false) { runs.append(TextRun(t, font: FontSpec(size: 12, weight: bold ? .heavy : .medium), color: c)) }
        add("AGENTRISE    ", Color(r: 1, g: 1, b: 1), bold: true)
        add("在岗 3    ", Color(hex: 0x9FB3FF))
        add("等你 1    ", Color(hex: 0xFFC95C), bold: true)
        add("完成 2    ", Color(hex: 0x6FF0A8))
        add("睡觉 0", Color(hex: 0xB8B0FF))
        let m = backend.measure(runs, maxWidth: .infinity, maxLines: 0)
        let header = CGSize(width: max(1, ceil(m.width)), height: max(1, ceil(m.height)))
        tiles.append(ComparisonTile(backend.bake(size: header, scale: scale) {
            $0.textLine(runs, in: CGRect(origin: .zero, size: header), truncatesTail: false)
        }))
        let lines = ["⚡ 修复登录 · 资深总监", "Claude Code · ~/personal/agentrise",
                     "正在：写代码 Sources/AgentriseScene/Art/ComparisonScenes.swift 和一个特别长的路径，超出最大宽度的部分被截断",
                     "已工作 12 分钟"]
        let (size, recipe) = TowerSceneModel.tooltipArt(lines, color: Team.color(0), measure: backend)
        tiles.append(ComparisonTile(backend.bake(size: size, scale: scale, recipe)))
        return tiles
    }

    /// Every emoji prop glyph, once, at the size the robots hold it (`RobotMotion.props`), plus the default prop size.
    private static func emoji(_ backend: ArtBackend) -> [ComparisonTile] {
        let art = RobotArt(scale: scale, backend: backend)
        let activities: [Activity] = [.reading, .searching, .coding, .runningCommand, .commandFailed, .browsing, .planning,
                                      .delegating, .sendingLark, .thinking, .compacting, .waitingAtDoor, .waitingForSubs,
                                      .reporting, .resting, .standby, .sleeping, .briefing, .other]
        var seen = Set<String>(), tiles: [ComparisonTile] = []
        for a in activities {
            for p in RobotMotion.props(a) {
                guard case let .emoji(s, size) = p.art, seen.insert(s).inserted else { continue }
                let image = art.emoji(s, size: size)
                let tile = ComparisonTile(image)
                tiles.append(p.tint.map { ComparisonTile(size: tile.size, layers: [(image, .zero, $0)]) } ?? tile)
            }
        }
        return tiles
    }

    // MARK: Composition

    /// Background of every scene: the window's (0x0A0E26).
    package static let backdrop: (r: UInt8, g: UInt8, b: UInt8) = (0x0A, 0x0E, 0x26)

    /// `tiles` laid out in a grid (one row of up to 4, else `ceil(sqrt(n))` columns; each column as wide and each row as tall as its largest
    /// tile, tiles centred in their cells, 12 pt gaps) over `backdrop`, at `scale`: opaque RGBA rows, top first.
    package static func compose(_ tiles: [ComparisonTile], backend: ArtBackend) -> (width: Int, height: Int, rgba: [UInt8]) {
        let columns = tiles.count <= 4 ? max(1, tiles.count) : Int(ceil(Double(tiles.count).squareRoot()))
        let rows = (tiles.count + columns - 1) / columns
        let gap = Int(12 * scale)
        func px(_ v: CGFloat) -> Int { Int((v * scale).rounded()) }
        var colWidth = [Int](repeating: 0, count: columns), rowHeight = [Int](repeating: 0, count: rows)
        for (i, t) in tiles.enumerated() {
            colWidth[i % columns] = max(colWidth[i % columns], px(t.size.width))
            rowHeight[i / columns] = max(rowHeight[i / columns], px(t.size.height))
        }
        let width = colWidth.reduce(gap) { $0 + $1 + gap }, height = rowHeight.reduce(gap) { $0 + $1 + gap }
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            out[i * 4] = backdrop.r; out[i * 4 + 1] = backdrop.g; out[i * 4 + 2] = backdrop.b
        }
        for (i, t) in tiles.enumerated() {
            let c = i % columns, r = i / columns
            let cellX = gap + colWidth[..<c].reduce(0) { $0 + $1 + gap }, cellY = gap + rowHeight[..<r].reduce(0) { $0 + $1 + gap }
            let tileX = cellX + (colWidth[c] - px(t.size.width)) / 2, tileY = cellY + (rowHeight[r] - px(t.size.height)) / 2
            for l in t.layers {
                over(backend.rgba(l.image), w: l.image.pixelWidth, h: l.image.pixelHeight, tint: l.tint,
                     at: (tileX + px(l.origin.x), tileY + px(l.origin.y)), into: &out, width: width, height: height)
            }
        }
        return (width, height, out)
    }

    /// Source-over of premultiplied RGBA `src` (optionally tinted) onto `dst` at `at` (pixels), clipped to `dst`.
    private static func over(_ src: [UInt8], w: Int, h: Int, tint: Color?, at: (x: Int, y: Int),
                             into dst: inout [UInt8], width: Int, height: Int) {
        let t: [Double] = tint.map { [$0.r, $0.g, $0.b] } ?? [1, 1, 1]
        for y in 0..<h where (0..<height).contains(at.y + y) {
            for x in 0..<w where (0..<width).contains(at.x + x) {
                let s = (y * w + x) * 4, d = ((at.y + y) * width + at.x + x) * 4
                let a = Double(src[s + 3]) / 255
                guard a > 0 else { continue }
                for k in 0..<3 {
                    let v: Double = Double(src[s + k]) * t[k] + Double(dst[d + k]) * (1 - a)
                    dst[d + k] = UInt8(max(0, min(255, v.rounded())))
                }
            }
        }
    }
}
