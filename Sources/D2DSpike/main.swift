// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT
//
// Direct2D 1.1 / DirectWrite / WIC spike: draws a small robot offscreen into a
// 240x200 WIC bitmap at scale 2 (192 dpi, so the drawing is 120x100 DIPs) and
// writes it as a PNG to the path in the first argument.
//
// WIC is called through WinSDK's own C vtables (WinSDK.WIC). Direct2D and
// DirectWrite are called through the types and vtables declared in CD2DSpike.h,
// because neither WinSDK nor the SDK headers give Swift usable ones (see that header).
// Any failed HRESULT prints the call and the code, then exits with 1.

#if os(Windows)
import CD2DSpike
import Foundation
import WinSDK
// D2D1_PIXEL_FORMAT (dcommon.h, reached through WinSDK.WIC) holds a DXGI_FORMAT, whose
// definition belongs to the explicit WinSDK.DirectX submodule. Without importing it,
// the 6.1.2 asserts compiler can't find DXGI_FORMAT when it round-trips debug types
// ("Failed to reconstruct type for $sSo11DXGI_FORMATVmD") and crashes.
import WinSDK.DirectX

typealias COMObject = UnsafeMutableRawPointer

let E_POINTER_ = HRESULT(bitPattern: 0x8000_4003)

func fail(_ call: String, _ hr: HRESULT) -> Never {
    let hex = String(UInt32(bitPattern: hr), radix: 16, uppercase: true)
    print("\(call) failed: 0x\(String(repeating: "0", count: max(0, 8 - hex.count)))\(hex)")
    exit(1)
}

func check(_ hr: HRESULT, _ call: String) {
    if hr < 0 { fail(call, hr) }
}

/// The vtable of a COM object: the first pointer-sized field of every COM object.
func vtable<T>(_ object: COMObject, _: T.Type) -> T {
    object.load(as: UnsafePointer<T>.self).pointee
}

func release(_ object: COMObject?) {
    guard let object else { return }
    _ = vtable(object, CD2D_IUnknownVtbl.self).Release!(object)
}

/// Runs a `void **`-out creation call and returns the object it made.
func created(_ call: String, _ body: (UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> HRESULT) -> COMObject {
    var out: UnsafeMutableRawPointer?
    check(body(&out), call)
    guard let out else { fail(call, E_POINTER_) }
    return out
}

/// The same for WinSDK's typed WIC out-parameters.
func createdWIC<T>(_ call: String, _: T.Type,
                   _ body: (UnsafeMutablePointer<UnsafeMutablePointer<T>?>) -> HRESULT) -> UnsafeMutablePointer<T> {
    var out: UnsafeMutablePointer<T>?
    check(body(&out), call)
    guard let out else { fail(call, E_POINTER_) }
    return out
}

func guid(_ text: String) -> GUID {
    let hex = Array(text.filter { $0 != "-" })
    func field(_ start: Int, _ count: Int) -> UInt64 { UInt64(String(hex[start..<start + count]), radix: 16)! }
    func byte(_ i: Int) -> UInt8 { UInt8(field(16 + 2 * i, 2)) }
    return GUID(Data1: UInt32(field(0, 8)), Data2: UInt16(field(8, 4)), Data3: UInt16(field(12, 4)),
                Data4: (byte(0), byte(1), byte(2), byte(3), byte(4), byte(5), byte(6), byte(7)))
}

// GUIDs as literals (checked against the SDK headers), so nothing needs dxguid.lib or uuid.lib.
var IID_ID2D1Factory1 = guid("bb12d362-daee-4b9a-aa1d-14ba401cfa1f")
var IID_ID2D1DeviceContext = guid("e8f7fe7a-191c-466d-ad95-975678bda998")
var IID_IDWriteFactory = guid("b859ee5a-d838-4b5b-a2e8-1adc7d93db48")
var CLSID_D2D1GaussianBlur = guid("1feb6d69-2fe6-4ac9-8c58-1d7f93e7a6a5")
var CLSID_D2D1Shadow = guid("c67ea361-1863-4e69-89db-695d3e9a5b6b")
var CLSID_WICImagingFactory2 = guid("317d06e8-5f24-433d-bdf7-79ce68d8abc2")
var IID_IWICImagingFactory = guid("ec5ec8a9-c395-4314-9c77-54d7a935ff70")
var GUID_WICPixelFormat32bppPBGRA = guid("6fddc324-4e03-4bfe-b185-3d77768dc910")
var GUID_WICPixelFormat32bppBGRA = guid("6fddc324-4e03-4bfe-b185-3d77768dc90f")
var GUID_ContainerFormatPng = guid("1b7cfaf4-713f-473c-bbcd-6137425faeaf")

let pixelWidth: UInt32 = 240
let pixelHeight: UInt32 = 200
let dpi: Float = 192   // scale 2

func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }

