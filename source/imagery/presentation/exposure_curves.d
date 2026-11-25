/++
Adjust exposure or map samples through a piecewise-linear tone curve. Start
with `exposure` or `curves` for scalar values and the corresponding
owned-raster operations for image regions. Supply samples in the intended
numeric domain; no color transfer is inferred.
+/
module imagery.presentation.exposure_curves;

import std.math : isFinite, pow;
import core.stdc.stdlib : malloc, free;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

/++
 Scale normalized samples by 2 raised to stops, then clip to [0,1]. Exposure(0) is the identity scale; `.init` has NaN stops and is invalid.
+/
struct Exposure
{
    /++
     Finite exposure adjustment in stops, in [-32,32].
    +/
    double stops;
}

/// Apply one exposure stop, then a normalized piecewise-linear curve.
@safe unittest
{
    double value;
    assert(tryExposure(0.25,Exposure(1),value) && value==0.5);
    CurvePoint[2] identity=[CurvePoint(0,0),CurvePoint(1,1)];
    assert(tryCurve(value,identity[],value)==ExposureCurvesError.none && value==0.5);
    assert(!tryExposure(0.25,Exposure.init,value));
}


/++
 Specify one normalized control point for piecewise-linear mapping. `.init` has NaN coordinates and is invalid; a curve needs at least two strictly increasing x coordinates.
+/
struct CurvePoint
{
    /++
     Input coordinate in [0,1]; strictly increases across the curve.
    +/
    double x;
    /++
     Output coordinate in [0,1].
    +/
    double y;
}

/++
 Report curve or owned-image mapping status. `.init` is none; use the returned status to determine success.
+/
enum ExposureCurvesError : ubyte {
    /++ The operation completed successfully. +/
    none,
    /++ Parameters or materialization prerequisites are invalid. +/
    invalidParameters,
    /++ A numeric sample is nonfinite or outside the required domain. +/
    nonFiniteSample }

private bool exposureOwnedBytes(size_t bytes, ref OwnedByteResource owner)
@trusted nothrow @nogc
{
    auto p = malloc(bytes);
    if (p is null) return false;
    if (!tryAdoptMallocResource(p, bytes, owner)) { free(p); return false; }
    return true;
}

/++
 Create an owned float32 raster with an exposure adjustment.

   Unsigned inputs are normalized by their type maximum. Float samples retain
   their numeric domain. Only affected planes are mapped; other planes retain normalized samples. No color transfer is inferred.

 Params:
  source = Borrowed raster, read only during the call.
  roi = Nonempty source-pixel rectangle fully inside src.
  affected = One flag per plane; false keeps that plane unchanged.
  settings = Finite exposure stops in [-32,32].
  maxResultBytes = Maximum requested output pixel bytes, excluding metadata.
  published = Receives the independent raster on success and is unchanged on reported failure.

 Returns:
 none on success, invalidParameters for invalid requests/materialization failures, or nonFiniteSample for nonfinite samples.

 Throws:
 Allocation exceptions from metadata arrays may propagate.
