// Independent DUB consumer: imports ONLY the experimental library's
// consumer-visible symbols and released public raster-d/color-d APIs.
// It does not use the original large M3 consumer or private raster modules.
module app;

import core.stdc.stdlib : malloc, free;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import color : SRgba8;
import imagery.presentation.composite :
    DecodedRgbaLayer, RgbaAssociation, RgbaEncoding, RgbaCompositeError,
    ResearchPreparedRgbaContext, tryPrepareRgbaContext,
    tryCompositeRgbaSourceOverPrepared;
import imagery.presentation.owned : tryCompositeOwnedRgbaResearch;

private void ensure(bool condition, string diagnostic)
{
    if (!condition)
        throw new Exception("M3 owned slice external consumer: " ~ diagnostic);
}

private RasterLease!ubyte newFourBand(
    size_t width, size_t height, bool planar)
{
    const bytes = width * height * 4;
    auto raw = cast(ubyte*)malloc(bytes);
    ensure(raw !is null, "allocate independent fixture");
    OwnedByteResource backing;
    if (!tryAdoptMallocResource(raw, bytes, backing))
    {
        free(raw);
        ensure(false, "adopt independent fixture");
    }
    PlaneByteLayout[4] planes;
    foreach (band; 0 .. 4)
        planes[band] = planar
            ? PlaneByteLayout(band * width * height,
                cast(ptrdiff_t)width, 1)
            : PlaneByteLayout(band, cast(ptrdiff_t)(width * 4), 4);
    RasterLease!ubyte lease;
    ensure(tryImportOwnedRaster!ubyte(
        backing, planes[], Region2D(0, 0, width, height), lease).ok,
        "import independent fixture from released raster-d");
    return lease;
}

private void fill(
    ref RasterLease!ubyte lease, bool pm, bool transparent, size_t seed)
{
    bool ok;
    scope auto write = lease.tryWritableView(ok);
    ensure(ok, "writable source backing");
    foreach (y; 0 .. write.height)
    foreach (x; 0 .. write.width)
    {
        const ubyte alpha = transparent
            ? 0
            : cast(ubyte)(64 + (x * 9 + y * 13 + seed) % 168);
        const ubyte red = pm
            ? cast(ubyte)(alpha / 3)
            : cast(ubyte)((x * 19 + y * 3 + 47 + seed) % 256);
        const ubyte green = pm
            ? cast(ubyte)(alpha / 2)
            : cast(ubyte)((x * 7 + y * 23 + seed) % 256);
        const ubyte blue = pm
            ? cast(ubyte)(alpha / 4)
            : cast(ubyte)((x * 5 + y * 11 + seed) % 256);
        ensure(write.trySetSample(0, x, y, red) &&
            write.trySetSample(1, x, y, green) &&
            write.trySetSample(2, x, y, blue) &&
            write.trySetSample(3, x, y, alpha),
            "write independent source fixture");
    }
}

private void compareAgainstPrepared(
    ref const ResearchPreparedRgbaContext context,
    scope DecodedRgbaLayer top, scope DecodedRgbaLayer lower,
    Region2D roi, ref RasterLease!SRgba8 published)
{
    auto expectedLease = newFourBand(roi.width, roi.height, true);
    bool writable;
    {
        scope auto expectedOutput = expectedLease.tryWritableView(writable);
        ensure(writable &&
            tryCompositeRgbaSourceOverPrepared(
                context, top, lower, roi, expectedOutput)
                == RgbaCompositeError.none,
            "independent prepared four-plane mathematical reference");
    }
    scope auto actual = published.view();
    scope auto expected = expectedLease.view();
    ensure(actual.planeCount == 1 &&
           actual.width == roi.width && actual.height == roi.height,
           "one complete packed ROI result");
    foreach (y; 0 .. roi.height)
    foreach (x; 0 .. roi.width)
    {
        SRgba8 pixel;
        ubyte[4] channels;
        ensure(actual.trySample(0, x, y, pixel),
            "read new packed output");
        foreach (band; 0 .. 4)
            ensure(expected.trySample(band, x, y, channels[band]),
                "read independent four-plane reference");
        ensure(pixel == SRgba8(
            channels[0], channels[1], channels[2], channels[3]),
            "byte-exact separate-module packed output");
    }
}

