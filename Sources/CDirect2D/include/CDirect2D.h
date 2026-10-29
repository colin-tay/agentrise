// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT
//
// Direct2D 1.1 / DirectWrite COM declarations for AgentriseWinArt (D2DPen).
//
// Swift 6.1.2's WinSDK module has no Direct2D or DirectWrite, and the SDK headers can't be used from a Clang
// module (Sources/CD2DSpike/include/CD2DSpike.h, Task 1, explains why in full). So, as there:
// - only <windows.h> and <wincodec.h> are included; dcommon.h (reached through wincodec.h) already gives
//   D2D1_POINT_2F, D2D1_RECT_F, D2D1_SIZE_F/U, D2D1_MATRIX_3X2_F, D2D_VECTOR_4F, D2D1_PIXEL_FORMAT,
//   D2D1_ALPHA_MODE and DWRITE_MEASURING_MODE, which must not be declared again;
// - every other value type and enum used is declared here with the SDK's name, layout and values (minus the
//   *_FORCE_DWORD enumerators; DirectWrite's enums are UINT32 constants, as dwrite.h is C++-only);
// - vtables are declared slot for slot in vtable order: methods called are typed, the rest are `void *`
//   placeholders. Every interface pointer is `void *`. Slot orders were checked against Wine's IDL files
//   (d2d1.idl, d2d1_1.idl, dwrite.idl, dwrite_1.idl, dwrite_2.idl, dwrite_3.idl), which list methods in the
//   order MSVC lays out the vtables (the C++ headers' overload grouping included);
// - a method returning a struct by value takes a hidden out-pointer after This and returns it (MSVC x64):
//   `RET *(STDMETHODCALLTYPE *M)(void *This, RET *out)`. Structs passed by value as arguments are fine.
//
// Swift code using this module must also `import WinSDK.DirectX` (D2D1_PIXEL_FORMAT holds a DXGI_FORMAT; without
// it the 6.1.2 compiler crashes reconstructing debug types).

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

typedef enum D2D1_ANTIALIAS_MODE { D2D1_ANTIALIAS_MODE_PER_PRIMITIVE = 0, D2D1_ANTIALIAS_MODE_ALIASED = 1 } D2D1_ANTIALIAS_MODE;
typedef enum D2D1_TEXT_ANTIALIAS_MODE {
    D2D1_TEXT_ANTIALIAS_MODE_DEFAULT = 0, D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE = 1,
    D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE = 2, D2D1_TEXT_ANTIALIAS_MODE_ALIASED = 3
} D2D1_TEXT_ANTIALIAS_MODE;
typedef enum D2D1_BITMAP_INTERPOLATION_MODE {
    D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR = 0, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR = 1
} D2D1_BITMAP_INTERPOLATION_MODE;
typedef enum D2D1_LAYER_OPTIONS { D2D1_LAYER_OPTIONS_NONE = 0, D2D1_LAYER_OPTIONS_INITIALIZE_FOR_CLEARTYPE = 1 } D2D1_LAYER_OPTIONS;
typedef struct D2D1_LAYER_PARAMETERS {
    D2D1_RECT_F contentBounds;
    void *geometricMask;            // ID2D1Geometry *
    D2D1_ANTIALIAS_MODE maskAntialiasMode;
    D2D1_MATRIX_3X2_F maskTransform;
    FLOAT opacity;
    void *opacityBrush;             // ID2D1Brush *
    D2D1_LAYER_OPTIONS layerOptions;
} D2D1_LAYER_PARAMETERS;

typedef enum D2D1_DRAW_TEXT_OPTIONS {
    D2D1_DRAW_TEXT_OPTIONS_NONE = 0, D2D1_DRAW_TEXT_OPTIONS_NO_SNAP = 1, D2D1_DRAW_TEXT_OPTIONS_CLIP = 2,
    D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT = 4, D2D1_DRAW_TEXT_OPTIONS_DISABLE_COLOR_BITMAP_SNAPPING = 8
} D2D1_DRAW_TEXT_OPTIONS;

