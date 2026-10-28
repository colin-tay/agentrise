// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import Agentrise

enum RobotKind: Hashable { case boss(Rank), sub, contractor }
enum RobotFace: Hashable { case focused, happy, waiting, error, asleep, calm }

/// Everything that decides how a robot's static parts look.
struct RobotLook: Hashable {
    let kind: RobotKind
    let teamIndex: Int
    let larkSession: Bool

    var rank: Rank? { if case let .boss(r) = kind { return r }; return nil }
    var teamColor: NSColor { Team.color(teamIndex) }
    /// Bosses wear their team's glyph on the neck ring.
    var emblem: String? { rank == nil ? nil : Team.glyph(teamIndex) }
    /// Director's visor band and expert's monocle sit on top of the eyes, so they get their own layer.
    var hasHeadOverlay: Bool { rank == .seniorDirector || rank == .seniorExpert }
}

/// The robot is cut into parts that animate independently. All parts except `prop` are drawn
/// on the shared robot canvas (`RobotArt.frame(_:)`), so they share one anchor.
enum RobotPart: Hashable {
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
private func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
private func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry + top, width: rx * 2, height: ry * 2), transform: nil)
}
private func poly(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: pts.map { P($0.0, $0.1) })
    p.closeSubpath()
    return p
}
private func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
    var pts: [(CGFloat, CGFloat)] = []
    for i in 0..<10 {
        let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        let rr = i % 2 == 0 ? r : r * 0.45
        pts.append((x + rr * cos(a), y + rr * sin(a)))
    }
    return poly(pts)
}

private let chromeColors = [NSColor.white, NSColor(hex: 0xDFE5FF), NSColor(hex: 0xB8C2EE), NSColor(hex: 0xEEF1FF)]
private let chromeStops: [CGFloat] = [0, 0.45, 0.55, 1]
private let gold = NSColor(hex: 0xFFCF3F), silver = NSColor(hex: 0xCFD6EA), cyan = NSColor(hex: 0x77CCFF)
private let waitingColor = NSColor(hex: 0xFFC95C)

/// Old `CAShapeLayer` / `CAGradientLayer` primitives replayed on a y-down `CGContext`.
private struct Pen {
    let ctx: CGContext
    let scale: CGFloat

    func shape(_ path: CGPath, fill: NSColor? = nil, stroke: NSColor? = nil, width: CGFloat = 1) {
        if let fill {
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    /// `CAGradientLayer` framed on the path's bounding box (outset 1 pt) and masked by the path.
    func gradient(_ path: CGPath, colors: [NSColor], locations: [CGFloat]? = nil, diagonal: Bool = true) {
        let box = path.boundingBox.insetBy(dx: -1, dy: -1)
        guard let g = CGGradient(colorsSpace: ArtKit.colorSpace, colors: colors.map(\.cgColor) as CFArray, locations: locations) else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: box.minX, y: box.minY),
                               end: diagonal ? CGPoint(x: box.maxX, y: box.maxY) : CGPoint(x: box.minX, y: box.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    func chrome(_ path: CGPath) { gradient(path, colors: chromeColors, locations: chromeStops) }

    /// A filled shape with a CA-style layer shadow (`shadowOffset = .zero`, no `shadowPath`): the shadow
    /// follows the fill's own alpha, exactly as Core Animation derived it from the layer contents.
    func glowing(_ path: CGPath, fill: NSColor, glow: NSColor, radius: CGFloat, opacity: CGFloat = 1) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: ArtKit.shadowBlur(radius: radius, scale: scale),
                      color: glow.withAlphaComponent(glow.alphaComponent * opacity).cgColor)
        shape(path, fill: fill)
        ctx.restoreGState()
    }

    func label(_ s: String, size: CGFloat, color: NSColor = .white, weight: NSFont.Weight = .semibold, at center: CGPoint) {
        ArtKit.drawLabel(s, size: size, color: color, weight: weight, center: center, ctx: ctx)
    }
}

// MARK: - RobotArt

/// Bakes robot parts into cached bitmaps at one backing scale.
final class RobotArt {
    let scale: CGFloat
    /// Transparent margin around name labels, so their shadow isn't clipped. The label's old
    /// `nameLayer` box is the image inset by this much on every side.
    static let namePadding: CGFloat = 3
    /// Transparent margin around `bubbleGlow` images (the bubble itself is inset by this much).
    static let bubbleGlowPadding: CGFloat = 8

