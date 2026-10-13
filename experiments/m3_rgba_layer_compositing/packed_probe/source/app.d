module app;

// Research ONLY: compare packed POD RGBA zip against independent 4-plane
// imagery adapter, and exercise raster-d's prewrite alias rejection.
// Fixed opacity 0.37 is a compile-time constant because zipTransformInto
// currently takes a compile-time transform alias with no runtime context.
import core.stdc.stdlib : malloc;
import core.memory : GC;
import std.datetime.stopwatch : StopWatch;
import std.conv : to;
import std.algorithm.searching : startsWith;
import std.stdio : writeln;

import color :
    Alpha, SRgbd, LinearSRgbd, SRgba8,
    premultiply, sourceOver, unpremultiply,
    toLinear, toSRgb, tryToSRgba8;
import imagery.presentation.composite :
    DecodedRgbaLayer, RgbaEncoding, RgbaAssociation,
    RgbaCompositeError, tryCompositeRgbaSourceOver;
import raster :
    OwnedByteResource, RasterLease,
    PlaneByteLayout, Region2D,
    RasterZipTransformError, isRasterSampleType, zipTransformInto,
    tryAdoptMallocResource, tryImportOwnedRaster;

static assert(isRasterSampleType!SRgba8);
static assert(SRgba8.sizeof == 4);

private enum double opacity = 0.37;

private void require(bool valid, string reason)
{
    if (!valid) throw new Exception("packed RGBA probe: " ~ reason);
}

// No unchecked unpacking, no copied sRGB/Porter-Duff formulas: color-d owns
// the math. Error reporting is deliberately incomplete in this *probe*;
// a checked quantization failure yields sentinel SRgba8.init, caught by
// exhaustive differential output checks. Do not promote this callback as-is.
private SRgba8 fixedSourceOver(SRgba8 fg, SRgba8 bg)
@safe pure nothrow @nogc
{
    const foregroundStraight = fg.toAlphaSRgb!double();
    const backgroundStraight = bg.toAlphaSRgb!double();
    const foreground = premultiply(Alpha!LinearSRgbd(
        foregroundStraight.color.toLinear(),
        foregroundStraight.alpha));
    const background = premultiply(Alpha!LinearSRgbd(
        backgroundStraight.color.toLinear(),
        backgroundStraight.alpha));
    const adjusted = typeof(foreground)(
        LinearSRgbd(
            foreground.color.r * opacity,
            foreground.color.g * opacity,
            foreground.color.b * opacity),
        foreground.alpha * opacity);
    const mixed = sourceOver(adjusted, background);
    const straight = unpremultiply(mixed);
    SRgba8 stored;
    if (!tryToSRgba8(
        Alpha!SRgbd(straight.color.toSRgb(), straight.alpha),
        stored))
        return SRgba8.init;
    return stored;
}

private SRgba8 fixture(size_t layer, size_t x, size_t y)
@safe pure nothrow @nogc
{
    const uint alpha = ((x + y + layer) % 7 == 0) ? 0 :
        ((x + 2 * y + layer) % 3 == 0 ? 128 : 255);
    return SRgba8(
        cast(ubyte)((37 * x + 17 * y + 71 * layer + 13) % 256),
        cast(ubyte)((11 * x + 41 * y + 43 * layer + 29) % 256),
        cast(ubyte)((19 * x + 23 * y + 97 * layer + 53) % 256),
        cast(ubyte)alpha);
}