// Geometry (d2d1.h).
typedef enum D2D1_FILL_MODE { D2D1_FILL_MODE_ALTERNATE = 0, D2D1_FILL_MODE_WINDING = 1 } D2D1_FILL_MODE;
typedef enum D2D1_FIGURE_BEGIN { D2D1_FIGURE_BEGIN_FILLED = 0, D2D1_FIGURE_BEGIN_HOLLOW = 1 } D2D1_FIGURE_BEGIN;
typedef enum D2D1_FIGURE_END { D2D1_FIGURE_END_OPEN = 0, D2D1_FIGURE_END_CLOSED = 1 } D2D1_FIGURE_END;
typedef enum D2D1_SWEEP_DIRECTION {
    D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE = 0, D2D1_SWEEP_DIRECTION_CLOCKWISE = 1
} D2D1_SWEEP_DIRECTION;
typedef enum D2D1_ARC_SIZE { D2D1_ARC_SIZE_SMALL = 0, D2D1_ARC_SIZE_LARGE = 1 } D2D1_ARC_SIZE;
typedef struct D2D1_ARC_SEGMENT {
    D2D1_POINT_2F point;
    D2D1_SIZE_F size;
    FLOAT rotationAngle;
    D2D1_SWEEP_DIRECTION sweepDirection;
    D2D1_ARC_SIZE arcSize;
} D2D1_ARC_SEGMENT;
typedef struct D2D1_QUADRATIC_BEZIER_SEGMENT { D2D1_POINT_2F point1, point2; } D2D1_QUADRATIC_BEZIER_SEGMENT;

// Effects (d2d1_1.h, d2d1effects.h).
typedef enum D2D1_INTERPOLATION_MODE {
    D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR = 0, D2D1_INTERPOLATION_MODE_LINEAR = 1, D2D1_INTERPOLATION_MODE_CUBIC = 2,
    D2D1_INTERPOLATION_MODE_MULTI_SAMPLE_LINEAR = 3, D2D1_INTERPOLATION_MODE_ANISOTROPIC = 4,
    D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC = 5
} D2D1_INTERPOLATION_MODE;
typedef enum D2D1_COMPOSITE_MODE { D2D1_COMPOSITE_MODE_SOURCE_OVER = 0 } D2D1_COMPOSITE_MODE;
typedef enum D2D1_PROPERTY_TYPE {
    D2D1_PROPERTY_TYPE_UNKNOWN = 0, D2D1_PROPERTY_TYPE_STRING = 1, D2D1_PROPERTY_TYPE_BOOL = 2,
    D2D1_PROPERTY_TYPE_UINT32 = 3, D2D1_PROPERTY_TYPE_INT32 = 4, D2D1_PROPERTY_TYPE_FLOAT = 5,
    D2D1_PROPERTY_TYPE_VECTOR2 = 6, D2D1_PROPERTY_TYPE_VECTOR3 = 7, D2D1_PROPERTY_TYPE_VECTOR4 = 8,
    D2D1_PROPERTY_TYPE_MATRIX_3X2 = 9, D2D1_PROPERTY_TYPE_MATRIX_4X3 = 10, D2D1_PROPERTY_TYPE_MATRIX_4X4 = 11,
    D2D1_PROPERTY_TYPE_MATRIX_5X4 = 12, D2D1_PROPERTY_TYPE_BLOB = 13, D2D1_PROPERTY_TYPE_IUNKNOWN = 14,
    D2D1_PROPERTY_TYPE_ENUM = 15
} D2D1_PROPERTY_TYPE;
typedef enum D2D1_SHADOW_PROP {
    D2D1_SHADOW_PROP_BLUR_STANDARD_DEVIATION = 0, D2D1_SHADOW_PROP_COLOR = 1, D2D1_SHADOW_PROP_OPTIMIZATION = 2
} D2D1_SHADOW_PROP;
typedef enum D2D1_SHADOW_OPTIMIZATION {
    D2D1_SHADOW_OPTIMIZATION_SPEED = 0, D2D1_SHADOW_OPTIMIZATION_BALANCED = 1, D2D1_SHADOW_OPTIMIZATION_QUALITY = 2
} D2D1_SHADOW_OPTIMIZATION;

