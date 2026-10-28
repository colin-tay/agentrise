// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A path in art space (points, origin top-left, y down), recorded as a list of elements. A value type that
/// each backend turns into its own path: `CGPath` on macOS (the very calls the old Core Graphics code made, so
/// the pixels stay the same), an `ID2D1PathGeometry` on Windows.
package struct ArtPath {
    package enum Element: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        /// `CGMutablePath.addArc(center:radius:startAngle:endAngle:clockwise:)`: angles in radians, measured in
        /// the path's own (y-down) space; a line joins the current point to the arc's start, if there is one.
        case arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool)
        /// `CGMutablePath.addArc(tangent1End:tangent2End:radius:)`: a line from the current point towards
        /// `tangent1End`, then the arc of `radius` tangent to both lines, ending on the second line.
        case tangentArc(tangent1End: CGPoint, tangent2End: CGPoint, radius: CGFloat)
        case close
        /// Whole closed shapes, kept as such so backends can use their native rectangle, rounded rectangle and
        /// ellipse (`CGPath(rect:)`, `CGPath(roundedRect:…)`, `CGPath(ellipseIn:)`).
        case rect(CGRect)
        case roundedRect(CGRect, radius: CGFloat)
        case ellipse(CGRect)
    }

    package private(set) var elements: [Element] = []

    package init() {}

    package mutating func move(to p: CGPoint) { elements.append(.move(p)) }
    package mutating func line(to p: CGPoint) { elements.append(.line(p)) }
    package mutating func quadCurve(to p: CGPoint, control: CGPoint) { elements.append(.quadCurve(to: p, control: control)) }
    package mutating func arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool) {
        elements.append(.arc(center: center, radius: radius, start: start, end: end, clockwise: clockwise))
    }
    package mutating func arc(tangent1End: CGPoint, tangent2End: CGPoint, radius: CGFloat) {
        elements.append(.tangentArc(tangent1End: tangent1End, tangent2End: tangent2End, radius: radius))
    }
    package mutating func close() { elements.append(.close) }

    package static func rect(_ r: CGRect) -> ArtPath { ArtPath(elements: [.rect(r)]) }
    package static func roundedRect(_ r: CGRect, radius: CGFloat) -> ArtPath { ArtPath(elements: [.roundedRect(r, radius: radius)]) }
    package static func ellipse(in r: CGRect) -> ArtPath { ArtPath(elements: [.ellipse(r)]) }

    /// A closed polygon through `points` (a move to the first, lines to the rest, then close).
    package static func polygon(_ points: [CGPoint]) -> ArtPath {
        var p = ArtPath()
        guard let first = points.first else { return p }
        p.move(to: first)
        for q in points.dropFirst() { p.line(to: q) }
        p.close()
        return p
    }

    private init(elements: [Element]) { self.elements = elements }

    /// The box around every point and control point, like `CGPath.boundingBox`: for the whole shapes it is their
    /// rectangle; an arc counts its whole circle's box (a superset; no recipe takes the box of a path with arcs).
    package var bounds: CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func add(_ p: CGPoint) { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        func add(_ r: CGRect) { add(CGPoint(x: r.minX, y: r.minY)); add(CGPoint(x: r.maxX, y: r.maxY)) }
        for e in elements {
            switch e {
            case let .move(p), let .line(p): add(p)
            case let .quadCurve(p, c): add(p); add(c)
            case let .arc(c, r, _, _, _): add(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            case let .tangentArc(t1, t2, _): add(t1); add(t2)
            case .close: break
            case let .rect(r), let .roundedRect(r, _), let .ellipse(r): add(r)
            }
        }
        guard minX <= maxX, minY <= maxY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
