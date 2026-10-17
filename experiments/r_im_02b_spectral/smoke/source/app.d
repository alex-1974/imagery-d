/++
 An independently built DUB consumer of the R-IM-02b research kernel.

 This constructs genuinely owned raster-d sources, masks and destinations,
 computes expected results directly from the synthetic physical fixture
 (without reading or calling the research implementation), and checks
 entire ROI outputs including invalidity and non-origin sub-ROIs.

 No claim that a satellite source or renderer has adopted this experiment.
+/
module app;

import core.stdc.stdlib : malloc;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import imagery.analysis.spectral_research :
    ResearchGrid, ResearchUnit, ResearchSpectralBand,
    ResearchSpectralError, tryNormalizedDifferenceIntoResearch;

private enum size_t W = 8;
private enum size_t H = 6;
private enum size_t C = 3;
private enum Layout : ubyte { planar, interleaved }

private void require(bool yes, string reason)
{
    if (!yes)
        throw new Exception("R-IM-02b independent consumer: " ~ reason);
}

private double redDN(size_t x, size_t y)
{
    if (x == 5 && y == 2)
        return 0.0;
    static if (true)
    {
        return cast(double)(200 + x + 2 * y);
    }
}

private double nirDN(size_t x, size_t y)
{
    if (x == 5 && y == 2)
        return 0.0;
    return cast(double)(400 + 3 * x + 4 * y);
}

private T fixture(T)(bool isNir, size_t plane, size_t x, size_t y)
{
    if (plane != 1)
        return cast(T)(10 * plane + x + y);
    static if (is(T == float))
    {
        if (isNir && x == 2 && y == 3)
            return float.nan;
        if (isNir && x == 6 && y == 4)
            return float.infinity;
        if (isNir && x == 7 && y == 5)
            return -400.0f;
        if (!isNir && x == 7 && y == 5)
            return 1200.0f;
    }
    return cast(T)(isNir ? nirDN(x, y) : redDN(x, y));
}

private bool redValid(size_t x, size_t y)
{
    return (x + 2 * y) % 5 != 0;
}

private bool nirValid(size_t x, size_t y)
{
    return (2 * x + y) % 7 != 0;
}

private RasterLease!T makeRaster(T)(
    size_t width, size_t height, size_t bands,
    Layout layout)
{
    const bytes = width * height * bands * T.sizeof;
    auto raw = cast(T*)malloc(bytes);
    require(raw !is null, "malloc owner backing");

    OwnedByteResource resource;
    require(tryAdoptMallocResource(raw, bytes, resource),
        "adopt raster-d owner");
    auto planes = new PlaneByteLayout[](bands);
    foreach (c; 0 .. bands)
        planes[c] = layout == Layout.planar
            ? PlaneByteLayout(c * width * height * T.sizeof,
                cast(ptrdiff_t)(width * T.sizeof),
                cast(ptrdiff_t)T.sizeof)
            : PlaneByteLayout(c * T.sizeof,
                cast(ptrdiff_t)(width * bands * T.sizeof),
                cast(ptrdiff_t)(bands * T.sizeof));
    RasterLease!T lease;
    auto imported = tryImportOwnedRaster!T(resource, planes[],
        Region2D(0, 0, width, height), lease);
    require(imported.ok, "import raster-d resource");
    return lease;
}

private RasterLease!T makeBand(T)(bool isNir, Layout layout)
{
    auto lease = makeRaster!T(W, H, C, layout);
    bool ok;
    scope auto writer = lease.tryWritableView(ok);
    require(ok, "acquire source writer");
    foreach (c; 0 .. C)
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
        require(writer.trySetSample(c, x, y,
            fixture!T(isNir, c, x, y)), "fill source fixture");
    return lease;
}

private RasterLease!ubyte makeMask(bool isNir)
{
    auto lease = makeRaster!ubyte(W, H, 1, Layout.interleaved);
    bool ok;
    scope auto writer = lease.tryWritableView(ok);
    require(ok, "acquire mask writer");
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
        require(writer.trySetSample(0, x, y,
            (isNir ? nirValid(x, y) : redValid(x, y))
                ? cast(ubyte)255 : cast(ubyte)0), "fill mask");
    return lease;
}

