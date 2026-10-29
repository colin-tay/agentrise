// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT
//
// COM plumbing for the Direct2D/DirectWrite/WIC calls (see CDirect2D.h for how the vtables are declared).
// A failed HRESULT here is a broken invariant (a bad argument or an exhausted machine), not something the art can
// recover from: like the macOS backend's force-unwrapped `CGContext(...)!`, it stops with the call and the code.

#if os(Windows)
import CDirect2D
import Foundation
import WinSDK
// D2D1_PIXEL_FORMAT holds a DXGI_FORMAT (WinSDK.DirectX); without this import the 6.1.2 compiler crashes.
import WinSDK.DirectX

typealias COMObject = UnsafeMutableRawPointer

func comFailure(_ call: String, _ hr: HRESULT) -> Never {
    let hex = String(UInt32(bitPattern: hr), radix: 16, uppercase: true)
    fatalError("\(call) failed: 0x\(String(repeating: "0", count: max(0, 8 - hex.count)))\(hex)")
}

func check(_ hr: HRESULT, _ call: @autoclosure () -> String) {
    if hr < 0 { comFailure(call(), hr) }
}

/// The vtable of a COM object (its first pointer-sized field), read as `T`.
func vtable<T>(_ object: COMObject, _: T.Type) -> T {
    object.load(as: UnsafePointer<T>.self).pointee
}

func release(_ object: COMObject?) {
    guard let object else { return }
    _ = vtable(object, CD2D_IUnknownVtbl.self).Release!(object)
}

/// Runs a `void **`-out creation call and returns the object it made (owned by the caller).
func created(_ call: @autoclosure () -> String, _ body: (UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> HRESULT) -> COMObject {
    var out: UnsafeMutableRawPointer?
    check(body(&out), call())
    guard let out else { comFailure(call(), HRESULT(bitPattern: 0x8000_4003)) }   // E_POINTER
    return out
}

/// The same for WinSDK's typed WIC out-parameters.
func createdWIC<T>(_ call: @autoclosure () -> String, _: T.Type,
                   _ body: (UnsafeMutablePointer<UnsafeMutablePointer<T>?>) -> HRESULT) -> UnsafeMutablePointer<T> {
    var out: UnsafeMutablePointer<T>?
    check(body(&out), call())
    guard let out else { comFailure(call(), HRESULT(bitPattern: 0x8000_4003)) }
    return out
}

/// `object` queried for `iid` (a new reference), or nil when it doesn't implement it.
func query(_ object: COMObject, _ iid: GUID) -> COMObject? {
    var iid = iid
    var out: UnsafeMutableRawPointer?
    guard vtable(object, CD2D_IUnknownVtbl.self).QueryInterface!(object, &iid, &out) >= 0 else { return nil }
    return out
}

/// Owns one reference to a COM object and releases it when it goes.
final class COMRef {
    let object: COMObject
    init(_ object: COMObject) { self.object = object }
    deinit { release(object) }
}

func guid(_ text: String) -> GUID {
    let hex = Array(text.filter { $0 != "-" })
    func field(_ start: Int, _ count: Int) -> UInt64 { UInt64(String(hex[start..<start + count]), radix: 16)! }
    func byte(_ i: Int) -> UInt8 { UInt8(field(16 + 2 * i, 2)) }
    return GUID(Data1: UInt32(field(0, 8)), Data2: UInt16(field(8, 4)), Data3: UInt16(field(12, 4)),
                Data4: (byte(0), byte(1), byte(2), byte(3), byte(4), byte(5), byte(6), byte(7)))
}

/// GUIDs as literals (checked against the SDK headers), so nothing needs dxguid.lib or uuid.lib.
enum GUIDs {
    static let ID2D1Factory1 = guid("bb12d362-daee-4b9a-aa1d-14ba401cfa1f")
    static let ID2D1DeviceContext = guid("e8f7fe7a-191c-466d-ad95-975678bda998")
    static let IDWriteFactory1 = guid("30572f99-dac6-41db-a16e-0486307e606a")
    static let IDWriteTextLayout3 = guid("07ddcd52-020e-4de8-ac33-6c953d83f92d")
    static let IWICImagingFactory = guid("ec5ec8a9-c395-4314-9c77-54d7a935ff70")
    static let CLSID_D2D1Shadow = guid("c67ea361-1863-4e69-89db-695d3e9a5b6b")
    static let CLSID_WICImagingFactory2 = guid("317d06e8-5f24-433d-bdf7-79ce68d8abc2")
    static let WICPixelFormat32bppPBGRA = guid("6fddc324-4e03-4bfe-b185-3d77768dc910")
    static let WICPixelFormat32bppBGRA = guid("6fddc324-4e03-4bfe-b185-3d77768dc90f")
    static let ContainerFormatPng = guid("1b7cfaf4-713f-473c-bbcd-6137425faeaf")
}

/// A NUL-terminated UTF-16 copy of `s`.
func wide(_ s: String) -> [WCHAR] { Array(s.utf16) + [0] }
#endif
