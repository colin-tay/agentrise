// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Agentrise

package enum RobotKind: Hashable { case boss(Rank), sub, contractor }
package enum RobotFace: Hashable { case focused, happy, waiting, error, asleep, calm }

/// Everything that decides how a robot's static parts look.
package struct RobotLook: Hashable {
    package let kind: RobotKind
    package let teamIndex: Int
    package let larkSession: Bool

    package init(kind: RobotKind, teamIndex: Int, larkSession: Bool) {
        self.kind = kind
        self.teamIndex = teamIndex
        self.larkSession = larkSession
    }

    package var rank: Rank? { if case let .boss(r) = kind { return r }; return nil }
    package var teamColor: Color { Team.color(teamIndex) }
    /// Bosses wear their team's glyph on the neck ring.
    package var emblem: String? { rank == nil ? nil : Team.glyph(teamIndex) }
    /// Director's visor band and expert's monocle sit on top of the eyes, so they get their own layer.
    package var hasHeadOverlay: Bool { rank == .seniorDirector || rank == .seniorExpert }
}

/// The robot is cut into parts that animate independently. All parts except `prop` are drawn
/// on the shared robot canvas (`RobotArt.frame(_:)`), so they share one anchor.
package enum RobotPart: Hashable {
    case halo                        // white; tinted with the team colour at runtime
    case torso(RobotLook)            // straps, body, stripe, body accessories, emblem, lark square
    case head(RobotLook)             // shell, visor, shine, headphones / sprout / hard hat
    case headOverlay(RobotLook)      // head accessories drawn above the eyes (director band, expert monocle)
    case leftHand, rightHand, ears, ring
    case eyes(RobotFace)             // focused and calm share one image; calm's 0.75 alpha is set on the sprite
    case pod, larkBadge
    case prop(String)                // emoji at the default prop size (13 pt); see `RobotArt.emoji`
}

// MARK: - Design-space path helpers (same as the old Robot.swift)

private let top: CGFloat = 14
private func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y + top) }
private func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y + top, width: w, height: h) }
private func rounded(_ r: CGRect, _ radius: CGFloat) -> ArtPath { .roundedRect(r, radius: radius) }
private func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> ArtPath {
    .ellipse(in: CGRect(x: cx - rx, y: cy - ry + top, width: rx * 2, height: ry * 2))
}
private func poly(_ pts: [(CGFloat, CGFloat)]) -> ArtPath { .polygon(pts.map { P($0.0, $0.1) }) }
private func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> ArtPath {
    var pts: [(CGFloat, CGFloat)] = []
    for i in 0..<10 {
        let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        let rr = i % 2 == 0 ? r : r * 0.45
        pts.append((x + rr * cos(a), y + rr * sin(a)))
    }
    return poly(pts)
}

private let white = Color(r: 1, g: 1, b: 1), black = Color(r: 0, g: 0, b: 0)
private let chromeColors = [white, Color(hex: 0xDFE5FF), Color(hex: 0xB8C2EE), Color(hex: 0xEEF1FF)]
private let chromeStops: [CGFloat] = [0, 0.45, 0.55, 1]
private let gold = Color(hex: 0xFFCF3F), silver = Color(hex: 0xCFD6EA), cyan = Color(hex: 0x77CCFF)
private let waitingColor = Color(hex: 0xFFC95C)

/// Old `CAShapeLayer` / `CAGradientLayer` primitives replayed on a `Pen`.
private struct Brush {
    let pen: Pen

    func shape(_ path: ArtPath, fill: Color? = nil, stroke: Color? = nil, width: CGFloat = 1) {
        if let fill { pen.fill(path, fill) }
        if let stroke { pen.stroke(path, stroke, width: width) }
    }

