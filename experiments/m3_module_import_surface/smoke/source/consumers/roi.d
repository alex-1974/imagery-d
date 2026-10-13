module consumers.roi;

// A genuinely separate DUB image consumer: this module imports only
// the image-module façade and raster-d's existing ownership/ROI API.
// No direct imports of M1/M3 internal experiment implementation modules.
import core.stdc.stdlib : malloc;
import core.memory : GC;
import imagery.core.channel : ChannelDescriptor;
import imagery.core.metadata : IntrinsicChannel;
import imagery.presentation.channels :
    ColourBinding, DeclaredColour, ValueInterpretation,
    ResearchLongLivedMetadataSource, SourceRoiError;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

private enum Layout : ubyte { planar, interleaved }
private enum size_t sourceWidth = 9;
private enum size_t sourceHeight = 7;
private enum size_t sourcePlanes = 5;
private enum size_t roiWidth = 3;
private enum size_t roiHeight = 2;
private enum size_t[3] selected = [4, 2, 0];

private void require(bool condition, string detail)
{
    if (!condition)
        throw new Exception("M3 independent ROI consumer: " ~ detail);
}

private float stored(size_t channel, size_t x, size_t y)
@safe pure nothrow @nogc
{
    return cast(float)(channel * 100 + y * 10 + x);
}

private bool valid(size_t x, size_t y)
@safe pure nothrow @nogc
{
    // Includes masked interior coordinates, not just ROI corners.
    return (x + 2 * y) % 5 != 0;
}

private RasterLease!float makePixels(
    size_t channels, size_t width, size_t height,
    Layout layout, bool initialize
)
{
    const bytes = channels * width * height * float.sizeof;
    auto memory = cast(float*)malloc(bytes);
    require(memory !is null, "malloc image pixels");

    OwnedByteResource owned;
    require(tryAdoptMallocResource(memory, bytes, owned),
        "adopt image allocation");

    auto planes = new PlaneByteLayout[](channels);
    foreach (c; 0 .. channels)
    {
        planes[c] = layout == Layout.planar
            ? PlaneByteLayout(c * width * height * float.sizeof,
                cast(ptrdiff_t)(width * float.sizeof),
                cast(ptrdiff_t)float.sizeof)
            : PlaneByteLayout(c * float.sizeof,
                cast(ptrdiff_t)(width * channels * float.sizeof),
                cast(ptrdiff_t)(channels * float.sizeof));
    }
    RasterLease!float result;
    const imported = tryImportOwnedRaster!float(
        owned, planes[], Region2D(0, 0, width, height), result);
    require(imported.ok, "import image pixel raster");

    if (initialize)
    {
        bool ok;
        scope auto writable = result.tryWritableView(ok);
        require(ok, "get source writer");
        foreach (c; 0 .. channels)
        foreach (y; 0 .. height)
        foreach (x; 0 .. width)
            require(writable.trySetSample(c, x, y, stored(c, x, y)),
                "initialize source pixel");
    }
    return result;
}

private RasterLease!ubyte makeValidity()
{
    const size_t bytes = sourceWidth * sourceHeight;
    auto memory = cast(ubyte*)malloc(bytes);
    require(memory !is null, "malloc validity");
    foreach (y; 0 .. sourceHeight)
    foreach (x; 0 .. sourceWidth)
        memory[y * sourceWidth + x] = valid(x, y) ? 255 : 0;

    OwnedByteResource owned;
    require(tryAdoptMallocResource(memory, bytes, owned),
        "adopt validity allocation");
    const PlaneByteLayout[1] planes =
        [PlaneByteLayout(0, cast(ptrdiff_t)sourceWidth, 1)];
    RasterLease!ubyte result;
    const imported = tryImportOwnedRaster!ubyte(
        owned, planes[], Region2D(0, 0, sourceWidth, sourceHeight),
        result);
    require(imported.ok, "import validity raster");
    return result;
}

// The consumer's independent formula does not call imagery's mapper.
private float reference(
    size_t component, size_t x, size_t y, bool hasMask,
    ValueInterpretation interpretation, bool refreshed
)
@safe pure nothrow @nogc
{
    if (hasMask && !valid(x, y))
        return 0.0f;
    const sample = stored(selected[component], x, y);
    if (interpretation == ValueInterpretation.stored)
        return sample;
    return refreshed ? sample * 2.0f + 1.0f
                     : sample * 0.5f - 4.0f;
}