// Independent oracle: the source formula uses known integer DN values,
// rather than reading pixels or importing any implementation math code.
// Physical calibration is explicitly applied before the comparison.
private void expected(T)(
    size_t x, size_t y, bool maskRed, bool maskNir,
    double offset, out float want, out ubyte valid)
{
    want = 0.0f;
    valid = 0;
    if ((maskRed && !redValid(x, y)) ||
        (maskNir && !nirValid(x, y)))
        return;
    static if (is(T == float))
    {
        if (x == 2 && y == 3 || x == 6 && y == 4)
            return;
    }

    double red = redDN(x, y);
    double nir = nirDN(x, y);
    static if (is(T == float))
    {
        if (x == 7 && y == 5)
        {
            red = 1200.0;
            nir = -400.0;
        }
    }
    red = red * 0.01 + offset;
    nir = nir * 0.01 + offset;
    const sum = red + nir;
    if (sum == 0.0)
        return;
    want = cast(float)((nir - red) / sum);
    valid = 255;
}

private void makeResult(
    size_t width, size_t height,
    out RasterLease!float values,
    out RasterLease!ubyte validity)
{
    // output parameters here are initially empty local test owners ONLY,
    // never live consumers' resources.
    values = makeRaster!float(width, height, 1, Layout.planar);
    validity = makeRaster!ubyte(width, height, 1, Layout.interleaved);
    bool okayA, okayB;
    scope auto a = values.tryWritableView(okayA);
    scope auto b = validity.tryWritableView(okayB);
    require(okayA && okayB, "output writers for sentinels");
    foreach (y; 0 .. height)
    foreach (x; 0 .. width)
        require(a.trySetSample(0, x, y, -777.0f) &&
                b.trySetSample(0, x, y, 44),
                "initialize output sentinels");
}

