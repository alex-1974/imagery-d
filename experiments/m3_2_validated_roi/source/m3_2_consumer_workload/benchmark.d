module m3_2_consumer_workload.benchmark;

import core.stdc.stdlib : exit, malloc;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln, stderr;

import m1_5_image_view.contract :
    ChannelDescriptor, ImageViewValidationError, tryMakeImageView;
import m3_2_channel_metadata.contract :
    IntrinsicChannel, ColourBinding, DeclaredColour,
    ValueInterpretation, SemanticMapError;
import m3_2_retained_metadata.contract :
    BorrowedSemanticImage, MetadataBorrowError, tryBorrowSemanticImage;
import m3_2_verified_roi.contract :
    ValidatedImmutableImage, VerifiedRoiError,
    tryMakeValidatedImmutableImage;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    WritableRasterView, Region2D, tryAdoptMallocResource,
    tryImportOwnedRaster;

private enum size_t extent = 96;
private enum float scale = 0.5f;
private enum float offset = -4.0f;
private enum Layout : ubyte { planar, interleaved }

private void ensure(bool condition, string reason)
{
    if (!condition)
    {
        stderr.writeln("M3.2.8 FAIL: ", reason);
        exit(1);
    }
}

private float storedValue(size_t c, size_t x, size_t y)
@safe pure nothrow @nogc
{
    return cast(float)(c * 16 + y * 2 + x);
}

private ubyte maskValue(size_t x, size_t y)
@safe pure nothrow @nogc
{
    return (x + y) % 11 == 0 ? 0 : 255;
}

private RasterLease!float makeSamples(
    size_t planes, size_t width, size_t height,
    Layout layout, bool fill
)
{
    const bytes = planes * width * height * float.sizeof;
    auto memory = cast(float*)malloc(bytes);
    ensure(memory !is null, "allocate samples");

    OwnedByteResource resource;
    ensure(tryAdoptMallocResource(memory, bytes, resource), "adopt samples");

    auto descriptors = new PlaneByteLayout[](planes);
    foreach (c; 0 .. planes)
    {
        descriptors[c] = layout == Layout.planar
            ? PlaneByteLayout(c * width * height * float.sizeof,
                cast(ptrdiff_t)(width * float.sizeof),
                cast(ptrdiff_t)float.sizeof)
            : PlaneByteLayout(c * float.sizeof,
                cast(ptrdiff_t)(width * planes * float.sizeof),
                cast(ptrdiff_t)(planes * float.sizeof));
    }

    RasterLease!float lease;
    auto result = tryImportOwnedRaster!float(
        resource, descriptors[], Region2D(0, 0, width, height), lease
    );
    ensure(result.ok, "import samples");
    if (fill)
    {
        bool ok;
        scope auto output = lease.tryWritableView(ok);
        ensure(ok, "source write capability");
        foreach (c; 0 .. planes)
        {
            foreach (y; 0 .. height)
            {
                foreach (x; 0 .. width)
                    ensure(output.trySetSample(c, x, y, storedValue(c, x, y)),
                        "initialize sample");
            }
        }
    }
    return lease;
}

private RasterLease!ubyte makeMask()
{
    const bytes = extent * extent;
    auto memory = cast(ubyte*)malloc(bytes);
    ensure(memory !is null, "allocate validity");
    foreach (y; 0 .. extent)
        foreach (x; 0 .. extent)
            memory[y * extent + x] = maskValue(x, y);

    OwnedByteResource resource;
    ensure(tryAdoptMallocResource(memory, bytes, resource), "adopt validity");

    const PlaneByteLayout[1] layout =
        [PlaneByteLayout(0, cast(ptrdiff_t)extent, 1)];
    RasterLease!ubyte lease;
    auto result = tryImportOwnedRaster!ubyte(
        resource, layout[], Region2D(0, 0, extent, extent), lease
    );
    ensure(result.ok, "import validity");
    return lease;
}

private Region2D window(size_t side, size_t ordinal)
@safe pure nothrow @nogc
{
    const size_t[4] xs = [0, 3, 13, 29];
    const size_t[4] ys = [0, 7, 17, 23];
    const index = ordinal % 4;
    return Region2D(xs[index], ys[index], side, side);
}

private ColourBinding mapping(size_t n)
@safe pure nothrow @nogc
{
    return ColourBinding(n - 1, n - 2, n - 3, DeclaredColour.unspecified);
}

/* The two noinline wrappers perform the **same** pixel mapping operation.
   The only intended difference is how the semantic ROI is constructed.
   Both call mapInto(), which presently still revalidates channel IDs. */
pragma(inline, false)
private bool mapConservative(
    scope BorrowedSemanticImage image,
    Region2D region,
    ColourBinding binding,
    scope WritableRasterView!float destination,
    out float result
)
@safe nothrow @nogc
{
    bool ok;
    auto roi = image.tryRoi(region, ok);
    result = 0.0f;
    if (!ok || roi.mapInto(
        binding, ValueInterpretation.physical, destination
    ) != SemanticMapError.none)
        return false;

    return destination.trySample(0, 0, 0, result);
}