private void exercise(
    ResearchLongLivedMetadataSource owner,
    Layout layout, bool hasMask,
    ValueInterpretation interpretation, bool refreshed
)
{
    auto inputLease = makePixels(
        sourcePlanes, sourceWidth, sourceHeight, layout, true);
    // Deliberately use the opposite layout for the output to ensure
    // mapping does not assume equal plane stride/packing.
    auto outputLease = makePixels(3, roiWidth, roiHeight,
        layout == Layout.planar ? Layout.interleaved : Layout.planar,
        false);
    RasterLease!ubyte maskLease;
    if (hasMask)
        maskLease = makeValidity();
    auto source = inputLease.view();
    auto mask = hasMask ? maskLease.view() : RasterView!ubyte.init;

    bool ok;
    scope auto destination = outputLease.tryWritableView(ok);
    require(ok, "acquire output writer");
    auto outputRead = outputLease.view();

    const binding = ColourBinding(
        selected[0], selected[1], selected[2],
        DeclaredColour.unspecified);
    const Region2D[3] windows = [
        Region2D(0, 0, roiWidth, roiHeight),
        Region2D(2, 1, roiWidth, roiHeight),
        Region2D(5, 3, roiWidth, roiHeight)
    ];
    float[9] first, last;

    auto before = GC.stats().allocatedInCurrentThread;
    const batchResult = owner.tryMapOrderedInto(
        source, mask, hasMask, binding, interpretation,
        windows[], destination, first[], last[]);
    auto after = GC.stats().allocatedInCurrentThread;
    require(batchResult == SourceRoiError.none,
        "actual ordered three-ROI mapping");
    require(after == before, "GC bytes allocated inside checked batch");

    // Every ROI is then mapped individually using the same real entry
    // point. Unlike six-corner-only benchmarks, this consumer reads and
    // independently checks ALL pixels of EVERY ROI, including interior
    // validity zeros and reordered/calibrated output planes.
    foreach (i, region; windows)
    {
        float[3] oneFirst, oneLast;
        before = GC.stats().allocatedInCurrentThread;
        const e = owner.tryMapOrderedInto(
            source, mask, hasMask, binding, interpretation,
            windows[i .. i + 1],
            destination, oneFirst[], oneLast[]);
        after = GC.stats().allocatedInCurrentThread;
        require(e == SourceRoiError.none, "singleton ROI mapping");
        require(after == before, "GC bytes allocated in checked singleton");

        foreach (component; 0 .. 3)
        {
            const firstExpected = reference(
                component, region.x, region.y,
                hasMask, interpretation, refreshed);
            const lastExpected = reference(
                component, region.x + roiWidth - 1,
                region.y + roiHeight - 1,
                hasMask, interpretation, refreshed);
            require(first[i * 3 + component] == firstExpected,
                "batched ROI first-corner oracle");
            require(last[i * 3 + component] == lastExpected,
                "batched ROI last-corner oracle");
            require(oneFirst[component] == first[i * 3 + component]
                && oneLast[component] == last[i * 3 + component],
                "batched and singleton observation equivalence");
            foreach (y; 0 .. roiHeight)
            foreach (x; 0 .. roiWidth)
            {
                float got;
                require(outputRead.trySample(component, x, y, got),
                    "read every produced pixel");
                const want = reference(
                    component, region.x + x, region.y + y,
                    hasMask, interpretation, refreshed);
                require(got == want,
                    "independent full-pixel oracle on EVERY ROI");
            }
        }
    }

    // Deliberately invalid ROI: failure occurs before any pixel writes,
    // preserving both destination and caller observation buffers.
    enum float sentinel = -12345.0f;
    foreach (component; 0 .. 3)
    foreach (y; 0 .. roiHeight)
    foreach (x; 0 .. roiWidth)
        require(destination.trySetSample(
            component, x, y, sentinel), "set failure sentinel");
    float[3] badFirst, badLast;
    badFirst[] = sentinel;
    badLast[] = sentinel;
    const Region2D[1] outside = [
        Region2D(sourceWidth - 1, sourceHeight - 1, roiWidth, roiHeight)
    ];
    const error = owner.tryMapOrderedInto(
        source, mask, hasMask, binding, interpretation,
        outside[], destination, badFirst[], badLast[]);
    require(error == SourceRoiError.invalidRegion,
        "invalid ROI rejected before destination write");
    foreach (component; 0 .. 3)
    {
        require(badFirst[component] == sentinel
            && badLast[component] == sentinel,
            "ROI failure does not modify observation buffers");
        foreach (y; 0 .. roiHeight)
        foreach (x; 0 .. roiWidth)
        {
            float got;
            require(outputRead.trySample(component, x, y, got)
                && got == sentinel, "ROI failure did not write pixel");
        }
    }

    // Bindings outside the source's 5 planes are rejected before write.
    const badBinding = ColourBinding(
        sourcePlanes, 2, 0, DeclaredColour.unspecified);
    require(owner.tryMapOrderedInto(
        source, mask, hasMask, badBinding, interpretation,
        windows[0 .. 1], destination, badFirst[], badLast[])
        == SourceRoiError.invalidBinding,
        "out-of-range component binding rejected");
}

void runImageRoiConsumer()
{
    auto ids = new ChannelDescriptor[](sourcePlanes);
    auto metadata = new IntrinsicChannel[](sourcePlanes);
    foreach (c; 0 .. sourcePlanes)
    {
        const id = cast(uint)(7000 + c);
        ids[c] = ChannelDescriptor(id);
        metadata[c] = IntrinsicChannel(
            id, "opaque-spectral-band", "unknown", true, 0.5f, -4.0f);
    }
    auto original = ResearchLongLivedMetadataSource.snapshot(
        ids[], metadata[]);
    foreach (c; 0 .. sourcePlanes)
    {
        const id = cast(uint)(7000 + c);
        metadata[c] = IntrinsicChannel(
            id, "updated-band", "unknown", true, 2.0f, 1.0f);
    }
    auto refreshed = ResearchLongLivedMetadataSource.snapshot(
        ids[], metadata[]);
    require(original.metadata[0].scale == 0.5f
        && original.metadata[0].sourceLabel == "opaque-spectral-band"
        && refreshed.metadata[0].scale == 2.0f
        && refreshed.metadata[0].sourceLabel == "updated-band",
        "original immutable generation is retained independently");

    foreach (layout; [Layout.planar, Layout.interleaved])
    foreach (hasMask; [false, true])
    foreach (interpretation;
        [ValueInterpretation.stored, ValueInterpretation.physical])
    {
        exercise(original, layout, hasMask, interpretation, false);
        exercise(refreshed, layout, hasMask, interpretation, true);
    }
    import std.stdio : writeln;
    writeln("M3 ROI consumer PASS: 16 configurations, 48 full-image ROI ",
        "oracles, masked interiors, planar/interleaved, metadata generations, ",
        "zero hot-path GC, fail-closed invalid ROI");
}
