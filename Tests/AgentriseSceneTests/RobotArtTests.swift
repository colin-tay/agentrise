// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import AgentriseScene
@testable import Agentrise

/// `RobotArt`'s sizes, anchors and caching, on any backend (here one that draws nothing). What the parts look
/// like is pinned on macOS by `AgentriseAppTests` (`RobotArtTests`, `ArtSnapshotTests`).
@Suite struct RobotArtTests {
    private let look = RobotLook(kind: .boss(.seniorEngineer), teamIndex: 0, larkSession: false)
    private func art(_ scale: CGFloat = 2.5, textCostLimit: Int = RobotArt.textCostLimit) -> RobotArt {
        RobotArt(scale: scale, backend: RecordingBackend(), textCostLimit: textCostLimit)
    }

    @Test func partsUseTheRobotCanvas() {
        let img = art().image(.torso(look))
        #expect(img.pixelWidth == 150)
        #expect(img.pixelHeight == 210)
        #expect(img.scale == 2.5)
        #expect(ArtKit.robotCanvas == CGSize(width: 60, height: 84))
    }

    @Test func sameLookIsCached() {
        let art = art()
        #expect(art.image(.head(look)) === art.image(.head(look)))
    }

    @Test func differentRankGivesDifferentHead() {
        let art = art()
        let director = art.image(.head(RobotLook(kind: .boss(.seniorDirector), teamIndex: 0, larkSession: false)))
        let grad = art.image(.head(RobotLook(kind: .boss(.newGrad), teamIndex: 0, larkSession: false)))
        #expect(director !== grad)
        #expect(RecordingBackend.commands(director) != RecordingBackend.commands(grad))
    }

    /// Scales unused by other suites: `RobotArt.shared` is process-wide and tests run in parallel.
    @Test func cacheIsKeyedByScaleAndBackend() {
        let backend = RecordingBackend()
        let a = RobotArt.shared(scale: 3.3, backend: backend), b = RobotArt.shared(scale: 4.15, backend: backend)
        #expect(a !== b)
        #expect(a === RobotArt.shared(scale: 3.3, backend: RecordingBackend()))   // same backend type
        #expect(b.scale == 4.15)
        #expect(b.image(.torso(look)).pixelWidth == 249)   // 60 × 4.15 = 249
        final class OtherBackend: ArtBackend {
            let inner = RecordingBackend()
            func bake(size: CGSize, scale: CGFloat, _ draw: (Pen) -> Void) -> BakedImage { inner.bake(size: size, scale: scale, draw) }
            func rgba(_ img: BakedImage) -> [UInt8] { inner.rgba(img) }
            func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize { inner.measure(runs, maxWidth: maxWidth, maxLines: maxLines) }
        }
        #expect(RobotArt.shared(scale: 3.3, backend: OtherBackend()) !== a)
    }

    @Test func calmSharesTheFocusedEyes() {
        let art = art()
        #expect(art.image(.eyes(.calm)) === art.image(.eyes(.focused)))
        #expect(RecordingBackend.commands(art.image(.eyes(.happy))) != RecordingBackend.commands(art.image(.eyes(.focused))))
    }

    @Test func overflowingPartsGetARoomierFrame() {
        // The sleep pod is wider than the canvas (x -6...66), and the halo's and lark badge's glows spill over it.
        let art = art()
        for part in [RobotPart.pod, .halo, .larkBadge] {
            let f = art.frame(part)
            #expect(f.contains(CGRect(origin: .zero, size: ArtKit.robotCanvas)))
            let img = art.image(part)
            #expect(img.pixelWidth == Int(f.width * 2.5))
            #expect(img.pixelHeight == Int(f.height * 2.5))
            // Drawn in design space: the whole part is moved by the frame's origin.
            #expect(RecordingBackend.commands(img).first == "translate \(CGSize(width: -f.minX, height: -f.minY)) {")
        }
        #expect(art.frame(.torso(look)) == CGRect(origin: .zero, size: ArtKit.robotCanvas))
    }

    @Test func propFrameIsItsLabelBoxCentredOnTheOrigin() {
        let art = art()
        // "💻" is one character: 0.5 × 13 = 6.5 wide → ceil + 2 = 9; ceil(13 × 1.3) = 17 tall.
        #expect(art.emojiSize("💻", size: 13) == CGSize(width: 9, height: 17))
        #expect(art.frame(.prop("💻")) == CGRect(x: -4.5, y: -8.5, width: 9, height: 17))
        let img = art.image(.prop("💻"))
        #expect(img.pixelWidth == 23 && img.pixelHeight == 43)   // 22.5 × 42.5 px, rounded up
        #expect(RecordingBackend.commands(img) == ["emoji 💻 13.0 \(CGPoint(x: 4.5, y: 8.5))"])
    }

