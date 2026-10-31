module imagery.presentation.exposure_curves;

import std.math : isFinite, pow;
import core.stdc.stdlib : malloc, free;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

struct Exposure
{
    double stops;
}

struct CurvePoint
{
    double x;
    double y;
}

enum ExposureCurvesError : ubyte { none, invalidParameters, nonFiniteSample }

private bool exposureOwnedBytes(size_t bytes, ref OwnedByteResource owner)
@trusted nothrow @nogc
{
    auto p = malloc(bytes);
    if (p is null) return false;
    if (!tryAdoptMallocResource(p, bytes, owner)) { free(p); return false; }
    return true;
}

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
