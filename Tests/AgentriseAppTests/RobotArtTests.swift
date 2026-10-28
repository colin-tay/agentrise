// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import AppKit
import CoreGraphics
import QuartzCore
@testable import AgentriseApp
@testable import Agentrise

@Suite struct RobotArtTests {
    private let look = RobotLook(kind: .boss(.seniorEngineer), teamIndex: 0, larkSession: false)

    /// 设计坐标（y 向下）处像素的 alpha，0...255。
    private func alpha(_ img: CGImage, at p: CGPoint, scale: CGFloat) -> UInt8 {
        let data = img.dataProvider!.data! as Data
        let x = Int(p.x * scale), y = Int(p.y * scale)
        let bpp = img.bitsPerPixel / 8
        let i = y * img.bytesPerRow + x * bpp
        // RGBA，alpha 在最后（premultipliedLast）
        #expect(img.alphaInfo == .premultipliedLast)
        return data[i + bpp - 1]
    }

    private func bytes(_ img: CGImage) -> Data { img.dataProvider!.data! as Data }

    @Test func partsUseTheRobotCanvas() {
        let img = RobotArt(scale: 2.5).image(.torso(look))
        #expect(img.width == 150)
        #expect(img.height == 210)
        #expect(ArtKit.robotCanvas == CGSize(width: 60, height: 84))
    }

    @Test func torsoHasPixelsWhereTheBodyIs() {
        let img = RobotArt(scale: 2.5).image(.torso(look))
        #expect(alpha(img, at: CGPoint(x: 30, y: 49 + 14), scale: 2.5) > 0)
        #expect(alpha(img, at: CGPoint(x: 2, y: 2), scale: 2.5) == 0)
    }

    @Test func sameLookIsCached() {
        let art = RobotArt(scale: 2.5)
        #expect(art.image(.head(look)) === art.image(.head(look)))
    }

    @Test func differentRankGivesDifferentHead() {
        let art = RobotArt(scale: 2.5)
        let director = art.image(.head(RobotLook(kind: .boss(.seniorDirector), teamIndex: 0, larkSession: false)))
        let grad = art.image(.head(RobotLook(kind: .boss(.newGrad), teamIndex: 0, larkSession: false)))
        #expect(bytes(director) != bytes(grad))
    }

    @Test func cacheIsKeyedByScale() {
        let a = RobotArt.shared(scale: 2.5), b = RobotArt.shared(scale: 3.75)
        #expect(a !== b)
        #expect(a === RobotArt.shared(scale: 2.5))
        #expect(b.scale == 3.75)
        #expect(b.image(.torso(look)).width == 225)
    }

