// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import CDirect2D
import Foundation
import WinSDK
import WinSDK.DirectX
import AgentriseScene

/// `Pen` on a Direct2D 1.1 device context drawing into a WIC bitmap (see `D2DArtBackend`). The target is at
/// 96 × `scale` dpi, so DIPs are points; the world transform stays the identity and `translated(by:)` is applied to
/// the coordinates as they are converted.
///
/// Shadows, global alpha and transparency layers follow Core Graphics' semantics (what `CGPen` does): a command drawn
/// while `shadowed` or `faded` is rendered alone into a transparent offscreen bitmap of the canvas's size, whose
/// shadow (Direct2D's Shadow effect) and then itself are composited onto the current target. Solid and gradient fills
/// and strokes take the global alpha as their brush opacity instead, when they cast no shadow. `layer` draws its body
/// into such a bitmap and composites it the same way. Clips are layers (or axis-aligned clips for a lone rectangle)
/// on the current target, so they cut whatever is composited onto it, shadows included.
package final class D2DPen: Pen {
    /// The Shadow effect's standard deviation, in DIPs, per point of Core Animation `shadowRadius` (`Pen.shadowed`'s
    /// `blur`). Calibrated against the macOS renders (CG's blur is `ArtKit.blurPerShadowRadius` = 0.65 × scale device
    /// pixels per point, measured to be a Gaussian of σ ≈ 0.32–0.36 pt per point of radius), then by eye on the
    /// side-by-side comparisons (`ComparisonScenes`).
    package static let blurCalibration: CGFloat = 0.31

    /// DirectWrite lays Segoe UI out with a line height of 1.33 em and its baseline 1.08 em down; AppKit lays the
    /// macOS system font out at about 1.25 em with its baseline 1 em down (both measured at the art's sizes). Each
    /// layout scales its lines by these factors (`DWRITE_LINE_SPACING_METHOD_PROPORTIONAL`), so text sits where it
    /// does on macOS in the same boxes.
    static let lineHeightFactor: CGFloat = 0.94
    static let baselineFactor: CGFloat = 0.927

    /// Segoe UI Emoji draws its glyphs about 0.8 × the size of Apple Color Emoji's at the same point size (measured
    /// on the emoji props), so a text of emoji only (a prop, `Pen.emoji`) is laid out this much larger, on a line
    /// box of the unscaled size and with its baseline put back so the glyph's centre stays where it was. Emoji
    /// inside other text keep their size, so the text's lines and baselines don't move.
    static let emojiScale: CGFloat = 1.25
    static let emojiBaselineFactor: CGFloat = 0.80

    /// Text rendering: grayscale antialiasing (the bitmaps are transparent), natural symmetric rendering, gamma 1.8
    /// (DirectWrite's default) and, while font smoothing is on, the default grayscale enhanced contrast, which
    /// darkens stems as macOS font smoothing does. Off, there is none (`setFontSmoothing(false)`).
    static let textGamma: Float = 1.8
    static let smoothingContrast: Float = 1

    package let scale: CGFloat
    private let backend: D2DArtBackend
    /// The canvas in DIPs (the bitmap's pixels / scale).
    private let canvas: D2D1_RECT_F

    /// The device context drawn on now: the bake's target, or an offscreen bitmap's while a shadowed command or a
    /// layer is drawn.
    private var target: COMObject
    private var state = State()
    private var smoothing = true

    private struct Shadow { var offset: CGSize; var blur: CGFloat; var color: Color }
    private struct State {
        var offset = CGSize.zero
        var alpha: CGFloat = 1
        var shadow: Shadow?
    }

    init(backend: D2DArtBackend, target: COMObject, pixelSize: (width: Int, height: Int), scale: CGFloat) {
        self.backend = backend
        self.target = target
        self.scale = scale
        canvas = D2D1_RECT_F(left: 0, top: 0, right: Float(CGFloat(pixelSize.width) / scale), bottom: Float(CGFloat(pixelSize.height) / scale))
    }

    /// Draws a whole bake on `target`.
    func run(_ draw: (Pen) -> Void) {
        begin(target)
        draw(self)
        end(target, "bake")
    }

    // MARK: Pen

    package func fill(_ p: ArtPath, _ c: Color) {
        command(brushAlpha: true) { dc, alpha in
            let g = geometry(p), brush = solid(c, opacity: alpha, on: dc)
            rt(dc).FillGeometry!(dc, g.object, brush.object, nil)
        }
    }

    package func stroke(_ p: ArtPath, _ c: Color, width: CGFloat) {
        command(brushAlpha: true) { dc, alpha in
            let g = geometry(p), brush = solid(c, opacity: alpha, on: dc)
            rt(dc).DrawGeometry!(dc, g.object, brush.object, Float(width), backend.roundStroke)
        }
    }

    package func linearGradient(_ p: ArtPath, colors: [Color], locations: [CGFloat]?, from: CGPoint, to: CGPoint, extend: Bool) {
        guard !colors.isEmpty else { return }
        command(brushAlpha: true) { dc, alpha in
            let vt = rt(dc)
            var stops = colors.enumerated().map { i, c in
                D2D1_GRADIENT_STOP(position: Float(locations?[i] ?? (colors.count == 1 ? 0 : CGFloat(i) / CGFloat(colors.count - 1))),
                                   color: d2dColor(c))
            }
            let collection = COMRef(created("ID2D1RenderTarget::CreateGradientStopCollection") {
                vt.CreateGradientStopCollection!(dc, &stops, UInt32(stops.count), D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP, $0)
            })
            var line = D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES(startPoint: point(from), endPoint: point(to))
            var props = brushProperties(alpha)
            let brush = COMRef(created("ID2D1RenderTarget::CreateLinearGradientBrush") {
                vt.CreateLinearGradientBrush!(dc, &line, &props, collection.object, $0)
            })
            let g = geometry(p)
            guard !extend else { return vt.FillGeometry!(dc, g.object, brush.object, nil) }
            // Without `extend`, only pixels whose centre lies between the end points' perpendiculars are painted:
            // an aliased mask of that band (aliased rasterisation keeps exactly the pixels whose centres are inside).
            let dx = to.x - from.x, dy = to.y - from.y, length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return }
            let far: CGFloat = 1e5, nx = -dy / length * far, ny = dx / length * far
            let band = geometry(.polygon([CGPoint(x: from.x + nx, y: from.y + ny), CGPoint(x: to.x + nx, y: to.y + ny),
                                          CGPoint(x: to.x - nx, y: to.y - ny), CGPoint(x: from.x - nx, y: from.y - ny)]))
            var layer = layerParameters(mask: band.object, antialias: D2D1_ANTIALIAS_MODE_ALIASED)
            vt.PushLayer!(dc, &layer, nil)
            vt.FillGeometry!(dc, g.object, brush.object, nil)
            vt.PopLayer!(dc)
        }
    }

    package func shadowed(offset: CGSize, blur: CGFloat, color: Color, _ body: () -> Void) {
        let saved = state.shadow
        state.shadow = Shadow(offset: offset, blur: blur, color: color)
        body()
        state.shadow = saved
    }

    package func glow(_ p: ArtPath, blur: CGFloat, color: Color) {
        let image = offscreen { dc in
            let g = geometry(p), brush = solid(Color(r: 0, g: 0, b: 0), opacity: 1, on: dc)
            rt(dc).FillGeometry!(dc, g.object, brush.object, nil)
        }
        composite(image, shadow: Shadow(offset: .zero, blur: blur, color: color), alpha: state.alpha, drawsImage: false)
    }

    package func layer(alpha: CGFloat, _ body: () -> Void) {
        let saved = state
        if alpha != 1 { state.alpha = alpha }   // like CGContext.setAlpha: replaces the global alpha
        let composited = state
        state.alpha = 1
        state.shadow = nil
        if composited.alpha == 1 && composited.shadow == nil {
            body()   // source-over is associative: drawing straight onto the target is the same picture
        } else {
            let image = offscreen { _ in body() }
            composite(image, shadow: composited.shadow, alpha: composited.alpha, drawsImage: true)
        }
        state = saved
    }

    package func faded(alpha: CGFloat, _ body: () -> Void) {
        let saved = state.alpha
        state.alpha = alpha
        body()
        state.alpha = saved
    }

    package func clipped(to p: ArtPath, _ body: () -> Void) {
        let dc = target, vt = rt(dc)
        if p.elements.count == 1, case let .rect(r) = p.elements[0] {
            var clip = rect(r)
            vt.PushAxisAlignedClip!(dc, &clip, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE)
            body()
            vt.PopAxisAlignedClip!(dc)
        } else {
            let g = geometry(p)
            var layer = layerParameters(mask: g.object, antialias: D2D1_ANTIALIAS_MODE_PER_PRIMITIVE)
            vt.PushLayer!(dc, &layer, nil)
            body()
            vt.PopLayer!(dc)
        }
    }

    package func translated(by offset: CGSize, _ body: () -> Void) {
        let saved = state.offset
        state.offset = CGSize(width: saved.width + offset.width, height: saved.height + offset.height)
        body()
        state.offset = saved
    }

    package func text(_ runs: [TextRun], shadow: TextShadow?, in rect: CGRect, maxLines: Int) {
        guard let shadow else { return drawText(runs, in: rect, maxLines: maxLines, centred: true, truncatesTail: false) }
        shadowed(offset: shadow.offset, blur: shadow.blur, color: shadow.color) {
            layer(alpha: 1) { drawText(runs, in: rect, maxLines: maxLines, centred: true, truncatesTail: false) }
        }
    }

    package func textLine(_ runs: [TextRun], in rect: CGRect, truncatesTail: Bool) {
        drawText(runs, in: rect, maxLines: 0, centred: false, truncatesTail: truncatesTail)
    }

    package func emoji(_ s: String, size: CGFloat, center: CGPoint) {
        ArtKit.drawLabel(s, font: FontSpec(size: size, weight: .regular), color: Color(r: 1, g: 1, b: 1), center: center, pen: self)
    }

    package func setFontSmoothing(_ on: Bool) { smoothing = on }

    package func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize {
        backend.measure(runs, maxWidth: maxWidth, maxLines: maxLines)
    }

    // MARK: Commands

    /// Runs one drawing command (`draw(target, brushOpacity)`) under the current shadow and global alpha.
    private func command(brushAlpha: Bool, _ draw: (COMObject, CGFloat) -> Void) {
        let alpha = state.alpha
        if state.shadow == nil && (alpha == 1 || brushAlpha) { return draw(target, alpha) }
        let image = offscreen { draw($0, 1) }
        composite(image, shadow: state.shadow, alpha: alpha, drawsImage: true)
    }

    /// Text in DirectWrite layouts (`D2DArtBackend.textLayout`), colour fonts on, from the top-left of `rect`.
    private func drawText(_ runs: [TextRun], in r: CGRect, maxLines: Int, centred: Bool, truncatesTail: Bool) {
        guard !runs.isEmpty else { return }
        command(brushAlpha: false) { dc, _ in
            var brushes: [COMRef] = []
            let layout = backend.textLayout(runs, width: r.width, maxLines: maxLines, height: r.height, centred: centred,
                                            truncatesTail: truncatesTail) { c in
                let b = self.solid(c, opacity: 1, on: dc)
                brushes.append(b)
                return b.object
            }
            let fallback = solid(runs[0].color, opacity: 1, on: dc)
            let vt = rt(dc)
            vt.SetTextRenderingParams!(dc, smoothing ? backend.smoothText : backend.plainText)
            vt.DrawTextLayout!(dc, point(r.origin), layout.object, fallback.object, D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT)
            withExtendedLifetime(brushes) {}
        }
    }

    // MARK: Offscreen bitmaps

    /// Draws `body` into a new transparent bitmap the size of the canvas (a compatible render target of the current
    /// one, so same dpi and format) and returns that ID2D1Bitmap.
    private func offscreen(_ body: (COMObject) -> Void) -> COMRef {
        let parent = target
        let bitmapTarget = created("ID2D1RenderTarget::CreateCompatibleRenderTarget") {
            rt(parent).CreateCompatibleRenderTarget!(parent, nil, nil, nil, D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE, $0)
        }
        guard let dc = query(bitmapTarget, GUIDs.ID2D1DeviceContext) else { fatalError("compatible render target is not an ID2D1DeviceContext") }
        target = dc
        begin(dc)
        body(dc)
        end(dc, "offscreen")
        target = parent
        let bitmap = created("ID2D1BitmapRenderTarget::GetBitmap") {
            vtable(bitmapTarget, CD2D_ID2D1BitmapRenderTargetVtbl.self).GetBitmap!(bitmapTarget, $0)
        }
        release(dc)
        release(bitmapTarget)
        return COMRef(bitmap)
    }

    /// Draws `image`'s shadow (if any; its colour's alpha times `alpha`) and then `image` itself at `alpha`.
    private func composite(_ image: COMRef, shadow: Shadow?, alpha: CGFloat, drawsImage: Bool) {
        let dc = target
        if let s = shadow {
            let effect = COMRef(created("ID2D1DeviceContext::CreateEffect(CLSID_D2D1Shadow)") {
                var clsid = GUIDs.CLSID_D2D1Shadow
                return vtable(dc, CD2D_ID2D1DeviceContextVtbl.self).CreateEffect!(dc, &clsid, $0)
            })
            let fx = vtable(effect.object, CD2D_ID2D1EffectVtbl.self)
            fx.SetInput!(effect.object, 0, image.object, true)
            setProperty(effect, UInt32(truncatingIfNeeded: D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION.rawValue), D2D1_PROPERTY_TYPE_FLOAT,
                        Float(s.blur * Self.blurCalibration))
            setProperty(effect, UInt32(truncatingIfNeeded: D2D1_SHADOW_PROP_COLOR.rawValue), D2D1_PROPERTY_TYPE_VECTOR4,
                        D2D1_VECTOR_4F(x: Float(s.color.r), y: Float(s.color.g), z: Float(s.color.b), w: Float(s.color.a * Double(alpha))))
            setProperty(effect, UInt32(truncatingIfNeeded: D2D1_SHADOW_PROP_OPTIMIZATION.rawValue), D2D1_PROPERTY_TYPE_UNKNOWN,
                        UInt32(truncatingIfNeeded: D2D1_SHADOW_OPTIMIZATION_QUALITY.rawValue))
            var output: UnsafeMutableRawPointer?
            fx.GetOutput!(effect.object, &output)
            guard let output else { comFailure("ID2D1Effect::GetOutput", HRESULT(bitPattern: 0x8000_4003)) }
            var at = D2D1_POINT_2F(x: Float(s.offset.width), y: Float(s.offset.height))
            vtable(dc, CD2D_ID2D1DeviceContextVtbl.self).DrawImage!(dc, output, &at, nil, D2D1_INTERPOLATION_MODE_LINEAR,
                                                                    D2D1_COMPOSITE_MODE_SOURCE_OVER)
            release(output)
        }
        guard drawsImage else { return }
        var dest = canvas
        rt(dc).DrawBitmap!(dc, image.object, &dest, Float(alpha), D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR, nil)
    }

    private func begin(_ dc: COMObject) {
        let vt = rt(dc)
        vt.BeginDraw!(dc)
        var clear = D2D1_COLOR_F(r: 0, g: 0, b: 0, a: 0)
        vt.Clear!(dc, &clear)
        vt.SetTextAntialiasMode!(dc, D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE)
    }

    private func end(_ dc: COMObject, _ what: String) {
        check(rt(dc).EndDraw!(dc, nil, nil), "ID2D1RenderTarget::EndDraw (\(what))")
    }

    private func setProperty<T>(_ effect: COMRef, _ index: UInt32, _ type: D2D1_PROPERTY_TYPE, _ value: T) {
        var value = value
        let hr = withUnsafeBytes(of: &value) { raw in
            vtable(effect.object, CD2D_ID2D1EffectVtbl.self).SetValue!(
                effect.object, index, type, raw.bindMemory(to: BYTE.self).baseAddress, UInt32(raw.count))
        }
        check(hr, "ID2D1Effect::SetValue(\(index))")
    }

    // MARK: Resources

    private func rt(_ dc: COMObject) -> CD2D_ID2D1RenderTargetVtbl { vtable(dc, CD2D_ID2D1RenderTargetVtbl.self) }

    private func solid(_ c: Color, opacity: CGFloat, on dc: COMObject) -> COMRef {
        var color = d2dColor(c), props = brushProperties(opacity)
        return COMRef(created("ID2D1RenderTarget::CreateSolidColorBrush") { rt(dc).CreateSolidColorBrush!(dc, &color, &props, $0) })
    }

    private func d2dColor(_ c: Color) -> D2D1_COLOR_F { D2D1_COLOR_F(r: Float(c.r), g: Float(c.g), b: Float(c.b), a: Float(c.a)) }

    private func brushProperties(_ opacity: CGFloat) -> D2D1_BRUSH_PROPERTIES {
        var p = D2D1_BRUSH_PROPERTIES()
        p.opacity = Float(opacity)
        p.transform = Self.identity
        return p
    }

    private func layerParameters(mask: COMObject, antialias: D2D1_ANTIALIAS_MODE) -> D2D1_LAYER_PARAMETERS {
        var p = D2D1_LAYER_PARAMETERS()
        p.contentBounds = D2D1_RECT_F(left: -.greatestFiniteMagnitude, top: -.greatestFiniteMagnitude,
                                      right: .greatestFiniteMagnitude, bottom: .greatestFiniteMagnitude)
        p.geometricMask = mask
        p.maskAntialiasMode = antialias
        p.maskTransform = Self.identity
        p.opacity = 1
        p.layerOptions = D2D1_LAYER_OPTIONS_NONE
        return p
    }

    private static let identity: D2D1_MATRIX_3X2_F = {
        var m = D2D1_MATRIX_3X2_F()
        withUnsafeMutableBytes(of: &m) { raw in
            for (i, v) in ([1, 0, 0, 1, 0, 0] as [Float]).enumerated() { raw.storeBytes(of: v, toByteOffset: i * 4, as: Float.self) }
        }
        return m
    }()

    // MARK: Geometry

    /// A point of the art (points) on the target: moved by the current translation.
    private func point(_ p: CGPoint) -> D2D1_POINT_2F {
        D2D1_POINT_2F(x: Float(p.x + state.offset.width), y: Float(p.y + state.offset.height))
    }

    private func rect(_ r: CGRect) -> D2D1_RECT_F {
        let o = state.offset
        return D2D1_RECT_F(left: Float(r.minX + o.width), top: Float(r.minY + o.height), right: Float(r.maxX + o.width), bottom: Float(r.maxY + o.height))
    }

    /// The Direct2D geometry of `p` (non-zero winding): a lone rectangle, rounded rectangle or ellipse is the
    /// factory's own; anything else a path geometry built element by element with Core Graphics' path semantics.
    private func geometry(_ p: ArtPath) -> COMRef {
        let factory = backend.d2d, f = vtable(factory, CD2D_ID2D1FactoryVtbl.self)
        if p.elements.count == 1 {
            switch p.elements[0] {
            case let .rect(r):
                var d = rect(r)
                return COMRef(created("ID2D1Factory::CreateRectangleGeometry") { f.CreateRectangleGeometry!(factory, &d, $0) })
            case let .roundedRect(r, radius):
                let rad = Float(max(0, min(radius, r.width / 2, r.height / 2)))
                var d = D2D1_ROUNDED_RECT(rect: rect(r), radiusX: rad, radiusY: rad)
                return COMRef(created("ID2D1Factory::CreateRoundedRectangleGeometry") { f.CreateRoundedRectangleGeometry!(factory, &d, $0) })
            case let .ellipse(r):
                var d = D2D1_ELLIPSE(point: point(CGPoint(x: r.midX, y: r.midY)), radiusX: Float(r.width / 2), radiusY: Float(r.height / 2))
                return COMRef(created("ID2D1Factory::CreateEllipseGeometry") { f.CreateEllipseGeometry!(factory, &d, $0) })
            default:
                break
            }
        }
        let path = COMRef(created("ID2D1Factory::CreatePathGeometry") { f.CreatePathGeometry!(factory, $0) })
        let sink = created("ID2D1PathGeometry::Open") { vtable(path.object, CD2D_ID2D1PathGeometryVtbl.self).Open!(path.object, $0) }
        var builder = PathBuilder(sink: sink, point: { self.point($0) })
        builder.sink.SetFillMode!(sink, D2D1_FILL_MODE_WINDING)
        for e in p.elements { builder.add(e) }
        builder.endFigure(closed: false)
        check(builder.sink.Close!(sink), "ID2D1GeometrySink::Close")
        release(sink)
        return path
    }
}