+/
ExposureCurvesError tryExposureOwned(T)(scope RasterView!T source, Region2D roi,
    scope const(bool)[] affected, Exposure settings, size_t maxResultBytes,
    ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    if (source.planeCount == 0 || source.width == 0 || source.height == 0)
        return ExposureCurvesError.invalidParameters;
    if (roi.width == 0 || roi.height == 0 || roi.x > source.width || roi.y > source.height ||
        roi.width > source.width - roi.x || roi.height > source.height - roi.y ||
        affected.length != source.planeCount || !isFinite(settings.stops) || settings.stops < -32 || settings.stops > 32)
        return ExposureCurvesError.invalidParameters;
    const bytes = roi.width * roi.height * source.planeCount * float.sizeof;
    if (bytes > maxResultBytes) return ExposureCurvesError.invalidParameters;
    OwnedByteResource owner;
    if (!exposureOwnedBytes(bytes, owner)) return ExposureCurvesError.invalidParameters;
    auto layouts = new PlaneByteLayout[](source.planeCount);
    foreach (c; 0 .. source.planeCount) layouts[c] = PlaneByteLayout(c * float.sizeof,
        cast(ptrdiff_t)(roi.width * source.planeCount * float.sizeof), cast(ptrdiff_t)(source.planeCount * float.sizeof));
    RasterLease!float result;
    if (!tryImportOwnedRaster!float(owner, layouts[], Region2D(0, 0, roi.width, roi.height), result).ok)
        return ExposureCurvesError.invalidParameters;
    bool writable;
    scope auto output = result.tryWritableView(writable);
    if (!writable) return ExposureCurvesError.invalidParameters;
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    foreach (c; 0 .. source.planeCount)
    {
        T raw;
        if (!source.trySample(c, x, y, raw)) return ExposureCurvesError.nonFiniteSample;
        double value;
        static if (is(T == ubyte)) value = cast(double)raw / 255.0;
        else static if (is(T == ushort)) value = cast(double)raw / 65535.0;
        else value = raw;
        if (affected[c] && !tryExposure(value, settings, value)) return ExposureCurvesError.nonFiniteSample;
        if (!output.trySetSample(c, x - roi.x, y - roi.y, cast(float)value)) return ExposureCurvesError.nonFiniteSample;
    }
    published = result;
    return ExposureCurvesError.none;
}

/++
 Create an owned float32 raster with an exposure adjustment.

   Unsigned inputs are normalized by their type maximum. Float samples retain
   their numeric domain. Only affected planes are mapped; other planes retain normalized samples. No color transfer is inferred.

 Params:
  source = Borrowed raster, read only during the call.
  roi = Nonempty source-pixel rectangle fully inside src.
  affected = One flag per plane; false keeps that plane unchanged.
  settings = Finite exposure stops in [-32,32].
  mask = Byte mask in the source grid; nonzero includes a sample, or mask/255 is mapping strength as described above.
  maxResultBytes = Maximum requested output pixel bytes, excluding metadata.
  published = Receives the independent raster on success and is unchanged on reported failure.

 Returns:
 none on success, invalidParameters for invalid requests/materialization failures, or nonFiniteSample for nonfinite samples.

 Throws:
 Allocation exceptions from metadata arrays may propagate.
+/
ExposureCurvesError tryExposureOwned(T)(scope RasterView!T source, Region2D roi,
    scope const(bool)[] affected, Exposure settings, scope RasterView!ubyte mask,
    size_t maxResultBytes, ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    if (mask.planeCount != 1 || mask.width != source.width || mask.height != source.height)
        return ExposureCurvesError.invalidParameters;
    RasterLease!float adjusted;
    auto status = tryExposureOwned!T(source, roi, affected, settings, maxResultBytes, adjusted);
    if (status != ExposureCurvesError.none) return status;
    bool writable;
    scope auto output = adjusted.tryWritableView(writable);
    if (!writable) return ExposureCurvesError.invalidParameters;
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        ubyte weight;
        if (!mask.trySample(0, x, y, weight)) return ExposureCurvesError.nonFiniteSample;
        const strength = cast(double)weight / 255.0;
        foreach (c; 0 .. source.planeCount)
        {
            T raw; float mapped;
            if (!source.trySample(c, x, y, raw) || !output.trySample(c, x - roi.x, y - roi.y, mapped))
                return ExposureCurvesError.nonFiniteSample;
            double original;
            static if (is(T == ubyte)) original = cast(double)raw / 255.0;
            else static if (is(T == ushort)) original = cast(double)raw / 65535.0;
            else original = raw;
            if (affected[c]) mapped = cast(float)(original + strength * (mapped - original));
            if (!output.trySetSample(c, x - roi.x, y - roi.y, mapped)) return ExposureCurvesError.nonFiniteSample;
        }
    }
    published = adjusted;
    return ExposureCurvesError.none;
}