private RasterLease!T makeLease(T)(
    size_t w, size_t h, bool packed, size_t layer, bool populate
)
{
    const size_t bytes = w * h * 4;
    auto memory = cast(ubyte*)malloc(bytes);
    require(memory !is null, "malloc pixel backing");
    OwnedByteResource owned;
    require(tryAdoptMallocResource(memory, bytes, owned),
        "adopt malloc resource");

    RasterLease!T result;
    if (packed)
    {
        const PlaneByteLayout[1] planes = [
            PlaneByteLayout(0, cast(ptrdiff_t)(w * 4), 4)
        ];
        require(tryImportOwnedRaster!T(
            owned, planes[], Region2D(0, 0, w, h), result).ok,
            "import packed POD RGBA lease");
    }
    else
    {
        PlaneByteLayout[4] planes;
        foreach (c; 0 .. 4)
            planes[c] = PlaneByteLayout(
                c, cast(ptrdiff_t)(w * 4), 4);
        require(tryImportOwnedRaster!T(
            owned, planes[], Region2D(0, 0, w, h), result).ok,
            "import four-plane RGBA byte lease");
    }
    if (populate)
    {
        bool ok;
        scope auto view = result.tryWritableView(ok);
        require(ok, "create write borrow");
        foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            const px = fixture(layer, x, y);
            static if (is(T == SRgba8))
                require(view.trySetSample(0, x, y, px),
                    "populate packed pixel");
            else
                require(
                    view.trySetSample(0, x, y, px.r) &&
                    view.trySetSample(1, x, y, px.g) &&
                    view.trySetSample(2, x, y, px.b) &&
                    view.trySetSample(3, x, y, px.a),
                    "populate four-plane pixel");
        }
    }
    return result;
}

private bool tryPacked(
    ref RasterLease!SRgba8 top,
    ref RasterLease!SRgba8 bottom,
    ref RasterLease!SRgba8 target
)
{
    RasterZipTransformError error;
    scope auto left = top.view();
    scope auto right = bottom.view();
    bool ok;
    scope auto output = target.tryWritableView(ok);
    if (!ok) return false;
    return left.zipTransformInto!fixedSourceOver(
        0, right, 0, output, 0, error)
        && error == RasterZipTransformError.none;
}