pragma(inline, false)
private bool mapVerified(
    scope ValidatedImmutableImage image,
    Region2D region,
    ColourBinding binding,
    scope WritableRasterView!float destination,
    out float result
)
@safe nothrow @nogc
{
    bool ok;
    auto roi = image.tryRoi(region, ok);
    result = 0.0f;
    if (!ok || roi.mapInto(
        binding, ValueInterpretation.physical, destination
    ) != SemanticMapError.none)
        return false;

    return destination.trySample(0, 0, 0, result);
}

private void checkOracle(
    scope RasterView!float produced,
    size_t n,
    Region2D region,
    bool hasMask
)
{
    // Called with a full output view; source origin comes from region.
    // Check all pixels and every mapped channel, not only a checksum.
    foreach (component; 0 .. 3)
    {
        foreach (y; 0 .. produced.height)
        {
            foreach (x; 0 .. produced.width)
            {
                float got;
                ensure(produced.trySample(component, x, y, got),
                    "read full output");
                const xx = region.x + x;
                const yy = region.y + y;
                const invalid = hasMask && maskValue(xx, yy) == 0;
                const expected = invalid ? 0.0f :
                    storedValue(n - 1 - component, xx, yy) * scale + offset;
                ensure(got == expected, "independent physical/mask oracle");
            }
        }
    }
}

private struct TimedSample
{
    ulong elapsedNs;
    double checksum;
}

private TimedSample measure(
    size_t mode,
    size_t repetitions,
    size_t round,
    size_t side,
    size_t n,
    scope BorrowedSemanticImage conservative,
    scope ValidatedImmutableImage verified,
    scope WritableRasterView!float destination
)
{
    auto binding = mapping(n);
    double checksum;
    StopWatch watch;
    watch.start();
    foreach (i; 0 .. repetitions)
    {
        const region = window(side, i + round);
        float sample;
        const ok = mode == 0
            ? mapConservative(conservative, region, binding, destination, sample)
            : mapVerified(verified, region, binding, destination, sample);
        ensure(ok, "consumer mapping failed");
        checksum += sample;
    }
    watch.stop();
    return TimedSample(cast(ulong)watch.peek.total!"nsecs", checksum);
}

private void runCase(
    size_t n, size_t side, Layout layout, bool hasMask,
    size_t rounds, size_t iterations, size_t warmups
)
{
    auto mutableIds = new ChannelDescriptor[](n);
    auto mutableMeaning = new IntrinsicChannel[](n);
    foreach (c; 0 .. n)
    {
        const id = cast(uint)(9000 + c);
        mutableIds[c] = ChannelDescriptor(id);
        mutableMeaning[c] = IntrinsicChannel(
            id, c % 2 ? "custom-1" : "NIR", "unknown",
            true, scale, offset
        );
    }

    immutable(ChannelDescriptor)[] ids = mutableIds.idup;
    immutable(IntrinsicChannel)[] meanings = mutableMeaning.idup;
    auto samples = makeSamples(n, extent, extent, layout, true);
    RasterLease!ubyte maskLease;
    if (hasMask) maskLease = makeMask();

    auto source = samples.view();
    auto mask = hasMask ? maskLease.view() : RasterView!ubyte.init;

    ImageViewValidationError imageError;
    auto base = tryMakeImageView!float(
        source, ids, mask, hasMask, imageError
    );
    ensure(imageError == ImageViewValidationError.none, "M1 view");

    MetadataBorrowError borrowError;
    auto conservative = tryBorrowSemanticImage(base, meanings, borrowError);
    ensure(borrowError == MetadataBorrowError.none, "M3.2.3 borrow");

    VerifiedRoiError verifiedError;
    auto verified = tryMakeValidatedImmutableImage(
        source, ids, meanings, mask, hasMask, verifiedError
    );
    ensure(verifiedError == VerifiedRoiError.none, "M3.2.6 immutable factory");

    auto outputOld = makeSamples(3, side, side, Layout.planar, false);
    auto outputNew = makeSamples(3, side, side, Layout.planar, false);
    bool writableOk;
    scope auto writableOld = outputOld.tryWritableView(writableOk);
    ensure(writableOk, "old writable output");
    scope auto writableNew = outputNew.tryWritableView(writableOk);
    ensure(writableOk, "new writable output");

    // Independent per-pixel correctness for two different ROI offsets.
    foreach (index; 0 .. 4)
    {
        const roi = window(side, index);
        float a;
        float b;
        ensure(mapConservative(
            conservative, roi, mapping(n), writableOld, a), "old mapping");
        ensure(mapVerified(
            verified, roi, mapping(n), writableNew, b), "verified mapping");
        ensure(a == b, "same sampled result");
        checkOracle(outputOld.view(), n, roi, hasMask);
        checkOracle(outputNew.view(), n, roi, hasMask);
    }

    foreach (warm; 0 .. warmups)
    {
        foreach (mode; 0 .. 2)
        {
            const v = measure(
                mode, iterations, warm, side, n,
                conservative, verified,
                mode == 0 ? writableOld : writableNew);
            // Warm-up is not an acceptance measurement. map* returns a
            // separate boolean status, checked by measure().
        }
    }

    foreach (round; 0 .. rounds)
    {
        // Reverse order every round; preserve identical sample sequence.
        const first = round % 2;
        TimedSample[2] results;
        foreach (slot; 0 .. 2)
        {
            const mode = (first + slot) % 2;
            auto sample = measure(
                mode, iterations, round + warmups,
                side, n, conservative, verified,
                mode == 0 ? writableOld : writableNew);
            results[mode] = sample;
            writeln("consumer_map,", n, ",", side, ",",
                layout == Layout.planar ? "planar" : "interleaved",
                ",", hasMask ? "masked" : "unmasked",
                ",", round, ",", slot, ",",
                mode == 0 ? "revalidated_image" : "verified_immutable_image",
                ",", iterations, ",", sample.elapsedNs, ",",
                sample.checksum);
        }
        ensure(results[0].checksum == results[1].checksum,
            "same checksum in paired processing round");
    }
}

