/++
 A separate DUB consumer of the bounded R-IM-02a prototype.

 All reference values are derived from synthetic fixture formulas rather
 than reading or calling the histogram's implementation. Layout independence,
 mask behavior, stored/physical conversion, partition invariance and
 failure-state preservation are verified over three D numeric sample types.
 This is a RESEARCH verification consumer, not an adopted product.
+/
module app;

import core.stdc.stdlib : malloc;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import imagery.analysis.histogram_research :
    Histogram8, HistogramError, HistogramMeaning, tryHistogram8Research;

private enum size_t W = 8;
private enum size_t H = 6;
private enum size_t C = 3;
private enum Layout : ubyte { planar, interleaved }

private void require(bool condition, string reason)
{
    if (!condition)
        throw new Exception("R-IM-02 histogram consumer: " ~ reason);
}

private T fixture(T)(size_t band, size_t x, size_t y)
{
    static if (is(T == float))
        if (band == 2 && x == 2 && y == 3)
            return float.nan;
    return cast(T)(band * 8 + x + 2 * y);
}

private bool valid(size_t x, size_t y)
{
    return ((x + 2 * y) % 5) != 0;
}

private RasterLease!T makeRaster(T)(Layout layout)
{
    const bytes = W * H * C * T.sizeof;
    auto raw = cast(T*)malloc(bytes);
    require(raw !is null, "malloc source pixels");

    OwnedByteResource resource;
    require(tryAdoptMallocResource(raw, bytes, resource),
        "adopt real raster backing");
    auto planes = new PlaneByteLayout[](C);
    foreach (band; 0 .. C)
        planes[band] = layout == Layout.planar
            ? PlaneByteLayout(band * W * H * T.sizeof,
                cast(ptrdiff_t)(W * T.sizeof),
                cast(ptrdiff_t)T.sizeof)
            : PlaneByteLayout(band * T.sizeof,
                cast(ptrdiff_t)(W * C * T.sizeof),
                cast(ptrdiff_t)(C * T.sizeof));

    RasterLease!T lease;
    const imported = tryImportOwnedRaster!T(
        resource, planes[], Region2D(0, 0, W, H), lease);
    require(imported.ok, "raster-d checked owner import");

    bool ok;
    scope auto writer = lease.tryWritableView(ok);
    require(ok, "create source writer");
    foreach (band; 0 .. C)
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
        require(writer.trySetSample(band, x, y,
            fixture!T(band, x, y)), "write raster pixel");
    return lease;
}

private RasterLease!ubyte makeMask()
{
    const bytes = W * H;
    auto raw = cast(ubyte*)malloc(bytes);
    require(raw !is null, "malloc separate mask");
    OwnedByteResource resource;
    require(tryAdoptMallocResource(raw, bytes, resource),
        "adopt mask");
    const PlaneByteLayout[1] planes = [
        PlaneByteLayout(0, cast(ptrdiff_t)W, 1)
    ];

    RasterLease!ubyte lease;
    const imported = tryImportOwnedRaster!ubyte(
        resource, planes[], Region2D(0, 0, W, H), lease);
    require(imported.ok, "import separate mask");
    bool ok;
    scope auto writer = lease.tryWritableView(ok);
    require(ok, "mask writer");
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
        require(writer.trySetSample(0, x, y,
            valid(x, y) ? cast(ubyte)255 : cast(ubyte)0),
            "write mask");
    return lease;
}

// Independent oracle: fixture is an exact integer grid except one deliberate
// float NaN. Bin boundaries are known multiples of eight, so this oracle
// classifies via integer quotient rather than the implementation's normalized
// floating-point bin calculation.
private Histogram8 expected(T)(
    size_t band, Region2D region, bool useMask, HistogramMeaning meaning)
{
    Histogram8 e;
    foreach (y; region.y .. region.y + region.height)
    foreach (x; region.x .. region.x + region.width)
    {
        if (useMask && !valid(x, y))
        {
            ++e.masked;
            continue;
        }
        static if (is(T == float))
        {
            if (band == 2 && x == 2 && y == 3)
            {
                ++e.nonFinite;
                continue;
            }
        }

        const raw = cast(size_t)(band * 8 + x + 2 * y);
        const physical = meaning == HistogramMeaning.physical
            ? raw * 2 + 1 : raw;

        if (physical >= 64)
        {
            ++e.outsideRange;
            continue;
        }
        const bucket = physical / 8;
        ++e.bins[bucket];
        ++e.counted;
    }
    return e;
}

