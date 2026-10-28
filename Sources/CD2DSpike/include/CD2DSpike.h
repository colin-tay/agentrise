// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT
//
// Direct2D / DirectWrite COM declarations for Swift.
//
// Swift 6.1.2's WinSDK Clang module has no Direct2D or DirectWrite (it does have
// wincodec.h, with full C vtables, as WinSDK.WIC), and the SDK headers can't fill
// the gap:
// - d2d1.h / d2d1_1.h compile in C (D2D_USE_C_DEFINITIONS), but in C they only
//   forward-declare the interfaces: no lpVtbl structs.
// - Including them in this module anyway crashes swift-frontend 6.1.2 while it
//   builds the module (clang ASTWriter assertion "expected a hidden declaration"
//   at dxgitype.h's DXGI_MODE_DESC: the DXGI headers already belong to WinSDK's
//   explicit DirectX submodule).
// - dwrite.h is C++-only.
//
// The geometry types in dcommon.h (D2D1_POINT_2F, D2D1_RECT_F, D2D1_SIZE_F/U,
// D2D1_MATRIX_3X2_F, D2D_VECTOR_4F, D2D1_PIXEL_FORMAT, D2D1_ALPHA_MODE,
// DWRITE_MEASURING_MODE) are already in WinSDK, because wincodec.h includes
// dcommon.h; redeclaring them here fails ("incompatible definitions in different
// translation units"). So this header includes wincodec.h for those and declares
// the rest itself: the other D2D1_* value types and enums the spike uses (same
// names, layouts and values as the SDK, minus the *_FORCE_DWORD enumerators), and
// the vtables, slot for slot in the order the C++ interfaces declare their virtual
// methods. Methods the spike calls are typed; the rest are `void *` placeholders
// that only keep the slot count right. Every interface pointer is `void *`, so
// Swift sees UnsafeMutableRawPointer and reads a vtable with
// `p.load(as: UnsafePointer<Vtbl>.self).pointee`.
//
// Swift code using this module must also `import WinSDK.DirectX`: D2D1_PIXEL_FORMAT
// holds a DXGI_FORMAT, which belongs to that explicit submodule, and without it
// the 6.1.2 asserts compiler crashes in its debug-type round trip.

#pragma once

#ifdef _WIN32

#include <windows.h>
#include <wincodec.h>   // WinSDK.WIC; brings dcommon.h

// ---- Direct2D value types (d2d1.h, d2d1_1.h, d2d1effects.h) ----

typedef struct D2D1_COLOR_F { FLOAT r, g, b, a; } D2D1_COLOR_F;   // D3DCOLORVALUE in the SDK
typedef D2D_VECTOR_4F D2D1_VECTOR_4F;
typedef struct D2D1_ROUNDED_RECT { D2D1_RECT_F rect; FLOAT radiusX, radiusY; } D2D1_ROUNDED_RECT;
typedef struct D2D1_ELLIPSE { D2D1_POINT_2F point; FLOAT radiusX, radiusY; } D2D1_ELLIPSE;
typedef UINT64 D2D1_TAG;

typedef enum D2D1_FACTORY_TYPE { D2D1_FACTORY_TYPE_SINGLE_THREADED = 0, D2D1_FACTORY_TYPE_MULTI_THREADED = 1 } D2D1_FACTORY_TYPE;
typedef enum D2D1_DEBUG_LEVEL { D2D1_DEBUG_LEVEL_NONE = 0 } D2D1_DEBUG_LEVEL;
typedef struct D2D1_FACTORY_OPTIONS { D2D1_DEBUG_LEVEL debugLevel; } D2D1_FACTORY_OPTIONS;

