/++
 R-IM-02c external DUB consumer. Uses ORIGINAL M1/M3.2 descriptors and
 snapshots (not a locally recreated metadata model), plus real raster-d
 ownership. Oracles are computed from fixture math, never from the kernel.
+/
module metadata_consumer;

import core.stdc.stdlib : malloc;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import m1_5_image_view.contract : ChannelDescriptor;
import m3_2_channel_metadata.contract : IntrinsicChannel;
import m3_2_metadata_owner.contract : ResearchMetadataState;
import imagery.analysis.spectral_research :
    ResearchGrid, ResearchNoData, ResearchSpectralError;
import imagery.analysis.spectral_metadata_research :
    ResearchMetadataImage, tryNormalizedDifferenceMetadataIntoResearch;

private enum size_t W = 8;
private enum size_t H = 6;
private enum size_t C = 3;
private enum Layout : ubyte { planar, interleaved }

private void insist(bool yes, string reason)
{
    if (!yes)
        throw new Exception("R-IM-02c: " ~ reason);
}

private double rawValue(bool nir, size_t x, size_t y)
{
    if (x == 5 && y == 2)
        return 0; // nondefined 0/0, independent of raw NoData
    if (x == 1 && y == 1)
        return 333; // valid normalized difference exactly zero
    return nir ? 400 + 3 * x + 4 * y : 200 + x + 2 * y;
}

private T rawSample(T)(bool nir, size_t band, size_t x, size_t y)
{
    if (band != 1)
        return cast(T)(band * 10 + x + y);
    static if (is(T == float))
    {
        if (nir && x == 2 && y == 3)
            return float.nan;
        if (nir && x == 6 && y == 4)
            return float.infinity;
        if (nir && x == 7 && y == 5)
            return -400.0f;
        if (!nir && x == 7 && y == 5)
            return 1200.0f;
    }
    return cast(T)rawValue(nir, x, y);
}

private bool validMask(bool nir, size_t x, size_t y)
{
    return nir ? ((2 * x + y) % 7 != 0)
               : ((x + 2 * y) % 5 != 0);
}

private RasterLease!T makeOwned(T)(
    size_t width, size_t height, size_t bands, Layout layout)
{
    const size_t bytes = width * height * bands * T.sizeof;
    auto memory = cast(T*)malloc(bytes);
    insist(memory !is null, "malloc raster");
    OwnedByteResource token;
    insist(tryAdoptMallocResource(memory, bytes, token), "adopt bytes");

    auto layouts = new PlaneByteLayout[](bands);
    foreach (c; 0 .. bands)
        layouts[c] = layout == Layout.planar
            ? PlaneByteLayout(c * width * height * T.sizeof,
                cast(ptrdiff_t)(width * T.sizeof), cast(ptrdiff_t)T.sizeof)
            : PlaneByteLayout(c * T.sizeof,
                cast(ptrdiff_t)(width * bands * T.sizeof),
                cast(ptrdiff_t)(bands * T.sizeof));

    RasterLease!T owner;
    auto imported = tryImportOwnedRaster!T(
        token, layouts[], Region2D(0, 0, width, height), owner);
    insist(imported.ok, "checked raster owner import");
    return owner;
}

private RasterLease!T makePixels(T)(bool nir, Layout layout)
{
    auto owner = makeOwned!T(W, H, C, layout);
    bool ok;
    scope auto view = owner.tryWritableView(ok);
    insist(ok, "source write view");
    foreach (c; 0 .. C)
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
        insist(view.trySetSample(c, x, y, rawSample!T(nir, c, x, y)),
            "write source pixel");
    return owner;
}

private RasterLease!ubyte makeMask(bool nir)
{
    auto owner = makeOwned!ubyte(W, H, 1, Layout.planar);
    bool ok;
    scope auto writer = owner.tryWritableView(ok);
    insist(ok, "mask write view");
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
        insist(writer.trySetSample(0, x, y,
            validMask(nir, x, y) ? cast(ubyte)255 : cast(ubyte)0),
            "write source mask");
    return owner;
}

private void buildDescriptors(
    bool nir, ref ChannelDescriptor[3] ids,
    ref IntrinsicChannel[3] fields)
{
    const uint selectedId = nir ? 77 : 42;
    foreach (c; 0 .. C)
    {
        const uint id = c == 1 ? selectedId : cast(uint)(100 + 10 * c);
        ids[c] = ChannelDescriptor(id);
        fields[c] = IntrinsicChannel(
            id, "opaque-band", "same-opaque-unit", true, 0.01f, 0.0f);
    }
}