    /// Where this scale's images are packed for batched drawing (see `RobotSprite.rebindTextures`).
    let atlas = TextureAtlas()

    /// Byte budgets (`bytesPerRow × height`) of the caches that keep recently baked images around while no
    /// sprite shows them: names and bubbles (open-ended strings), and parts and emoji (a bounded but, over
    /// many teams and ranks, sizeable set).
    static let textCostLimit = 4 << 20
    static let shapeCostLimit = 8 << 20

    private let lock = NSLock()
    /// Every image handed out and still alive (held by a sprite, the atlas or a cache below), so asking again
    /// returns the same object: the atlas keys images by identity, so a re-render would be packed twice.
    private let live = NSMapTable<NSString, CGImage>.strongToWeakObjects()
    private let shapes = NSCache<NSString, CGImage>()
    private let texts = NSCache<NSString, CGImage>()

    init(scale: CGFloat, textCostLimit: Int = RobotArt.textCostLimit, shapeCostLimit: Int = RobotArt.shapeCostLimit) {
        self.scale = scale
        texts.totalCostLimit = textCostLimit
        shapes.totalCostLimit = shapeCostLimit
    }

    /// What an image weighs in the caches.
    static func cost(_ img: CGImage) -> Int { img.bytesPerRow * img.height }

    private final class WeakArt { weak var art: RobotArt?; init(_ a: RobotArt) { art = a } }
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var instances: [CGFloat: WeakArt] = [:]

    /// One instance (and so one image cache and atlas) per backing scale, while anyone uses it: the scene
    /// holds the current scale's, robots the one they were baked with. After a scale change the old one
    /// goes (with its atlas) once the last robot baked with it is gone. So moving the window back to a
    /// display it was on before bakes that scale's robot art (and packs its atlas) again from scratch.
    static func shared(scale: CGFloat) -> RobotArt {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let a = instances[scale]?.art { return a }
        let a = RobotArt(scale: scale)
        instances = instances.filter { $0.value.art != nil }
        instances[scale] = WeakArt(a)
        return a
    }

    // MARK: Geometry

    /// Where a part's image sits in robot design space (points, y down, canvas origin at the
    /// canvas's top-left). Most parts cover exactly the 60×84 canvas; the sleep pod (x −6…66) and the
    /// glows of the halo and lark badge spill over it, so those three use a roomier frame. A prop's
    /// frame is its label box centred on (0, 0) — the old layer `position`.
    static func frame(_ part: RobotPart) -> CGRect {
        switch part {
        case .halo, .pod, .larkBadge:
            return CGRect(x: -10, y: 0, width: 80, height: 96)
        case let .prop(s):
            let sz = ArtKit.labelSize(s, size: 13, weight: .regular)
            return CGRect(x: -sz.width / 2, y: -sz.height / 2, width: sz.width, height: sz.height)
        default:
            return CGRect(origin: .zero, size: ArtKit.robotCanvas)
        }
    }

    /// The SpriteKit `anchorPoint` (y up) that pins `design` (robot design space, y down) for this part's image.
    static func anchorPoint(_ part: RobotPart, design p: CGPoint) -> CGPoint {
        let f = frame(part)
        return CGPoint(x: (p.x - f.minX) / f.width, y: 1 - (p.y - f.minY) / f.height)
    }

    // MARK: Cached images

    func image(_ part: RobotPart) -> CGImage {
        let key: RobotPart = part == .eyes(.calm) ? .eyes(.focused) : part
        return cached("p|\(key)", in: shapes) { render(key) }
    }

    /// An emoji (or any glyph) drawn like the old `prop(...)` text layers: white, regular weight,
    /// in a `textLayer` box (text width + 2 by `ceil(size × 1.3)`), meant to be centred on its position.
    func emoji(_ s: String, size: CGFloat) -> CGImage {
        cached("e|\(size)|\(s)", in: shapes) { renderLabel(s, size: size) }
    }

    /// The status bubble: 15 pt tall pill, 9 pt bold text, dark text on the waiting colour.
    func bubble(_ text: String, color: NSColor) -> CGImage {
        cachedText("b|\(Self.colorKey(color))|\(text)") {
            let fg = color == waitingColor ? NSColor(hex: 0x2A1A00) : .white
            let sz = Self.bubbleSize(text), w = sz.width, h = sz.height
            return ArtKit.image(size: sz, scale: scale) { ctx in
                let pen = Pen(ctx: ctx, scale: scale)
                pen.shape(rounded(CGRect(x: 0, y: 0, width: w, height: h), h / 2), fill: color)
                pen.label(text, size: 9, color: fg, weight: .bold, at: CGPoint(x: w / 2, y: h / 2))
            }
        }
    }