// From d2d1.h (D2d1.lib).
HRESULT WINAPI D2D1CreateFactory(D2D1_FACTORY_TYPE factoryType, REFIID riid,
                                 const D2D1_FACTORY_OPTIONS *options, void **factory);

// ---- Direct2D vtables ----

#define CD2D_SLOT(name) void *name

#define CD2D_IUNKNOWN_SLOTS                                                              \
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(void *This, const IID *riid, void **out); \
    ULONG (STDMETHODCALLTYPE *AddRef)(void *This);                                       \
    ULONG (STDMETHODCALLTYPE *Release)(void *This);

typedef struct CD2D_IUnknownVtbl {
    CD2D_IUNKNOWN_SLOTS
} CD2D_IUnknownVtbl;

// ID2D1Factory : IUnknown
typedef struct CD2D_ID2D1FactoryVtbl {
    CD2D_IUNKNOWN_SLOTS
    CD2D_SLOT(ReloadSystemMetrics);
    CD2D_SLOT(GetDesktopDpi);
    HRESULT (STDMETHODCALLTYPE *CreateRectangleGeometry)(void *This, const D2D1_RECT_F *rect, void **geometry);
    HRESULT (STDMETHODCALLTYPE *CreateRoundedRectangleGeometry)(void *This, const D2D1_ROUNDED_RECT *rect, void **geometry);
    HRESULT (STDMETHODCALLTYPE *CreateEllipseGeometry)(void *This, const D2D1_ELLIPSE *ellipse, void **geometry);
    CD2D_SLOT(CreateGeometryGroup);
    CD2D_SLOT(CreateTransformedGeometry);
    HRESULT (STDMETHODCALLTYPE *CreatePathGeometry)(void *This, void **geometry);
    HRESULT (STDMETHODCALLTYPE *CreateStrokeStyle)(void *This, const D2D1_STROKE_STYLE_PROPERTIES *props,
        const FLOAT *dashes, UINT32 dashesCount, void **strokeStyle);
    CD2D_SLOT(CreateDrawingStateBlock);
    HRESULT (STDMETHODCALLTYPE *CreateWicBitmapRenderTarget)(void *This, void *wicBitmap,
        const D2D1_RENDER_TARGET_PROPERTIES *props, void **renderTarget);
    CD2D_SLOT(CreateHwndRenderTarget);
    CD2D_SLOT(CreateDxgiSurfaceRenderTarget);
    CD2D_SLOT(CreateDCRenderTarget);
} CD2D_ID2D1FactoryVtbl;

// ID2D1PathGeometry : ID2D1Geometry : ID2D1Resource : IUnknown
typedef struct CD2D_ID2D1PathGeometryVtbl {
    CD2D_IUNKNOWN_SLOTS
    CD2D_SLOT(GetFactory);
    CD2D_SLOT(GetBounds);
    CD2D_SLOT(GetWidenedBounds);
    CD2D_SLOT(StrokeContainsPoint);
    CD2D_SLOT(FillContainsPoint);
    CD2D_SLOT(CompareWithGeometry);
    CD2D_SLOT(Simplify);
    CD2D_SLOT(Tessellate);
    CD2D_SLOT(CombineWithGeometry);
    CD2D_SLOT(Outline);
    CD2D_SLOT(ComputeArea);
    CD2D_SLOT(ComputeLength);
    CD2D_SLOT(ComputePointAtLength);
    CD2D_SLOT(Widen);
    HRESULT (STDMETHODCALLTYPE *Open)(void *This, void **geometrySink);
    CD2D_SLOT(Stream);
    CD2D_SLOT(GetSegmentCount);
    CD2D_SLOT(GetFigureCount);
} CD2D_ID2D1PathGeometryVtbl;