// Expected values deliberately use synthetic fixture formulas, not the
// research kernel or destination pixels. The metadata float calibration
// factor is widened to double exactly as the adapter does.
private void expected(T)(
    size_t x, size_t y, bool hasMask, bool updatedRed,
    out float want, out ubyte valid)
{
    want = 0;
    valid = 0;
    if (hasMask && (!validMask(true, x, y) ||
                    !validMask(false, x, y)))
        return;

    if (x == 5 && y == 3)
        return; // explicit NIR raw NoData sentinel 427
    static if (is(T == float))
    {
        if ((x == 2 && y == 3) || (x == 6 && y == 4))
            return;
    }

    double rawNir = rawValue(true, x, y);
    double rawRed = rawValue(false, x, y);
    static if (is(T == float))
        if (x == 7 && y == 5)
        {
            rawNir = -400;
            rawRed = 1200;
        }

    const nir = rawNir * cast(double)0.01f;
    const red = rawRed * cast(double)(updatedRed ? 0.02f : 0.01f);
    const denom = nir + red;
    if (denom == 0)
        return;
    const answer = (nir - red) / denom;
    if (answer != answer || answer > cast(double)float.max ||
        answer < -cast(double)float.max)
        return;
    want = cast(float)answer;
    valid = 255;
}

private void freshOutput(
    size_t width, size_t height,
    ref RasterLease!float pixels,
    ref RasterLease!ubyte mask)
{
    pixels = makeOwned!float(width, height, 1, Layout.planar);
    mask = makeOwned!ubyte(width, height, 1, Layout.interleaved);
    bool pa, ma;
    scope auto p = pixels.tryWritableView(pa);
    scope auto m = mask.tryWritableView(ma);
    insist(pa && ma, "result writer");
    foreach (y; 0 .. height)
    foreach (x; 0 .. width)
        insist(p.trySetSample(0, x, y, -999.0f) &&
               m.trySetSample(0, x, y, 33), "result sentinel");
}