    /// `CAGradientLayer` framed on the path's bounding box (outset 1 pt) and masked by the path.
    func gradient(_ path: ArtPath, colors: [Color], locations: [CGFloat]? = nil, diagonal: Bool = true) {
        let box = path.bounds.insetBy(dx: -1, dy: -1)
        pen.linearGradient(path, colors: colors, locations: locations, from: CGPoint(x: box.minX, y: box.minY),
                           to: diagonal ? CGPoint(x: box.maxX, y: box.maxY) : CGPoint(x: box.minX, y: box.maxY))
    }

    func chrome(_ path: ArtPath) { gradient(path, colors: chromeColors, locations: chromeStops) }

    /// A filled shape with a CA-style layer shadow (`shadowOffset = .zero`, no `shadowPath`): the shadow
    /// follows the fill's own alpha, exactly as Core Animation derived it from the layer contents.
    func glowing(_ path: ArtPath, fill: Color, glow: Color, radius: CGFloat, opacity: CGFloat = 1) {
        pen.shadowed(offset: .zero, blur: radius, color: glow.withAlpha(glow.a * Double(opacity))) {
            shape(path, fill: fill)
        }
    }

    func label(_ s: String, size: CGFloat, color: Color = white, weight: FontWeight = .semibold, at center: CGPoint) {
        ArtKit.drawLabel(s, font: FontSpec(size: size, weight: weight), color: color, center: center, pen: pen)
    }
}

// MARK: - RobotArt