    /// Size in points of `bubble(text, color:)`: the 9 pt bold label plus 12, by 15.
    static func bubbleSize(_ text: String) -> CGSize {
        CGSize(width: ArtKit.labelSize(text, size: 9, weight: .bold).width + 12, height: 15)
    }

    /// The pulsing bubble's glow (the old `shadowRadius = 6` at full opacity), shadow only. The image is
    /// `bubbleGlowPadding` larger than `bubble(text, color:)` on every side and shares its centre.
    func bubbleGlow(_ text: String, color: NSColor) -> CGImage {
        cachedText("g|\(Self.colorKey(color))|\(text)") {
            let sz = Self.bubbleSize(text), w = sz.width, h = sz.height, pad = Self.bubbleGlowPadding
            return ArtKit.image(size: CGSize(width: w + pad * 2, height: h + pad * 2), scale: scale) { ctx in
                ArtKit.glow(rounded(CGRect(x: pad, y: pad, width: w, height: h), h / 2), color: color, radius: 6, scale: scale, ctx: ctx)
            }
        }
    }

    /// Two-line name label exactly like the old `setName`: semibold 11 (9 when `small`) in #E8EEFF, an
    /// optional second line 1.5 pt smaller in `stripe` (or #B8C4E8), centred, with a 1.5 pt black shadow.
    /// The old label box (≤ 130 wide) is the image inset by `namePadding`; it sat with its top at design y 82.
    func name(_ s: String, small: Bool, stripe: NSColor?) -> CGImage {
        cachedText("n|\(small)|\(stripe.map(Self.colorKey) ?? "-")|\(s)") {
            let (text, sz, box) = Self.nameLayout(s, small: small, stripe: stripe)
            let pad = Self.namePadding
            return ArtKit.image(size: CGSize(width: box.width + pad * 2, height: box.height + pad * 2), scale: scale) { ctx in
                let inner = CGRect(x: pad, y: pad, width: box.width, height: box.height)
                // The old layer was not wrapped: lay the text out wide, centred, and clip to the box.
                let layoutWidth = max(box.width, ceil(sz.width) + 4)
                let textRect = CGRect(x: inner.midX - layoutWidth / 2, y: inner.minY, width: layoutWidth, height: inner.height)
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: ArtKit.shadowBlur(radius: 1.5, scale: scale), color: NSColor.black.cgColor)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.saveGState()
                ctx.clip(to: inner)
                ArtKit.draw(text, in: textRect, ctx: ctx)
                ctx.restoreGState()
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
    }

    /// Size in points of `name(s, small:, stripe:)`: the old label box plus `namePadding` on every side.
    static func nameImageSize(_ s: String, small: Bool) -> CGSize {
        let box = nameLayout(s, small: small, stripe: nil).box
        return CGSize(width: box.width + namePadding * 2, height: box.height + namePadding * 2)
    }

    /// The old `setName` text, its unwrapped size, and the label box (≤ 130 wide).
    private static func nameLayout(_ s: String, small: Bool, stripe: NSColor?) -> (NSAttributedString, CGSize, box: CGSize) {
        let lines = s.components(separatedBy: "\n")
        let size: CGFloat = small ? 9 : 11
        let text = NSMutableAttributedString(string: lines[0], attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor(hex: 0xE8EEFF)])
        if lines.count > 1 {
            text.append(NSAttributedString(string: "\n" + lines[1], attributes: [.font: NSFont.systemFont(ofSize: size - 1.5, weight: .medium), .foregroundColor: stripe ?? NSColor(hex: 0xB8C4E8)]))
        }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        let sz = text.boundingRect(with: NSSize(width: 200, height: 100), options: [.usesLineFragmentOrigin]).size
        return (text, sz, CGSize(width: min(ceil(sz.width) + 4, 130), height: ceil(sz.height) + 2))
    }