private bool tryFourPlane(
    ref RasterLease!ubyte top,
    ref RasterLease!ubyte bottom,
    ref RasterLease!ubyte target,
    size_t w, size_t h
)
{
    bool ok;
    scope auto output = target.tryWritableView(ok);
    if (!ok) return false;
    const upper = DecodedRgbaLayer(top.view(),
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    const lower = DecodedRgbaLayer(bottom.view(),
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    return tryCompositeRgbaSourceOver(upper, lower,
        Region2D(0, 0, w, h), opacity, output)
        == RgbaCompositeError.none;
}

private size_t compare(
    ref RasterLease!SRgba8 packed,
    ref RasterLease!ubyte regular, size_t w, size_t h
)
{
    scope auto a = packed.view();
    scope auto b = regular.view();
    size_t differences = 0;
    foreach (y; 0 .. h)
    foreach (x; 0 .. w)
    {
        SRgba8 pixel;
        require(a.trySample(0, x, y, pixel), "read packed output");
        ubyte[4] channels;
        foreach (c; 0 .. 4)
            require(b.trySample(c, x, y, channels[c]),
                "read four-plane output");
        if (pixel.r != channels[0] ||
            pixel.g != channels[1] ||
            pixel.b != channels[2] ||
            pixel.a != channels[3])
            ++differences;
    }
    return differences;
}

private void verifyOverlapRejected(
    ref RasterLease!SRgba8 upper, ref RasterLease!SRgba8 bottom,
    size_t w, size_t h
)
{
    scope auto before = upper.view();
    // Derive a deterministic checksum before attempting illegal in-place use.
    ulong hashBefore = 0;
    foreach (y; 0 .. h)
    foreach (x; 0 .. w)
    {
        SRgba8 pixel;
        require(before.trySample(0, x, y, pixel), "read pre-alias source");
        hashBefore += cast(ulong)pixel.r + pixel.g + pixel.b + pixel.a;
    }

    bool ok;
    scope auto destination = upper.tryWritableView(ok);
    require(ok, "borrow overlapping writable destination");
    RasterZipTransformError failure;
    require(!before.zipTransformInto!fixedSourceOver(
        0, bottom.view(), 0, destination, 0, failure),
        "reject actual source/output overlap");
    require(failure == RasterZipTransformError.leftDestinationOverlap,
        "classify overlap before writing");

    ulong hashAfter = 0;
    scope auto after = upper.view();
    foreach (y; 0 .. h)
    foreach (x; 0 .. w)
    {
        SRgba8 pixel;
        require(after.trySample(0, x, y, pixel), "read post-alias source");
        hashAfter += cast(ulong)pixel.r + pixel.g + pixel.b + pixel.a;
        require(pixel == fixture(0, x, y),
            "alias failure left every source pixel intact");
    }
    require(hashAfter == hashBefore, "alias error preserved whole source");
}

private long measure(
    bool packed,
    size_t iterations,
    ref RasterLease!SRgba8 topPacked,
    ref RasterLease!SRgba8 bottomPacked,
    ref RasterLease!SRgba8 dstPacked,
    ref RasterLease!ubyte topRegular,
    ref RasterLease!ubyte bottomRegular,
    ref RasterLease!ubyte dstRegular,
    size_t w, size_t h
)
{
    StopWatch timer;
    const gcBefore = GC.stats().allocatedInCurrentThread;
    timer.start();
    foreach (i; 0 .. iterations)
    {
        if (packed)
            require(tryPacked(topPacked, bottomPacked, dstPacked),
                "packed raster source-over");
        else
            require(tryFourPlane(
                topRegular, bottomRegular, dstRegular, w, h),
                "checked four-plane source-over");
    }
    timer.stop();
    const gcAfter = GC.stats().allocatedInCurrentThread;
    require(gcBefore == gcAfter, "zero GC bytes in measured calls");
    return timer.peek.total!"usecs";
}

void main(string[] args)
{
    size_t w = 128;
    size_t h = 128;
    size_t rounds = 3;
    size_t iterations = 2;
    foreach (arg; args[1 .. $])
    {
        if (arg.startsWith("--width=")) w = to!size_t(arg[8 .. $]);
        else if (arg.startsWith("--height=")) h = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--rounds=")) rounds = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--iterations="))
            iterations = to!size_t(arg[13 .. $]);
        else throw new Exception("Unknown option " ~ arg);
    }
    require(w > 0 && h > 0 && w <= size_t.max / h &&
        w * h <= cast(size_t)ptrdiff_t.max / 4 &&
        rounds > 0 && iterations > 0,
        "valid dimensions and measurement counts");

    auto topPacked = makeLease!SRgba8(w, h, true, 0, true);
    auto bottomPacked = makeLease!SRgba8(w, h, true, 1, true);
    auto destPacked = makeLease!SRgba8(w, h, true, 0, false);
    auto topRegular = makeLease!ubyte(w, h, false, 0, true);
    auto bottomRegular = makeLease!ubyte(w, h, false, 1, true);
    auto destRegular = makeLease!ubyte(w, h, false, 0, false);

    static assert(isRasterSampleType!SRgba8);
    verifyOverlapRejected(topPacked, bottomPacked, w, h);
    require(tryPacked(topPacked, bottomPacked, destPacked),
        "prepare packed compositor");
    require(tryFourPlane(
        topRegular, bottomRegular, destRegular, w, h),
        "prepare canonical compositor");
    require(compare(destPacked, destRegular, w, h) == 0,
        "all RGBA output pixels exactly equal");

    writeln("width,height,round,iterations,four_plane_us,packed_zip_us,",
        "pixel_differences");
    foreach (round; 0 .. rounds)
    {
        long canonicalUs;
        long packedUs;
        if (round % 2 == 0)
        {
            canonicalUs = measure(false, iterations,
                topPacked, bottomPacked, destPacked,
                topRegular, bottomRegular, destRegular, w, h);
            packedUs = measure(true, iterations,
                topPacked, bottomPacked, destPacked,
                topRegular, bottomRegular, destRegular, w, h);
        }
        else
        {
            packedUs = measure(true, iterations,
                topPacked, bottomPacked, destPacked,
                topRegular, bottomRegular, destRegular, w, h);
            canonicalUs = measure(false, iterations,
                topPacked, bottomPacked, destPacked,
                topRegular, bottomRegular, destRegular, w, h);
        }
        const mismatches = compare(destPacked, destRegular, w, h);
        require(mismatches == 0, "paired equivalent output");
        writeln(w, ",", h, ",", round, ",", iterations,
            ",", canonicalUs, ",", packedUs, ",", mismatches);
    }
    writeln("PACKED-PROBE PASS: exact all-pixel equivalent; ",
        "physical overlap rejected before writing");
}