func color(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> D2D1_COLOR_F {
    D2D1_COLOR_F(r: r, g: g, b: b, a: a)
}

func rect(_ l: Float, _ t: Float, _ r: Float, _ b: Float) -> D2D1_RECT_F {
    D2D1_RECT_F(left: l, top: t, right: r, bottom: b)
}

func ellipse(_ x: Float, _ y: Float, _ rx: Float, _ ry: Float) -> D2D1_ELLIPSE {
    D2D1_ELLIPSE(point: D2D1_POINT_2F(x: x, y: y), radiusX: rx, radiusY: ry)
}

// MARK: - Direct2D wrappers (all through CD2DSpike's vtables)

func rt(_ target: COMObject) -> CD2D_ID2D1RenderTargetVtbl { vtable(target, CD2D_ID2D1RenderTargetVtbl.self) }

func solidBrush(_ target: COMObject, _ c: D2D1_COLOR_F) -> COMObject {
    var c = c
    return created("ID2D1RenderTarget::CreateSolidColorBrush") { rt(target).CreateSolidColorBrush!(target, &c, nil, $0) }
}

func setProperty<T>(_ effect: COMObject, _ index: UInt32, _ type: D2D1_PROPERTY_TYPE, _ value: T, _ call: String) {
    var value = value
    let hr = withUnsafeBytes(of: &value) { raw in
        vtable(effect, CD2D_ID2D1EffectVtbl.self).SetValue!(
            effect, index, type, raw.bindMemory(to: BYTE.self).baseAddress, UInt32(raw.count))
    }
    check(hr, call)
}

func effectOutput(_ effect: COMObject) -> COMObject {
    var image: UnsafeMutableRawPointer?
    vtable(effect, CD2D_ID2D1EffectVtbl.self).GetOutput!(effect, &image)
    guard let image else { fail("ID2D1Effect::GetOutput", E_POINTER_) }
    return image
}

/// Draws into a transparent offscreen layer the size of `parent` and returns its bitmap.
func offscreenLayer(_ parent: COMObject, _ name: String, _ draw: (COMObject) -> Void) -> COMObject {
    let layer = created("ID2D1RenderTarget::CreateCompatibleRenderTarget (\(name))") {
        rt(parent).CreateCompatibleRenderTarget!(parent, nil, nil, nil, D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE, $0)
    }
    var clear = color(0, 0, 0, 0)
    rt(layer).BeginDraw!(layer)
    rt(layer).Clear!(layer, &clear)
    draw(layer)
    check(rt(layer).EndDraw!(layer, nil, nil), "ID2D1BitmapRenderTarget::EndDraw (\(name))")
    let bitmap = created("ID2D1BitmapRenderTarget::GetBitmap (\(name))") {
        vtable(layer, CD2D_ID2D1BitmapRenderTargetVtbl.self).GetBitmap!(layer, $0)
    }
    release(layer)
    return bitmap
}

// MARK: - Main

guard CommandLine.arguments.count >= 2 else {
    print("usage: D2DSpike <output.png>")
    exit(2)
}
let outputPath = CommandLine.arguments[1]

check(CoInitializeEx(nil, 0 /* COINIT_MULTITHREADED */), "CoInitializeEx")

// WIC factory and the offscreen bitmap.
let wicFactory = createdWIC("CoCreateInstance(CLSID_WICImagingFactory2)", IWICImagingFactory.self) { out in
    out.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
        CoCreateInstance(&CLSID_WICImagingFactory2, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &IID_IWICImagingFactory, $0)
    }
}
let wic = wicFactory.pointee.lpVtbl.pointee
let wicBitmap = createdWIC("IWICImagingFactory::CreateBitmap", IWICBitmap.self) {
    wic.CreateBitmap(wicFactory, pixelWidth, pixelHeight, &GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, $0)
}