    /// The yellow "?" sign held up while waiting at the door (16×14, centred on its position).
    func doorSign() -> CGImage {
        cachedText("sign") {
            ArtKit.image(size: CGSize(width: 16, height: 14), scale: scale) { ctx in
                let pen = Pen(ctx: ctx, scale: scale)
                pen.shape(rounded(CGRect(x: 0, y: 0, width: 16, height: 14), 3), fill: waitingColor)
                pen.label("?", size: 11, color: NSColor(hex: 0x2A1A00), weight: .black, at: CGPoint(x: 8, y: 7))
            }
        }
    }

    private func cachedText(_ key: String, _ make: () -> CGImage) -> CGImage { cached(key, in: texts, make) }

    /// The live image for `key`, else one from `cache`, else a fresh one (kept in `cache` at its byte cost).
    private func cached(_ key: String, in cache: NSCache<NSString, CGImage>, _ make: () -> CGImage) -> CGImage {
        let k = key as NSString
        lock.lock(); defer { lock.unlock() }
        if let img = cache.object(forKey: k) { return img }
        if let img = live.object(forKey: k) {
            cache.setObject(img, forKey: k, cost: Self.cost(img))
            return img
        }
        let img = make()
        live.setObject(img, forKey: k)
        cache.setObject(img, forKey: k, cost: Self.cost(img))
        return img
    }

    private static func colorKey(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "%.4f,%.4f,%.4f,%.4f", s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }

    private func renderLabel(_ s: String, size: CGFloat) -> CGImage {
        let box = ArtKit.labelSize(s, size: size, weight: .regular)
        return ArtKit.image(size: box, scale: scale) { ctx in
            ArtKit.drawLabel(s, size: size, color: .white, weight: .regular, center: CGPoint(x: box.width / 2, y: box.height / 2), ctx: ctx)
        }
    }

    // MARK: Drawing

    private func render(_ part: RobotPart) -> CGImage {
        if case let .prop(s) = part { return renderLabel(s, size: 13) }
        let f = Self.frame(part)
        return ArtKit.image(size: f.size, scale: scale) { ctx in
            ctx.translateBy(x: -f.minX, y: -f.minY)
            let pen = Pen(ctx: ctx, scale: scale)
            switch part {
            case .halo:
                let p = oval(30, 66, 15, 3.6)
                pen.glowing(p, fill: NSColor.white.withAlphaComponent(0.85), glow: .white, radius: 5)
            case let .torso(look): drawTorso(look, pen)
            case let .head(look): drawHead(look, pen)
            case let .headOverlay(look): drawHeadOverlay(look, pen)
            case .leftHand: pen.chrome(oval(11, 47, 4.5, 4.5))
            case .rightHand: pen.chrome(oval(49, 47, 4.5, 4.5))
            case .ears:
                for x in [8.5, 51.5] as [CGFloat] { pen.shape(oval(x, 20, 4.5, 4.5), fill: cyan) }
            case .ring: pen.shape(oval(30, 38.5, 9, 2), stroke: cyan, width: 1.2)
            case let .eyes(face): drawEyes(face, pen)
            case .pod:
                // Old pod: a CALayer at (-6, 8, 72, 76), corner radius 34, 1 pt border inside the bounds.
                let r = CGRect(x: -6, y: 8, width: 72, height: 76)
                pen.shape(rounded(r, 34), fill: NSColor(hex: 0x968CFF, alpha: 0.16))
                pen.shape(rounded(r.insetBy(dx: 0.5, dy: 0.5), 33.5), stroke: NSColor(hex: 0xB4AAFF, alpha: 0.55), width: 1)
            case .larkBadge:
                let c = P(52, 4)
                let b = rounded(CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14), 4)
                pen.glowing(b, fill: NSColor(hex: 0x3370FF), glow: NSColor(hex: 0x3370FF), radius: 5)
                pen.label("飞", size: 8.5, weight: .bold, at: c)
            case .prop:
                break
            }
        }
    }

