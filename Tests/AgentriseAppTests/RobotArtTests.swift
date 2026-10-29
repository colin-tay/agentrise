// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import AppKit
import CoreGraphics
import QuartzCore
@testable import AgentriseApp
@testable import Agentrise
@testable import AgentriseScene
import AgentriseMacArt

/// What `RobotArt` draws through `CGArtBackend` (pixels). Sizes, anchors and caching are covered on every
/// platform by `AgentriseSceneTests.RobotArtTests`.
@Suite struct RobotArtTests {
    private let look = RobotLook(kind: .boss(.seniorEngineer), teamIndex: 0, larkSession: false)

    /// 设计坐标（y 向下）处像素的 alpha，0...255。
    private func alpha(_ img: BakedImage, at p: CGPoint, scale: CGFloat) -> UInt8 {
        let x = Int(p.x * scale), y = Int(p.y * scale)
        return CGArtBackend.shared.rgba(img)[(y * img.pixelWidth + x) * 4 + 3]
    }

    private func bytes(_ img: CGImage) -> Data { img.dataProvider!.data! as Data }
    private func bytes(_ img: BakedImage) -> [UInt8] { CGArtBackend.shared.rgba(img) }

    @Test func torsoHasPixelsWhereTheBodyIs() {
        let img = RobotArt(scale: 2.5).image(.torso(look))
        #expect(img.cgImage.alphaInfo == .premultipliedLast)
        #expect(alpha(img, at: CGPoint(x: 30, y: 49 + 14), scale: 2.5) > 0)
        #expect(alpha(img, at: CGPoint(x: 2, y: 2), scale: 2.5) == 0)
    }

    @Test func differentRankGivesDifferentHead() {
        let art = RobotArt(scale: 2.5)
        let director = art.image(.head(RobotLook(kind: .boss(.seniorDirector), teamIndex: 0, larkSession: false)))
        let grad = art.image(.head(RobotLook(kind: .boss(.newGrad), teamIndex: 0, larkSession: false)))
        #expect(bytes(director) != bytes(grad))
    }

    @Test func textImageIsNonEmpty() {
        let img = CGArtBackend.shared.bake(size: CGSize(width: 80, height: 16), scale: 2.5) { pen in
            pen.text("测试 ⚡ Grok", font: FontSpec(size: 11, weight: .semibold), color: Color(r: 1, g: 1, b: 1), shadow: nil,
                     in: CGRect(x: 0, y: 0, width: 80, height: 16), maxLines: 1)
        }
        #expect(img.pixelWidth == 200 && img.pixelHeight == 40)
        #expect(bytes(img).enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 })
    }

    @Test func calmSharesTheFocusedEyes() {
        let art = RobotArt(scale: 2.5)
        #expect(art.image(.eyes(.calm)) === art.image(.eyes(.focused)))
        #expect(bytes(art.image(.eyes(.happy))) != bytes(art.image(.eyes(.focused))))
    }

    @Test func podSpillsLeftOfTheCanvas() {
        // 舱壁左缘在设计 x = -6 处（画布外），中心高度 y = 46
        let art = RobotArt(scale: 2.5)
        let f = art.frame(.pod)
        #expect(alpha(art.image(.pod), at: CGPoint(x: -5.6 - f.minX, y: 46 - f.minY), scale: 2.5) > 0)
    }

    @Test func haloGlowSpillsBelowTheCanvas() {
        // 光环椭圆底边在设计 y = 83.6；发光（半径 5）要画到画布外。
        let art = RobotArt(scale: 2.5)
        let f = art.frame(.halo)
        let halo = art.image(.halo)
        #expect(alpha(halo, at: CGPoint(x: 30 - f.minX, y: 86 - f.minY), scale: 2.5) > 0)
        #expect(alpha(halo, at: CGPoint(x: 30 - f.minX, y: 66 + 14 - f.minY), scale: 2.5) > 200)
    }

    @Test func haloGlowMatchesCoreAnimation() {
        // 旧光环：CAShapeLayer，填充白色 0.85，shadowRadius 5，没有 shadowPath（阴影按内容 alpha 生成）。
        let scale: CGFloat = 2.5
        let art = RobotArt(scale: scale)
        let f = art.frame(.halo)
        let old = CGArtBackend.image(size: f.size, scale: scale) { ctx in
            ctx.translateBy(x: -f.minX, y: -f.minY)
            let l = CAShapeLayer()
            l.frame = CGRect(origin: .zero, size: ArtKit.robotCanvas)
            l.path = CGPath(ellipseIn: CGRect(x: 15, y: 62.4 + 14, width: 30, height: 7.2), transform: nil)
            l.fillColor = NSColor.white.withAlphaComponent(0.85).cgColor
            l.shadowColor = NSColor.white.cgColor; l.shadowRadius = 5; l.shadowOpacity = 1; l.shadowOffset = .zero
            l.render(in: ctx)
        }
        let a = bytes(old), b = bytes(art.image(.halo).cgImage)
        #expect(a.count == b.count)
        var worst = 0
        for i in stride(from: 3, to: min(a.count, b.count), by: 4) { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        #expect(worst <= 8, "max alpha difference \(worst)")
    }
}
