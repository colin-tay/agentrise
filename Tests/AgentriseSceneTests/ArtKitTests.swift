// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import AgentriseScene
@testable import Agentrise

@Suite struct ArtKitTests {
    @Test func pixelSizeRoundsUpButNotPastWholePixels() {
        func px(_ w: CGFloat, _ h: CGFloat, _ scale: CGFloat) -> [Int] {
            let s = ArtKit.pixelSize(CGSize(width: w, height: h), scale: scale)
            return [s.width, s.height]
        }
        #expect(px(30.3, 17, 2.5) == [76, 43])
        #expect(px(60, 84, 2.5) == [150, 210])
        #expect(px(0, 0.1, 2) == [1, 1])
    }

    @Test func shadowBlurScalesTheCoreAnimationRadius() {
        #expect(ArtKit.blurPerShadowRadius == 0.65)
        #expect(ArtKit.shadowBlur(radius: 6, scale: 2) == 6 * 0.65 * 2)
    }

    @Test func labelSizeIsTextWidthPlusTwoByOnePointThreeLines() {
        let m = RecordingBackend()
        // "B1" at 9 pt: 2 × 4.5 = 9 → 11; ceil(9 × 1.3) = 12.
        #expect(ArtKit.labelSize("B1", font: FontSpec(size: 9, weight: .bold), using: m) == CGSize(width: 11, height: 12))
        #expect(ArtKit.labelSize("abc", font: FontSpec(size: 10.5, weight: .semibold), using: m) == CGSize(width: 18, height: 14))
    }

    @Test func drawLabelCentresTheLabelBox() {
        let pen = RecordingPen(scale: 2)
        ArtKit.drawLabel("B1", font: FontSpec(size: 9, weight: .bold), color: Color(hex: 0xDFE6FF), center: CGPoint(x: 12, y: 7.5), pen: pen)
        #expect(pen.recording.commands == ["text [\"B1\"] nil \(CGRect(x: 6.5, y: 1.5, width: 11, height: 12)) 0"])
    }

    @Test func pathShapesKeepTheirKindAndBounds() {
        let r = CGRect(x: 1, y: 2, width: 30, height: 10)
        #expect(ArtPath.rect(r).elements == [.rect(r)])
        #expect(ArtPath.roundedRect(r, radius: 4).elements == [.roundedRect(r, radius: 4)])
        #expect(ArtPath.ellipse(in: r).elements == [.ellipse(r)])
        #expect(ArtPath.roundedRect(r, radius: 4).bounds == r)
        let tri = ArtPath.polygon([CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 2, y: 3)])
        #expect(tri.elements == [.move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 4, y: 0)), .line(CGPoint(x: 2, y: 3)), .close])
        #expect(tri.bounds == CGRect(x: 0, y: 0, width: 4, height: 3))
        var curve = ArtPath()
        curve.move(to: CGPoint(x: 0, y: 10)); curve.quadCurve(to: CGPoint(x: 10, y: 10), control: CGPoint(x: 5, y: -2))
        #expect(curve.bounds == CGRect(x: 0, y: -2, width: 10, height: 12))   // the control point counts, as in CGPath.boundingBox
        #expect(ArtPath().bounds == .zero)
    }

    @Test func buildingArtUsesTheBackendAndKeepsItsSizes() {
        let backend = RecordingBackend()
        let layout = BuildingLayout.make(size: CGSize(width: 1200, height: 800))
        let bg = BuildingArt.background(layout, scale: 2, backend: backend)
        #expect(bg.pixelWidth == 2400 && bg.pixelHeight == 1600)
        let commands = RecordingBackend.commands(bg)
        #expect(commands.first == "smoothing false")
        #expect(commands.contains { $0.hasPrefix("gradient") && $0.hasSuffix(" false") })   // the shaft's unextended gradient
        let body = BuildingArt.cabBody(layout), m = BuildingArt.cabMargin
        let cab = BuildingArt.cab(layout, scale: 2, backend: backend)
        let cabPixels = ArtKit.pixelSize(CGSize(width: body.width + 2 * m, height: body.height + 2 * m), scale: 2)
        #expect(cab.pixelWidth == cabPixels.width && cab.pixelHeight == cabPixels.height)
        #expect(cab.pixelHeight == 160)   // (40 + 2 × 20) × 2
        // "电梯": 2 × 4.5 = 9 → 11 by ceil(11.7) = 12.
        #expect(BuildingArt.elevatorLabelSize(backend) == CGSize(width: 11, height: 12))
        let label = BuildingArt.elevatorLabel(scale: 2, backend: backend)
        #expect(label.pixelWidth == 22 && label.pixelHeight == 24)
        let leds = BuildingArt.ledSpecs(layout)
        #expect(leds.count == 6 * (layout.rooms[.serverRoom]?.count ?? 0))
        #expect(BuildingArt.led(color: leds[0].color, scale: 2, backend: backend).pixelWidth == 8)
    }
}