private void runCase(T)(
    Layout redLayout, Layout nirLayout,
    bool maskRed, bool maskNir, double offset)
{
    auto redOwner = makeBand!T(false, redLayout);
    auto nirOwner = makeBand!T(true, nirLayout);
    auto redMaskOwner = makeMask(false);
    auto nirMaskOwner = makeMask(true);

    const grid = ResearchGrid(11, 300, 600, 10, -10);
    auto red = ResearchSpectralBand!T(
        redOwner.view(), 1, 42, grid,
        ResearchUnit.reflectance, true, 0.01, offset);
    auto nir = ResearchSpectralBand!T(
        nirOwner.view(), 1, 77, grid,
        ResearchUnit.reflectance, true, 0.01, offset);
    auto maskA = maskNir ? nirMaskOwner.view() : RasterView!ubyte.init;
    auto maskB = maskRed ? redMaskOwner.view() : RasterView!ubyte.init;

    const Region2D full = Region2D(0, 0, W, H);
    const Region2D[4] quadrants = [
        Region2D(0, 0, 4, 3),
        Region2D(4, 0, 4, 3),
        Region2D(0, 3, 4, 3),
        Region2D(4, 3, 4, 3)
    ];

    float[W * H] wholeValues;
    ubyte[W * H] wholeMask;
    foreach (iteration; 0 .. 5)
    {
        const region = iteration == 0 ? full : quadrants[iteration - 1];
        RasterLease!float outValues;
        RasterLease!ubyte outMask;
        makeResult(region.width, region.height, outValues, outMask);
        bool writableA, writableB;
        scope auto dst = outValues.tryWritableView(writableA);
        scope auto dstMask = outMask.tryWritableView(writableB);
        require(writableA && writableB, "independent output views");

        const status = tryNormalizedDifferenceIntoResearch! (T, T)(
            nir, red, region, maskA, maskNir, maskB, maskRed,
            dst, dstMask);
        require(status == ResearchSpectralError.none,
            "valid grid/ROI normalized difference");

        auto readValues = outValues.view();
        auto readMask = outMask.view();
        foreach (localY; 0 .. region.height)
        foreach (localX; 0 .. region.width)
        {
            const x = region.x + localX;
            const y = region.y + localY;
            float observed;
            ubyte observedValidity;
            require(readValues.trySample(0, localX, localY, observed) &&
                    readMask.trySample(0, localX, localY, observedValidity),
                    "read every numeric output and validity sample");

            float want;
            ubyte valid;
            expected!T(x, y, maskRed, maskNir, offset, want, valid);
            require(observedValidity == valid, "oracle validity");
            const difference = observed - want;
            require(difference >= -0.000002f &&
                    difference <= 0.000002f, "oracle normalized value");
            if (iteration == 0)
            {
                wholeValues[y * W + x] = observed;
                wholeMask[y * W + x] = observedValidity;
            }
            else
                require(observed == wholeValues[y * W + x] &&
                        observedValidity == wholeMask[y * W + x],
                        "exact whole versus quadrant output");
        }
    }

    // Fail-closed preflight on a nonempty caller-owned destination.
    RasterLease!float outValues;
    RasterLease!ubyte outMask;
    makeResult(W, H, outValues, outMask);
    bool wa, wb;
    scope auto dst = outValues.tryWritableView(wa);
    scope auto vm = outMask.tryWritableView(wb);
    require(wa && wb, "negative case destination");

    auto bad = nir;
    bad.grid = ResearchGrid(11, 300, 600, 20, -20);
    require(tryNormalizedDifferenceIntoResearch!(T, T)(
        bad, red, full, maskA, maskNir, maskB, maskRed,
        dst, vm) == ResearchSpectralError.mismatchedGrid,
        "reject unequal native pixel resolution even at same array size");

    bad = nir;
    bad.grid = ResearchGrid(12, 300, 600, 10, -10);
    require(tryNormalizedDifferenceIntoResearch!(T, T)(
        bad, red, full, maskA, maskNir, maskB, maskRed,
        dst, vm) == ResearchSpectralError.mismatchedGrid,
        "reject unequal spatial frame");

    bad = nir;
    bad.grid = ResearchGrid(11, 310, 600, 10, -10);
    require(tryNormalizedDifferenceIntoResearch!(T, T)(
        bad, red, full, maskA, maskNir, maskB, maskRed,
        dst, vm) == ResearchSpectralError.mismatchedGrid,
        "reject shifted grid origin");

    bad = nir;
    bad.scale = double.nan;
    require(tryNormalizedDifferenceIntoResearch!(T, T)(
        bad, red, full, maskA, maskNir, maskB, maskRed,
        dst, vm) == ResearchSpectralError.invalidCalibration,
        "reject nonfinite calibration");

    bad = nir;
    bad.unit = ResearchUnit.radiance;
    require(tryNormalizedDifferenceIntoResearch!(T, T)(
        bad, red, full, maskA, maskNir, maskB, maskRed,
        dst, vm) == ResearchSpectralError.invalidCalibration,
        "reject unit mismatch");

    bad = nir;
    bad.calibrated = false;
    require(tryNormalizedDifferenceIntoResearch!(T, T)(
        bad, red, full, maskA, maskNir, maskB, maskRed,
        dst, vm) == ResearchSpectralError.invalidCalibration,
        "reject missing calibration");

    bad = nir;
    bad.plane = C;
    require(tryNormalizedDifferenceIntoResearch!(T, T)(
        bad, red, full, maskA, maskNir, maskB, maskRed,
        dst, vm) == ResearchSpectralError.invalidBand,
        "reject nonexistent band index");

    require(tryNormalizedDifferenceIntoResearch!(T, T)(
        nir, red, Region2D(7, 5, 2, 2),
        maskA, maskNir, maskB, maskRed,
        dst, vm) == ResearchSpectralError.invalidRegion,
        "reject overflowed logical ROI");

    require(tryNormalizedDifferenceIntoResearch!(T, T)(
        nir, red, full, RasterView!ubyte.init, true,
        maskB, maskRed, dst, vm) == ResearchSpectralError.invalidMask,
        "reject missing but required mask");

    // Every preflight rejection above must leave EVERY output sample intact.
    auto readValues = outValues.view();
    auto readMask = outMask.view();
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
    {
        float current;
        ubyte mask;
        require(readValues.trySample(0, x, y, current) &&
                readMask.trySample(0, x, y, mask) &&
                current == -777.0f && mask == 44,
                "all negative preflight calls preserved original output");
    }
}

void main()
{
    foreach (redLayout; [Layout.planar, Layout.interleaved])
    foreach (nirLayout; [Layout.planar, Layout.interleaved])
    foreach (maskRed; [false, true])
    foreach (maskNir; [false, true])
    foreach (offset; [0.0, 1.5])
    {
        runCase!ushort(redLayout, nirLayout, maskRed, maskNir, offset);
        runCase!float(redLayout, nirLayout, maskRed, maskNir, offset);
    }

    writeln("R-IM-02b spectral consumer PASS: 64 configurations, ",
        "320 complete ROI+mask outputs, 2 sample types, 4 mask combinations, ",
        "whole/quadrant equivalence, numerical oracle, fail-closed grid");
}
