// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT
//
// Direct2D / DirectWrite COM vtables for Swift.
//
// The Windows SDK's d2d1.h and d2d1_1.h compile in C (they switch to
// D2D_USE_C_DEFINITIONS when __cplusplus is not defined), but in C they only
// forward-declare the interfaces: there are no lpVtbl structs. dwrite.h is
// C++-only and cannot be included from C at all. WinSDK's Clang module has
// neither header (it does have wincodec.h, with full C vtables, as WinSDK.WIC).
//
// So this header takes the value types (D2D1_* structs and enums) from the SDK
// headers and declares the vtables itself, slot for slot in the order the C++
// interfaces declare their virtual methods. Methods the spike calls are typed;
// the rest are `void *` placeholders that only keep the slot count right.
// Every interface pointer is `void *`, so Swift sees UnsafeMutableRawPointer and
// reads the vtable with `p.load(as: UnsafePointer<Vtbl>.self).pointee`.

#pragma once

#ifdef _WIN32

#include <windows.h>
#include <wincodec.h>
#include <d2d1_1.h>
#include <d2d1effects.h>

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