    private func drawTorso(_ look: RobotLook, _ pen: Pen) {
        let rank = look.rank
        if rank == .newGrad {   // backpack straps behind the body
            pen.shape(rounded(R(16, 42, 5, 13), 2), fill: NSColor(hex: 0xFF9F43))
            pen.shape(rounded(R(39, 42, 5, 13), 2), fill: NSColor(hex: 0xFF9F43))
        }
        pen.chrome(rounded(R(19, 41, 22, 17), 8.5))
        let stripe = CGMutablePath(); stripe.move(to: P(23, 52)); stripe.addLine(to: P(37, 52))
        pen.shape(stripe, stroke: rank?.stripe ?? look.teamColor, width: 2.5)
        if let rank { drawBodyAccessories(rank, pen) }
        if let emblem = look.emblem {   // team emblem pendant on the neck ring
            pen.shape(poly((0..<6).map { i in let a = CGFloat(i) * .pi / 3; return (30 + 4.6 * cos(a), 38.5 + 4.6 * sin(a)) }),
                      fill: look.teamColor, stroke: .white, width: 0.6)
            pen.label(emblem, size: 5.5, color: NSColor(hex: 0x0A0F2C), weight: .black, at: P(30, 38.6))
        }
        if look.larkSession {
            pen.shape(rounded(R(40, 49, 9, 9), 2.5), fill: NSColor(hex: 0x3370FF))
            pen.label("飞", size: 5.6, weight: .bold, at: P(44.5, 53.5))
        }
    }

    private func drawBodyAccessories(_ rank: Rank, _ pen: Pen) {
        switch rank {
        case .seniorDirector:
            let cape = CGMutablePath(); cape.move(to: P(19, 45)); cape.addLine(to: P(30, 51)); cape.addLine(to: P(41, 45)); cape.addLine(to: P(41, 55)); cape.addQuadCurve(to: P(19, 55), control: P(30, 60)); cape.closeSubpath()
            pen.shape(cape, fill: NSColor(hex: 0x5B2BB5))
            pen.shape(poly([(19, 45), (24, 44), (30, 51)]), fill: NSColor(hex: 0x7D4BE0))
            pen.shape(poly([(41, 45), (36, 44), (30, 51)]), fill: NSColor(hex: 0x7D4BE0))
            pen.shape(poly([(30, 46), (28.2, 49), (30, 57), (31.8, 49)]), fill: gold)
            pen.shape(star(36.5, 47.5, 2.4), fill: gold)
            pen.shape(star(23.5, 47.5, 2.4), fill: gold)
        case .seniorExpert:
            let vest = CGMutablePath(); vest.move(to: P(20, 45)); vest.addLine(to: P(30, 49)); vest.addLine(to: P(40, 45)); vest.addLine(to: P(40, 55)); vest.addQuadCurve(to: P(20, 55), control: P(30, 59)); vest.closeSubpath()
            pen.shape(vest, fill: NSColor(hex: 0x23407A))
            pen.shape(oval(30, 51.5, 0.9, 0.9), fill: silver)
            pen.shape(oval(30, 54.5, 0.9, 0.9), fill: silver)
            pen.shape(poly([(26, 44.5), (30, 46.3), (34, 44.5), (34, 48.1), (30, 46.3), (26, 48.1)]), fill: silver)
        case .seniorEngineer:
            let blue = NSColor(hex: 0x4CC3FF)
            let lan = CGMutablePath(); lan.move(to: P(22, 41)); lan.addLine(to: P(30, 47)); lan.addLine(to: P(38, 41))
            pen.shape(lan, stroke: blue, width: 1.2)
            pen.shape(rounded(R(26.5, 46, 7, 6), 1.5), fill: .white, stroke: blue, width: 0.8)
        case .newGrad:
            let red = NSColor(hex: 0xFF7A7A)
            let lan = CGMutablePath(); lan.move(to: P(25, 41)); lan.addLine(to: P(30, 48)); lan.addLine(to: P(35, 41))
            pen.shape(lan, stroke: red, width: 1.2)
            pen.shape(rounded(R(26.5, 47, 7, 6), 1.5), fill: .white, stroke: red, width: 0.8)
            pen.shape(rounded(R(27.8, 48.5, 4.4, 1), 0.5), fill: red)
        }
    }

