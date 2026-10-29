// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
// D2D1_PIXEL_FORMAT holds a DXGI_FORMAT; without this import the 6.1.2 compiler crashes (see CDirect2D.h).
import WinSDK.DirectX
import CDirect2D
import AgentriseScene
import AgentriseWinArt

/// An affine map like `CGAffineTransform`: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
struct Affine {
    var a: CGFloat = 1, b: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 1, tx: CGFloat = 0, ty: CGFloat = 0

    static let identity = Affine()

    /// `self`, then `t`.
    func then(_ t: Affine) -> Affine {
        Affine(a: t.a * a + t.c * b, b: t.b * a + t.d * b,
               c: t.a * c + t.c * d, d: t.b * c + t.d * d,
               tx: t.a * tx + t.c * ty + t.tx, ty: t.b * tx + t.d * ty + t.ty)
    }

    func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty) }

    /// A node's transform in its parent, as SpriteKit composes it: scale, then rotate (counter-clockwise, y up),
    /// then move.
    static func node(_ n: SceneNode) -> Affine {
        let cs = cos(n.zRotation), sn = sin(n.zRotation)
        return Affine(a: cs * n.xScale, b: sn * n.xScale, c: -sn * n.yScale, d: cs * n.yScale, tx: n.position.x, ty: n.position.y)
    }

    var d2d: D2D1_MATRIX_3X2_F {
        var m = D2D1_MATRIX_3X2_F()
        withUnsafeMutableBytes(of: &m) { raw in
            for (i, v) in [a, b, c, d, tx, ty].enumerated() { raw.storeBytes(of: Float(v), toByteOffset: i * 4, as: Float.self) }
        }
        return m
    }
}

/// `D2DERR_RECREATE_TARGET`: the device was lost; the target and everything uploaded to it must be made again.
let recreateTarget = HRESULT(bitPattern: 0x8899_000C)