// Direct2D 1.1 factory, a WIC render target, and its ID2D1DeviceContext.
let d2dFactory = created("D2D1CreateFactory(ID2D1Factory1)") {
    D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory1, nil, $0)
}
let factory = vtable(d2dFactory, CD2D_ID2D1FactoryVtbl.self)

// Pixel format {UNKNOWN, UNKNOWN}: take the WIC bitmap's (PBGRA). See CD2D_RenderTargetProperties.
var targetProps = CD2D_RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_SOFTWARE, dpi)
let wicTarget = created("ID2D1Factory::CreateWicBitmapRenderTarget") {
    factory.CreateWicBitmapRenderTarget!(d2dFactory, UnsafeMutableRawPointer(wicBitmap), &targetProps, $0)
}
let dc = created("QueryInterface(ID2D1DeviceContext)") {
    vtable(wicTarget, CD2D_IUnknownVtbl.self).QueryInterface!(wicTarget, &IID_ID2D1DeviceContext, $0)
}
release(wicTarget)
let ctx = vtable(dc, CD2D_ID2D1DeviceContextVtbl.self)

var roundProps = D2D1_STROKE_STYLE_PROPERTIES(
    startCap: D2D1_CAP_STYLE_ROUND, endCap: D2D1_CAP_STYLE_ROUND, dashCap: D2D1_CAP_STYLE_ROUND,
    lineJoin: D2D1_LINE_JOIN_ROUND, miterLimit: 10, dashStyle: D2D1_DASH_STYLE_SOLID, dashOffset: 0)
let roundStroke = created("ID2D1Factory::CreateStrokeStyle") {
    factory.CreateStrokeStyle!(d2dFactory, &roundProps, nil, 0, $0)
}

// DirectWrite text formats.
let dwFactory = created("DWriteCreateFactory") {
    DWriteCreateFactory(UInt32(CD2D_DWRITE_FACTORY_TYPE_SHARED), &IID_IDWriteFactory, $0)
}
func textFormat(_ family: String, _ weight: Int, _ size: Float, _ locale: String) -> COMObject {
    let format = created("IDWriteFactory::CreateTextFormat (\(family))") {
        vtable(dwFactory, CD2D_IDWriteFactoryVtbl.self).CreateTextFormat!(
            dwFactory, wide(family), nil, UInt32(weight), UInt32(CD2D_DWRITE_FONT_STYLE_NORMAL),
            UInt32(CD2D_DWRITE_FONT_STRETCH_NORMAL), size, wide(locale), $0)
    }
    let vt = vtable(format, CD2D_IDWriteTextFormatVtbl.self)
    check(vt.SetTextAlignment!(format, UInt32(CD2D_DWRITE_TEXT_ALIGNMENT_CENTER)), "IDWriteTextFormat::SetTextAlignment")
    check(vt.SetParagraphAlignment!(format, UInt32(CD2D_DWRITE_PARAGRAPH_ALIGNMENT_CENTER)),
          "IDWriteTextFormat::SetParagraphAlignment")
    return format
}
// 11 pt = 11 DIPs, as on macOS. Locale zh-CN so the Han fallback is Microsoft YaHei UI.
let nameFormat = textFormat("Segoe UI", Int(CD2D_DWRITE_FONT_WEIGHT_SEMI_BOLD), 11, "zh-CN")
let emojiFormat = textFormat("Segoe UI Emoji", Int(CD2D_DWRITE_FONT_WEIGHT_NORMAL), 15, "en-US")

// Geometry, in DIPs on the 120x100 canvas.
var body = D2D1_ROUNDED_RECT(rect: rect(40, 46, 80, 76), radiusX: 8, radiusY: 8)
var head = ellipse(60, 27, 16, 13)
var neckRing = ellipse(60, 44, 10, 2.6)
var leftEye = ellipse(54, 27, 2.4, 2.4)
var rightEye = ellipse(66, 27, 2.4, 2.4)