private void preparation(size_t n, size_t iterations)
{
    auto inputs = new ChannelDescriptor[](n);
    auto meaning = new IntrinsicChannel[](n);
    foreach (c; 0 .. n)
    {
        const id = cast(uint)(9000 + c);
        inputs[c] = ChannelDescriptor(id);
        meaning[c] = IntrinsicChannel(
            id, "NIR", "unknown", true, scale, offset
        );
    }

    immutable(ChannelDescriptor)[] ids = inputs.idup;
    immutable(IntrinsicChannel)[] meanings = meaning.idup;
    auto lease = makeSamples(n, extent, extent, Layout.planar, false);
    auto source = lease.view();

    StopWatch watch;
    size_t checksum;

    // Borrow-only reference setup: caller retains mutable descriptors.
    // No snapshots; identities are checked each time.
    watch.start();
    foreach (i; 0 .. iterations)
    {
        ImageViewValidationError baseErr;
        auto image = tryMakeImageView!float(
            source, inputs[], RasterView!ubyte.init, false, baseErr
        );
        ensure(baseErr == ImageViewValidationError.none,
            "borrow-only M1 preparation");
        MetadataBorrowError borrowErr;
        auto borrow = tryBorrowSemanticImage(
            image, meaning[], borrowErr
        );
        ensure(borrowErr == MetadataBorrowError.none,
            "borrow-only semantic preparation");
        checksum += borrow.intrinsic.length;
    }
    watch.stop();
    writeln("consumer_setup,", n, ",caller_borrow_validate,",
        iterations, ",", watch.peek.total!"nsecs", ",", checksum);

    watch.reset();
    checksum = 0;

    // Already immutable: validation only, no allocation in the factory.
    watch.start();
    foreach (i; 0 .. iterations)
    {
        VerifiedRoiError err;
        auto view = tryMakeValidatedImmutableImage(
            source, ids, meanings, RasterView!ubyte.init,
            false, err);
        ensure(err == VerifiedRoiError.none, "preparation validation");
        checksum += view.intrinsic.length;
    }
    watch.stop();
    writeln("consumer_setup,", n, ",already_immutable_validate,",
        iterations, ",", watch.peek.total!"nsecs", ",", checksum);

    // Borrowed mutable input: two .idup copies plus validation. The
    // labels are immutable strings, not a deep copy of pointed-to text.
    watch.reset();
    checksum = 0;
    watch.start();
    foreach (i; 0 .. iterations)
    {
        immutable(ChannelDescriptor)[] copyIds = inputs.idup;
        immutable(IntrinsicChannel)[] copyMeaning = meaning.idup;
        VerifiedRoiError err;
        auto view = tryMakeValidatedImmutableImage(
            source, copyIds, copyMeaning, RasterView!ubyte.init,
            false, err);
        ensure(err == VerifiedRoiError.none, "preparation snapshot");
        checksum += view.intrinsic.length;
    }
    watch.stop();
    writeln("consumer_setup,", n, ",snapshot_and_validate,",
        iterations, ",", watch.peek.total!"nsecs", ",", checksum);
}

/++
    Run source-independent, actual mapped-pixel ROI workload. Caller must
    interpret hosted runner timings as functional smoke evidence only.
+/
void runConsumerWorkload(
    bool smoke, size_t iterations, size_t rounds, size_t warmups
)
{
    ensure(iterations > 0 && rounds > 0, "benchmark iterations and rounds");
    writeln("consumer_schema,channels,roi_side,layout,mask,round,slot,mode,iterations,elapsed_ns,checksum");
    foreach (n; smoke ? [cast(size_t)3, 17] :
        [cast(size_t)3, 17, 64, 256])
    {
        preparation(n, smoke ? 4 : 100);
        foreach (side; smoke ? [cast(size_t)8, 32] :
            [cast(size_t)8, 32, 64])
        {
            runCase(n, side, Layout.planar, true,
                rounds, iterations, warmups);
            runCase(n, side, Layout.interleaved, false,
                rounds, iterations, warmups);
        }
    }
    writeln("M3.2.8 PASS: consumer mapping, mask and metadata preparation");
}