/// A Direct2D render target the display draws on (a window's, or an offscreen WIC bitmap's) and the GPU bitmaps
/// uploaded to it. Bitmaps belong to their target: a new target (device loss, a new offscreen size) starts empty.
package final class D2DSurface {
    private enum Kind { case window(HWND), offscreen }
    private let kind: Kind
    /// ID2D1RenderTarget (an ID2D1HwndRenderTarget for a window).
    private(set) var target: COMObject?
    private var offscreenBitmap: UnsafeMutablePointer<IWICBitmap>?
    /// The last attempt to make the target failed (logged once, not on every frame).
    private var reportedFailure = false
    package private(set) var pixelWidth: Int, pixelHeight: Int
    package private(set) var scale: CGFloat

    // Uploaded bitmaps (ID2D1Bitmap).
    weak var atlas: TextureAtlas?
    var atlasVersion = -1
    var pages: [(revision: Int, bitmap: COMRef?)] = []
    var standalone: [ObjectIdentifier: (image: Weak<BakedImage>, bitmap: COMRef)] = [:]
    var tinted: [TintKey: (image: Weak<BakedImage>, bitmap: COMRef)] = [:]
    var drawings: [ObjectIdentifier: (drawing: Weak<ArtDrawing>, bitmap: COMRef)] = [:]
    var brushes: [Color: COMRef] = [:]

    struct TintKey: Hashable { let image: ObjectIdentifier; let color: Color }

    private static var factory: COMObject { D2DArtBackend.shared.d2d }

    /// A window's surface: an `ID2D1HwndRenderTarget` presenting on the display's refresh (EndDraw waits for it).
    package init(window: HWND, pixelWidth: Int, pixelHeight: Int, scale: CGFloat) {
        kind = .window(window)
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
        self.scale = scale
    }

    /// An offscreen surface (software WIC render target): screenshots and tests.
    package init(offscreenWidth: Int, height: Int, scale: CGFloat) {
        kind = .offscreen
        pixelWidth = max(1, offscreenWidth)
        pixelHeight = max(1, height)
        self.scale = scale
    }

    deinit { discard() }

    /// The target, made on first use (and after a loss). Nil when it can't be made.
    func ensureTarget() -> COMObject? {
        if let target { return target }
        D2DArtBackend.joinCOM()   // WIC on a thread that may not have joined COM yet (tests)
        var props = D2D1_RENDER_TARGET_PROPERTIES()
        props.dpiX = Float(96 * scale)
        props.dpiY = Float(96 * scale)
        let f = vtable(Self.factory, CD2D_ID2D1FactoryVtbl.self)
        var out: UnsafeMutableRawPointer?
        var hr: HRESULT
        switch kind {
        case .window(let hwnd):
            props.type = D2D1_RENDER_TARGET_TYPE_DEFAULT
            props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM
            props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE
            var hp = D2D1_HWND_RENDER_TARGET_PROPERTIES(hwnd: hwnd, pixelSize: D2D1_SIZE_U(width: UInt32(pixelWidth), height: UInt32(pixelHeight)),
                                                        presentOptions: D2D1_PRESENT_OPTIONS_NONE)
            hr = f.CreateHwndRenderTarget!(Self.factory, &props, &hp, &out)
        case .offscreen:
            let wic = D2DArtBackend.shared.wic
            var format = GUIDs.WICPixelFormat32bppPBGRA
            var bitmap: UnsafeMutablePointer<IWICBitmap>?
            hr = wic.pointee.lpVtbl.pointee.CreateBitmap(wic, UINT(pixelWidth), UINT(pixelHeight), &format, WICBitmapCacheOnLoad, &bitmap)
            guard hr >= 0, let bitmap else { Log.write("IWICImagingFactory::CreateBitmap failed: \(hex(hr))"); return nil }
            offscreenBitmap = bitmap
            props.type = D2D1_RENDER_TARGET_TYPE_SOFTWARE   // pixel format {UNKNOWN, UNKNOWN}: the WIC bitmap's (PBGRA)
            hr = f.CreateWicBitmapRenderTarget!(Self.factory, UnsafeMutableRawPointer(bitmap), &props, &out)
        }
        guard hr >= 0, let out else {
            if !reportedFailure { Log.write("creating the render target failed: \(hex(hr))") }
            reportedFailure = true
            return nil
        }
        reportedFailure = false
        target = out
        return out
    }

    /// The window's client area changed size or dpi: the target follows (bitmaps stay valid).
    package func resize(pixelWidth w: Int, pixelHeight h: Int, scale s: CGFloat) {
        let w = max(1, w), h = max(1, h)
        guard w != pixelWidth || h != pixelHeight || s != scale else { return }
        pixelWidth = w
        pixelHeight = h
        scale = s
        guard let target else { return }
        switch kind {
        case .window:
            var size = D2D1_SIZE_U(width: UInt32(w), height: UInt32(h))
            let vt = vtable(target, CD2D_ID2D1HwndRenderTargetVtbl.self)
            vt.SetDpi!(target, Float(96 * s), Float(96 * s))
            if vt.Resize!(target, &size) < 0 { discard() }
        case .offscreen:
            discard()   // a WIC bitmap has one size: start over
        }
    }

    /// Whether DXGI reports the window as fully covered (frames are pointless then).
    package var isOccluded: Bool {
        guard case .window = kind, let target else { return false }
        return vtable(target, CD2D_ID2D1HwndRenderTargetVtbl.self).CheckWindowState!(target) == D2D1_WINDOW_STATE_OCCLUDED
    }

    /// Drops the target and every bitmap uploaded to it.
    func discard() {
        pages.removeAll()
        atlasVersion = -1
        standalone.removeAll()
        tinted.removeAll()
        drawings.removeAll()
        brushes.removeAll()
        release(target)
        target = nil
        if let b = offscreenBitmap { release(UnsafeMutableRawPointer(b)) }
        offscreenBitmap = nil
    }

    /// The offscreen surface's pixels: premultiplied BGRA, rows top first.
    package func pixelsBGRA() -> [UInt8]? {
        guard let bitmap = offscreenBitmap else { return nil }
        let stride = pixelWidth * 4
        var bytes = [UInt8](repeating: 0, count: stride * pixelHeight)
        let hr = bytes.withUnsafeMutableBufferPointer { buf in
            bitmap.pointee.lpVtbl.pointee.CopyPixels(bitmap, nil, UINT(stride), UINT(buf.count), buf.baseAddress)
        }
        return hr >= 0 ? bytes : nil
    }

    // MARK: Uploads

    static var bitmapProperties: D2D1_BITMAP_PROPERTIES {
        var p = D2D1_BITMAP_PROPERTIES()
        p.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM
        p.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED
        p.dpiX = 96   // one DIP per pixel: source rectangles are in pixels
        p.dpiY = 96
        return p
    }

    /// A bitmap of premultiplied BGRA pixels.
    func upload(bgra: UnsafeRawPointer, width: Int, height: Int) -> COMRef? {
        guard let target else { return nil }
        var props = Self.bitmapProperties
        var out: UnsafeMutableRawPointer?
        let hr = vtable(target, CD2D_ID2D1RenderTargetVtbl.self).CreateBitmap!(
            target, D2D1_SIZE_U(width: UInt32(width), height: UInt32(height)), bgra, UInt32(width * 4), &props, &out)
        guard hr >= 0, let out else { Log.write("ID2D1RenderTarget::CreateBitmap failed: \(hex(hr))"); return nil }
        return COMRef(out)
    }

    /// A bitmap of a baked WIC bitmap (32 bpp premultiplied BGRA).
    func upload(wic: UnsafeMutablePointer<IWICBitmap>) -> COMRef? {
        guard let target else { return nil }
        var props = Self.bitmapProperties
        var out: UnsafeMutableRawPointer?
        let hr = vtable(target, CD2D_ID2D1RenderTargetVtbl.self).CreateBitmapFromWicBitmap!(target, UnsafeMutableRawPointer(wic), &props, &out)
        guard hr >= 0, let out else { Log.write("ID2D1RenderTarget::CreateBitmapFromWicBitmap failed: \(hex(hr))"); return nil }
        return COMRef(out)
    }

    func brush(_ c: Color) -> COMRef? {
        if let b = brushes[c] { return b }
        guard let target else { return nil }
        var color = D2D1_COLOR_F(r: Float(c.r), g: Float(c.g), b: Float(c.b), a: Float(c.a))
        var out: UnsafeMutableRawPointer?
        guard vtable(target, CD2D_ID2D1RenderTargetVtbl.self).CreateSolidColorBrush!(target, &color, nil, &out) >= 0, let out else { return nil }
        let b = COMRef(out)
        brushes[c] = b
        return b
    }
}