// ID2D1GeometrySink : ID2D1SimplifiedGeometrySink : IUnknown
typedef struct CD2D_ID2D1GeometrySinkVtbl {
    CD2D_IUNKNOWN_SLOTS
    void (STDMETHODCALLTYPE *SetFillMode)(void *This, D2D1_FILL_MODE fillMode);
    CD2D_SLOT(SetSegmentFlags);
    void (STDMETHODCALLTYPE *BeginFigure)(void *This, D2D1_POINT_2F startPoint, D2D1_FIGURE_BEGIN figureBegin);
    CD2D_SLOT(AddLines);
    CD2D_SLOT(AddBeziers);
    void (STDMETHODCALLTYPE *EndFigure)(void *This, D2D1_FIGURE_END figureEnd);
    HRESULT (STDMETHODCALLTYPE *Close)(void *This);
    void (STDMETHODCALLTYPE *AddLine)(void *This, D2D1_POINT_2F point);
    CD2D_SLOT(AddBezier);
    void (STDMETHODCALLTYPE *AddQuadraticBezier)(void *This, const D2D1_QUADRATIC_BEZIER_SEGMENT *bezier);
    CD2D_SLOT(AddQuadraticBeziers);
    void (STDMETHODCALLTYPE *AddArc)(void *This, const D2D1_ARC_SEGMENT *arc);
} CD2D_ID2D1GeometrySinkVtbl;

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
    CD2D_SLOT(FillRoundedRectangle);                                                     \
    CD2D_SLOT(DrawEllipse);                                                              \
    CD2D_SLOT(FillEllipse);                                                              \
    void (STDMETHODCALLTYPE *DrawGeometry)(void *This, void *geometry, void *brush,      \
        FLOAT strokeWidth, void *strokeStyle);                                           \
    void (STDMETHODCALLTYPE *FillGeometry)(void *This, void *geometry, void *brush,      \
        void *opacityBrush);                                                             \
    CD2D_SLOT(FillMesh);                                                                 \
    CD2D_SLOT(FillOpacityMask);                                                          \
    void (STDMETHODCALLTYPE *DrawBitmap)(void *This, void *bitmap,                       \
        const D2D1_RECT_F *destinationRectangle, FLOAT opacity,                          \
        D2D1_BITMAP_INTERPOLATION_MODE interpolationMode,                                \
        const D2D1_RECT_F *sourceRectangle);                                             \
    CD2D_SLOT(DrawText_);                                                                \
    void (STDMETHODCALLTYPE *DrawTextLayout)(void *This, D2D1_POINT_2F origin,           \
        void *textLayout, void *defaultFillBrush, D2D1_DRAW_TEXT_OPTIONS options);       \
    CD2D_SLOT(DrawGlyphRun);                                                             \
    CD2D_SLOT(SetTransform);                                                             \
    CD2D_SLOT(GetTransform);                                                             \
    CD2D_SLOT(SetAntialiasMode);                                                         \
    CD2D_SLOT(GetAntialiasMode);                                                         \
    void (STDMETHODCALLTYPE *SetTextAntialiasMode)(void *This,                           \
        D2D1_TEXT_ANTIALIAS_MODE textAntialiasMode);                                     \
    CD2D_SLOT(GetTextAntialiasMode);                                                     \
    void (STDMETHODCALLTYPE *SetTextRenderingParams)(void *This, void *textRenderingParams); \
    CD2D_SLOT(GetTextRenderingParams);                                                   \
    CD2D_SLOT(SetTags);                                                                  \
    CD2D_SLOT(GetTags);                                                                  \
    void (STDMETHODCALLTYPE *PushLayer)(void *This,                                      \
        const D2D1_LAYER_PARAMETERS *layerParameters, void *layer);                      \
    void (STDMETHODCALLTYPE *PopLayer)(void *This);                                      \
    CD2D_SLOT(Flush);                                                                    \
    CD2D_SLOT(SaveDrawingState);                                                         \
    CD2D_SLOT(RestoreDrawingState);                                                      \
    void (STDMETHODCALLTYPE *PushAxisAlignedClip)(void *This,                            \
        const D2D1_RECT_F *clipRect, D2D1_ANTIALIAS_MODE antialiasMode);                 \
    void (STDMETHODCALLTYPE *PopAxisAlignedClip)(void *This);                            \
    void (STDMETHODCALLTYPE *Clear)(void *This, const D2D1_COLOR_F *clearColor);         \
    void (STDMETHODCALLTYPE *BeginDraw)(void *This);                                     \
    HRESULT (STDMETHODCALLTYPE *EndDraw)(void *This, D2D1_TAG *tag1, D2D1_TAG *tag2);    \
    CD2D_SLOT(GetPixelFormat);                                                           \
    CD2D_SLOT(SetDpi);                                                                   \
    CD2D_SLOT(GetDpi);                                                                   \
    CD2D_SLOT(GetSize);                                                                  \
    /* Struct return: hidden out-pointer after This (see the top of this file). */      \
    D2D1_SIZE_U *(STDMETHODCALLTYPE *GetPixelSize)(void *This, D2D1_SIZE_U *out);        \
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