// Brushes.
let black = solidBrush(dc, color(0, 0, 0))
let white = solidBrush(dc, color(1, 1, 1))
let cyan = solidBrush(dc, color(0.30, 0.95, 1.0))
let headFill = solidBrush(dc, color(0.96, 0.56, 0.24))
let eyeFill = solidBrush(dc, color(0.10, 0.11, 0.18))
var stops = [
    D2D1_GRADIENT_STOP(position: 0, color: color(0.45, 0.66, 1.00)),
    D2D1_GRADIENT_STOP(position: 1, color: color(0.18, 0.26, 0.72)),
]
let gradientStops = created("ID2D1RenderTarget::CreateGradientStopCollection") {
    ctx.CreateGradientStopCollection!(dc, &stops, UInt32(stops.count), D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP, $0)
}
var gradientProps = D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES(
    startPoint: D2D1_POINT_2F(x: 60, y: 46), endPoint: D2D1_POINT_2F(x: 60, y: 76))
let bodyGradient = created("ID2D1RenderTarget::CreateLinearGradientBrush") {
    ctx.CreateLinearGradientBrush!(dc, &gradientProps, nil, gradientStops, $0)
}

// Offscreen layers that feed the effects.
let bodySilhouette = offscreenLayer(dc, "body silhouette") { layer in
    rt(layer).FillRoundedRectangle!(layer, &body, black)
}
let ringLayer = offscreenLayer(dc, "neck ring") { layer in
    rt(layer).DrawEllipse!(layer, &neckRing, cyan, 2.5, roundStroke)
}

// Shadow under the body.
let shadow = created("ID2D1DeviceContext::CreateEffect(CLSID_D2D1Shadow)") {
    ctx.CreateEffect!(dc, &CLSID_D2D1Shadow, $0)
}
vtable(shadow, CD2D_ID2D1EffectVtbl.self).SetInput!(shadow, 0, bodySilhouette, true)
setProperty(shadow, UInt32(truncatingIfNeeded: D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION.rawValue),
            D2D1_PROPERTY_TYPE_FLOAT, Float(3), "ID2D1Effect::SetValue(shadow blur)")
setProperty(shadow, UInt32(truncatingIfNeeded: D2D1_SHADOW_PROP_COLOR.rawValue),
            D2D1_PROPERTY_TYPE_VECTOR4, D2D1_VECTOR_4F(x: 0.02, y: 0.03, z: 0.10, w: 0.6),
            "ID2D1Effect::SetValue(shadow color)")
let shadowImage = effectOutput(shadow)

// Glow around the neck ring.
let glow = created("ID2D1DeviceContext::CreateEffect(CLSID_D2D1GaussianBlur)") {
    ctx.CreateEffect!(dc, &CLSID_D2D1GaussianBlur, $0)
}
vtable(glow, CD2D_ID2D1EffectVtbl.self).SetInput!(glow, 0, ringLayer, true)
setProperty(glow, UInt32(truncatingIfNeeded: D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION.rawValue),
            D2D1_PROPERTY_TYPE_FLOAT, Float(2.5), "ID2D1Effect::SetValue(glow blur)")
let glowImage = effectOutput(glow)

// The frame.
var background = color(0.11, 0.12, 0.17)
var shadowOffset = D2D1_POINT_2F(x: 0, y: 3)
let name = Array("张三 Claude".utf16)
let book = Array("📖".utf16)
var nameRect = rect(0, 80, 120, 98)
var bookRect = rect(40, 48, 80, 76)

ctx.BeginDraw!(dc)
ctx.Clear!(dc, &background)
ctx.DrawImage!(dc, shadowImage, &shadowOffset, nil, D2D1_INTERPOLATION_MODE_LINEAR, D2D1_COMPOSITE_MODE_SOURCE_OVER)
ctx.FillRoundedRectangle!(dc, &body, bodyGradient)
ctx.DrawImage!(dc, glowImage, nil, nil, D2D1_INTERPOLATION_MODE_LINEAR, D2D1_COMPOSITE_MODE_SOURCE_OVER)
ctx.DrawImage!(dc, glowImage, nil, nil, D2D1_INTERPOLATION_MODE_LINEAR, D2D1_COMPOSITE_MODE_SOURCE_OVER)
ctx.DrawEllipse!(dc, &neckRing, cyan, 1.5, roundStroke)
ctx.FillEllipse!(dc, &head, headFill)
ctx.DrawEllipse!(dc, &head, white, 2, roundStroke)
ctx.FillEllipse!(dc, &leftEye, eyeFill)
ctx.FillEllipse!(dc, &rightEye, eyeFill)
ctx.DrawText_!(dc, book, UInt32(book.count), emojiFormat, &bookRect, white,
               D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT, DWRITE_MEASURING_MODE_NATURAL)
