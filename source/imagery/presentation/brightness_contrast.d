/++
 Normalized image-domain brightness and contrast mapping.

 This module defines the numeric contract independently of raster layout:
 `brightness` shifts normalized values by [-1, 1], while `contrast` scales
 around the midpoint and must be finite. Values are clipped to [0, 1].
 It performs no colour conversion, alpha inference or NoData handling.
+/
module imagery.presentation.brightness_contrast;

import core.stdc.stdlib : malloc, free;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, WritableRasterView, tryAdoptMallocResource,
    tryImportOwnedRaster;
import std.math : isFinite;

struct BrightnessContrast
{
    double brightness;
    double contrast;
}

enum BrightnessContrastError : ubyte
{
    none,
    invalidParameters,
    nonFiniteSample,
    invalidSource,
    invalidRegion,
    invalidChannelSelection,
    invalidMask,
    sampleFailure,
    allocationFailure,
    resultExceedsBudget
}

private bool inside(Region2D roi, size_t width, size_t height)
@safe pure nothrow @nogc
{
    return roi.width != 0 && roi.height != 0 && roi.x <= width &&
        roi.y <= height && roi.width <= width - roi.x &&
        roi.height <= height - roi.y;
}

private bool tryOwnedBytes(size_t bytes, ref OwnedByteResource owner)
@trusted nothrow @nogc
{
    if (bytes == 0) return false;
    auto p = malloc(bytes);
    if (p is null) return false;
    if (!tryAdoptMallocResource(p, bytes, owner)) { free(p); return false; }
    return true;
}

private double normalized(T)(T value)
@safe pure nothrow @nogc
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    static if (is(T == ubyte)) return cast(double)value / 255.0;
    else static if (is(T == ushort)) return cast(double)value / 65535.0;
    else return cast(double)value;
}

private BrightnessContrastError execute(T)(scope RasterView!T src,
    Region2D roi, scope const(bool)[] affected,
    BrightnessContrast settings, scope RasterView!ubyte mask,
    bool hasMask, scope WritableRasterView!float dst)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    if (src.planeCount == 0 || src.width == 0 || src.height == 0)
        return BrightnessContrastError.invalidSource;
    if (!inside(roi, src.width, src.height))
        return BrightnessContrastError.invalidRegion;
    if (affected.length != src.planeCount || !valid(settings))
        return affected.length != src.planeCount
            ? BrightnessContrastError.invalidChannelSelection
            : BrightnessContrastError.invalidParameters;
    if (hasMask && (mask.planeCount != 1 || mask.width != src.width ||
        mask.height != src.height)) return BrightnessContrastError.invalidMask;
    if (dst.planeCount != src.planeCount || dst.width != roi.width ||
        dst.height != roi.height) return BrightnessContrastError.allocationFailure;
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        ubyte weight = 255;
        if (hasMask && !mask.trySample(0, x, y, weight))
            return BrightnessContrastError.sampleFailure;
        const strength = cast(double)weight / 255.0;
        foreach (channel; 0 .. src.planeCount)
        {
            T raw;
            if (!src.trySample(channel, x, y, raw))
                return BrightnessContrastError.sampleFailure;
            const original = normalized(raw);
            double mapped;
            if (!isFinite(original)) mapped = original;
            else
            {
                auto status = tryMapNormalized(original, settings, mapped);
                if (status != BrightnessContrastError.none) return status;
                mapped = original + strength * (mapped - original);
            }
            if (!dst.trySetSample(channel, x - roi.x, y - roi.y,
                cast(float)mapped)) return BrightnessContrastError.sampleFailure;
        }
    }
    return BrightnessContrastError.none;
}