/++
 Create an owned float32 raster using one piecewise-linear curve on selected planes.

   Unsigned input is normalized by its type maximum. No color transfer or
   alpha handling is inferred. Output coordinates begin at (0,0).

 Params:
  source = Borrowed source raster.
  roi = Nonempty contained source-pixel rectangle.
  affected = One flag per plane; false keeps that plane unchanged.
  points = At least two normalized control points with strictly increasing x, borrowed during this call.
  maxResultBytes = Maximum requested output pixel bytes, excluding metadata.
  published = Replaced on success; unchanged on reported failure.

 Returns:
 none on success or a named input/mapping failure.

 Throws:
 Allocation exceptions from metadata arrays may propagate.
+/
ExposureCurvesError tryCurvesOwned(T)(scope RasterView!T source, Region2D roi,
    scope const(bool)[] affected, scope const(CurvePoint)[] points,
    size_t maxResultBytes, ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    if (source.planeCount == 0 || source.width == 0 || source.height == 0 || points.length < 2)
        return ExposureCurvesError.invalidParameters;
    if (roi.width == 0 || roi.height == 0 || roi.x > source.width || roi.y > source.height ||
        roi.width > source.width - roi.x || roi.height > source.height - roi.y || affected.length != source.planeCount)
        return ExposureCurvesError.invalidParameters;
    const bytes = roi.width * roi.height * source.planeCount * float.sizeof;
    if (bytes > maxResultBytes) return ExposureCurvesError.invalidParameters;
    OwnedByteResource owner;
    if (!exposureOwnedBytes(bytes, owner)) return ExposureCurvesError.invalidParameters;
    auto layouts = new PlaneByteLayout[](source.planeCount);
    foreach (c; 0 .. source.planeCount) layouts[c] = PlaneByteLayout(c * float.sizeof,
        cast(ptrdiff_t)(roi.width * source.planeCount * float.sizeof), cast(ptrdiff_t)(source.planeCount * float.sizeof));
    RasterLease!float result;
    if (!tryImportOwnedRaster!float(owner, layouts[], Region2D(0, 0, roi.width, roi.height), result).ok)
        return ExposureCurvesError.invalidParameters;
    bool writable;
    scope auto output = result.tryWritableView(writable);
    if (!writable) return ExposureCurvesError.invalidParameters;
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    foreach (c; 0 .. source.planeCount)
    {
        T raw;
        if (!source.trySample(c, x, y, raw)) return ExposureCurvesError.nonFiniteSample;
        double value;
        static if (is(T == ubyte)) value = cast(double)raw / 255.0;
        else static if (is(T == ushort)) value = cast(double)raw / 65535.0;
        else value = raw;
        if (affected[c] && tryCurve(value, points, value) != ExposureCurvesError.none)
            return ExposureCurvesError.invalidParameters;
        if (!output.trySetSample(c, x - roi.x, y - roi.y, cast(float)value)) return ExposureCurvesError.nonFiniteSample;
    }
    published = result;
    return ExposureCurvesError.none;
}

/++
 Create an owned float32 raster using one piecewise-linear curve on selected planes.

   Unsigned input is normalized by its type maximum. No color transfer or
   alpha handling is inferred. Output coordinates begin at (0,0).

 Params:
  source = Borrowed source raster.
  roi = Nonempty contained source-pixel rectangle.
  affected = One flag per plane; false keeps that plane unchanged.
  points = At least two normalized control points with strictly increasing x, borrowed during this call.
  mask = Byte mask in the source grid; nonzero includes a sample, or mask/255 is mapping strength as described above.
  maxResultBytes = Maximum requested output pixel bytes, excluding metadata.
  published = Replaced on success; unchanged on reported failure.

 Returns:
 none on success or a named input/mapping failure.

 Throws:
 Allocation exceptions from metadata arrays may propagate.