typedef enum D2D1_RENDER_TARGET_TYPE {
    D2D1_RENDER_TARGET_TYPE_DEFAULT = 0, D2D1_RENDER_TARGET_TYPE_SOFTWARE = 1, D2D1_RENDER_TARGET_TYPE_HARDWARE = 2
} D2D1_RENDER_TARGET_TYPE;
typedef enum D2D1_RENDER_TARGET_USAGE { D2D1_RENDER_TARGET_USAGE_NONE = 0 } D2D1_RENDER_TARGET_USAGE;
typedef enum D2D1_FEATURE_LEVEL { D2D1_FEATURE_LEVEL_DEFAULT = 0 } D2D1_FEATURE_LEVEL;
typedef struct D2D1_RENDER_TARGET_PROPERTIES {
    D2D1_RENDER_TARGET_TYPE type;
    D2D1_PIXEL_FORMAT pixelFormat;
    FLOAT dpiX, dpiY;
    D2D1_RENDER_TARGET_USAGE usage;
    D2D1_FEATURE_LEVEL minLevel;
} D2D1_RENDER_TARGET_PROPERTIES;

typedef enum D2D1_CAP_STYLE {
    D2D1_CAP_STYLE_FLAT = 0, D2D1_CAP_STYLE_SQUARE = 1, D2D1_CAP_STYLE_ROUND = 2, D2D1_CAP_STYLE_TRIANGLE = 3
} D2D1_CAP_STYLE;
typedef enum D2D1_LINE_JOIN {
    D2D1_LINE_JOIN_MITER = 0, D2D1_LINE_JOIN_BEVEL = 1, D2D1_LINE_JOIN_ROUND = 2, D2D1_LINE_JOIN_MITER_OR_BEVEL = 3
} D2D1_LINE_JOIN;
typedef enum D2D1_DASH_STYLE { D2D1_DASH_STYLE_SOLID = 0 } D2D1_DASH_STYLE;
typedef struct D2D1_STROKE_STYLE_PROPERTIES {
    D2D1_CAP_STYLE startCap, endCap, dashCap;
    D2D1_LINE_JOIN lineJoin;
    FLOAT miterLimit;
    D2D1_DASH_STYLE dashStyle;
    FLOAT dashOffset;
} D2D1_STROKE_STYLE_PROPERTIES;

typedef struct D2D1_BRUSH_PROPERTIES { FLOAT opacity; D2D1_MATRIX_3X2_F transform; } D2D1_BRUSH_PROPERTIES;
typedef struct D2D1_GRADIENT_STOP { FLOAT position; D2D1_COLOR_F color; } D2D1_GRADIENT_STOP;
typedef struct D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES { D2D1_POINT_2F startPoint, endPoint; } D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES;
typedef enum D2D1_GAMMA { D2D1_GAMMA_2_2 = 0, D2D1_GAMMA_1_0 = 1 } D2D1_GAMMA;
typedef enum D2D1_EXTEND_MODE { D2D1_EXTEND_MODE_CLAMP = 0, D2D1_EXTEND_MODE_WRAP = 1, D2D1_EXTEND_MODE_MIRROR = 2 } D2D1_EXTEND_MODE;
typedef enum D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS {
    D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_NONE = 0, D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_GDI_COMPATIBLE = 1
} D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS;

typedef enum D2D1_DRAW_TEXT_OPTIONS {
    D2D1_DRAW_TEXT_OPTIONS_NONE = 0, D2D1_DRAW_TEXT_OPTIONS_NO_SNAP = 1, D2D1_DRAW_TEXT_OPTIONS_CLIP = 2,
    D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT = 4, D2D1_DRAW_TEXT_OPTIONS_DISABLE_COLOR_BITMAP_SNAPPING = 8
} D2D1_DRAW_TEXT_OPTIONS;