private BrightnessContrastError tryBrightnessContrastOwnedImpl(T)(
    scope RasterView!T src, Region2D roi, scope const(bool)[] affected,
    BrightnessContrast settings, scope RasterView!ubyte mask, bool hasMask,
    size_t maxResultBytes, ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    if (src.planeCount == 0 || src.width == 0 || src.height == 0)
        return BrightnessContrastError.invalidSource;
    if (!inside(roi, src.width, src.height))
        return BrightnessContrastError.invalidRegion;
    if (affected.length != src.planeCount)
        return BrightnessContrastError.invalidChannelSelection;
    if (!valid(settings)) return BrightnessContrastError.invalidParameters;
    if (hasMask && (mask.planeCount != 1 || mask.width != src.width || mask.height != src.height))
        return BrightnessContrastError.invalidMask;
    if (roi.width > size_t.max / roi.height || src.planeCount > size_t.max / (roi.width * roi.height) / float.sizeof)
        return BrightnessContrastError.allocationFailure;
    const bytes = roi.width * roi.height * src.planeCount * float.sizeof;
    if (bytes > maxResultBytes || bytes > cast(size_t)ptrdiff_t.max)
        return BrightnessContrastError.resultExceedsBudget;
    OwnedByteResource owned;
    if (!tryOwnedBytes(bytes, owned)) return BrightnessContrastError.allocationFailure;
    auto layouts = new PlaneByteLayout[](src.planeCount);
    foreach (c; 0 .. src.planeCount)
        layouts[c] = PlaneByteLayout(c * float.sizeof,
            cast(ptrdiff_t)(roi.width * src.planeCount * float.sizeof),
            cast(ptrdiff_t)(src.planeCount * float.sizeof));
    RasterLease!float temporary;
    if (!tryImportOwnedRaster!float(owned, layouts[], Region2D(0, 0, roi.width, roi.height), temporary).ok)
        return BrightnessContrastError.allocationFailure;
    bool writable;
    scope auto output = temporary.tryWritableView(writable);
    if (!writable) return BrightnessContrastError.allocationFailure;
    auto status = execute!T(src, roi, affected, settings, mask, hasMask, output);
    if (status != BrightnessContrastError.none) return status;
    published = temporary;
    return BrightnessContrastError.none;
}

BrightnessContrastError tryBrightnessContrastOwned(T)(
    scope RasterView!T src, Region2D roi, scope const(bool)[] affected,
    BrightnessContrast settings, size_t maxResultBytes,
    ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    return tryBrightnessContrastOwnedImpl!T(src, roi, affected, settings,
        RasterView!ubyte.init, false, maxResultBytes, published);
}

BrightnessContrastError tryBrightnessContrastOwned(T)(
    scope RasterView!T src, Region2D roi, scope const(bool)[] affected,
    BrightnessContrast settings, scope RasterView!ubyte mask,
    size_t maxResultBytes, ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    return tryBrightnessContrastOwnedImpl!T(src, roi, affected, settings,
        mask, true, maxResultBytes, published);
}

bool valid(BrightnessContrast settings)
@safe pure nothrow @nogc
{
    return isFinite(settings.brightness) && isFinite(settings.contrast) &&
        settings.brightness >= -1.0 && settings.brightness <= 1.0 &&
        settings.contrast >= -1.0;
}

BrightnessContrastError tryMapNormalized(
    double input,
    BrightnessContrast settings,
    out double output)
@safe pure nothrow @nogc
{
    if (!valid(settings))
        return BrightnessContrastError.invalidParameters;
    if (!isFinite(input))
        return BrightnessContrastError.nonFiniteSample;

    double mapped = (input - 0.5) * (1.0 + settings.contrast) +
        0.5 + settings.brightness;
    if (mapped < 0.0)
        mapped = 0.0;
    else if (mapped > 1.0)
        mapped = 1.0;
    output = mapped;
    return BrightnessContrastError.none;
}

unittest
{
    double output;
    assert(tryMapNormalized(0.25, BrightnessContrast(0, 0), output) ==
        BrightnessContrastError.none);
    assert(output == 0.25);
    assert(tryMapNormalized(0.25, BrightnessContrast(0.1, 0), output) ==
        BrightnessContrastError.none);
    assert(output == 0.35);
    assert(tryMapNormalized(0.25, BrightnessContrast(0, 1), output) ==
        BrightnessContrastError.none);
    assert(output == 0.0);
    assert(tryMapNormalized(double.nan, BrightnessContrast(0, 0), output) ==
        BrightnessContrastError.nonFiniteSample);
    assert(!valid(BrightnessContrast(double.nan, 0)));
}