private bool equal(Histogram8 a, Histogram8 b)
{
    if (a.counted != b.counted || a.masked != b.masked ||
        a.nonFinite != b.nonFinite ||
        a.outsideRange != b.outsideRange)
        return false;
    foreach (i; 0 .. 8)
        if (a.bins[i] != b.bins[i])
            return false;
    return true;
}

private void add(ref Histogram8 total, Histogram8 part)
{
    foreach (i; 0 .. 8)
        total.bins[i] += part.bins[i];
    total.counted += part.counted;
    total.masked += part.masked;
    total.nonFinite += part.nonFinite;
    total.outsideRange += part.outsideRange;
}

private void exercise(T)(
    Layout layout, bool useMask, HistogramMeaning meaning, size_t band)
{
    auto pixels = makeRaster!T(layout);
    auto maskOwner = makeMask();
    auto input = pixels.view();
    auto mask = useMask ? maskOwner.view() : RasterView!ubyte.init;

    const Region2D whole = Region2D(0, 0, W, H);
    const Region2D[4] parts = [
        Region2D(0, 0, 4, 3),
        Region2D(4, 0, 4, 3),
        Region2D(0, 3, 4, 3),
        Region2D(4, 3, 4, 3)
    ];

    Histogram8 all;
    const status = tryHistogram8Research!T(input, band, whole, mask,
        useMask, meaning, 2.0, 1.0, 0.0, 64.0, all);
    require(status == HistogramError.none, "complete histogram");
    require(equal(all, expected!T(band, whole, useMask, meaning)),
        "independent full-ROI oracle");

    Histogram8 combined;
    foreach (region; parts)
    {
        Histogram8 part;
        require(tryHistogram8Research!T(input, band, region, mask,
            useMask, meaning, 2.0, 1.0, 0.0, 64.0, part)
            == HistogramError.none, "partitioned ROI");
        require(equal(part, expected!T(band, region, useMask, meaning)),
            "independent partition oracle");
        add(combined, part);
    }
    require(equal(all, combined), "whole == partitioned histogram");

    // Failure-state preservation: prior output must remain identical.
    auto prior = all;
    require(tryHistogram8Research!T(input, band,
        Region2D(W - 1, H - 1, 2, 2), mask,
        useMask, meaning, 2.0, 1.0, 0.0, 64.0, prior)
        == HistogramError.invalidRegion &&
        equal(prior, all), "bad ROI and previous state");

    require(tryHistogram8Research!T(input, C, whole, mask,
        useMask, meaning, 2.0, 1.0, 0.0, 64.0, prior)
        == HistogramError.invalidSource &&
        equal(prior, all), "bad band and previous state");

    require(tryHistogram8Research!T(input, band, whole, mask,
        useMask, meaning, 2.0, 1.0, 64.0, 64.0, prior)
        == HistogramError.invalidRange &&
        equal(prior, all), "bad numeric interval and previous state");

    require(tryHistogram8Research!T(input, band, whole,
        RasterView!ubyte.init, true,
        meaning, 2.0, 1.0, 0.0, 64.0, prior)
        == HistogramError.invalidMask &&
        equal(prior, all), "bad mask and previous state");

    if (meaning == HistogramMeaning.physical)
    {
        require(tryHistogram8Research!T(input, band, whole, mask,
            useMask, meaning, double.nan, 1.0, 0.0, 64.0, prior)
            == HistogramError.invalidCalibration &&
            equal(prior, all), "bad physical calibration and previous state");
    }
}

void main()
{
    foreach (layout; [Layout.planar, Layout.interleaved])
    foreach (useMask; [false, true])
    foreach (meaning; [HistogramMeaning.stored, HistogramMeaning.physical])
    foreach (band; [cast(size_t)0, cast(size_t)2])
    {
        exercise!ubyte(layout, useMask, meaning, band);
        exercise!ushort(layout, useMask, meaning, band);
        exercise!float(layout, useMask, meaning, band);
    }

    writeln("R-IM-02a histogram consumer PASS: 48 cases, 240 complete ",
        "ROI histograms, 3 numeric types, 2 layouts, 2 mask states, ",
        "2 value meanings, 2 bands, independent oracles, ",
        "whole/partition equivalence, input failure preservation");
}