    @Test func anchorPointMapsDesignPointsIntoTheImage() {
        let art = art()
        let a = art.anchorPoint(.torso(look), design: CGPoint(x: 30, y: 84))
        #expect(a == CGPoint(x: 0.5, y: 0))
        let f = art.frame(.pod)
        let b = art.anchorPoint(.pod, design: CGPoint(x: f.minX, y: f.minY))
        #expect(b == CGPoint(x: 0, y: 1))
    }

    @Test func labelsAndBubblesAreCachedByContent() {
        let art = art()
        let b1 = art.bubble("等你回复", color: Color(hex: 0xFFC95C))
        #expect(b1 === art.bubble("等你回复", color: Color(hex: 0xFFC95C)))
        #expect(b1 !== art.bubble("等你回复", color: Color(hex: 0x1F8F57)))
        #expect(b1.pixelHeight == 38)   // 15 pt × 2.5 = 37.5 px, rounded up
        let n = art.name("⚡ 主线\n高级专家", small: false, stripe: Rank.seniorExpert.stripe)
        #expect(n === art.name("⚡ 主线\n高级专家", small: false, stripe: Rank.seniorExpert.stripe))
        #expect(n !== art.name("⚡ 主线\n高级专家", small: true, stripe: Rank.seniorExpert.stripe))
        #expect(art.emoji("💻", size: 14) === art.emoji("💻", size: 14))
        #expect(art.emoji("💻", size: 14).pixelWidth > 0)
    }

    /// The waiting bubble's dark text, the others' white text; the glow is shadow only.
    @Test func bubbleTextColourFollowsTheBubble() {
        let art = art()
        let waiting = RecordingBackend.commands(art.bubble("等你回复", color: Color(hex: 0xFFC95C)))
        let done = RecordingBackend.commands(art.bubble("做完了", color: Color(hex: 0x1F8F57)))
        #expect(waiting.contains { $0.hasPrefix("text") } && done.contains { $0.hasPrefix("text") })
        #expect(waiting.last != done.last)
        let glow = RecordingBackend.commands(art.bubbleGlow("等你回复", color: Color(hex: 0xFFC95C)))
        #expect(glow.count == 1 && glow[0].hasPrefix("glow "))
    }

    /// The name image is the label box plus `namePadding` on every side; the box is at most 130 wide.
    @Test func nameImageSizeIsTheLabelBoxPlusPadding() {
        let art = art()
        // 6 characters at 11 pt: 33 wide → +4 = 37; one 11 pt line: 13.75 → ceil + 2 = 16.
        #expect(art.nameImageSize("Abcdef", small: false) == CGSize(width: 37 + 6, height: 16 + 6))
        let long = String(repeating: "长", count: 40)
        let longWidth: CGFloat = art.nameImageSize(long, small: false).width
        #expect(longWidth == CGFloat(136))   // 130 + 6
        let img = art.name("Abcdef", small: false, stripe: nil)
        #expect(img.pixelWidth == Int((43 * 2.5).rounded(.up)) && img.pixelHeight == Int((22 * 2.5).rounded(.up)))
    }

    /// Names and bubbles are kept by byte cost: past the budget, images nobody holds are dropped (and baked
    /// again when asked for), while one still in use stays the same object however much else is baked.
    @Test func textCacheIsLimitedByBytes() {
        #expect(RobotArt.textCostLimit == 4 << 20)
        let art = art(textCostLimit: 200_000)
        let one = art.name("名字 0", small: false, stripe: nil)
        let cost = RobotArt.cost(one)
        #expect(cost == one.pixelWidth * 4 * one.pixelHeight && cost > 5_000)
        weak var dropped = art.name("名字 1", small: false, stripe: nil)
        let held = art.name("名字 2", small: false, stripe: nil)
        for i in 3..<(3 + 4 * 200_000 / cost) { _ = art.name("名字 \(i)", small: false, stripe: nil) }
        #expect(dropped == nil)
        #expect(art.name("名字 2", small: false, stripe: nil) === held)
        #expect(art.name("名字 0", small: false, stripe: nil) === one)
    }
}