// ---- DirectWrite (dwrite.h, dwrite_1.h, dwrite_3.h) ----

enum {
    CD2D_DWRITE_FACTORY_TYPE_SHARED = 0,
    CD2D_DWRITE_FONT_STYLE_NORMAL = 0,
    CD2D_DWRITE_FONT_STRETCH_NORMAL = 5,
    CD2D_DWRITE_TEXT_ALIGNMENT_LEADING = 0,
    CD2D_DWRITE_TEXT_ALIGNMENT_CENTER = 2,
    CD2D_DWRITE_PARAGRAPH_ALIGNMENT_NEAR = 0,
    CD2D_DWRITE_WORD_WRAPPING_WRAP = 0,
    CD2D_DWRITE_WORD_WRAPPING_NO_WRAP = 1,
    CD2D_DWRITE_TRIMMING_GRANULARITY_CHARACTER = 1,
    CD2D_DWRITE_PIXEL_GEOMETRY_FLAT = 0,
    CD2D_DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC = 5,
    CD2D_DWRITE_LINE_SPACING_METHOD_PROPORTIONAL = 2,
    CD2D_DWRITE_FONT_LINE_GAP_USAGE_DEFAULT = 0,
};

typedef struct DWRITE_TEXT_RANGE { UINT32 startPosition, length; } DWRITE_TEXT_RANGE;
typedef struct DWRITE_TEXT_METRICS {
    FLOAT left, top, width, widthIncludingTrailingWhitespace, height, layoutWidth, layoutHeight;
    UINT32 maxBidiReorderingDepth, lineCount;
} DWRITE_TEXT_METRICS;
typedef struct DWRITE_LINE_METRICS {
    UINT32 length, trailingWhitespaceLength, newlineLength;
    FLOAT height, baseline;
    BOOL isTrimmed;
} DWRITE_LINE_METRICS;
typedef struct DWRITE_TRIMMING { UINT32 granularity, delimiter, delimiterCount; } DWRITE_TRIMMING;
typedef struct DWRITE_LINE_SPACING {   // dwrite_3.h
    UINT32 method;                      // DWRITE_LINE_SPACING_METHOD
    FLOAT height, baseline, leadingBefore;
    UINT32 fontLineGapUsage;            // DWRITE_FONT_LINE_GAP_USAGE
} DWRITE_LINE_SPACING;

// From dwrite.h (DWrite.lib). The real third parameter is IUnknown **.
HRESULT WINAPI DWriteCreateFactory(UINT32 factoryType, REFIID iid, void **factory);

