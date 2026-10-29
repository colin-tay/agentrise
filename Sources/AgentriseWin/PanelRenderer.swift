// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import Agentrise
import AgentriseScene
import AgentriseWinArt

/// The "待处理 / 组织架构" panel, drawn with the same `Pen` as the scene: the macOS `PanelView` (SwiftUI) as one
/// `ArtDrawing` on a sprite above everything else in the scene tree (`node`, z 2000). A column in landscape, a strip
/// in portrait, cards for who waits on you and who is done, rows for who works, the sleep pods behind a toggle, and the
/// toast at the bottom. It is drawn again only when something it shows changes: the published state, the hovered
/// row, the layout or scale, the scroll offset, the sleepers toggle, or an age text ("N 分钟", checked once a minute).
package final class PanelRenderer {
    package let node = SceneNode(name: "panel", sprite: true)
    package static let zPosition: CGFloat = 2_000

    package private(set) var state = TowerPanelState()
    /// The session highlighted from the panel or the tower (its row gets the team colour).
    package var hovered: String? { didSet { if hovered != oldValue { dirty = true } } }
    package private(set) var showSleepers = false
    /// Points scrolled: down in the column, right in the strip.
    package private(set) var scroll: CGFloat = 0
    /// Where the panel sits (layout coordinates, top-left origin).
    package private(set) var rect: CGRect = .zero
    private var orientation: TowerOrientation = .landscape
    private var scale: CGFloat = 1
    private var sceneHeight: CGFloat = 0
    private var contentLength: CGFloat = 0
    private var hits: [(rect: CGRect, hit: Hit)] = []
    private var dirty = true
    private let measure: TextMeasuring
    /// The age texts in the last drawing, cards in order.
    private var agesDrawn: [String] = []
    /// Now, for the ages (tests set it).
    package var clock: () -> Date = Date.init

    /// Panels drawn (tests).
    package private(set) var drawCount = 0
    /// Clicked a card or row.
    package var onOpen: ((String) -> Void)?
    /// The pointer went over a card or row (nil: off them).
    package var onHover: ((String?) -> Void)?

    package enum Hit: Equatable { case session(String), sleepers }

    package init(measure: TextMeasuring = D2DArtBackend.shared) {
        self.measure = measure
        node.zPosition = Self.zPosition
        node.anchorPoint = CGPoint(x: 0, y: 1)   // top-left
    }

    package func update(_ s: TowerPanelState) {
        guard s != state else { return }
        state = s
        dirty = true
    }

    /// The scene's layout (or scale) changed.
    package func layout(_ geo: BuildingLayout, scale: CGFloat) {
        guard geo.panel != rect || geo.orientation != orientation || scale != self.scale || geo.size.height != sceneHeight else { return }
        if geo.orientation != orientation { scroll = 0 }
        rect = geo.panel
        orientation = geo.orientation
        self.scale = scale
        sceneHeight = geo.size.height
        node.position = CGPoint(x: rect.minX, y: sceneHeight - rect.minY)
        node.size = rect.size
        dirty = true
    }

    /// A minute passed: draw again on the next frame if an age text ("3 分钟" → "4 分钟") changed.
    package func refreshAges() {
        if ages(now: clock()) != agesDrawn { dirty = true }
    }

    /// The age texts the panel shows: waiting and done cards in the column, waiting cards only in the strip.
    private func ages(now: Date) -> [String] {
        (orientation == .landscape ? state.waiting + state.done : state.waiting).map { $0.age(now: now) }
    }

    /// Draws the panel again if anything it shows changed (called before each render, never per frame otherwise).
    package func prepare() {
        guard dirty, rect.width >= 1, rect.height >= 1 else { return }
        dirty = false
        let now = clock()
        var plan = makePlan(now: now)
        // The content got shorter (or the panel taller): scroll back within it.
        let limit = max(0, plan.length - (orientation == .landscape ? rect.height : rect.width))
        if scroll > limit {
            scroll = limit
            plan = makePlan(now: now)
        }
        agesDrawn = ages(now: now)
        hits = plan.hits
        contentLength = plan.length
        let size = rect.size, elements = plan.elements, landscape = orientation == .landscape
        node.drawing = ArtDrawing(size: size, scale: scale) { pen in Self.draw(elements, size: size, landscape: landscape, pen: pen) }
        drawCount += 1
    }

    // MARK: Pointer

    package func contains(_ layoutPoint: CGPoint) -> Bool { rect.contains(layoutPoint) }

    /// What is under a layout point.
    package func hit(at layoutPoint: CGPoint) -> Hit? {
        guard rect.contains(layoutPoint) else { return nil }
        let p = CGPoint(x: layoutPoint.x - rect.minX, y: layoutPoint.y - rect.minY)
        return hits.last { $0.rect.contains(p) }?.hit
    }

    package func click(at layoutPoint: CGPoint) {
        switch hit(at: layoutPoint) {
        case .session(let id): onOpen?(id)
        case .sleepers:
            showSleepers.toggle()
            dirty = true
        case nil: break
        }
    }

    /// The pointer is at a layout point (nil: it left the panel): hovering a card or row highlights its team.
    package func hover(at layoutPoint: CGPoint?) {
        var sid: String?
        if let p = layoutPoint, case .session(let id) = hit(at: p) { sid = id }
        if sid != hoverReported {
            hoverReported = sid
            onHover?(sid)
        }
    }
    private var hoverReported: String?

    /// A wheel turn of `notches` (positive: towards the user, i.e. scroll down/right).
    package func scroll(notches: CGFloat) {
        let limit = max(0, contentLength - (orientation == .landscape ? rect.height : rect.width))
        let next = min(limit, max(0, scroll + notches * 40))
        guard next != scroll else { return }
        scroll = next
        dirty = true
    }

    // MARK: Plan

    private enum Element {
        case fill(ArtPath, Color)
        case stroke(ArtPath, Color, CGFloat)
        case line([TextRun], CGRect, truncates: Bool)
        case emoji(String, CGFloat, CGPoint)
    }

    private struct Plan {
        var elements: [Element] = []
        var hits: [(rect: CGRect, hit: Hit)] = []
        var length: CGFloat = 0
    }

    static let amber = Color(r: 1, g: 0.79, b: 0.36)
    static let green = Color(r: 0.44, g: 0.94, b: 0.66)
    static let red = Color(r: 1, g: 0.23, b: 0.19)
    static let ink = Color(r: 0.87, g: 0.9, b: 1)
    static let sub = Color(r: 0.56, g: 0.61, b: 0.88)
    static let white = Color(r: 1, g: 1, b: 1)
    static let larkBlue = Color(r: 0.2, g: 0.44, b: 1)
    static let panelFill = Color(r: 0.04, g: 0.055, b: 0.15, a: 0.9)
    static let panelBorder = Color(r: 0.23, g: 0.27, b: 0.59)
    static let sleepColor = Color(r: 0.72, g: 0.69, b: 1)
    static let glyphInk = Color(r: 0.04, g: 0.06, b: 0.15)

    private func size(_ runs: [TextRun], width: CGFloat = .infinity, lines: Int = 1) -> CGSize {
        let s = measure.measure(runs, maxWidth: width, maxLines: lines)
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    private func run(_ s: String, _ size: CGFloat, _ weight: FontWeight = .regular, _ color: Color) -> [TextRun] {
        [TextRun(s, font: FontSpec(size: size, weight: weight), color: color)]
    }

    private func makePlan(now: Date) -> Plan {
        var plan = Plan()
        if orientation == .landscape { column(&plan, now: now) } else { strip(&plan, now: now) }
        toast(&plan)
        return plan
    }

    private func column(_ plan: inout Plan, now: Date) {
        let pad: CGFloat = 10, spacing: CGFloat = 6
        let x = pad, width = rect.width - 2 * pad
        var y = pad - scroll
        func text(_ runs: [TextRun], top: CGFloat = 0, bottom: CGFloat = 0, hit: Hit? = nil) {
            y += top
            let s = size(runs)
            plan.elements.append(.line(runs, CGRect(x: x, y: y, width: width, height: s.height), truncates: true))
            if let hit { plan.hits.append((CGRect(x: x, y: y, width: min(width, s.width), height: s.height), hit)) }
            y += s.height + bottom + spacing
        }
        text(run("待处理 / 组织架构", 12, .bold, Self.white), bottom: 2)
        if state.waiting.isEmpty && state.done.isEmpty { text(run("没有需要你处理的", 11, .regular, Self.sub)) }
        for s in state.waiting {
            let error = s.status == .error
            let detail = (s.summary ?? (error ? "出错了" : "在等你回复")) + " · \(s.age(now: now))"
            y += card(s, color: error ? Self.red : Self.amber, icon: error ? "⚠️" : "🙋", detail: detail,
                      frame: CGRect(x: x, y: y, width: width, height: 0), &plan) + spacing
        }
        for s in state.done {
            y += card(s, color: Self.green, icon: "✓", detail: "做完了 · \(s.age(now: now))",
                      frame: CGRect(x: x, y: y, width: width, height: 0), &plan) + spacing
        }
        text(run("干活中", 10.5, .regular, Self.sub), top: 6)
        for s in state.working { y += row(s, frame: CGRect(x: x, y: y, width: width, height: 0), &plan) + spacing }
        text(run("🌙 睡眠舱 \(state.sleeping.count) \(showSleepers ? "▾" : "▸")", 11, .regular, Self.sleepColor), top: 6, hit: .sleepers)
        if showSleepers {
            for s in state.sleeping { y += row(s, frame: CGRect(x: x, y: y, width: width, height: 0), &plan) + spacing }
        }
        plan.length = y + scroll - spacing + pad
    }

    private func strip(_ plan: inout Plan, now: Date) {
        let pad: CGFloat = 6, spacing: CGFloat = 6
        var x = pad - scroll
        let top = pad, height = rect.height - 2 * pad
        if state.waiting.isEmpty && state.done.isEmpty {
            let runs = run("没有需要你处理的", 11, .regular, Self.sub)
            let s = size(runs)
            plan.elements.append(.line(runs, CGRect(x: x + 8, y: (rect.height - s.height) / 2, width: s.width + 2, height: s.height), truncates: false))
            x += s.width + 16 + spacing
        }
        for s in state.waiting {
            x += card(s, color: s.status == .error ? Self.red : Self.amber, icon: "🙋", detail: s.age(now: now),
                      frame: CGRect(x: x, y: top, width: 220, height: height), fitWidth: true, &plan) + spacing
        }
        for s in state.done {
            x += card(s, color: Self.green, icon: "✓", detail: "做完了",
                      frame: CGRect(x: x, y: top, width: 200, height: height), fitWidth: true, &plan) + spacing
        }
        plan.length = x + scroll - spacing + pad
    }

    /// A card: icon, bold title (one line) and the lark badge, then the detail (up to two lines). Returns the card's
    /// height (column) or width (strip, `fitWidth`: as wide as its content, at most `frame.width`).
    private func card(_ s: PanelEntry, color: Color, icon: String, detail: String, frame: CGRect, fitWidth: Bool = false,
                      _ plan: inout Plan) -> CGFloat {
        let titleRuns = run(s.title, 11.5, .bold, Self.ink)
        let detailRuns = run(detail, 10.5, .regular, Self.sub)
        let emojiIcon = icon != "✓"
        let iconRuns = run(icon, 11.5, .bold, color)
        let iconSize = emojiIcon ? CGSize(width: 15, height: 15) : size(iconRuns)
        let lark = s.lark ? larkBadgeSize() : .zero
        let titleSize = size(titleRuns)
        var width = frame.width
        if fitWidth {
            let line1 = iconSize.width + 4 + titleSize.width + (s.lark ? 4 + lark.width : 0)
            width = min(frame.width, 16 + max(line1, size(detailRuns).width))
        }
        let inner = width - 16
        let line1H = max(titleSize.height, iconSize.height)
        let detailH = size(detailRuns, width: inner, lines: 2).height
        let height = fitWidth ? frame.height : 5 + line1H + 2 + detailH + 5
        let box = CGRect(x: frame.minX, y: frame.minY, width: width, height: height)
        plan.elements.append(.fill(.roundedRect(box, radius: 8), color.withAlpha(0.12)))
        plan.elements.append(.stroke(.roundedRect(box.insetBy(dx: 0.5, dy: 0.5), radius: 7.5), color, 1))
        var x = box.minX + 8
        let y = box.minY + 5
        if emojiIcon {
            plan.elements.append(.emoji(icon, 11, CGPoint(x: x + iconSize.width / 2, y: y + line1H / 2)))
        } else {
            plan.elements.append(.line(iconRuns, CGRect(x: x, y: y + (line1H - iconSize.height) / 2, width: iconSize.width + 2, height: iconSize.height), truncates: false))
        }
        x += iconSize.width + 4
        let titleWidth = max(0, min(titleSize.width, box.maxX - 8 - x - (s.lark ? 4 + lark.width : 0)))
        plan.elements.append(.line(titleRuns, CGRect(x: x, y: y + (line1H - titleSize.height) / 2, width: titleWidth, height: titleSize.height), truncates: true))
        if s.lark { larkBadge(at: CGPoint(x: x + titleWidth + 4, y: y + (line1H - lark.height) / 2), &plan) }
        plan.elements.append(.line(detailRuns, CGRect(x: box.minX + 8, y: y + line1H + 2, width: inner, height: detailH + 0.5), truncates: false))
        plan.hits.append((box, .session(s.id)))
        return fitWidth ? width : height
    }

    /// A row: the team mark in a team-coloured disc, the title (one line), the lark badge, and the counts on the
    /// right; tinted with the team colour while hovered. Returns its height.
    private func row(_ s: PanelEntry, frame: CGRect, _ plan: inout Plan) -> CGFloat {
        let team = Team.color(s.teamIndex)
        let titleRuns = run(s.title, 11, .semibold, Self.ink)
        let countRuns = run(s.countsText, 9.5, .regular, Self.sub)
        let titleSize = size(titleRuns), countSize = size(countRuns)
        let lineH = max(14, titleSize.height)
        let box = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 3 + lineH + 3)
        if hovered == s.id { plan.elements.append(.fill(.roundedRect(box, radius: 6), team.withAlpha(0.2))) }
        var x = box.minX + 5
        let midY = box.minY + 3 + lineH / 2
        let disc = CGRect(x: x, y: midY - 7, width: 14, height: 14)
        plan.elements.append(.fill(.ellipse(in: disc), team))
        let glyphRuns = run(Team.glyph(s.teamIndex), 9, .black, Self.glyphInk)
        let g = size(glyphRuns)
        plan.elements.append(.line(glyphRuns, CGRect(x: disc.midX - g.width / 2, y: disc.midY - g.height / 2, width: g.width + 2, height: g.height), truncates: false))
        x = disc.maxX + 5
        let countX = box.maxX - 5 - countSize.width
        let lark = s.lark ? larkBadgeSize() : .zero
        let titleWidth = max(0, min(titleSize.width, countX - 4 - x - (s.lark ? 5 + lark.width : 0)))
        plan.elements.append(.line(titleRuns, CGRect(x: x, y: midY - titleSize.height / 2, width: titleWidth, height: titleSize.height), truncates: true))
        if s.lark { larkBadge(at: CGPoint(x: x + titleWidth + 5, y: midY - lark.height / 2), &plan) }
        plan.elements.append(.line(countRuns, CGRect(x: countX, y: midY - countSize.height / 2, width: countSize.width + 2, height: countSize.height), truncates: false))
        plan.hits.append((box, .session(s.id)))
        return box.height
    }

    private func larkBadgeSize() -> CGSize {
        let s = size(run("飞", 8.5, .bold, Self.white))
        return CGSize(width: s.width + 6, height: s.height)
    }

    private func larkBadge(at p: CGPoint, _ plan: inout Plan) {
        let runs = run("飞", 8.5, .bold, Self.white)
        let s = size(runs)
        let box = CGRect(x: p.x, y: p.y, width: s.width + 6, height: s.height)
        plan.elements.append(.fill(.roundedRect(box, radius: 3), Self.larkBlue))
        plan.elements.append(.line(runs, CGRect(x: box.minX + 3, y: box.minY, width: s.width + 2, height: s.height), truncates: false))
    }

    private func toast(_ plan: inout Plan) {
        guard let t = state.toast else { return }
        let runs = run(t, 11, .semibold, Self.white)
        let s = size(runs, width: max(10, rect.width - 36))
        let box = CGRect(x: (rect.width - s.width - 20) / 2, y: rect.height - 8 - s.height - 12, width: s.width + 20, height: s.height + 12)
        plan.elements.append(.fill(.roundedRect(box, radius: box.height / 2), Self.larkBlue))
        plan.elements.append(.line(runs, CGRect(x: box.minX + 10, y: box.minY + 6, width: s.width + 1, height: s.height + 0.5), truncates: false))
    }

    // MARK: Drawing

    private static func draw(_ elements: [Element], size: CGSize, landscape: Bool, pen: Pen) {
        let outer = CGRect(origin: .zero, size: size)
        pen.fill(.roundedRect(outer, radius: 10), panelFill)
        if landscape { pen.stroke(.roundedRect(outer.insetBy(dx: 0.5, dy: 0.5), radius: 9.5), panelBorder, width: 1) }
        pen.clipped(to: .roundedRect(outer, radius: 10)) {
            for e in elements {
                switch e {
                case let .fill(p, c): pen.fill(p, c)
                case let .stroke(p, c, w): pen.stroke(p, c, width: w)
                case let .line(runs, r, truncates): pen.textLine(runs, in: r, truncatesTail: truncates)
                case let .emoji(s, size, center): pen.emoji(s, size: size, center: center)
                }
            }
        }
    }
}
#endif