typedef enum D2D1_INTERPOLATION_MODE {
    D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR = 0, D2D1_INTERPOLATION_MODE_LINEAR = 1, D2D1_INTERPOLATION_MODE_CUBIC = 2,
    D2D1_INTERPOLATION_MODE_MULTI_SAMPLE_LINEAR = 3, D2D1_INTERPOLATION_MODE_ANISOTROPIC = 4,
    D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC = 5
} D2D1_INTERPOLATION_MODE;
typedef enum D2D1_COMPOSITE_MODE { D2D1_COMPOSITE_MODE_SOURCE_OVER = 0 } D2D1_COMPOSITE_MODE;
typedef enum D2D1_PROPERTY_TYPE {
    D2D1_PROPERTY_TYPE_UNKNOWN = 0, D2D1_PROPERTY_TYPE_STRING = 1, D2D1_PROPERTY_TYPE_BOOL = 2,
    D2D1_PROPERTY_TYPE_UINT32 = 3, D2D1_PROPERTY_TYPE_INT32 = 4, D2D1_PROPERTY_TYPE_FLOAT = 5,
    D2D1_PROPERTY_TYPE_VECTOR2 = 6, D2D1_PROPERTY_TYPE_VECTOR3 = 7, D2D1_PROPERTY_TYPE_VECTOR4 = 8
} D2D1_PROPERTY_TYPE;
typedef enum D2D1_GAUSSIANBLUR_PROP { D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION = 0 } D2D1_GAUSSIANBLUR_PROP;
typedef enum D2D1_SHADOW_PROP {
    D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION = 0, D2D1_SHADOW_PROP_COLOR = 1
} D2D1_SHADOW_PROP;

// From d2d1.h (D2d1.lib).
HRESULT WINAPI D2D1CreateFactory(D2D1_FACTORY_TYPE factoryType, REFIID riid,
                                 const D2D1_FACTORY_OPTIONS *options, void **factory);

// ---- vtables ----

#define CD2D_SLOT(name) void *name

#define CD2D_IUNKNOWN_SLOTS                                                              \
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(void *This, const IID *riid, void **out); \
    ULONG (STDMETHODCALLTYPE *AddRef)(void *This);                                       \
    ULONG (STDMETHODCALLTYPE *Release)(void *This);

typedef struct CD2D_IUnknownVtbl {
    CD2D_IUNKNOWN_SLOTS
} CD2D_IUnknownVtbl;

// ID2D1Factory : IUnknown
#define CD2D_ID2D1FACTORY_SLOTS                                                          \
    CD2D_IUNKNOWN_SLOTS                                                                  \
    CD2D_SLOT(ReloadSystemMetrics);                                                      \
    CD2D_SLOT(GetDesktopDpi);                                                            \
    CD2D_SLOT(CreateRectangleGeometry);                                                  \
    CD2D_SLOT(CreateRoundedRectangleGeometry);                                           \
    CD2D_SLOT(CreateEllipseGeometry);                                                    \
    CD2D_SLOT(CreateGeometryGroup);                                                      \
    CD2D_SLOT(CreateTransformedGeometry);                                                \
    CD2D_SLOT(CreatePathGeometry);                                                       \
    HRESULT (STDMETHODCALLTYPE *CreateStrokeStyle)(void *This,                           \
        const D2D1_STROKE_STYLE_PROPERTIES *props, const FLOAT *dashes,                  \
        UINT32 dashesCount, void **strokeStyle);                                         \
    CD2D_SLOT(CreateDrawingStateBlock);                                                  \
    HRESULT (STDMETHODCALLTYPE *CreateWicBitmapRenderTarget)(void *This,                 \
        void *wicBitmap, const D2D1_RENDER_TARGET_PROPERTIES *props,                     \
        void **renderTarget);                                                            \
    CD2D_SLOT(CreateHwndRenderTarget);                                                   \
    CD2D_SLOT(CreateDxgiSurfaceRenderTarget);                                            \
    CD2D_SLOT(CreateDCRenderTarget);

typedef struct CD2D_ID2D1FactoryVtbl {
    CD2D_ID2D1FACTORY_SLOTS
} CD2D_ID2D1FactoryVtbl;

