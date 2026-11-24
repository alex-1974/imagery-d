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

/++
 Adjust normalized brightness and contrast around midpoint 0.5. Use BrightnessContrast(0,0) for identity. `.init` contains NaNs and is invalid; no transfer conversion is implied.
+/
struct BrightnessContrast
{
    /++
     Additive shift in [-1,1], finite; zero leaves brightness unchanged.
    +/
    double brightness;
    /++
     Finite contrast adjustment at least -1; multiplier is 1+contrast, so zero is identity.
    +/
    double contrast;
}

/// Construct identity settings explicitly and handle a nonfinite input.
@safe unittest
{
    import std.math : isNaN;
    auto identity=BrightnessContrast(0,0);
    assert(valid(identity) && !valid(BrightnessContrast.init));
    double output;
    assert(tryMapNormalized(0.25,identity,output)==BrightnessContrastError.none && output==0.25);
    assert(tryMapNormalized(double.nan,identity,output)==BrightnessContrastError.nonFiniteSample);
    assert(isNaN(output));
}


/// Adjust selected color channels while preserving a separate fourth channel.
@system unittest
{
    import std.math : signbit;
    auto memory = cast(float*)malloc(4 * float.sizeof);
    assert(memory !is null);
    memory[0] = 0.25f; memory[1] = 0.75f; memory[2] = 0.5f; memory[3] = -0.0f;
    OwnedByteResource owner;
    assert(tryAdoptMallocResource(memory, 4 * float.sizeof, owner));
    PlaneByteLayout[4] layouts;
    foreach (c; 0 .. 4) layouts[c] = PlaneByteLayout(c * float.sizeof,
        4 * float.sizeof, 4 * float.sizeof);
    RasterLease!float source, result;
    assert(tryImportOwnedRaster!float(owner, layouts[], Region2D(0, 0, 1, 1), source).ok);
    bool[4] affected = [true, false, true, false];
    assert(tryBrightnessContrastOwned(source.view, Region2D(0, 0, 1, 1), affected[],
        BrightnessContrast(0.125, 0), 16, result) == BrightnessContrastError.none);
    float value;
    assert(result.view.trySample(0, 0, 0, value) && value == 0.375f);
    assert(result.view.trySample(1, 0, 0, value) && value == 0.75f);
    assert(result.view.trySample(3, 0, 0, value) && value == 0 && signbit(value));
}

/++
 Report mapping or raster-materialization status. `.init` is none; callers must use the returned status, not infer that an operation ran.
+/
enum BrightnessContrastError : ubyte
{
    /++ The operation completed successfully. +/
    none,
    /++ Parameters or materialization prerequisites are invalid. +/
    invalidParameters,
    /++ A numeric sample is nonfinite or outside the required domain. +/
    nonFiniteSample,
    /++ Source shape, identity or sample descriptor is invalid. +/
    invalidSource,
    /++ The requested pixel rectangle is empty or outside the source extent. +/
    invalidRegion,
    /++ The channel-selection length or selection is invalid. +/
    invalidChannelSelection,
    /++ The validity/mask extent or plane count is invalid. +/
    invalidMask,
    /++ A raster sample could not be read or written. +/
    sampleFailure,
    /++ Storage allocation or owned-raster construction failed. +/
    allocationFailure,
    /++ Required retained output storage exceeds the caller’s budget. +/
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
            float mapped;
            static if (is(T == float)) mapped = raw;
            else mapped = cast(float)normalized(raw);
            if (affected[channel] && weight != 0)
            {
                const original = normalized(raw);
                if (isFinite(original))
                {
                    double adjusted;
                    auto status = tryMapNormalized(original, settings, adjusted);
                    if (status != BrightnessContrastError.none) return status;
                    mapped = cast(float)(original + strength * (adjusted - original));
                }
            }
            if (!dst.trySetSample(channel, x - roi.x, y - roi.y,
                mapped)) return BrightnessContrastError.sampleFailure;
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

/++
 Create an independent float32 raster with brightness/contrast applied.

   Unsigned samples are normalized by their type maximum. Float samples are
   used as supplied. Nonfinite float samples pass through. An optional
   ubyte mask blends original and mapped samples with weight mask/255.
   Only affected channels are mapped. Other channels retain their normalized
   values; float samples are copied without arithmetic, including NaN, infinity
   and signed zero. A zero mask weight also copies the original sample directly.
   No alpha or NoData semantics are inferred.
   The output starts at (0,0) and has the requested region dimensions.

 Params:
  src = Borrowed source raster; kept only for this call.
  roi = Nonempty source-pixel rectangle fully inside src.
  affected = One flag per source plane; true maps the channel and false copies its normalized value.
  settings = Finite brightness/contrast settings.
  maxResultBytes = Limit on requested output pixel bytes, excluding metadata.
  published = Replaced only on success; unchanged on a reported failure.

 Returns:
 none on success, otherwise the named validation, budget, allocation or sample error.

 Throws:
 Allocation exceptions from metadata arrays may propagate; this API is not nothrow.
+/
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

/++
 Create an independent float32 raster with brightness/contrast applied.

   Unsigned samples are normalized by their type maximum. Float samples are
   used as supplied. Nonfinite float samples pass through. An optional
   ubyte mask blends original and mapped samples with weight mask/255.
   Only affected channels are mapped. Unselected channels and zero-weight mask
   samples retain their original normalized values. Float NaN, infinities and
   signed zero pass through without arithmetic. No alpha or NoData semantics are inferred.
   The output starts at (0,0) and has the requested region dimensions.

 Params:
  src = Borrowed source raster; kept only for this call.
  roi = Nonempty source-pixel rectangle fully inside src.
  affected = One flag per source plane; true maps and false preserves the normalized sample.
  settings = Finite brightness/contrast settings.
  mask = Byte mask in the source grid; nonzero includes a sample, or mask/255 is mapping strength as described above.
  maxResultBytes = Limit on requested output pixel bytes, excluding metadata.
  published = Replaced only on success; unchanged on a reported failure.

 Returns:
 none on success, otherwise the named validation, budget, allocation or sample error.

 Throws:
 Allocation exceptions from metadata arrays may propagate; this API is not nothrow.
+/
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

/++
 Check whether brightness/contrast settings lie in the supported domain.

 Params:
  settings = Finite brightness in [-1,1] and finite contrast at least -1.

 Returns:
 True for valid settings.
+/
bool valid(BrightnessContrast settings)
@safe pure nothrow @nogc
{
    return isFinite(settings.brightness) && isFinite(settings.contrast) &&
        settings.brightness >= -1.0 && settings.brightness <= 1.0 &&
        settings.contrast >= -1.0;
}

/++
 Map a normalized sample through midpoint contrast and additive brightness.

   The result is clipped to [0,1]. This function does not convert color space.

 Params:
  input = Finite scalar input; values outside [0,1] are mapped and clipped.
  settings = Brightness and contrast settings; use BrightnessContrast(0,0) for identity.
  output = Receives the mapped value. As an out parameter it is NaN on early failure.

 Returns:
 none on success, invalidParameters for invalid settings, or nonFiniteSample for nonfinite input.
+/
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

/++
 Preferred consumer spelling of tryBrightnessContrastOwned; shares its input, ownership and failure contract.
+/
alias brightnessContrast = tryBrightnessContrastOwned;