    @Test func textImageIsNonEmpty() {
        let s = NSAttributedString(string: "测试 ⚡ Grok", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        let img = ArtKit.text(s, scale: 2.5)
        #expect(img.width > 0)
        #expect(img.height > 0)
    }

    @Test func calmSharesTheFocusedEyes() {
        let art = RobotArt(scale: 2.5)
        #expect(art.image(.eyes(.calm)) === art.image(.eyes(.focused)))
        #expect(bytes(art.image(.eyes(.happy))) != bytes(art.image(.eyes(.focused))))
    }

    @Test func overflowingPartsGetARoomierFrame() {
        // 睡眠舱比画布宽（x -6...66），光环/飞书角标的发光也会出界：这三张用加宽的画框。
        let art = RobotArt(scale: 2.5)
        for part in [RobotPart.pod, .halo, .larkBadge] {
            let f = RobotArt.frame(part)
            #expect(f.contains(CGRect(origin: .zero, size: ArtKit.robotCanvas)))
            let img = art.image(part)
            #expect(img.width == Int(f.width * 2.5))
            #expect(img.height == Int(f.height * 2.5))
        }
        let pod = art.image(.pod)
        let f = RobotArt.frame(.pod)
        // 舱壁左缘在设计 x = -6 处（画布外），中心高度 y = 46
        #expect(alpha(pod, at: CGPoint(x: -5.6 - f.minX, y: 46 - f.minY), scale: 2.5) > 0)
        #expect(RobotArt.frame(.torso(look)) == CGRect(origin: .zero, size: ArtKit.robotCanvas))
    }

    @Test func haloGlowSpillsBelowTheCanvas() {
        // 光环椭圆底边在设计 y = 83.6；发光（半径 5）要画到画布外。
        let art = RobotArt(scale: 2.5)
        let f = RobotArt.frame(.halo)
        let halo = art.image(.halo)
        #expect(alpha(halo, at: CGPoint(x: 30 - f.minX, y: 86 - f.minY), scale: 2.5) > 0)
        #expect(alpha(halo, at: CGPoint(x: 30 - f.minX, y: 66 + 14 - f.minY), scale: 2.5) > 200)
    }

    @Test func haloGlowMatchesCoreAnimation() {
        // 旧光环：CAShapeLayer，填充白色 0.85，shadowRadius 5，没有 shadowPath（阴影按内容 alpha 生成）。
        let scale: CGFloat = 2.5
        let f = RobotArt.frame(.halo)
        let old = ArtKit.image(size: f.size, scale: scale) { ctx in
            ctx.translateBy(x: -f.minX, y: -f.minY)
            let l = CAShapeLayer()
            l.frame = CGRect(origin: .zero, size: ArtKit.robotCanvas)
            l.path = CGPath(ellipseIn: CGRect(x: 15, y: 62.4 + 14, width: 30, height: 7.2), transform: nil)
            l.fillColor = NSColor.white.withAlphaComponent(0.85).cgColor
            l.shadowColor = NSColor.white.cgColor; l.shadowRadius = 5; l.shadowOpacity = 1; l.shadowOffset = .zero
            l.render(in: ctx)
        }
        let a = bytes(old), b = bytes(RobotArt(scale: scale).image(.halo))
        #expect(a.count == b.count)
        var worst = 0
        for i in stride(from: 3, to: min(a.count, b.count), by: 4) { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        #expect(worst <= 8, "max alpha difference \(worst)")
    }

    @Test func anchorPointMapsDesignPointsIntoTheImage() {
        let a = RobotArt.anchorPoint(.torso(look), design: CGPoint(x: 30, y: 84))
        #expect(a == CGPoint(x: 0.5, y: 0))
        let f = RobotArt.frame(.pod)
        let b = RobotArt.anchorPoint(.pod, design: CGPoint(x: f.minX, y: f.minY))
        #expect(b == CGPoint(x: 0, y: 1))
    }

    @Test func labelsAndBubblesAreCachedByContent() {
        let art = RobotArt(scale: 2.5)
        let b1 = art.bubble("等你回复", color: NSColor(hex: 0xFFC95C))
        #expect(b1 === art.bubble("等你回复", color: NSColor(hex: 0xFFC95C)))
        #expect(b1.height == 38)   // 15 pt × 2.5 = 37.5 px, rounded up
        let n = art.name("⚡ 主线\n高级专家", small: false, stripe: Rank.seniorExpert.stripe)
        #expect(n === art.name("⚡ 主线\n高级专家", small: false, stripe: Rank.seniorExpert.stripe))
        #expect(n !== art.name("⚡ 主线\n高级专家", small: true, stripe: Rank.seniorExpert.stripe))
        #expect(art.emoji("💻", size: 14) === art.emoji("💻", size: 14))
        #expect(art.emoji("💻", size: 14).width > 0)
    }

    /// Names and bubbles are kept by byte cost: past the budget, images nobody holds are dropped (and baked
    /// again when asked for), while one still in use stays the same object however much else is baked.
    @Test func textCacheIsLimitedByBytes() {
        #expect(RobotArt.textCostLimit == 4 << 20)
        let art = RobotArt(scale: 2.5, textCostLimit: 200_000)
        let one = art.name("名字 0", small: false, stripe: nil)
        let cost = RobotArt.cost(one)
        #expect(cost == one.bytesPerRow * one.height && cost > 10_000)
        weak var dropped = art.name("名字 1", small: false, stripe: nil)
        let held = art.name("名字 2", small: false, stripe: nil)
        for i in 3..<(3 + 4 * 200_000 / cost) { _ = art.name("名字 \(i)", small: false, stripe: nil) }
        #expect(dropped == nil)
        #expect(art.name("名字 2", small: false, stripe: nil) === held)
        #expect(art.name("名字 0", small: false, stripe: nil) === one)
    }
}