+/
ExposureCurvesError tryCurvesOwned(T)(scope RasterView!T source, Region2D roi,
    scope const(bool)[] affected, scope const(CurvePoint)[] points,
    scope RasterView!ubyte mask, size_t maxResultBytes,
    ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    if (mask.planeCount != 1 || mask.width != source.width || mask.height != source.height)
        return ExposureCurvesError.invalidParameters;
    RasterLease!float adjusted;
    auto status = tryCurvesOwned!T(source, roi, affected, points, maxResultBytes, adjusted);
    if (status != ExposureCurvesError.none) return status;
    bool writable;
    scope auto output = adjusted.tryWritableView(writable);
    if (!writable) return ExposureCurvesError.invalidParameters;
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        ubyte weight;
        if (!mask.trySample(0, x, y, weight)) return ExposureCurvesError.nonFiniteSample;
        const strength = cast(double)weight / 255.0;
        foreach (c; 0 .. source.planeCount)
        {
            T raw; float mapped;
            if (!source.trySample(c, x, y, raw) || !output.trySample(c, x - roi.x, y - roi.y, mapped))
                return ExposureCurvesError.nonFiniteSample;
            double original;
            static if (is(T == ubyte)) original = cast(double)raw / 255.0;
            else static if (is(T == ushort)) original = cast(double)raw / 65535.0;
            else original = raw;
            if (affected[c]) mapped = cast(float)(original + strength * (mapped - original));
            if (!output.trySetSample(c, x - roi.x, y - roi.y, mapped)) return ExposureCurvesError.nonFiniteSample;
        }
    }
    published = adjusted;
    return ExposureCurvesError.none;
}

/++
 Scale one finite sample by an exposure adjustment and clip to [0,1].

 Params:
  input = Finite scalar input.
  settings = Finite stop adjustment in [-32,32].
  output = Receives the clipped sample; reset to NaN on entry and on early failure.

 Returns:
 True on success, false for invalid stops or nonfinite input.
+/
bool tryExposure(double input, Exposure settings, out double output)
@safe pure nothrow @nogc
{
    if (!isFinite(settings.stops) || settings.stops < -32.0 || settings.stops > 32.0)
        return false;
    if (!isFinite(input)) return false;
    output = input * pow(2.0, settings.stops);
    if (output < 0.0) output = 0.0;
    if (output > 1.0) output = 1.0;
    return true;
}

/++
 Map one sample through a piecewise-linear normalized curve.

   Inputs beyond the first/last x use the respective endpoint y value.

 Params:
  input = Finite scalar to map.
  points = At least two finite points in [0,1] squared with strictly increasing x; borrowed only during the call.
  output = Receives the mapped sample; reset to NaN on entry and on early failure.

 Returns:
 none on success or invalidParameters for invalid input/control points.
+/
ExposureCurvesError tryCurve(double input, scope const(CurvePoint)[] points,
    out double output)
@safe pure nothrow @nogc
{
    if (!isFinite(input) || points.length < 2) return ExposureCurvesError.invalidParameters;
    foreach (i, point; points)
    {
        if (!isFinite(point.x) || !isFinite(point.y) || point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1 ||
            (i != 0 && point.x <= points[i - 1].x)) return ExposureCurvesError.invalidParameters;
    }
    if (input <= points[0].x) { output = points[0].y; return ExposureCurvesError.none; }
    foreach (i; 1 .. points.length)
        if (input <= points[i].x)
        {
            const span = points[i].x - points[i - 1].x;
            const t = (input - points[i - 1].x) / span;
            output = points[i - 1].y + t * (points[i].y - points[i - 1].y);
            return ExposureCurvesError.none;
        }
    output = points[$ - 1].y;
    return ExposureCurvesError.none;
}

unittest
{
    double value;
    assert(tryExposure(0.25, Exposure(1), value) && value == 0.5);
    auto identity = [CurvePoint(0, 0), CurvePoint(1, 1)];
    assert(tryCurve(0.25, identity, value) == ExposureCurvesError.none && value == 0.25);
    auto lift = [CurvePoint(0, 0.1), CurvePoint(1, 1)];
    assert(tryCurve(0, lift, value) == ExposureCurvesError.none && value == 0.1);
}

/++
 Preferred spelling of tryExposure; maps one scalar with the same out-parameter and boolean status contract.
+/
alias exposure = tryExposure;
/++
 Preferred spelling of tryCurve; maps one scalar with the same control-point and output contract.
+/
alias curves = tryCurve;