private void runCase(size_t mask, bool transparent)
{
    enum size_t width = 9, height = 7;
    const upperPm = (mask & 1) != 0;
    const lowerPm = (mask & 2) != 0;
    const topMeaning = upperPm ? RgbaEncoding.linearSRgb
                              : RgbaEncoding.encodedSRgb;
    const lowerMeaning = lowerPm ? RgbaEncoding.linearSRgb
                                : RgbaEncoding.encodedSRgb;
    const topAssociation = upperPm ? RgbaAssociation.premultiplied
                                   : RgbaAssociation.straight;
    const lowerAssociation = lowerPm ? RgbaAssociation.premultiplied
                                     : RgbaAssociation.straight;

    auto upperLease = newFourBand(width, height, false);
    auto lowerLease = newFourBand(width, height, true);
    fill(upperLease, upperPm, transparent, 0);
    fill(lowerLease, lowerPm, transparent, 17);
    const upper = DecodedRgbaLayer(
        upperLease.view(), topMeaning, topAssociation);
    const lower = DecodedRgbaLayer(
        lowerLease.view(), lowerMeaning, lowerAssociation);
    const roi = Region2D(2, 1, 4, 3);
    ResearchPreparedRgbaContext prepared;
    ensure(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none,
        "create reusable 256-entry LUT from color-d");

    RasterLease!SRgba8 result;
    ensure(tryCompositeOwnedRgbaResearch(
        prepared, upper, lower, roi, result)
        == RgbaCompositeError.none,
        "produce complete packed ROI with private scratch");
    compareAgainstPrepared(prepared, upper, lower, roi, result);

    scope auto current = result.view();
    SRgba8 preserved;
    ensure(current.trySample(0, 0, 0, preserved),
        "read completed owned result before mutation");
    // A second caller-provided result must NOT be overwritten or reset,
    // even if the new invocation has otherwise valid inputs.
    ensure(tryCompositeOwnedRgbaResearch(
        prepared, upper, lower, roi, result)
        == RgbaCompositeError.invalidOutput,
        "reject already-owned output without invoking ref reset");
    ensure(current.trySample(0, 0, 0, preserved),
        "old owner still retained after rejected update");

    auto independentlyRetained = result;
    result = RasterLease!SRgba8.init;
    ensure(result.view().planeCount == 0,
        "release only one copy of a shared raster owner");

    // New output must never borrow storage from its input. Change source
    // through released raster-d writable view after publishing.
    {
        bool writable;
        scope auto source = upperLease.tryWritableView(writable);
        ensure(writable &&
            source.trySetSample(0, roi.x, roi.y, 0) &&
            source.trySetSample(3, roi.x, roi.y, 0),
            "mutate former input independently of publication");
    }
    SRgba8 after;
    scope auto stillOwned = independentlyRetained.view();
    ensure(stillOwned.trySample(0, 0, 0, after) && after == preserved,
        "retained packed output unaffected by source mutation");
    // Ordinary raster-d copies follow the backing lifetime, not cache
    // membership, and must not be charged as independent physical pixels.
    writeln("M3 OWNED SLICE CASE PASS: mask=", mask,
        ", transparent=", transparent ? 1 : 0,
        ", checked 12 packed ROI pixels against prepared reference");
}

private void rejectBeforePublication()
{
    auto upperLease = newFourBand(8, 6, false);
    auto lowerLease = newFourBand(8, 6, true);
    fill(upperLease, true, false, 3);
    fill(lowerLease, false, false, 7);
    const upper = DecodedRgbaLayer(upperLease.view(),
        RgbaEncoding.linearSRgb, RgbaAssociation.premultiplied);
    const lower = DecodedRgbaLayer(lowerLease.view(),
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    const roi = Region2D(1, 1, 3, 2);

    ResearchPreparedRgbaContext prepared;
    ensure(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none, "valid prepare");
    RasterLease!SRgba8 unpublished;
    ensure(tryCompositeOwnedRgbaResearch(
        prepared, upper, lower, Region2D(size_t.max, 0, 1, 1),
        unpublished) == RgbaCompositeError.invalidRegion &&
        unpublished.view().planeCount == 0,
        "reject overflowing/outside ROI without publication");
    ResearchPreparedRgbaContext inert;
    ensure(tryCompositeOwnedRgbaResearch(
        inert, upper, lower, roi, unpublished)
        == RgbaCompositeError.invalidPreparedContext &&
        unpublished.view().planeCount == 0,
        "reject inert .init context without publication");

    // Poison the *last* PM input pixel, not just the first.
    {
        bool writable;
        scope auto source = upperLease.tryWritableView(writable);
        ensure(writable &&
            source.trySetSample(0, roi.x + roi.width - 1,
                roi.y + roi.height - 1, 255) &&
            source.trySetSample(3, roi.x + roi.width - 1,
                roi.y + roi.height - 1, 0),
            "poison final input coordinate");
    }
    ensure(tryCompositeOwnedRgbaResearch(
        prepared, upper, lower, roi, unpublished)
        == RgbaCompositeError.invalidPremultiplication &&
        unpublished.view().planeCount == 0,
        "reject invalid linear PM before publishing");
    writeln("M3 OWNED SLICE REJECTION PASS: ROI, inert .init and last PM sample");
}

void main()
{
    foreach (mask; 0 .. 4)
        foreach (transparent; [false, true])
            runCase(mask, transparent);
    rejectBeforePublication();
    writeln("M3 OWNED SLICE EXTERNAL DUB PASS: 8 mask/pattern cases, ",
        "96 exact packed ROI pixels, owner copy/retirement, ",
        "source independence and classified preflight failures");
}