// ID2D1RenderTarget : ID2D1Resource : IUnknown
#define CD2D_ID2D1RENDERTARGET_SLOTS                                                     \
    CD2D_IUNKNOWN_SLOTS                                                                  \
    CD2D_SLOT(GetFactory);                                                               \
    CD2D_SLOT(CreateBitmap);                                                             \
    CD2D_SLOT(CreateBitmapFromWicBitmap);                                                \
    CD2D_SLOT(CreateSharedBitmap);                                                       \
    CD2D_SLOT(CreateBitmapBrush);                                                        \
    HRESULT (STDMETHODCALLTYPE *CreateSolidColorBrush)(void *This,                       \
        const D2D1_COLOR_F *color, const D2D1_BRUSH_PROPERTIES *brushProps,              \
        void **brush);                                                                   \
    HRESULT (STDMETHODCALLTYPE *CreateGradientStopCollection)(void *This,                \
        const D2D1_GRADIENT_STOP *stops, UINT32 count, D2D1_GAMMA gamma,                 \
        D2D1_EXTEND_MODE extendMode, void **collection);                                 \
    HRESULT (STDMETHODCALLTYPE *CreateLinearGradientBrush)(void *This,                   \
        const D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES *gradientProps,                      \
        const D2D1_BRUSH_PROPERTIES *brushProps, void *stops, void **brush);             \
    CD2D_SLOT(CreateRadialGradientBrush);                                                \
    HRESULT (STDMETHODCALLTYPE *CreateCompatibleRenderTarget)(void *This,                \
        const D2D1_SIZE_F *desiredSize, const D2D1_SIZE_U *desiredPixelSize,             \
        const D2D1_PIXEL_FORMAT *desiredFormat,                                          \
        D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS options, void **bitmapRenderTarget);       \
    CD2D_SLOT(CreateLayer);                                                              \
    CD2D_SLOT(CreateMesh);                                                               \
    CD2D_SLOT(DrawLine);                                                                 \
    CD2D_SLOT(DrawRectangle);                                                            \
    CD2D_SLOT(FillRectangle);                                                            \
    CD2D_SLOT(DrawRoundedRectangle);                                                     \
    void (STDMETHODCALLTYPE *FillRoundedRectangle)(void *This,                           \
        const D2D1_ROUNDED_RECT *roundedRect, void *brush);                              \
    void (STDMETHODCALLTYPE *DrawEllipse)(void *This, const D2D1_ELLIPSE *ellipse,       \
        void *brush, FLOAT strokeWidth, void *strokeStyle);                              \
    void (STDMETHODCALLTYPE *FillEllipse)(void *This, const D2D1_ELLIPSE *ellipse,       \
        void *brush);                                                                    \
    CD2D_SLOT(DrawGeometry);                                                             \
    CD2D_SLOT(FillGeometry);                                                             \
    CD2D_SLOT(FillMesh);                                                                 \
    CD2D_SLOT(FillOpacityMask);                                                          \
    CD2D_SLOT(DrawBitmap);                                                               \
    /* windows.h #defines DrawText to DrawTextW, hence the trailing underscore. */       \
    void (STDMETHODCALLTYPE *DrawText_)(void *This, const WCHAR *string,                 \
        UINT32 length, void *textFormat, const D2D1_RECT_F *layoutRect,                  \
        void *defaultFillBrush, D2D1_DRAW_TEXT_OPTIONS options,                          \
        DWRITE_MEASURING_MODE measuringMode);                                            \
    CD2D_SLOT(DrawTextLayout);                                                           \
    CD2D_SLOT(DrawGlyphRun);                                                             \
    CD2D_SLOT(SetTransform);                                                             \
    CD2D_SLOT(GetTransform);                                                             \
    CD2D_SLOT(SetAntialiasMode);                                                         \
    CD2D_SLOT(GetAntialiasMode);                                                         \
    CD2D_SLOT(SetTextAntialiasMode);                                                     \
    CD2D_SLOT(GetTextAntialiasMode);                                                     \
    CD2D_SLOT(SetTextRenderingParams);                                                   \
    CD2D_SLOT(GetTextRenderingParams);                                                   \
    CD2D_SLOT(SetTags);                                                                  \
    CD2D_SLOT(GetTags);                                                                  \
    CD2D_SLOT(PushLayer);                                                                \
    CD2D_SLOT(PopLayer);                                                                 \
    CD2D_SLOT(Flush);                                                                    \
    CD2D_SLOT(SaveDrawingState);                                                         \
    CD2D_SLOT(RestoreDrawingState);                                                      \
    CD2D_SLOT(PushAxisAlignedClip);                                                      \
    CD2D_SLOT(PopAxisAlignedClip);                                                       \
    void (STDMETHODCALLTYPE *Clear)(void *This, const D2D1_COLOR_F *clearColor);         \
    void (STDMETHODCALLTYPE *BeginDraw)(void *This);                                     \
    HRESULT (STDMETHODCALLTYPE *EndDraw)(void *This, D2D1_TAG *tag1, D2D1_TAG *tag2);    \
    CD2D_SLOT(GetPixelFormat);                                                           \
    CD2D_SLOT(SetDpi);                                                                   \
    CD2D_SLOT(GetDpi);                                                                   \
    CD2D_SLOT(GetSize);                                                                  \
    CD2D_SLOT(GetPixelSize);                                                             \
    CD2D_SLOT(GetMaximumBitmapSize);                                                     \
    CD2D_SLOT(IsSupported);