// IDWriteFactory1 : IDWriteFactory : IUnknown
typedef struct CD2D_IDWriteFactory1Vtbl {
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
        void *fontCollection, UINT32 weight, UINT32 style, UINT32 stretch, FLOAT fontSize,
        const WCHAR *localeName, void **textFormat);
    CD2D_SLOT(CreateTypography);
    CD2D_SLOT(GetGdiInterop);
    HRESULT (STDMETHODCALLTYPE *CreateTextLayout)(void *This, const WCHAR *string, UINT32 stringLength,
        void *textFormat, FLOAT maxWidth, FLOAT maxHeight, void **textLayout);
    CD2D_SLOT(CreateGdiCompatibleTextLayout);
    HRESULT (STDMETHODCALLTYPE *CreateEllipsisTrimmingSign)(void *This, void *textFormat, void **trimmingSign);
    CD2D_SLOT(CreateTextAnalyzer);
    CD2D_SLOT(CreateNumberSubstitution);
    CD2D_SLOT(CreateGlyphRunAnalysis);
    // IDWriteFactory1
    CD2D_SLOT(GetEudcFontCollection);
    HRESULT (STDMETHODCALLTYPE *CreateCustomRenderingParams1)(void *This, FLOAT gamma, FLOAT enhancedContrast,
        FLOAT enhancedContrastGrayscale, FLOAT clearTypeLevel, UINT32 pixelGeometry, UINT32 renderingMode,
        void **renderingParams);
} CD2D_IDWriteFactory1Vtbl;

// IDWriteTextFormat : IUnknown
#define CD2D_IDWRITETEXTFORMAT_SLOTS                                                     \
    CD2D_IUNKNOWN_SLOTS                                                                  \
    HRESULT (STDMETHODCALLTYPE *SetTextAlignment)(void *This, UINT32 textAlignment);     \
    HRESULT (STDMETHODCALLTYPE *SetParagraphAlignment)(void *This, UINT32 paragraphAlignment); \
    HRESULT (STDMETHODCALLTYPE *SetWordWrapping)(void *This, UINT32 wordWrapping);       \
    CD2D_SLOT(SetReadingDirection);                                                      \
    CD2D_SLOT(SetFlowDirection);                                                         \
    CD2D_SLOT(SetIncrementalTabStop);                                                    \
    HRESULT (STDMETHODCALLTYPE *SetTrimming)(void *This, const DWRITE_TRIMMING *trimmingOptions, \
        void *trimmingSign);                                                             \
    CD2D_SLOT(SetLineSpacing);                                                           \
    CD2D_SLOT(GetTextAlignment);                                                         \
    CD2D_SLOT(GetParagraphAlignment);                                                    \
    CD2D_SLOT(GetWordWrapping);                                                          \
    CD2D_SLOT(GetReadingDirection);                                                      \
    CD2D_SLOT(GetFlowDirection);                                                         \
    CD2D_SLOT(GetIncrementalTabStop);                                                    \
    CD2D_SLOT(GetTrimming);                                                              \
    CD2D_SLOT(GetLineSpacing);                                                           \
    CD2D_SLOT(GetFontCollection);                                                        \
    CD2D_SLOT(GetFontFamilyNameLength);                                                  \
    CD2D_SLOT(GetFontFamilyName);                                                        \
    CD2D_SLOT(GetFontWeight);                                                            \
    CD2D_SLOT(GetFontStyle);                                                             \
    CD2D_SLOT(GetFontStretch);                                                           \
    CD2D_SLOT(GetFontSize);                                                              \
    CD2D_SLOT(GetLocaleNameLength);                                                      \
    CD2D_SLOT(GetLocaleName);

typedef struct CD2D_IDWriteTextFormatVtbl {
    CD2D_IDWRITETEXTFORMAT_SLOTS
} CD2D_IDWriteTextFormatVtbl;