/// Bakes robot parts into cached bitmaps at one backing scale.
package final class RobotArt {
    package let scale: CGFloat
    package let backend: ArtBackend
    /// Transparent margin around name labels, so their shadow isn't clipped. The label's old
    /// `nameLayer` box is the image inset by this much on every side.
    package static let namePadding: CGFloat = 3
    /// Transparent margin around `bubbleGlow` images (the bubble itself is inset by this much).
    package static let bubbleGlowPadding: CGFloat = 8

    /// Byte budgets (`4 × pixels`) of the caches that keep recently baked images around while no
    /// sprite shows them: names and bubbles (open-ended strings), and parts and emoji (a bounded but, over
    /// many teams and ranks, sizeable set).
    package static let textCostLimit = 4 << 20
    package static let shapeCostLimit = 8 << 20

    private let lock = NSLock()
    /// Every image handed out and still alive (held by a sprite, the atlas or a cache below), so asking again
    /// returns the same object: the atlas keys images by identity, so a re-render would be packed twice.
    private var live: [String: WeakImage] = [:]
    private var liveCountAfterPrune = 0
    private let shapes = NSCache<NSString, BakedImage>()
    private let texts = NSCache<NSString, BakedImage>()

    private final class WeakImage { weak var image: BakedImage?; init(_ i: BakedImage) { image = i } }

    package init(scale: CGFloat, backend: ArtBackend, textCostLimit: Int = RobotArt.textCostLimit, shapeCostLimit: Int = RobotArt.shapeCostLimit) {
        self.scale = scale
        self.backend = backend
        texts.totalCostLimit = textCostLimit
        shapes.totalCostLimit = shapeCostLimit
    }

    /// What an image weighs in the caches: its pixels' bytes.
    package static func cost(_ img: BakedImage) -> Int { img.pixelWidth * 4 * img.pixelHeight }

    private final class WeakArt { weak var art: RobotArt?; init(_ a: RobotArt) { art = a } }
    private static let sharedLock = NSLock()
    private struct SharedKey: Hashable { let scale: CGFloat; let backend: ObjectIdentifier }
    nonisolated(unsafe) private static var instances: [SharedKey: WeakArt] = [:]

    /// One instance (and so one image cache and atlas) per backing scale and backend type, while anyone uses it: the scene
    /// holds the current scale's, robots the one they were baked with. After a scale change the old one
    /// goes (with its atlas) once the last robot baked with it is gone. So moving the window back to a
    /// display it was on before bakes that scale's robot art (and packs its atlas) again from scratch.
    package static func shared(scale: CGFloat, backend: ArtBackend) -> RobotArt {
        sharedLock.lock(); defer { sharedLock.unlock() }
        let key = SharedKey(scale: scale, backend: ObjectIdentifier(type(of: backend)))
        if let a = instances[key]?.art { return a }
        let a = RobotArt(scale: scale, backend: backend)
        instances = instances.filter { $0.value.art != nil }
        instances[key] = WeakArt(a)
        return a
    }

    // MARK: Geometry

    /// Where a part's image sits in robot design space (points, y down, canvas origin at the
    /// canvas's top-left). Most parts cover exactly the 60×84 canvas; the sleep pod (x −6…66) and the
    /// glows of the halo and lark badge spill over it, so those three use a roomier frame. A prop's
    /// frame is its label box centred on (0, 0) — the old layer `position`.
    package func frame(_ part: RobotPart) -> CGRect {
        switch part {
        case .halo, .pod, .larkBadge:
            return CGRect(x: -10, y: 0, width: 80, height: 96)
        case let .prop(s):
            let sz = emojiSize(s, size: 13)
            return CGRect(x: -sz.width / 2, y: -sz.height / 2, width: sz.width, height: sz.height)
        default:
            return CGRect(origin: .zero, size: ArtKit.robotCanvas)
        }
    }

    /// The anchor point (y up, 0…1 over the image) that pins `design` (robot design space, y down) for this part's image.
    package func anchorPoint(_ part: RobotPart, design p: CGPoint) -> CGPoint {
        let f = frame(part)
        return CGPoint(x: (p.x - f.minX) / f.width, y: 1 - (p.y - f.minY) / f.height)
    }

    // MARK: Cached images

    package func image(_ part: RobotPart) -> BakedImage {
        let key: RobotPart = part == .eyes(.calm) ? .eyes(.focused) : part
        return cached("p|\(key)", in: shapes) { render(key) }
    }

    /// An emoji (or any glyph) drawn like the old `prop(...)` text layers: white, regular weight,
    /// in a `textLayer` box (text width + 2 by `ceil(size × 1.3)`), meant to be centred on its position.
    package func emoji(_ s: String, size: CGFloat) -> BakedImage {
        cached("e|\(size)|\(s)", in: shapes) { renderLabel(s, size: size) }
    }

    /// Size in points of `emoji(s, size:)`.
    package func emojiSize(_ s: String, size: CGFloat) -> CGSize {
        ArtKit.labelSize(s, font: FontSpec(size: size, weight: .regular), using: backend)
    }

    /// The status bubble: 15 pt tall pill, 9 pt bold text, dark text on the waiting colour.
    package func bubble(_ text: String, color: Color) -> BakedImage {
        cachedText("b|\(Self.colorKey(color))|\(text)") {
            let fg = color == waitingColor ? Color(hex: 0x2A1A00) : white
            let sz = bubbleSize(text), w = sz.width, h = sz.height
            return backend.bake(size: sz, scale: scale) { pen in
                let b = Brush(pen: pen)
                b.shape(rounded(CGRect(x: 0, y: 0, width: w, height: h), h / 2), fill: color)
                b.label(text, size: 9, color: fg, weight: .bold, at: CGPoint(x: w / 2, y: h / 2))
            }
        }
    }

    /// Size in points of `bubble(text, color:)`: the 9 pt bold label plus 12, by 15.
    package func bubbleSize(_ text: String) -> CGSize {
        CGSize(width: ArtKit.labelSize(text, font: FontSpec(size: 9, weight: .bold), using: backend).width + 12, height: 15)
    }

    /// The pulsing bubble's glow (the old `shadowRadius = 6` at full opacity), shadow only. The image is
    /// `bubbleGlowPadding` larger than `bubble(text, color:)` on every side and shares its centre.
    package func bubbleGlow(_ text: String, color: Color) -> BakedImage {
        cachedText("g|\(Self.colorKey(color))|\(text)") {
            let sz = bubbleSize(text), w = sz.width, h = sz.height, pad = Self.bubbleGlowPadding
            return backend.bake(size: CGSize(width: w + pad * 2, height: h + pad * 2), scale: scale) { pen in
                pen.glow(rounded(CGRect(x: pad, y: pad, width: w, height: h), h / 2), blur: 6, color: color)
            }
        }
    }

    /// Two-line name label exactly like the old `setName`: semibold 11 (9 when `small`) in #E8EEFF, an
    /// optional second line 1.5 pt smaller in `stripe` (or #B8C4E8), centred, with a 1.5 pt black shadow.
    /// The old label box (≤ 130 wide) is the image inset by `namePadding`; it sat with its top at design y 82.
    package func name(_ s: String, small: Bool, stripe: Color?) -> BakedImage {
        cachedText("n|\(small)|\(stripe.map(Self.colorKey) ?? "-")|\(s)") {
            let (runs, sz, box) = nameLayout(s, small: small, stripe: stripe)
            let pad = Self.namePadding
            return backend.bake(size: CGSize(width: box.width + pad * 2, height: box.height + pad * 2), scale: scale) { pen in
                let inner = CGRect(x: pad, y: pad, width: box.width, height: box.height)
                // The old layer was not wrapped: lay the text out wide, centred, and clip to the box.
                let layoutWidth = max(box.width, ceil(sz.width) + 4)
                let textRect = CGRect(x: inner.midX - layoutWidth / 2, y: inner.minY, width: layoutWidth, height: inner.height)
                pen.shadowed(offset: .zero, blur: 1.5, color: black) {
                    pen.layer(alpha: 1) {
                        pen.clipped(to: .rect(inner)) {
                            pen.text(runs, shadow: nil, in: textRect, maxLines: 0)
                        }
                    }
                }
            }
        }
    }

    /// Size in points of `name(s, small:, stripe:)`: the old label box plus `namePadding` on every side.
    package func nameImageSize(_ s: String, small: Bool) -> CGSize {
        let box = nameLayout(s, small: small, stripe: nil).box
        return CGSize(width: box.width + Self.namePadding * 2, height: box.height + Self.namePadding * 2)
    }

    /// The old `setName` text, its unwrapped size, and the label box (≤ 130 wide).
    private func nameLayout(_ s: String, small: Bool, stripe: Color?) -> ([TextRun], CGSize, box: CGSize) {
        let lines = s.components(separatedBy: "\n")
        let size: CGFloat = small ? 9 : 11
        var runs = [TextRun(lines[0], font: FontSpec(size: size, weight: .semibold), color: Color(hex: 0xE8EEFF))]
        if lines.count > 1 {
            runs.append(TextRun("\n" + lines[1], font: FontSpec(size: size - 1.5, weight: .medium), color: stripe ?? Color(hex: 0xB8C4E8)))
        }
        let sz = backend.measure(runs, maxWidth: 200, maxLines: 0)
        return (runs, sz, CGSize(width: min(ceil(sz.width) + 4, 130), height: ceil(sz.height) + 2))
    }

    /// The yellow "?" sign held up while waiting at the door (16×14, centred on its position).
    package func doorSign() -> BakedImage {
        cachedText("sign") {
            backend.bake(size: CGSize(width: 16, height: 14), scale: scale) { pen in
                let b = Brush(pen: pen)
                b.shape(rounded(CGRect(x: 0, y: 0, width: 16, height: 14), 3), fill: waitingColor)
                b.label("?", size: 11, color: Color(hex: 0x2A1A00), weight: .black, at: CGPoint(x: 8, y: 7))
            }
        }
    }

    private func cachedText(_ key: String, _ make: () -> BakedImage) -> BakedImage { cached(key, in: texts, make) }

    /// The live image for `key`, else one from `cache`, else a fresh one (kept in `cache` at its byte cost).
    private func cached(_ key: String, in cache: NSCache<NSString, BakedImage>, _ make: () -> BakedImage) -> BakedImage {
        let k = NSString(string: key)
        lock.lock(); defer { lock.unlock() }
        if let img = cache.object(forKey: k) { return img }
        if let img = live[key]?.image {
            cache.setObject(img, forKey: k, cost: Self.cost(img))
            return img
        }
        let img = make()
        live[key] = WeakImage(img)
        if live.count >= 2 * max(64, liveCountAfterPrune) {   // drop the entries of images that are gone
            live = live.filter { $0.value.image != nil }
            liveCountAfterPrune = live.count
        }
        cache.setObject(img, forKey: k, cost: Self.cost(img))
        return img
    }

    private static func colorKey(_ c: Color) -> String {
        String(format: "%.4f,%.4f,%.4f,%.4f", c.r, c.g, c.b, c.a)
    }

    private func renderLabel(_ s: String, size: CGFloat) -> BakedImage {
        let box = emojiSize(s, size: size)
        return backend.bake(size: box, scale: scale) { pen in
            pen.emoji(s, size: size, center: CGPoint(x: box.width / 2, y: box.height / 2))
        }
    }

    // MARK: Drawing

    private func render(_ part: RobotPart) -> BakedImage {
        if case let .prop(s) = part { return renderLabel(s, size: 13) }
        let f = frame(part)
        return backend.bake(size: f.size, scale: scale) { pen in
            pen.translated(by: CGSize(width: -f.minX, height: -f.minY)) {
                let b = Brush(pen: pen)
                switch part {
                case .halo:
                    let p = oval(30, 66, 15, 3.6)
                    b.glowing(p, fill: white.withAlpha(0.85), glow: white, radius: 5)
                case let .torso(look): drawTorso(look, b)
                case let .head(look): drawHead(look, b)
                case let .headOverlay(look): drawHeadOverlay(look, b)
                case .leftHand: b.chrome(oval(11, 47, 4.5, 4.5))
                case .rightHand: b.chrome(oval(49, 47, 4.5, 4.5))
                case .ears:
                    for x in [8.5, 51.5] as [CGFloat] { b.shape(oval(x, 20, 4.5, 4.5), fill: cyan) }
                case .ring: b.shape(oval(30, 38.5, 9, 2), stroke: cyan, width: 1.2)
                case let .eyes(face): drawEyes(face, b)
                case .pod:
                    // Old pod: a CALayer at (-6, 8, 72, 76), corner radius 34, 1 pt border inside the bounds.
                    let r = CGRect(x: -6, y: 8, width: 72, height: 76)
                    b.shape(rounded(r, 34), fill: Color(hex: 0x968CFF, alpha: 0.16))
                    b.shape(rounded(r.insetBy(dx: 0.5, dy: 0.5), 33.5), stroke: Color(hex: 0xB4AAFF, alpha: 0.55), width: 1)
                case .larkBadge:
                    let c = P(52, 4)
                    let badge = rounded(CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14), 4)
                    b.glowing(badge, fill: Color(hex: 0x3370FF), glow: Color(hex: 0x3370FF), radius: 5)
                    b.label("飞", size: 8.5, weight: .bold, at: c)
                case .prop:
                    break
                }
            }
        }
    }

    private func drawTorso(_ look: RobotLook, _ b: Brush) {
        let rank = look.rank
        if rank == .newGrad {   // backpack straps behind the body
            b.shape(rounded(R(16, 42, 5, 13), 2), fill: Color(hex: 0xFF9F43))
            b.shape(rounded(R(39, 42, 5, 13), 2), fill: Color(hex: 0xFF9F43))
        }
        b.chrome(rounded(R(19, 41, 22, 17), 8.5))
        var stripe = ArtPath(); stripe.move(to: P(23, 52)); stripe.line(to: P(37, 52))
        b.shape(stripe, stroke: rank.map(\.stripe) ?? look.teamColor, width: 2.5)
        if let rank { drawBodyAccessories(rank, b) }
        if let emblem = look.emblem {   // team emblem pendant on the neck ring
            b.shape(poly((0..<6).map { i in let a = CGFloat(i) * .pi / 3; return (30 + 4.6 * cos(a), 38.5 + 4.6 * sin(a)) }),
                    fill: look.teamColor, stroke: white, width: 0.6)
            b.label(emblem, size: 5.5, color: Color(hex: 0x0A0F2C), weight: .black, at: P(30, 38.6))
        }
        if look.larkSession {
            b.shape(rounded(R(40, 49, 9, 9), 2.5), fill: Color(hex: 0x3370FF))
            b.label("飞", size: 5.6, weight: .bold, at: P(44.5, 53.5))
        }
    }

    private func drawBodyAccessories(_ rank: Rank, _ b: Brush) {
        switch rank {
        case .seniorDirector:
            var cape = ArtPath(); cape.move(to: P(19, 45)); cape.line(to: P(30, 51)); cape.line(to: P(41, 45)); cape.line(to: P(41, 55)); cape.quadCurve(to: P(19, 55), control: P(30, 60)); cape.close()
            b.shape(cape, fill: Color(hex: 0x5B2BB5))
            b.shape(poly([(19, 45), (24, 44), (30, 51)]), fill: Color(hex: 0x7D4BE0))
            b.shape(poly([(41, 45), (36, 44), (30, 51)]), fill: Color(hex: 0x7D4BE0))
            b.shape(poly([(30, 46), (28.2, 49), (30, 57), (31.8, 49)]), fill: gold)
            b.shape(star(36.5, 47.5, 2.4), fill: gold)
            b.shape(star(23.5, 47.5, 2.4), fill: gold)
        case .seniorExpert:
            var vest = ArtPath(); vest.move(to: P(20, 45)); vest.line(to: P(30, 49)); vest.line(to: P(40, 45)); vest.line(to: P(40, 55)); vest.quadCurve(to: P(20, 55), control: P(30, 59)); vest.close()
            b.shape(vest, fill: Color(hex: 0x23407A))
            b.shape(oval(30, 51.5, 0.9, 0.9), fill: silver)
            b.shape(oval(30, 54.5, 0.9, 0.9), fill: silver)
            b.shape(poly([(26, 44.5), (30, 46.3), (34, 44.5), (34, 48.1), (30, 46.3), (26, 48.1)]), fill: silver)
        case .seniorEngineer:
            let blue = Color(hex: 0x4CC3FF)
            var lan = ArtPath(); lan.move(to: P(22, 41)); lan.line(to: P(30, 47)); lan.line(to: P(38, 41))
            b.shape(lan, stroke: blue, width: 1.2)
            b.shape(rounded(R(26.5, 46, 7, 6), 1.5), fill: white, stroke: blue, width: 0.8)
        case .newGrad:
            let red = Color(hex: 0xFF7A7A)
            var lan = ArtPath(); lan.move(to: P(25, 41)); lan.line(to: P(30, 48)); lan.line(to: P(35, 41))
            b.shape(lan, stroke: red, width: 1.2)
            b.shape(rounded(R(26.5, 47, 7, 6), 1.5), fill: white, stroke: red, width: 0.8)
            b.shape(rounded(R(27.8, 48.5, 4.4, 1), 0.5), fill: red)
        }
    }

    private func drawHead(_ look: RobotLook, _ b: Brush) {
        b.chrome(rounded(R(9, 5, 42, 30), 15))
        b.gradient(rounded(R(13, 10, 34, 19), 9.5), colors: [Color(hex: 0x16204F), Color(hex: 0x0A0F2C)], diagonal: false)
        var shine = ArtPath(); shine.move(to: P(16, 8)); shine.quadCurve(to: P(34, 6), control: P(24, 5))
        b.shape(shine, stroke: white, width: 2)
        // Head accessories that never overlap the face (the rest are in `headOverlay`).
        switch look.rank {
        case .seniorEngineer:
            let blue = Color(hex: 0x4CC3FF)
            var arc = ArtPath(); arc.arc(center: P(30, 22), radius: 24, start: .pi, end: 2 * .pi, clockwise: false)
            b.shape(arc, stroke: blue, width: 2.6)
            b.shape(rounded(R(3, 16, 6, 10), 2.5), fill: blue)
            b.shape(rounded(R(51, 16, 6, 10), 2.5), fill: blue)
            var mic = ArtPath(); mic.move(to: P(6, 25)); mic.quadCurve(to: P(19, 34), control: P(7, 34))
            b.shape(mic, stroke: blue, width: 1.4)
            b.shape(oval(19, 34, 1.6, 1.6), fill: blue)
        case .newGrad:
            var stem = ArtPath(); stem.move(to: P(30, 5)); stem.line(to: P(30, -3))
            b.shape(stem, stroke: Color(hex: 0x44CC44), width: 2)
            b.shape(oval(26, -3, 4.2, 2.3), fill: Color(hex: 0x66DD66))
            b.shape(oval(34, -3, 4.2, 2.3), fill: Color(hex: 0x66DD66))
        default:
            break
        }
        if look.kind == .contractor {   // yellow hard hat
            var hat = ArtPath()
            hat.move(to: P(14, 11)); hat.quadCurve(to: P(46, 11), control: P(30, -6)); hat.close()
            b.glowing(hat, fill: Color(hex: 0xFFCC33), glow: Color(hex: 0xFFCC33), radius: 4, opacity: 0.8)
            b.shape(rounded(R(11, 10, 38, 3), 1.5), fill: Color(hex: 0xE0A800))
        }
    }

    private func drawHeadOverlay(_ look: RobotLook, _ b: Brush) {
        switch look.rank {
        case .seniorDirector:
            b.shape(rounded(R(14, 13, 32, 5), 2.5), fill: Color(hex: 0x1A1030, alpha: 0.85), stroke: gold, width: 1)
        case .seniorExpert:
            b.shape(oval(37.7, 19.5, 6, 6), fill: Color(hex: 0xC8E6FF, alpha: 0.12), stroke: silver, width: 1.6)
            var chain = ArtPath(); chain.move(to: P(43.5, 21)); chain.quadCurve(to: P(41, 40), control: P(46, 30))
            b.shape(chain, stroke: silver, width: 0.8)
        default:
            break
        }
    }

    private func drawEyes(_ face: RobotFace, _ b: Brush) {
        let cx: CGFloat = 30, cy: CGFloat = 19.5, dx: CGFloat = 8
        switch face {
        case .focused, .calm:
            for x in [cx - dx, cx + dx] {
                let e = rounded(R(x - 2.75, cy - 4, 5.5, 8), 2.2)
                b.glowing(e, fill: Color(hex: 0x77FFFF), glow: Color(hex: 0x77FFFF), radius: 2, opacity: 0.9)
            }
        case .happy:
            var p = ArtPath()
            for x in [cx - dx, cx + dx] { p.move(to: P(x - 3.3, cy + 1.6)); p.quadCurve(to: P(x + 3.3, cy + 1.6), control: P(x, cy - 3.8)) }
            b.shape(p, stroke: Color(hex: 0x6FF0A8), width: 2.2)
        case .waiting:
            for x in [cx - dx, cx + dx] {
                b.shape(oval(x, cy - 1, 3.3, 3.3), fill: Color(hex: 0xFFC95C))
                b.shape(oval(x + 1.1, cy - 2.2, 1.1, 1.1), fill: white)
            }
        case .error:
            var p = ArtPath()
            for x in [cx - dx, cx + dx] {
                p.move(to: P(x - 2.8, cy - 2.8)); p.line(to: P(x + 2.8, cy + 2.8))
                p.move(to: P(x + 2.8, cy - 2.8)); p.line(to: P(x - 2.8, cy + 2.8))
            }
            b.shape(p, stroke: Color(hex: 0xFF5A5A), width: 2)
        case .asleep:
            var p = ArtPath()
            for x in [cx - dx, cx + dx] { p.move(to: P(x - 3.3, cy)); p.line(to: P(x + 3.3, cy)) }
            b.shape(p, stroke: Color(hex: 0x9A93D8), width: 2)
        }
    }
}