typedef struct CD2D_ID2D1RenderTargetVtbl {
    CD2D_ID2D1RENDERTARGET_SLOTS
} CD2D_ID2D1RenderTargetVtbl;

// ID2D1BitmapRenderTarget : ID2D1RenderTarget
typedef struct CD2D_ID2D1BitmapRenderTargetVtbl {
    CD2D_ID2D1RENDERTARGET_SLOTS
    HRESULT (STDMETHODCALLTYPE *GetBitmap)(void *This, void **bitmap);
} CD2D_ID2D1BitmapRenderTargetVtbl;

// ID2D1DeviceContext : ID2D1RenderTarget (Direct2D 1.1)
typedef struct CD2D_ID2D1DeviceContextVtbl {
    CD2D_ID2D1RENDERTARGET_SLOTS
    CD2D_SLOT(CreateBitmap1);
    CD2D_SLOT(CreateBitmapFromWicBitmap1);
    CD2D_SLOT(CreateColorContext);
    CD2D_SLOT(CreateColorContextFromFilename);
    CD2D_SLOT(CreateColorContextFromWicColorContext);
    CD2D_SLOT(CreateBitmapFromDxgiSurface);
    HRESULT (STDMETHODCALLTYPE *CreateEffect)(void *This, const CLSID *effectId, void **effect);
    CD2D_SLOT(CreateGradientStopCollection1);
    CD2D_SLOT(CreateImageBrush);
    CD2D_SLOT(CreateBitmapBrush1);
    CD2D_SLOT(CreateCommandList);
    CD2D_SLOT(IsDxgiFormatSupported);
    CD2D_SLOT(IsBufferPrecisionSupported);
    CD2D_SLOT(GetImageLocalBounds);
    CD2D_SLOT(GetImageWorldBounds);
    CD2D_SLOT(GetGlyphRunWorldBounds);
    CD2D_SLOT(GetDevice);
    CD2D_SLOT(SetTarget);
    CD2D_SLOT(GetTarget);
    CD2D_SLOT(SetRenderingControls);
    CD2D_SLOT(GetRenderingControls);
    CD2D_SLOT(SetPrimitiveBlend);
    CD2D_SLOT(GetPrimitiveBlend);
    CD2D_SLOT(SetUnitMode);
    CD2D_SLOT(GetUnitMode);
    CD2D_SLOT(DrawGlyphRun1);
    void (STDMETHODCALLTYPE *DrawImage)(void *This, void *image,
        const D2D1_POINT_2F *targetOffset, const D2D1_RECT_F *imageRectangle,
        D2D1_INTERPOLATION_MODE interpolationMode, D2D1_COMPOSITE_MODE compositeMode);
} CD2D_ID2D1DeviceContextVtbl;