    private func drawHead(_ look: RobotLook, _ pen: Pen) {
        pen.chrome(rounded(R(9, 5, 42, 30), 15))
        pen.gradient(rounded(R(13, 10, 34, 19), 9.5), colors: [NSColor(hex: 0x16204F), NSColor(hex: 0x0A0F2C)], diagonal: false)
        let shine = CGMutablePath(); shine.move(to: P(16, 8)); shine.addQuadCurve(to: P(34, 6), control: P(24, 5))
        pen.shape(shine, stroke: .white, width: 2)
        // Head accessories that never overlap the face (the rest are in `headOverlay`).
        switch look.rank {
        case .seniorEngineer:
            let blue = NSColor(hex: 0x4CC3FF)
            let arc = CGMutablePath(); arc.addArc(center: P(30, 22), radius: 24, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            pen.shape(arc, stroke: blue, width: 2.6)
            pen.shape(rounded(R(3, 16, 6, 10), 2.5), fill: blue)
            pen.shape(rounded(R(51, 16, 6, 10), 2.5), fill: blue)
            let mic = CGMutablePath(); mic.move(to: P(6, 25)); mic.addQuadCurve(to: P(19, 34), control: P(7, 34))
            pen.shape(mic, stroke: blue, width: 1.4)
            pen.shape(oval(19, 34, 1.6, 1.6), fill: blue)
        case .newGrad:
            let stem = CGMutablePath(); stem.move(to: P(30, 5)); stem.addLine(to: P(30, -3))
            pen.shape(stem, stroke: NSColor(hex: 0x44CC44), width: 2)
            pen.shape(oval(26, -3, 4.2, 2.3), fill: NSColor(hex: 0x66DD66))
            pen.shape(oval(34, -3, 4.2, 2.3), fill: NSColor(hex: 0x66DD66))
        default:
            break
        }
        if look.kind == .contractor {   // yellow hard hat
            let hat = CGMutablePath()
            hat.move(to: P(14, 11)); hat.addQuadCurve(to: P(46, 11), control: P(30, -6)); hat.closeSubpath()
            pen.glowing(hat, fill: NSColor(hex: 0xFFCC33), glow: NSColor(hex: 0xFFCC33), radius: 4, opacity: 0.8)
            pen.shape(rounded(R(11, 10, 38, 3), 1.5), fill: NSColor(hex: 0xE0A800))
        }
    }

    private func drawHeadOverlay(_ look: RobotLook, _ pen: Pen) {
        switch look.rank {
        case .seniorDirector:
            pen.shape(rounded(R(14, 13, 32, 5), 2.5), fill: NSColor(hex: 0x1A1030, alpha: 0.85), stroke: gold, width: 1)
        case .seniorExpert:
            pen.shape(oval(37.7, 19.5, 6, 6), fill: NSColor(hex: 0xC8E6FF, alpha: 0.12), stroke: silver, width: 1.6)
            let chain = CGMutablePath(); chain.move(to: P(43.5, 21)); chain.addQuadCurve(to: P(41, 40), control: P(46, 30))
            pen.shape(chain, stroke: silver, width: 0.8)
        default:
            break
        }
    }

    private func drawEyes(_ face: RobotFace, _ pen: Pen) {
        let cx: CGFloat = 30, cy: CGFloat = 19.5, dx: CGFloat = 8
        switch face {
        case .focused, .calm:
            for x in [cx - dx, cx + dx] {
                let e = rounded(R(x - 2.75, cy - 4, 5.5, 8), 2.2)
                pen.glowing(e, fill: NSColor(hex: 0x77FFFF), glow: NSColor(hex: 0x77FFFF), radius: 2, opacity: 0.9)
            }
        case .happy:
            let p = CGMutablePath()
            for x in [cx - dx, cx + dx] { p.move(to: P(x - 3.3, cy + 1.6)); p.addQuadCurve(to: P(x + 3.3, cy + 1.6), control: P(x, cy - 3.8)) }
            pen.shape(p, stroke: NSColor(hex: 0x6FF0A8), width: 2.2)
        case .waiting:
            for x in [cx - dx, cx + dx] {
                pen.shape(oval(x, cy - 1, 3.3, 3.3), fill: NSColor(hex: 0xFFC95C))
                pen.shape(oval(x + 1.1, cy - 2.2, 1.1, 1.1), fill: .white)
            }
        case .error:
            let p = CGMutablePath()
            for x in [cx - dx, cx + dx] {
                p.move(to: P(x - 2.8, cy - 2.8)); p.addLine(to: P(x + 2.8, cy + 2.8))
                p.move(to: P(x + 2.8, cy - 2.8)); p.addLine(to: P(x - 2.8, cy + 2.8))
            }
            pen.shape(p, stroke: NSColor(hex: 0xFF5A5A), width: 2)
        case .asleep:
            let p = CGMutablePath()
            for x in [cx - dx, cx + dx] { p.move(to: P(x - 3.3, cy)); p.addLine(to: P(x + 3.3, cy)) }
            pen.shape(p, stroke: NSColor(hex: 0x9A93D8), width: 2)
        }
    }
}