ctx.DrawText_!(dc, name, UInt32(name.count), nameFormat, &nameRect, white,
               D2D1_DRAW_TEXT_OPTIONS_NONE, DWRITE_MEASURING_MODE_NATURAL)
check(ctx.EndDraw!(dc, nil, nil), "ID2D1DeviceContext::EndDraw")

// Encode the WIC bitmap as PNG (PNG has no premultiplied format, so convert to BGRA first).
let converter = createdWIC("IWICImagingFactory::CreateFormatConverter", IWICFormatConverter.self) {
    wic.CreateFormatConverter(wicFactory, $0)
}
check(converter.pointee.lpVtbl.pointee.Initialize(
          converter, UnsafeMutablePointer<IWICBitmapSource>(OpaquePointer(wicBitmap)), &GUID_WICPixelFormat32bppBGRA,
          WICBitmapDitherTypeNone, nil, 0, WICBitmapPaletteTypeCustom),
      "IWICFormatConverter::Initialize")

let stream = createdWIC("IWICImagingFactory::CreateStream", IWICStream.self) {
    wic.CreateStream(wicFactory, $0)
}
check(stream.pointee.lpVtbl.pointee.InitializeFromFilename(stream, wide(outputPath), DWORD(GENERIC_WRITE)),
      "IWICStream::InitializeFromFilename")
let encoder = createdWIC("IWICImagingFactory::CreateEncoder(PNG)", IWICBitmapEncoder.self) {
    wic.CreateEncoder(wicFactory, &GUID_ContainerFormatPng, nil, $0)
}
let enc = encoder.pointee.lpVtbl.pointee
check(enc.Initialize(encoder, UnsafeMutablePointer<IStream>(OpaquePointer(stream)), WICBitmapEncoderNoCache),
      "IWICBitmapEncoder::Initialize")
let frame = createdWIC("IWICBitmapEncoder::CreateNewFrame", IWICBitmapFrameEncode.self) {
    enc.CreateNewFrame(encoder, $0, nil)
}
let frm = frame.pointee.lpVtbl.pointee
check(frm.Initialize(frame, nil), "IWICBitmapFrameEncode::Initialize")
check(frm.SetSize(frame, pixelWidth, pixelHeight), "IWICBitmapFrameEncode::SetSize")
check(frm.SetResolution(frame, Double(dpi), Double(dpi)), "IWICBitmapFrameEncode::SetResolution")
var framePixelFormat = GUID_WICPixelFormat32bppBGRA
check(frm.SetPixelFormat(frame, &framePixelFormat), "IWICBitmapFrameEncode::SetPixelFormat")
check(frm.WriteSource(frame, UnsafeMutablePointer<IWICBitmapSource>(OpaquePointer(converter)), nil),
      "IWICBitmapFrameEncode::WriteSource")
check(frm.Commit(frame), "IWICBitmapFrameEncode::Commit")
check(enc.Commit(encoder), "IWICBitmapEncoder::Commit")

for object in [shadowImage, glowImage, shadow, glow, bodySilhouette, ringLayer, bodyGradient, gradientStops,
               black, white, cyan, headFill, eyeFill, nameFormat, emojiFormat, dwFactory, roundStroke, dc, d2dFactory,
               UnsafeMutableRawPointer(frame), UnsafeMutableRawPointer(encoder), UnsafeMutableRawPointer(stream),
               UnsafeMutableRawPointer(converter), UnsafeMutableRawPointer(wicBitmap),
               UnsafeMutableRawPointer(wicFactory)] {
    release(object)
}
CoUninitialize()
print("D2DSpike: wrote \(outputPath) (\(pixelWidth)x\(pixelHeight) px, \(Int(dpi)) dpi)")
#endif