// ID2D1Effect : ID2D1Properties : IUnknown
typedef struct CD2D_ID2D1EffectVtbl {
    CD2D_IUNKNOWN_SLOTS
    CD2D_SLOT(GetPropertyCount);
    CD2D_SLOT(GetPropertyName);
    CD2D_SLOT(GetPropertyNameLength);
    CD2D_SLOT(GetType);
    CD2D_SLOT(GetPropertyIndex);
    CD2D_SLOT(SetValueByName);
    HRESULT (STDMETHODCALLTYPE *SetValue)(void *This, UINT32 index, D2D1_PROPERTY_TYPE type,
        const BYTE *data, UINT32 dataSize);
    CD2D_SLOT(GetValueByName);
    CD2D_SLOT(GetValue);
    CD2D_SLOT(GetValueSize);
    CD2D_SLOT(GetSubProperties);
    void (STDMETHODCALLTYPE *SetInput)(void *This, UINT32 index, void *input, BOOL invalidate);
    CD2D_SLOT(SetInputCount);
    CD2D_SLOT(GetInput);
    CD2D_SLOT(GetInputCount);
    void (STDMETHODCALLTYPE *GetOutput)(void *This, void **outputImage);
} CD2D_ID2D1EffectVtbl;

// ---- DirectWrite: dwrite.h is C++-only, so its enums are declared here too. ----

typedef UINT32 CD2D_DWRITE_FONT_WEIGHT;      // DWRITE_FONT_WEIGHT
typedef UINT32 CD2D_DWRITE_FONT_STYLE;       // DWRITE_FONT_STYLE
typedef UINT32 CD2D_DWRITE_FONT_STRETCH;     // DWRITE_FONT_STRETCH
typedef UINT32 CD2D_DWRITE_TEXT_ALIGNMENT;   // DWRITE_TEXT_ALIGNMENT
typedef UINT32 CD2D_DWRITE_PARAGRAPH_ALIGNMENT; // DWRITE_PARAGRAPH_ALIGNMENT

enum {
    CD2D_DWRITE_FACTORY_TYPE_SHARED = 0,
    CD2D_DWRITE_FONT_WEIGHT_NORMAL = 400,
    CD2D_DWRITE_FONT_WEIGHT_SEMI_BOLD = 600,
    CD2D_DWRITE_FONT_STYLE_NORMAL = 0,
    CD2D_DWRITE_FONT_STRETCH_NORMAL = 5,
    CD2D_DWRITE_TEXT_ALIGNMENT_CENTER = 2,
    CD2D_DWRITE_PARAGRAPH_ALIGNMENT_CENTER = 2,
};

// IDWriteFactory : IUnknown
typedef struct CD2D_IDWriteFactoryVtbl {
    CD2D_IUNKNOWN_SLOTS
    CD2D_SLOT(GetSystemFontCollection);
    CD2D_SLOT(CreateCustomFontCollection);
    CD2D_SLOT(RegisterFontCollectionLoader);
    CD2D_SLOT(UnregisterFontCollectionLoader);
    CD2D_SLOT(CreateFontFileReference);
    CD2D_SLOT(CreateCustomFontFileReference);
    CD2D_SLOT(CreateFontFace);
    CD2D_SLOT(CreateRenderingParams);
    CD2D_SLOT(CreateMonitorRenderingParams);
    CD2D_SLOT(CreateCustomRenderingParams);
    CD2D_SLOT(RegisterFontFileLoader);
    CD2D_SLOT(UnregisterFontFileLoader);
    HRESULT (STDMETHODCALLTYPE *CreateTextFormat)(void *This, const WCHAR *familyName,
        void *fontCollection, CD2D_DWRITE_FONT_WEIGHT weight, CD2D_DWRITE_FONT_STYLE style,
        CD2D_DWRITE_FONT_STRETCH stretch, FLOAT fontSize, const WCHAR *localeName,
        void **textFormat);
} CD2D_IDWriteFactoryVtbl;

// IDWriteTextFormat : IUnknown
typedef struct CD2D_IDWriteTextFormatVtbl {
    CD2D_IUNKNOWN_SLOTS
    HRESULT (STDMETHODCALLTYPE *SetTextAlignment)(void *This, CD2D_DWRITE_TEXT_ALIGNMENT a);
    HRESULT (STDMETHODCALLTYPE *SetParagraphAlignment)(void *This, CD2D_DWRITE_PARAGRAPH_ALIGNMENT a);
} CD2D_IDWriteTextFormatVtbl;

// From dwrite.h (DWrite.lib). The real third parameter is IUnknown **.
HRESULT WINAPI DWriteCreateFactory(UINT32 factoryType, REFIID iid, void **factory);

#endif // _WIN32
