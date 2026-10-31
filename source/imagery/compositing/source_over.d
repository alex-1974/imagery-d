/++ Explicit alpha source-over compositing contract. +/
module imagery.compositing.source_over;

import core.stdc.stdlib : malloc, free;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import std.math : isFinite;

enum AlphaAssociation : ubyte { straight, premultiplied }
enum BlendMode : ubyte { normal, multiply, screen, darken, lighten }
enum SourceOverError : ubyte { none, invalidParameters, nonFiniteSample }

struct RgbaNormalized
{
    double r, g, b, a;
}

double blendChannel(double source, double destination, BlendMode mode)
@safe pure nothrow @nogc
{
    final switch (mode)
    {
        case BlendMode.normal: return source;
        case BlendMode.multiply: return source * destination;
        case BlendMode.screen: return 1.0 - (1.0 - source) * (1.0 - destination);
        case BlendMode.darken: return source < destination ? source : destination;
        case BlendMode.lighten: return source > destination ? source : destination;
    }
}

private bool inUnit(double value) @safe pure nothrow @nogc
{
    return isFinite(value) && value >= 0.0 && value <= 1.0;
}

/++ Composite `source` over `destination` without implicit association changes. +/
SourceOverError trySourceOver(
    RgbaNormalized source,
    RgbaNormalized destination,
    AlphaAssociation association,
    out RgbaNormalized result)
@safe pure nothrow @nogc
{
    if (!inUnit(source.a) || !inUnit(destination.a))
        return SourceOverError.invalidParameters;
    if (!inUnit(source.r) || !inUnit(source.g) || !inUnit(source.b) ||
        !inUnit(destination.r) || !inUnit(destination.g) || !inUnit(destination.b))
        return SourceOverError.nonFiniteSample;
    const inverse = 1.0 - source.a;
    const outA = source.a + destination.a * inverse;
    if (association == AlphaAssociation.premultiplied)
    {
        result = RgbaNormalized(
            source.r + destination.r * inverse,
            source.g + destination.g * inverse,
            source.b + destination.b * inverse, outA);
    }
    else
    {
        if (outA == 0.0) { result = RgbaNormalized(0, 0, 0, 0); return SourceOverError.none; }
        result = RgbaNormalized(
            (source.r * source.a + destination.r * destination.a * inverse) / outA,
            (source.g * source.a + destination.g * destination.a * inverse) / outA,
            (source.b * source.a + destination.b * destination.a * inverse) / outA, outA);
    }
    return SourceOverError.none;
}

SourceOverError tryBlendSourceOver(
    RgbaNormalized source, RgbaNormalized destination,
    AlphaAssociation association, BlendMode mode,
    out RgbaNormalized result)
@safe pure nothrow @nogc
{
    if (mode == BlendMode.normal)
        return trySourceOver(source, destination, association, result);
    RgbaNormalized blended = source;
    blended.r = blendChannel(source.r, destination.r, mode);
    blended.g = blendChannel(source.g, destination.g, mode);
    blended.b = blendChannel(source.b, destination.b, mode);
    return trySourceOver(blended, destination, association, result);
}

private bool ownedBytes(size_t bytes, ref OwnedByteResource owner)
@trusted nothrow @nogc
{
    auto p = malloc(bytes);
    if (p is null) return false;
    if (!tryAdoptMallocResource(p, bytes, owner)) { free(p); return false; }
    return true;
}

SourceOverError tryRgbaSourceOverOwned(
    scope RasterView!ubyte source,
    scope RasterView!ubyte destination,
    Region2D roi,
    AlphaAssociation association,
    size_t maxResultBytes,
    ref RasterLease!ubyte published)
@safe
{
    if (source.planeCount != 4 || destination.planeCount != 4 ||
        source.width == 0 || source.height == 0 ||
        destination.width != source.width || destination.height != source.height)
        return SourceOverError.invalidParameters;
    if (roi.width == 0 || roi.height == 0 || roi.x > source.width ||
        roi.y > source.height || roi.width > source.width - roi.x ||
        roi.height > source.height - roi.y)
        return SourceOverError.invalidParameters;
    if (roi.width > size_t.max / roi.height ||
        roi.width * roi.height > size_t.max / 4)
        return SourceOverError.invalidParameters;
    const bytes = roi.width * roi.height * 4;
    if (bytes > maxResultBytes) return SourceOverError.invalidParameters;
    OwnedByteResource owner;
    if (!ownedBytes(bytes, owner)) return SourceOverError.invalidParameters;
    PlaneByteLayout[4] layouts;
    foreach (c; 0 .. 4) layouts[c] = PlaneByteLayout(c,
        cast(ptrdiff_t)(roi.width * 4), 4);
    RasterLease!ubyte temporary;
    if (!tryImportOwnedRaster!ubyte(owner, layouts[],
        Region2D(0, 0, roi.width, roi.height), temporary).ok)
        return SourceOverError.invalidParameters;
    bool writable;
    scope auto output = temporary.tryWritableView(writable);
    if (!writable) return SourceOverError.invalidParameters;
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        RgbaNormalized s, d, composited;
        ubyte sr, sg, sb, sa, dr, dg, db, da;
        if (!source.trySample(0, x, y, sr) || !source.trySample(1, x, y, sg) ||
            !source.trySample(2, x, y, sb) || !source.trySample(3, x, y, sa) ||
            !destination.trySample(0, x, y, dr) || !destination.trySample(1, x, y, dg) ||
            !destination.trySample(2, x, y, db) || !destination.trySample(3, x, y, da))
            return SourceOverError.nonFiniteSample;
        s = RgbaNormalized(sr / 255.0, sg / 255.0, sb / 255.0, sa / 255.0);
        d = RgbaNormalized(dr / 255.0, dg / 255.0, db / 255.0, da / 255.0);
        auto status = trySourceOver(s, d, association, composited);
        if (status != SourceOverError.none) return status;
        if (!output.trySetSample(0, x - roi.x, y - roi.y, cast(ubyte)(composited.r * 255.0 + 0.5)) ||
            !output.trySetSample(1, x - roi.x, y - roi.y, cast(ubyte)(composited.g * 255.0 + 0.5)) ||
            !output.trySetSample(2, x - roi.x, y - roi.y, cast(ubyte)(composited.b * 255.0 + 0.5)) ||
            !output.trySetSample(3, x - roi.x, y - roi.y, cast(ubyte)(composited.a * 255.0 + 0.5)))
            return SourceOverError.nonFiniteSample;
    }
    published = temporary;
    return SourceOverError.none;
}

unittest
{
    RgbaNormalized result;
    assert(trySourceOver(RgbaNormalized(1, 0, 0, 1),
        RgbaNormalized(0, 0, 1, 1), AlphaAssociation.straight, result) == SourceOverError.none);
    assert(result.r == 1 && result.b == 0 && result.a == 1);
    assert(trySourceOver(RgbaNormalized(1, 1, 1, 0),
        RgbaNormalized(0.2, 0.3, 0.4, 0), AlphaAssociation.straight, result) == SourceOverError.none);
    assert(result.a == 0);
    assert(blendChannel(0.25, 0.5, BlendMode.multiply) == 0.125);
    assert(blendChannel(0.25, 0.5, BlendMode.screen) == 0.625);
    assert(blendChannel(0.25, 0.5, BlendMode.darken) == 0.25);
    assert(blendChannel(0.25, 0.5, BlendMode.lighten) == 0.5);
}