// IDWriteTextLayout3 : IDWriteTextLayout2 : IDWriteTextLayout1 : IDWriteTextLayout : IDWriteTextFormat
typedef struct CD2D_IDWriteTextLayout3Vtbl {
    CD2D_IDWRITETEXTFORMAT_SLOTS
    // IDWriteTextLayout
    CD2D_SLOT(SetMaxWidth);
    CD2D_SLOT(SetMaxHeight);
    CD2D_SLOT(SetFontCollection);
    HRESULT (STDMETHODCALLTYPE *SetFontFamilyName)(void *This, const WCHAR *name, DWRITE_TEXT_RANGE textRange);
    HRESULT (STDMETHODCALLTYPE *SetFontWeight)(void *This, UINT32 fontWeight, DWRITE_TEXT_RANGE textRange);
    CD2D_SLOT(SetFontStyle);
    CD2D_SLOT(SetFontStretch);
    HRESULT (STDMETHODCALLTYPE *SetFontSize)(void *This, FLOAT fontSize, DWRITE_TEXT_RANGE textRange);
    CD2D_SLOT(SetUnderline);
    CD2D_SLOT(SetStrikethrough);
    HRESULT (STDMETHODCALLTYPE *SetDrawingEffect)(void *This, void *drawingEffect, DWRITE_TEXT_RANGE textRange);
    CD2D_SLOT(SetInlineObject);
    CD2D_SLOT(SetTypography);
    CD2D_SLOT(SetLocaleName);
    CD2D_SLOT(GetMaxWidth);
    CD2D_SLOT(GetMaxHeight);
    CD2D_SLOT(GetFontCollection1);
    CD2D_SLOT(GetFontFamilyNameLength1);
    CD2D_SLOT(GetFontFamilyName1);
    CD2D_SLOT(GetFontWeight1);
    CD2D_SLOT(GetFontStyle1);
    CD2D_SLOT(GetFontStretch1);
    CD2D_SLOT(GetFontSize1);
    CD2D_SLOT(GetUnderline);
    CD2D_SLOT(GetStrikethrough);
    CD2D_SLOT(GetDrawingEffect);
    CD2D_SLOT(GetInlineObject);
    CD2D_SLOT(GetTypography);
    CD2D_SLOT(GetLocaleNameLength1);
    CD2D_SLOT(GetLocaleName1);
    CD2D_SLOT(Draw);
    HRESULT (STDMETHODCALLTYPE *GetLineMetrics)(void *This, DWRITE_LINE_METRICS *lineMetrics,
        UINT32 maxLineCount, UINT32 *actualLineCount);
    HRESULT (STDMETHODCALLTYPE *GetMetrics)(void *This, DWRITE_TEXT_METRICS *textMetrics);
    CD2D_SLOT(GetOverhangMetrics);
    CD2D_SLOT(GetClusterMetrics);
    CD2D_SLOT(DetermineMinWidth);
    CD2D_SLOT(HitTestPoint);
    CD2D_SLOT(HitTestTextPosition);
    CD2D_SLOT(HitTestTextRange);
    // IDWriteTextLayout1
    CD2D_SLOT(SetPairKerning);
    CD2D_SLOT(GetPairKerning);
    CD2D_SLOT(SetCharacterSpacing);
    CD2D_SLOT(GetCharacterSpacing);
    // IDWriteTextLayout2
    CD2D_SLOT(GetMetrics1);
    CD2D_SLOT(SetVerticalGlyphOrientation);
    CD2D_SLOT(GetVerticalGlyphOrientation);
    CD2D_SLOT(SetLastLineWrapping);
    CD2D_SLOT(GetLastLineWrapping);
    CD2D_SLOT(SetOpticalAlignment);
    CD2D_SLOT(GetOpticalAlignment);
    CD2D_SLOT(SetFontFallback);
    CD2D_SLOT(GetFontFallback);
    // IDWriteTextLayout3
    CD2D_SLOT(InvalidateLayout);
    HRESULT (STDMETHODCALLTYPE *SetLineSpacing3)(void *This, const DWRITE_LINE_SPACING *lineSpacingOptions);
    CD2D_SLOT(GetLineSpacing3);
    CD2D_SLOT(GetLineMetrics3);
} CD2D_IDWriteTextLayout3Vtbl;

#endif // _WIN32