private void caseWithMetadata(T)(Layout layout, bool hasMask, bool updatedRed)
{
    auto nirOwned = makePixels!T(true, layout);
    auto redOwned = makePixels!T(false,
        layout == Layout.planar ? Layout.interleaved : Layout.planar);
    auto nirMaskOwned = makeMask(true);
    auto redMaskOwned = makeMask(false);

    ChannelDescriptor[3] nirIds, redIds;
    IntrinsicChannel[3] nirFields, redFields;
    buildDescriptors(true, nirIds, nirFields);
    buildDescriptors(false, redIds, redFields);
    auto nirSnapshot = ResearchMetadataState.snapshot(nirIds[], nirFields[]);
    auto redSnapshot = ResearchMetadataState.snapshot(redIds[], redFields[]);

    // Caller storage is mutable: immutable snapshot must preserve old
    // semantics while new generations may explicitly differ.
    redFields[1] = IntrinsicChannel(
        42, "changed-band", "same-opaque-unit", true, 0.02f, 0.0f);
    auto newerRed = ResearchMetadataState.snapshot(redIds[], redFields[]);
    redIds[1] = ChannelDescriptor(999);
    redFields[1] = IntrinsicChannel(
        999, "mutated-again", "other-unit", false, 99.0f, 42.0f);
    insist(redSnapshot.identities[1].semanticId == 42 &&
           redSnapshot.metadata[1].scale == 0.01f &&
           newerRed.metadata[1].scale == 0.02f &&
           newerRed.identities[1].semanticId == 42,
           "original immutable metadata unaffected by caller mutation");

    const grid = ResearchGrid(11, 300, 600, 10, -10);
    auto nir = ResearchMetadataImage!T(
        nirOwned.view(), nirSnapshot, 1, grid,
        ResearchNoData!T(true, cast(T)427));
    auto red = ResearchMetadataImage!T(
        redOwned.view(), updatedRed ? newerRed : redSnapshot,
        1, grid, ResearchNoData!T.init);
    auto aMask = hasMask ? nirMaskOwned.view() : RasterView!ubyte.init;
    auto bMask = hasMask ? redMaskOwned.view() : RasterView!ubyte.init;

    const Region2D full = Region2D(0, 0, W, H);
    const Region2D[4] four = [
        Region2D(0, 0, 4, 3), Region2D(4, 0, 4, 3),
        Region2D(0, 3, 4, 3), Region2D(4, 3, 4, 3)
    ];
    float[W * H] reference;
    ubyte[W * H] referenceMask;

    foreach (round; 0 .. 5)
    {
        const region = round == 0 ? full : four[round - 1];
        RasterLease!float outOwner;
        RasterLease!ubyte maskOwner;
        freshOutput(region.width, region.height, outOwner, maskOwner);
        bool pa, ma;
        scope auto output = outOwner.tryWritableView(pa);
        scope auto validity = maskOwner.tryWritableView(ma);
        insist(pa && ma, "writable result");
        const status = tryNormalizedDifferenceMetadataIntoResearch!(T, T)(
            nir, red, region, aMask, hasMask, bMask, hasMask,
            output, validity);
        insist(status == ResearchSpectralError.none,
            "metadata-bound execution");

        auto p = outOwner.view();
        auto m = maskOwner.view();
        foreach (yy; 0 .. region.height)
        foreach (xx; 0 .. region.width)
        {
            const x = region.x + xx;
            const y = region.y + yy;
            float got, want;
            ubyte flag, wantFlag;
            insist(p.trySample(0, xx, yy, got) &&
                   m.trySample(0, xx, yy, flag), "read full output");
            expected!T(x, y, hasMask, updatedRed, want, wantFlag);
            const d = got - want;
            insist(flag == wantFlag && d >= -0.000002f &&
                d <= 0.000002f, "independent full numerical oracle");
            if (round == 0)
            {
                reference[y * W + x] = got;
                referenceMask[y * W + x] = flag;
            }
            else
                insist(got == reference[y * W + x] &&
                       flag == referenceMask[y * W + x],
                       "whole / segmented equality");
        }
    }

    RasterLease!float outOwner;
    RasterLease!ubyte maskOwner;
    freshOutput(W, H, outOwner, maskOwner);
    bool pa, ma;
    scope auto output = outOwner.tryWritableView(pa);
    scope auto validity = maskOwner.tryWritableView(ma);
    insist(pa && ma, "negative-case write view");

    // An ID mismatch is not repaired by trusting a selected plane number.
    auto corruptedIds = [ChannelDescriptor(100), ChannelDescriptor(999),
                         ChannelDescriptor(120)];
    auto validFields = [
        IntrinsicChannel(100, "x", "same-opaque-unit", true, 1, 0),
        IntrinsicChannel(77, "y", "same-opaque-unit", true, 1, 0),
        IntrinsicChannel(120, "z", "same-opaque-unit", true, 1, 0)
    ];
    auto bad = nir;
    bad.metadata = ResearchMetadataState.snapshot(
        corruptedIds[], validFields[]);
    insist(tryNormalizedDifferenceMetadataIntoResearch!(T, T)(
        bad, red, full, aMask, hasMask, bMask, hasMask,
        output, validity) == ResearchSpectralError.invalidIdentity,
        "reject ID mismatch");

    auto wrongQuantity = [
        IntrinsicChannel(100, "x", "same-opaque-unit", true, 1, 0),
        IntrinsicChannel(77, "y", "different-unit", true, 1, 0),
        IntrinsicChannel(120, "z", "same-opaque-unit", true, 1, 0)
    ];
    bad.metadata = ResearchMetadataState.snapshot(
        nirIds[], wrongQuantity[]);
    insist(tryNormalizedDifferenceMetadataIntoResearch!(T, T)(
        bad, red, full, aMask, hasMask, bMask, hasMask,
        output, validity) == ResearchSpectralError.invalidCalibration,
        "reject incompatible opaque quantity labels");

    wrongQuantity[1] = IntrinsicChannel(
        77, "y", "same-opaque-unit", false, 1, 0);
    bad.metadata = ResearchMetadataState.snapshot(
        nirIds[], wrongQuantity[]);
    insist(tryNormalizedDifferenceMetadataIntoResearch!(T, T)(
        bad, red, full, aMask, hasMask, bMask, hasMask,
        output, validity) == ResearchSpectralError.invalidCalibration,
        "reject missing band calibration");

    wrongQuantity[1] = IntrinsicChannel(
        77, "y", "same-opaque-unit", true, float.nan, 0);
    bad.metadata = ResearchMetadataState.snapshot(
        nirIds[], wrongQuantity[]);
    insist(tryNormalizedDifferenceMetadataIntoResearch!(T, T)(
        bad, red, full, aMask, hasMask, bMask, hasMask,
        output, validity) == ResearchSpectralError.invalidCalibration,
        "reject nonfinite calibration from immutable metadata");

    static if (is(T == float))
    {
        bad = nir;
        bad.noData = ResearchNoData!T(true, float.nan);
        insist(tryNormalizedDifferenceMetadataIntoResearch!(T, T)(
            bad, red, full, aMask, hasMask, bMask, hasMask,
            output, validity) == ResearchSpectralError.invalidNoData,
            "reject NaN as equality NoData sentinel");
    }

    auto outputRead = outOwner.view();
    auto validityRead = maskOwner.view();
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
    {
        float got;
        ubyte flag;
        insist(outputRead.trySample(0, x, y, got) &&
               validityRead.trySample(0, x, y, flag) &&
               got == -999.0f && flag == 33,
               "failed metadata preflight preserved complete output");
    }
}

void runMetadataConsumer()
{
    foreach (layout; [Layout.planar, Layout.interleaved])
    foreach (hasMask; [false, true])
    foreach (updated; [false, true])
    {
        caseWithMetadata!ushort(layout, hasMask, updated);
        caseWithMetadata!float(layout, hasMask, updated);
    }
    import std.stdio : writeln;
    writeln("R-IM-02c metadata consumer PASS: 16 configurations, ",
        "80 whole+partition numeric/mask outputs, independent immutable ",
        "snapshots, stored NoData, mask, calibration, fail-closed metadata");
}
