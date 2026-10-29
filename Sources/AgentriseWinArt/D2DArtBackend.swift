// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import CDirect2D
import Foundation
import WinSDK
import WinSDK.DirectX
import AgentriseScene

/// A bitmap baked by `D2DArtBackend`: the WIC bitmap Direct2D drew into (32 bpp premultiplied BGRA, sRGB, rows top
/// first, `ArtKit.pixelSize` pixels at 96 × scale dpi). This is `BakedImage.native` on Windows.
///
/// For the display (Task 12): upload it once with `ID2D1RenderTarget::CreateBitmapFromWicBitmap(bitmap, …)` on the
/// window's device context, or copy `pixelsBGRA()` into a `CreateBitmap` call; then only blit.
package final class WICImage {
    /// The WIC bitmap (owned by this object; `AddRef` it to keep it longer).
    package let bitmap: UnsafeMutablePointer<IWICBitmap>
    package let pixelWidth: Int, pixelHeight: Int

    init(_ bitmap: UnsafeMutablePointer<IWICBitmap>, width: Int, height: Int) {
        self.bitmap = bitmap
        pixelWidth = width
        pixelHeight = height
    }

    deinit { release(UnsafeMutableRawPointer(bitmap)) }

    /// The pixels as WIC holds them: premultiplied BGRA, rows top first, `pixelWidth × 4` bytes per row.
    package func pixelsBGRA() -> [UInt8] {
        D2DArtBackend.joinCOM()
        let stride = pixelWidth * 4
        var bytes = [UInt8](repeating: 0, count: stride * pixelHeight)
        bytes.withUnsafeMutableBufferPointer { buf in
            check(bitmap.pointee.lpVtbl.pointee.CopyPixels(bitmap, nil, UINT(stride), UINT(buf.count), buf.baseAddress),
                  "IWICBitmap::CopyPixels")
        }
        return bytes
    }
}

extension BakedImage {
    /// The WIC bitmap of an image baked by `D2DArtBackend`.
    package var wicImage: WICImage { native as! WICImage }
}