/// A weak reference, for caches keyed by an object's identity.
struct Weak<T: AnyObject> { weak var object: T? }

func hex(_ hr: HRESULT) -> String { "0x" + String(UInt32(bitPattern: hr), radix: 16, uppercase: true) }

/// Draws a `TowerSceneModel` with Direct2D: every frame it steps the model and blits the scene tree from bitmaps that
/// were uploaded once. "Bake once, only blit" (spec §5.4): a frame never bakes. The model bakes robot parts and
/// labels when they first appear or change (`bakeCount`); the display uploads
/// - each atlas page when its revision changes (`TextureAtlas.version`), from the page's pixels;
/// - each image that isn't packed (yet) once, from its WIC bitmap (`CreateBitmapFromWicBitmap`);
/// - each tinted image (the halo's team colour, a prop's tint) once per colour, multiplied on the CPU;
/// - each `ArtDrawing` (building, cab, header, tooltip, panel) once per instance: baked with `D2DArtBackend` and
///   uploaded, its CPU pixels dropped right after (`drawCount`).
/// After a device loss (`D2DERR_RECREATE_TARGET`) the surface starts over and uploads again; full atlas pages whose
/// pixels were already read can't be drawn again, so their images are shown standalone until the next atlas reset.
///
/// Like `SpriteKitDisplay`, it draws with SpriteKit's conventions: positions in the parent's points, y up, rotation
/// counter-clockwise, alpha multiplied down the tree, a hidden node hides its subtree, and the draw order is the sum
/// of the `zPosition`s along the path (SpriteKit's `ignoresSiblingOrder`), ties in tree order.
package final class D2DDisplay {
    package let model: TowerSceneModel
    /// Drawings baked into bitmaps (each `ArtDrawing` instance once per surface).
    package private(set) var drawCount = 0
    /// GPU bitmaps made (pages, standalone and tinted images, drawings).
    package private(set) var uploadCount = 0
    /// Called before each render (the panel re-draws itself here when its state changed).
    package var beforeRender: (() -> Void)?
    package static let background = Color(hex: 0x0A0E26)

    private struct Item {
        let node: SceneNode
        let world: Affine
        let z: CGFloat
        let order: Int
        let alpha: CGFloat
        let tether: TowerSceneModel.Tether?
    }
    private var items: [Item] = []
    private var frames = 0

    package init(model: TowerSceneModel) { self.model = model }

    /// One frame: steps the model by `dt` and draws it on `surface`. False when nothing could be drawn (no target,
    /// or the device was lost: the next frame starts over).
    @discardableResult
    package func frame(dt: TimeInterval, on surface: D2DSurface) -> Bool {
        model.step(dt: dt)
        return render(on: surface)
    }

    /// Draws the scene tree as it is now.
    @discardableResult
    package func render(on surface: D2DSurface) -> Bool {
        beforeRender?()
        guard let rt = surface.ensureTarget() else { return false }
        syncAtlas(surface)
        frames += 1
        if frames % 120 == 0 { prune(surface) }
        collect()
        let vt = vtable(rt, CD2D_ID2D1RenderTargetVtbl.self)
        vt.BeginDraw!(rt)
        var identity = Affine.identity.d2d
        vt.SetTransform!(rt, &identity)
        let bg = Self.background
        var clear = D2D1_COLOR_F(r: Float(bg.r), g: Float(bg.g), b: Float(bg.b), a: 1)
        vt.Clear!(rt, &clear)
        let flip = Affine(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: model.size.height)
        for item in items {
            if let t = item.tether {
                drawTether(t, item, flip: flip, rt: rt, vt: vt, surface: surface)
            } else {
                drawSprite(item, flip: flip, rt: rt, vt: vt, surface: surface)
            }
        }
        let hr = vt.EndDraw!(rt, nil, nil)
        if hr == recreateTarget {
            Log.write("Direct2D device lost: recreating the target")
            surface.discard()
            return false
        }
        if hr < 0 { Log.write("ID2D1RenderTarget::EndDraw failed: \(hex(hr))") }
        // Drawings nothing shows any more (an old background is 8–33 MB at 2×) go now.
        if surface.drawings.contains(where: { $0.value.drawing.object == nil }) {
            surface.drawings = surface.drawings.filter { $0.value.drawing.object != nil }
        }
        return hr >= 0
    }

    // MARK: Tree

    private func collect() {
        items.removeAll(keepingCapacity: true)
        let tethers = model.tethers.isEmpty ? [:] : Dictionary(model.tethers.map { (ObjectIdentifier($0.node), $0) }, uniquingKeysWith: { a, _ in a })
        walk(model.root, world: .identity, z: 0, alpha: 1, tethers: tethers)
        items.sort { $0.z != $1.z ? $0.z < $1.z : $0.order < $1.order }
    }

    private func walk(_ n: SceneNode, world: Affine, z: CGFloat, alpha: CGFloat, tethers: [ObjectIdentifier: TowerSceneModel.Tether]) {
        for c in n.children where !c.isHidden {
            let a = alpha * c.alpha
            guard a > 0 else { continue }   // alpha multiplies down: nothing below shows either
            let w = Affine.node(c).then(world)
            let cz = z + c.zPosition
            if let t = tethers[ObjectIdentifier(c)] {
                items.append(Item(node: c, world: w, z: cz, order: items.count, alpha: a, tether: t))
            } else if c.isSprite, c.image != nil || c.drawing != nil, c.size.width > 0, c.size.height > 0 {
                items.append(Item(node: c, world: w, z: cz, order: items.count, alpha: a, tether: nil))
            }
            if !c.children.isEmpty { walk(c, world: w, z: cz, alpha: a, tethers: tethers) }
        }
    }

    // MARK: Sprites

    private func drawSprite(_ item: Item, flip: Affine, rt: COMObject, vt: CD2D_ID2D1RenderTargetVtbl, surface: D2DSurface) {
        let n = item.node
        guard let (bitmap, source) = bitmap(for: n, surface: surface) else { return }
        let w = n.size.width, h = n.size.height
        // Bitmap space (points, y down) → the node's space (y up, around the anchor) → scene → window (y down).
        let toNode = Affine(a: 1, b: 0, c: 0, d: -1, tx: -n.anchorPoint.x * w, ty: (1 - n.anchorPoint.y) * h)
        var m = toNode.then(item.world).then(flip).d2d
        vt.SetTransform!(rt, &m)
        var dest = D2D1_RECT_F(left: 0, top: 0, right: Float(w), bottom: Float(h))
        var src = source
        vt.DrawBitmap!(rt, bitmap.object, &dest, Float(min(1, item.alpha)), D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, &src)
    }

    /// The node's bitmap and the part of it to draw (pixels).
    private func bitmap(for n: SceneNode, surface s: D2DSurface) -> (COMRef, D2D1_RECT_F)? {
        if let image = n.image {
            let whole = D2D1_RECT_F(left: 0, top: 0, right: Float(image.pixelWidth), bottom: Float(image.pixelHeight))
            if let tint = n.color, n.colorBlendFactor > 0 {
                return tinted(image, tint, factor: n.colorBlendFactor, surface: s).map { ($0, whole) }
            }
            if let (page, rect) = model.atlas.placement(of: image), page < s.pages.count, let b = s.pages[page].bitmap {
                return (b, D2D1_RECT_F(left: Float(rect.minX), top: Float(rect.minY), right: Float(rect.maxX), bottom: Float(rect.maxY)))
            }
            return standalone(image, surface: s).map { ($0, whole) }
        }
        if let d = n.drawing {
            return drawing(d, surface: s).map { b in
                let (pw, ph) = d.pixelSize
                return (b, D2D1_RECT_F(left: 0, top: 0, right: Float(pw), bottom: Float(ph)))
            }
        }
        return nil
    }

    private func standalone(_ image: BakedImage, surface s: D2DSurface) -> COMRef? {
        let id = ObjectIdentifier(image)
        if let hit = s.standalone[id], hit.image.object === image { return hit.bitmap }
        guard let b = s.upload(wic: image.wicImage.bitmap) else { return nil }
        uploadCount += 1
        s.standalone[id] = (Weak(object: image), b)
        return b
    }

    /// The image with its colour multiplied by `color` (SpriteKit's `color` at `colorBlendFactor`), made once.
    private func tinted(_ image: BakedImage, _ color: Color, factor: CGFloat, surface s: D2DSurface) -> COMRef? {
        let f = Double(min(1, max(0, factor)))
        let c = Color(r: 1 + (color.r - 1) * f, g: 1 + (color.g - 1) * f, b: 1 + (color.b - 1) * f)
        let key = D2DSurface.TintKey(image: ObjectIdentifier(image), color: c)
        if let hit = s.tinted[key], hit.image.object === image { return hit.bitmap }
        var px = image.wicImage.pixelsBGRA()
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = UInt8((Double(px[i]) * c.b).rounded())
            px[i + 1] = UInt8((Double(px[i + 1]) * c.g).rounded())
            px[i + 2] = UInt8((Double(px[i + 2]) * c.r).rounded())
        }
        guard let b = px.withUnsafeBytes({ s.upload(bgra: $0.baseAddress!, width: image.pixelWidth, height: image.pixelHeight) }) else { return nil }
        uploadCount += 1
        s.tinted[key] = (Weak(object: image), b)
        return b
    }

    private func drawing(_ d: ArtDrawing, surface s: D2DSurface) -> COMRef? {
        let id = ObjectIdentifier(d)
        if let hit = s.drawings[id], hit.drawing.object === d { return hit.bitmap }
        let baked = d.bake(with: D2DArtBackend.shared)
        drawCount += 1
        guard let b = s.upload(wic: baked.wicImage.bitmap) else { return nil }
        uploadCount += 1
        s.drawings[id] = (Weak(object: d), b)
        return b
    }

    // MARK: Atlas

    /// Uploads the atlas pages whose revision changed (only when the atlas's version did).
    private func syncAtlas(_ s: D2DSurface) {
        let atlas = model.atlas
        if s.atlas !== atlas {
            s.atlas = atlas
            s.atlasVersion = -1
            s.pages.removeAll()
        }
        guard atlas.version != s.atlasVersion else { return }
        s.atlasVersion = atlas.version
        let count = atlas.pageCount
        if s.pages.count > count { s.pages.removeLast(s.pages.count - count) }
        for i in 0..<count {
            let revision = atlas.pageRevision(i)
            if i < s.pages.count, s.pages[i].revision == revision { continue }
            var bitmap: COMRef?
            if let (w, h) = atlas.pageDimensions(i) {
                let bytes = w * h * 4
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes, alignment: 16)
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                if atlas.drawPage(i, into: buffer) {
                    // RGBA → BGRA.
                    let p = buffer.bindMemory(to: UInt8.self)
                    for j in stride(from: 0, to: bytes, by: 4) { p.swapAt(j, j + 2) }
                    bitmap = s.upload(bgra: UnsafeRawPointer(p.baseAddress!), width: w, height: h)
                    if bitmap != nil { uploadCount += 1 }
                }
                buffer.deallocate()
            }
            let page = (revision, bitmap)
            if i < s.pages.count { s.pages[i] = page } else { s.pages.append(page) }
        }
        prune(s)
    }

    /// Lets go of standalone bitmaps of images that are gone or now drawn from a page, and of tints of gone images.
    private func prune(_ s: D2DSurface) {
        let atlas = model.atlas
        s.standalone = s.standalone.filter { _, v in
            guard let img = v.image.object else { return false }
            guard let (page, _) = atlas.placement(of: img) else { return true }
            return !(page < s.pages.count && s.pages[page].bitmap != nil)
        }
        s.tinted = s.tinted.filter { $0.value.image.object != nil }
    }

    // MARK: Tethers

    /// A tether: the dashed quad curve `SpriteKitDisplay` strokes (2 pt, 6 on 6 off at the flow's phase, a 2 pt
    /// glow), rebuilt every frame so it follows robots that walk or ride (geometry, not a bitmap).
    private func drawTether(_ t: TowerSceneModel.Tether, _ item: Item, flip: Affine, rt: COMObject,
                            vt: CD2D_ID2D1RenderTargetVtbl, surface: D2DSurface) {
        guard let c = model.tetherCurve(from: t.bossKey, to: t.key) else { return }
        let factory = D2DArtBackend.shared.d2d
        let f = vtable(factory, CD2D_ID2D1FactoryVtbl.self)
        var out: UnsafeMutableRawPointer?
        guard f.CreatePathGeometry!(factory, &out) >= 0, let pathObject = out else { return }
        let path = COMRef(pathObject)
        out = nil
        guard vtable(pathObject, CD2D_ID2D1PathGeometryVtbl.self).Open!(pathObject, &out) >= 0, let sink = out else { return }
        let sv = vtable(sink, CD2D_ID2D1GeometrySinkVtbl.self)
        sv.BeginFigure!(sink, D2D1_POINT_2F(x: Float(c.from.x), y: Float(c.from.y)), D2D1_FIGURE_BEGIN_HOLLOW)
        var q = D2D1_QUADRATIC_BEZIER_SEGMENT(point1: D2D1_POINT_2F(x: Float(c.control.x), y: Float(c.control.y)),
                                              point2: D2D1_POINT_2F(x: Float(c.to.x), y: Float(c.to.y)))
        sv.AddQuadraticBezier!(sink, &q)
        sv.EndFigure!(sink, D2D1_FIGURE_END_OPEN)
        _ = sv.Close!(sink)
        release(sink)
        var m = item.world.then(flip).d2d
        vt.SetTransform!(rt, &m)
        let a = Double(min(1, item.alpha))
        // Dash phases are periodic; keep ours positive (as `SpriteKitDisplay.tetherPath`).
        var phase = t.phase.truncatingRemainder(dividingBy: 12)
        if phase < 0 { phase += 12 }
        for (width, alpha) in [(CGFloat(6), 0.3), (CGFloat(2), 1.0)] {
            guard let brush = surface.brush(t.color.withAlpha(t.color.a * alpha * a)), let style = dashes(width: width, phase: phase) else { continue }
            vt.DrawGeometry!(rt, path.object, brush.object, Float(width), style.object)
        }
    }

    /// 6 pt on, 6 pt off, starting `phase` points into the pattern. Direct2D measures dashes in stroke widths.
    private func dashes(width: CGFloat, phase: CGFloat) -> COMRef? {
        let factory = D2DArtBackend.shared.d2d
        var props = D2D1_STROKE_STYLE_PROPERTIES(
            startCap: D2D1_CAP_STYLE_FLAT, endCap: D2D1_CAP_STYLE_FLAT, dashCap: D2D1_CAP_STYLE_FLAT,
            lineJoin: D2D1_LINE_JOIN_MITER, miterLimit: 10, dashStyle: D2D1_DASH_STYLE_CUSTOM, dashOffset: Float(phase / width))
        var pattern: [Float] = [Float(6 / width), Float(6 / width)]
        var out: UnsafeMutableRawPointer?
        guard vtable(factory, CD2D_ID2D1FactoryVtbl.self).CreateStrokeStyle!(factory, &props, &pattern, 2, &out) >= 0, let out else { return nil }
        return COMRef(out)
    }

    // MARK: Snapshot

    /// The scene drawn offscreen at `pixelWidth` × `pixelHeight` and `scale` (what the window shows, without the title
    /// bar): opaque RGBA rows, top first. A new offscreen target, so everything is uploaded (and drawings baked) for it.
    package func snapshot(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> (width: Int, height: Int, rgba: [UInt8])? {
        let s = D2DSurface(offscreenWidth: pixelWidth, height: pixelHeight, scale: scale)
        guard render(on: s), var px = s.pixelsBGRA() else { return nil }
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) }
        return (s.pixelWidth, s.pixelHeight, px)
    }
}
#endif