/// Feeds `ArtPath` elements to an ID2D1GeometrySink the way `CGMutablePath` builds them: `move` starts a figure,
/// lines and curves continue the current one (after `close`, from the closed figure's start), an arc is joined to the
/// current point by a line, and whole shapes are closed figures of their own.
private struct PathBuilder {
    let sinkObject: COMObject
    let sink: CD2D_ID2D1GeometrySinkVtbl
    let point: (CGPoint) -> D2D1_POINT_2F
    /// The current point and the open figure's start (art space, before the translation).
    var current: CGPoint?, start: CGPoint?
    var open = false

    init(sink: COMObject, point: @escaping (CGPoint) -> D2D1_POINT_2F) {
        sinkObject = sink
        self.sink = vtable(sink, CD2D_ID2D1GeometrySinkVtbl.self)
        self.point = point
    }

    mutating func add(_ e: ArtPath.Element) {
        switch e {
        case let .move(p):
            begin(p)
        case let .line(p):
            continueFigure()
            sink.AddLine!(sinkObject, point(p))
            current = p
        case let .quadCurve(p, c):
            continueFigure()
            var q = D2D1_QUADRATIC_BEZIER_SEGMENT(point1: point(c), point2: point(p))
            sink.AddQuadraticBezier!(sinkObject, &q)
            current = p
        case let .arc(c, r, a0, a1, clockwise):
            // Angles are in the path's own (y-down) space; Core Graphics' `clockwise` goes towards smaller angles,
            // which on a y-down canvas turns counter-clockwise.
            let p0 = CGPoint(x: c.x + r * cos(a0), y: c.y + r * sin(a0))
            if open { lineIfApart(p0) } else { begin(p0) }
            var sweep = a1 - a0
            if clockwise { while sweep > 0 { sweep -= 2 * .pi } } else { while sweep < 0 { sweep += 2 * .pi } }
            sweep = max(-2 * .pi, min(2 * .pi, sweep))
            arc(center: c, radius: r, from: a0, sweep: sweep)
        case let .tangentArc(t1, t2, r):
            tangentArc(t1, t2, r)
        case .close:
            guard open else { return }
            endFigure(closed: true)
            current = start
        case let .rect(r):
            endFigure(closed: false)
            begin(CGPoint(x: r.minX, y: r.minY))
            for q in [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] {
                sink.AddLine!(sinkObject, point(q))
            }
            endFigure(closed: true)
        case let .roundedRect(r, radius):
            let rad = max(0, min(radius, r.width / 2, r.height / 2))
            guard rad > 0 else { return add(.rect(r)) }
            endFigure(closed: false)
            begin(CGPoint(x: r.minX + rad, y: r.minY))
            let corners: [(CGPoint, CGPoint)] = [
                (CGPoint(x: r.maxX - rad, y: r.minY), CGPoint(x: r.maxX, y: r.minY + rad)),
                (CGPoint(x: r.maxX, y: r.maxY - rad), CGPoint(x: r.maxX - rad, y: r.maxY)),
                (CGPoint(x: r.minX + rad, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - rad)),
                (CGPoint(x: r.minX, y: r.minY + rad), CGPoint(x: r.minX + rad, y: r.minY))]
            for (lineEnd, arcEnd) in corners {
                sink.AddLine!(sinkObject, point(lineEnd))
                var a = D2D1_ARC_SEGMENT(point: point(arcEnd), size: D2D1_SIZE_F(width: Float(rad), height: Float(rad)), rotationAngle: 0,
                                         sweepDirection: D2D1_SWEEP_DIRECTION_CLOCKWISE, arcSize: D2D1_ARC_SIZE_SMALL)
                sink.AddArc!(sinkObject, &a)
            }
            endFigure(closed: true)
        case let .ellipse(r):
            endFigure(closed: false)
            let rx = r.width / 2, ry = r.height / 2
            begin(CGPoint(x: r.maxX, y: r.midY))
            for q in [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)] {
                var a = D2D1_ARC_SEGMENT(point: point(q), size: D2D1_SIZE_F(width: Float(rx), height: Float(ry)), rotationAngle: 0,
                                         sweepDirection: D2D1_SWEEP_DIRECTION_CLOCKWISE, arcSize: D2D1_ARC_SIZE_SMALL)
                sink.AddArc!(sinkObject, &a)
            }
            endFigure(closed: true)
        }
    }

    mutating func begin(_ p: CGPoint) {
        endFigure(closed: false)
        sink.BeginFigure!(sinkObject, point(p), D2D1_FIGURE_BEGIN_FILLED)
        open = true
        current = p
        start = p
    }

    /// Lines and curves after a `close` (or with no figure) start a new figure at the current point.
    mutating func continueFigure() {
        if !open { begin(current ?? .zero) }
    }

    mutating func endFigure(closed: Bool) {
        guard open else { return }
        sink.EndFigure!(sinkObject, closed ? D2D1_FIGURE_END_CLOSED : D2D1_FIGURE_END_OPEN)
        open = false
    }

    mutating func lineIfApart(_ p: CGPoint) {
        if let c = current, abs(c.x - p.x) < 1e-9, abs(c.y - p.y) < 1e-9 { return }
        sink.AddLine!(sinkObject, point(p))
        current = p
    }

    /// An arc of `sweep` radians (positive: towards larger angles) from angle `a0`, in pieces of at most 90°.
    mutating func arc(center c: CGPoint, radius r: CGFloat, from a0: CGFloat, sweep: CGFloat) {
        guard sweep != 0, r > 0 else { return }
        let pieces = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
        for i in 1...pieces {
            let a = a0 + sweep * CGFloat(i) / CGFloat(pieces)
            let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            var seg = D2D1_ARC_SEGMENT(point: point(p), size: D2D1_SIZE_F(width: Float(r), height: Float(r)), rotationAngle: 0,
                                       sweepDirection: sweep > 0 ? D2D1_SWEEP_DIRECTION_CLOCKWISE : D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE,
                                       arcSize: D2D1_ARC_SIZE_SMALL)
            sink.AddArc!(sinkObject, &seg)
            current = p
        }
    }

    /// `CGMutablePath.addArc(tangent1End:tangent2End:radius:)`: a line from the current point to where the circle of
    /// `radius` touches the line towards `t1`, then the arc to where it touches the line from `t1` to `t2`. With no
    /// corner to round (no current point, a zero radius, or the three points in a line), just a line to `t1`.
    mutating func tangentArc(_ t1: CGPoint, _ t2: CGPoint, _ r: CGFloat) {
        continueFigure()
        let p0 = current ?? t1
        let ax = p0.x - t1.x, ay = p0.y - t1.y, bx = t2.x - t1.x, by = t2.y - t1.y
        let la = (ax * ax + ay * ay).squareRoot(), lb = (bx * bx + by * by).squareRoot()
        guard r > 0, la > 0, lb > 0 else { return lineIfApart(t1) }
        let ux = ax / la, uy = ay / la, vx = bx / lb, vy = by / lb
        let cosTheta = max(-1, min(1, ux * vx + uy * vy)), theta = acos(cosTheta)
        guard theta > 1e-9, abs(theta - .pi) > 1e-9 else { return lineIfApart(t1) }
        let d = r / tan(theta / 2)
        let a = CGPoint(x: t1.x + ux * d, y: t1.y + uy * d), b = CGPoint(x: t1.x + vx * d, y: t1.y + vy * d)
        lineIfApart(a)
        // Travelling towards t1 (−u) and turning onto v: a positive cross product turns clockwise on a y-down canvas.
        let cross = (-ux) * vy - (-uy) * vx
        var seg = D2D1_ARC_SEGMENT(point: point(b), size: D2D1_SIZE_F(width: Float(r), height: Float(r)), rotationAngle: 0,
                                   sweepDirection: cross > 0 ? D2D1_SWEEP_DIRECTION_CLOCKWISE : D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE,
                                   arcSize: D2D1_ARC_SIZE_SMALL)
        sink.AddArc!(sinkObject, &seg)
        current = b
    }
}
#endif