/// Bakes the portable art with Direct2D 1.1 and DirectWrite, offscreen: each bake makes a WIC bitmap of
/// `ArtKit.pixelSize(size, scale:)` pixels and a software WIC render target on it at 96 × `scale` dpi, so one DIP is
/// one point and every coordinate the recipes give is drawn as is (`D2DPen`). Any scale works (1, 1.25, 1.5, 2…);
/// the bitmap is the point size times the scale, rounded up.
///
/// Any thread may bake, measure or read pixels, concurrently: the Direct2D factory is multi-threaded and every bake
/// has its own render target. COM: each thread that bakes joins the multi-threaded apartment the first time it does
/// (`joinCOM()`), unless it is already in an apartment (a UI thread in its STA stays there). Only WIC is
/// COM-activated (Direct2D and DirectWrite factories are plain objects), and WIC's factory and bitmaps are
/// free-threaded, so the same objects serve every thread whatever its apartment.
package final class D2DArtBackend: ArtBackend {
    package static let shared = D2DArtBackend()

    let wic: UnsafeMutablePointer<IWICImagingFactory>
    /// ID2D1Factory1, multi-threaded.
    let d2d: COMObject
    /// IDWriteFactory1, shared.
    let dwrite: COMObject
    /// Round caps and joins, as every `Pen.stroke` draws.
    let roundStroke: COMObject
    /// Text rendering with (`smooth`) and without (`plain`) the stem darkening of macOS font smoothing.
    let smoothText: COMObject, plainText: COMObject

    /// Makes sure the calling thread is in a COM apartment: on its first call, a thread with none joins the
    /// multi-threaded apartment for good (it is never left; the thread's end does that). A thread already in an
    /// apartment keeps it (CoInitializeEx answers RPC_E_CHANGED_MODE for an STA, S_FALSE for the MTA).
    static func joinCOM() {
        let key = "agentrise.D2DArtBackend.com"
        let thread = Thread.current.threadDictionary
        guard thread[key] == nil else { return }
        _ = CoInitializeEx(nil, DWORD(COINIT_MULTITHREADED.rawValue))
        thread[key] = true
    }

    package init() {
        Self.joinCOM()
        var clsid = GUIDs.CLSID_WICImagingFactory2, iid = GUIDs.IWICImagingFactory
        wic = createdWIC("CoCreateInstance(CLSID_WICImagingFactory2)", IWICImagingFactory.self) { out in
            out.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
                CoCreateInstance(&clsid, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &iid, $0)
            }
        }
        var d2dIID = GUIDs.ID2D1Factory1
        let factory = created("D2D1CreateFactory(ID2D1Factory1)") { D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, &d2dIID, nil, $0) }
        var dwIID = GUIDs.IDWriteFactory1
        let writer = created("DWriteCreateFactory(IDWriteFactory1)") { DWriteCreateFactory(UInt32(CD2D_DWRITE_FACTORY_TYPE_SHARED), &dwIID, $0) }
        var round = D2D1_STROKE_STYLE_PROPERTIES(
            startCap: D2D1_CAP_STYLE_ROUND, endCap: D2D1_CAP_STYLE_ROUND, dashCap: D2D1_CAP_STYLE_ROUND,
            lineJoin: D2D1_LINE_JOIN_ROUND, miterLimit: 10, dashStyle: D2D1_DASH_STYLE_SOLID, dashOffset: 0)
        roundStroke = created("ID2D1Factory::CreateStrokeStyle") {
            vtable(factory, CD2D_ID2D1FactoryVtbl.self).CreateStrokeStyle!(factory, &round, nil, 0, $0)
        }
        func params(_ contrast: Float) -> COMObject {
            created("IDWriteFactory1::CreateCustomRenderingParams") {
                vtable(writer, CD2D_IDWriteFactory1Vtbl.self).CreateCustomRenderingParams1!(
                    writer, D2DPen.textGamma, contrast, contrast, 0, UInt32(CD2D_DWRITE_PIXEL_GEOMETRY_FLAT),
                    UInt32(CD2D_DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC), $0)
            }
        }
        smoothText = params(D2DPen.smoothingContrast)
        plainText = params(0)
        d2d = factory
        dwrite = writer
    }

    package func bake(size: CGSize, scale: CGFloat, _ draw: (Pen) -> Void) -> BakedImage {
        Self.joinCOM()
        let (w, h) = ArtKit.pixelSize(size, scale: scale)
        var format = GUIDs.WICPixelFormat32bppPBGRA
        let bitmap = createdWIC("IWICImagingFactory::CreateBitmap", IWICBitmap.self) {
            wic.pointee.lpVtbl.pointee.CreateBitmap(wic, UINT(w), UINT(h), &format, WICBitmapCacheOnLoad, $0)
        }
        var props = D2D1_RENDER_TARGET_PROPERTIES()
        props.type = D2D1_RENDER_TARGET_TYPE_SOFTWARE   // pixel format {UNKNOWN, UNKNOWN}: the WIC bitmap's (PBGRA)
        props.dpiX = Float(96 * scale)
        props.dpiY = Float(96 * scale)
        let target = created("ID2D1Factory::CreateWicBitmapRenderTarget") {
            vtable(d2d, CD2D_ID2D1FactoryVtbl.self).CreateWicBitmapRenderTarget!(d2d, UnsafeMutableRawPointer(bitmap), &props, $0)
        }
        guard let dc = query(target, GUIDs.ID2D1DeviceContext) else { fatalError("WIC render target is not an ID2D1DeviceContext") }
        release(target)
        let pen = D2DPen(backend: self, target: dc, pixelSize: (w, h), scale: scale)
        pen.run(draw)
        release(dc)
        return BakedImage(pixelWidth: w, pixelHeight: h, scale: scale, native: WICImage(bitmap, width: w, height: h))
    }

    package func rgba(_ img: BakedImage) -> [UInt8] {
        Self.joinCOM()
        var px = img.wicImage.pixelsBGRA()
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) }
        return px
    }

    package func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize {
        let layout = textLayout(runs, width: maxWidth, maxLines: maxLines, centred: true, truncatesTail: false, brush: nil)
        var m = DWRITE_TEXT_METRICS()
        check(vtable(layout.object, CD2D_IDWriteTextLayout3Vtbl.self).GetMetrics!(layout.object, &m), "IDWriteTextLayout::GetMetrics")
        return CGSize(width: CGFloat(m.width), height: CGFloat(m.height))
    }

    // MARK: Text

    /// The art's font family: Segoe UI, whose fallback (Microsoft YaHei UI for Han with the zh-CN locale, Segoe UI
    /// Emoji for emoji) DirectWrite picks by itself.
    static let family = wide("Segoe UI"), locale = wide("zh-CN")

    /// DirectWrite weights. Segoe UI has no 500 face, and DirectWrite would match medium to Regular, visibly lighter
    /// than SF Medium (the name plates' second line, the header): medium asks for Semibold, which reads closer.
    static func weight(_ w: FontWeight) -> UInt32 {
        switch w {
        case .regular: return 400
        case .medium: return 600
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        }
    }

    /// A DirectWrite layout of `runs` (one font size, weight and, with `brush`, drawing brush per run) `width` wide
    /// (`.infinity`: unwrapped), centred or leading, or one line cut with an ellipsis (`truncatesTail`). It keeps at
    /// most `maxLines` lines (0: all) and, with `height`, only the lines that fit in it whole (the first always),
    /// as AppKit draws in a rect; a cut layout drops the kept lines' trailing line break, as `CGArtBackend` does.
    /// Line height and baseline are scaled to the macOS system font's (`D2DPen.lineHeightFactor`); a layout of
    /// emoji only is scaled to Apple Color Emoji's size (`D2DPen.emojiScale`).
    func textLayout(_ runs: [TextRun], width: CGFloat, maxLines: Int, height: CGFloat? = nil, centred: Bool, truncatesTail: Bool,
                    brush: ((Color) -> COMObject)?) -> COMRef {
        let emojiOnly = !runs.isEmpty && runs.allSatisfy { Self.isEmoji($0.text) }
        let sizeScale = emojiOnly ? D2DPen.emojiScale : 1
        let first = runs.first?.font ?? FontSpec(size: 12, weight: .regular)
        let dw = vtable(dwrite, CD2D_IDWriteFactory1Vtbl.self)
        let format = COMRef(created("IDWriteFactory::CreateTextFormat") {
            dw.CreateTextFormat!(dwrite, Self.family, nil, Self.weight(first.weight), UInt32(CD2D_DWRITE_FONT_STYLE_NORMAL),
                                 UInt32(CD2D_DWRITE_FONT_STRETCH_NORMAL), Float(first.size * sizeScale), Self.locale, $0)
        })
        let text = Array(runs.map(\.text).joined().utf16)
        let unwrapped = !width.isFinite || truncatesTail
        let layoutWidth: Float = width.isFinite ? Float(max(0, width)) : 1e6
        let raw = created("IDWriteFactory::CreateTextLayout") {
            dw.CreateTextLayout!(dwrite, text, UInt32(text.count), format.object, layoutWidth, 1e6, $0)
        }
        // Every layout of Windows 10 and later is an IDWriteTextLayout3 (needed for proportional line spacing).
        guard let object = query(raw, GUIDs.IDWriteTextLayout3) else { fatalError("IDWriteTextLayout is not an IDWriteTextLayout3") }
        release(raw)
        let layout = COMRef(object)
        let vt = vtable(object, CD2D_IDWriteTextLayout3Vtbl.self)
        check(vt.SetTextAlignment!(object, UInt32(centred && width.isFinite ? CD2D_DWRITE_TEXT_ALIGNMENT_CENTER : CD2D_DWRITE_TEXT_ALIGNMENT_LEADING)),
              "IDWriteTextLayout::SetTextAlignment")
        check(vt.SetParagraphAlignment!(object, UInt32(CD2D_DWRITE_PARAGRAPH_ALIGNMENT_NEAR)), "IDWriteTextLayout::SetParagraphAlignment")
        check(vt.SetWordWrapping!(object, UInt32(unwrapped ? CD2D_DWRITE_WORD_WRAPPING_NO_WRAP : CD2D_DWRITE_WORD_WRAPPING_WRAP)),
              "IDWriteTextLayout::SetWordWrapping")
        // Scaled emoji keep the line box of their unscaled size, their centre where the unscaled glyph's was.
        var spacing = DWRITE_LINE_SPACING(method: UInt32(CD2D_DWRITE_LINE_SPACING_METHOD_PROPORTIONAL),
                                          height: Float(D2DPen.lineHeightFactor / sizeScale),
                                          baseline: Float(emojiOnly ? D2DPen.emojiBaselineFactor : D2DPen.baselineFactor),
                                          leadingBefore: 0, fontLineGapUsage: UInt32(CD2D_DWRITE_FONT_LINE_GAP_USAGE_DEFAULT))
        check(vt.SetLineSpacing3!(object, &spacing), "IDWriteTextLayout3::SetLineSpacing")
        if truncatesTail {
            let sign = COMRef(created("IDWriteFactory::CreateEllipsisTrimmingSign") { dw.CreateEllipsisTrimmingSign!(dwrite, format.object, $0) })
            var trimming = DWRITE_TRIMMING(granularity: UInt32(CD2D_DWRITE_TRIMMING_GRANULARITY_CHARACTER), delimiter: 0, delimiterCount: 0)
            check(vt.SetTrimming!(object, &trimming, sign.object), "IDWriteTextLayout::SetTrimming")
        }
        var start: UInt32 = 0
        for r in runs {
            let length = UInt32(r.text.utf16.count)
            let range = DWRITE_TEXT_RANGE(startPosition: start, length: length)
            check(vt.SetFontWeight!(object, Self.weight(r.font.weight), range), "IDWriteTextLayout::SetFontWeight")
            check(vt.SetFontSize!(object, Float(r.font.size * sizeScale), range), "IDWriteTextLayout::SetFontSize")
            if let brush { check(vt.SetDrawingEffect!(object, brush(r.color), range), "IDWriteTextLayout::SetDrawingEffect") }
            start += length
        }
        for range in Self.fullWidthSymbolRanges(runs.map(\.text).joined()) {
            check(vt.SetFontFamilyName!(object, Self.symbolFamily, range), "IDWriteTextLayout::SetFontFamilyName")
        }
        guard maxLines > 0 || height != nil else { return layout }
        var count: UInt32 = 0
        _ = vt.GetLineMetrics!(object, nil, 0, &count)   // E_NOT_SUFFICIENT_BUFFER, with the count
        var lines = [DWRITE_LINE_METRICS](repeating: DWRITE_LINE_METRICS(), count: Int(count))
        check(vt.GetLineMetrics!(object, &lines, count, &count), "IDWriteTextLayout::GetLineMetrics")
        var limit = maxLines > 0 ? min(maxLines, lines.count) : lines.count
        if let height {
            var bottom: CGFloat = 0, fitting = 0
            for l in lines {
                bottom += CGFloat(l.height)
                guard bottom <= height + 1e-3 else { break }
                fitting += 1
            }
            limit = min(limit, max(1, fitting))
        }
        guard limit < lines.count else { return layout }
        var keep = lines.prefix(limit).reduce(0) { $0 + Int($1.length) }
        let newlines: Set<UInt16> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
        while keep > 0, newlines.contains(text[keep - 1]) { keep -= 1 }
        return textLayout(Self.prefix(runs, utf16: keep), width: width, maxLines: 0, centred: centred,
                          truncatesTail: truncatesTail, brush: brush)
    }

    /// The geometric symbols macOS draws em-wide from its CJK fonts (the team marks ◆ ★ ▲ ● ✦ ■ ✚): Segoe UI's
    /// own forms, and Microsoft YaHei UI's, are about half that size (◆ 10 × 10 px at 11 pt, 2×, against 22 × 21 on
    /// macOS), so they come from SimSun, whose GB2312 symbols are full-width. SimSun's ascent and descent are inside
    /// Segoe UI's, so lines keep their height and baseline (`D2DPenTests`). A symbol SimSun lacks (✦ ✚ ✓) falls
    /// back as before.
    static let symbolFamily = wide("SimSun")

    /// UTF-16 ranges of `s`'s characters that are one symbol from the Geometric Shapes, Miscellaneous Symbols or
    /// Dingbats blocks and not shown as emoji.
    static func fullWidthSymbolRanges(_ s: String) -> [DWRITE_TEXT_RANGE] {
        var out: [DWRITE_TEXT_RANGE] = [], at: UInt32 = 0
        for c in s {
            let length = UInt32(c.utf16.count)
            if c.unicodeScalars.count == 1, let u = c.unicodeScalars.first, (0x25A0...0x27BF).contains(u.value),
               !u.properties.isEmojiPresentation {
                out.append(DWRITE_TEXT_RANGE(startPosition: at, length: length))
            }
            at += length
        }
        return out
    }

    /// Whether `s` is only emoji (characters shown as colour emoji by default, or asked to be with U+FE0F), so
    /// macOS draws all of it in Apple Color Emoji.
    static func isEmoji(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { c in
            c.unicodeScalars.contains { $0.value == 0xFE0F } || (c.unicodeScalars.first?.properties.isEmojiPresentation ?? false)
        }
    }

    /// The first `count` UTF-16 code units of `runs` (a line boundary, so never inside a character).
    static func prefix(_ runs: [TextRun], utf16 count: Int) -> [TextRun] {
        var left = count, out: [TextRun] = []
        for r in runs where left > 0 {
            let units = Array(r.text.utf16)
            let n = min(left, units.count)
            out.append(TextRun(String(decoding: units[..<n], as: UTF16.self), font: r.font, color: r.color))
            left -= n
        }
        return out
    }

    // MARK: PNG

    /// Writes opaque or straight-alpha RGBA rows (top first) as a PNG file (for ArtGallery and the tests).
    package func writePNG(rgba: [UInt8], width: Int, height: Int, to path: String) throws {
        Self.joinCOM()
        var bgra = rgba
        for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
        let f = wic.pointee.lpVtbl.pointee
        var format = GUIDs.WICPixelFormat32bppBGRA
        let source = bgra.withUnsafeMutableBufferPointer { buf in
            createdWIC("IWICImagingFactory::CreateBitmapFromMemory", IWICBitmap.self) {
                f.CreateBitmapFromMemory(wic, UINT(width), UINT(height), &format, UINT(width * 4), UINT(buf.count), buf.baseAddress, $0)
            }
        }
        defer { release(UnsafeMutableRawPointer(source)) }
        let stream = createdWIC("IWICImagingFactory::CreateStream", IWICStream.self) { f.CreateStream(wic, $0) }
        defer { release(UnsafeMutableRawPointer(stream)) }
        check(stream.pointee.lpVtbl.pointee.InitializeFromFilename(stream, wide(path), DWORD(GENERIC_WRITE)),
              "IWICStream::InitializeFromFilename(\(path))")
        var png = GUIDs.ContainerFormatPng
        let encoder = createdWIC("IWICImagingFactory::CreateEncoder(PNG)", IWICBitmapEncoder.self) { f.CreateEncoder(wic, &png, nil, $0) }
        defer { release(UnsafeMutableRawPointer(encoder)) }
        let enc = encoder.pointee.lpVtbl.pointee
        check(enc.Initialize(encoder, UnsafeMutablePointer<IStream>(OpaquePointer(stream)), WICBitmapEncoderNoCache),
              "IWICBitmapEncoder::Initialize")
        let frame = createdWIC("IWICBitmapEncoder::CreateNewFrame", IWICBitmapFrameEncode.self) { enc.CreateNewFrame(encoder, $0, nil) }
        defer { release(UnsafeMutableRawPointer(frame)) }
        let frm = frame.pointee.lpVtbl.pointee
        check(frm.Initialize(frame, nil), "IWICBitmapFrameEncode::Initialize")
        check(frm.SetSize(frame, UINT(width), UINT(height)), "IWICBitmapFrameEncode::SetSize")
        check(frm.SetPixelFormat(frame, &format), "IWICBitmapFrameEncode::SetPixelFormat")
        check(frm.WriteSource(frame, UnsafeMutablePointer<IWICBitmapSource>(OpaquePointer(source)), nil),
              "IWICBitmapFrameEncode::WriteSource")
        check(frm.Commit(frame), "IWICBitmapFrameEncode::Commit")
        check(enc.Commit(encoder), "IWICBitmapEncoder::Commit")
    }
}
#endif
