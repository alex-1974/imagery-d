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
    ValidatedImmutableImage, VerifiedRoiError, PreparedSemanticMap,
    tryMakeValidatedImmutableImage, tryPrepareSemanticMap;
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

pragma(inline, false)
private bool mapPrepared(
    scope PreparedSemanticMap plan,
    Region2D region,
    scope WritableRasterView!float destination,
    out float result
)
@safe nothrow @nogc
{
    result = 0.0f;
    bool ok;
    auto child = plan.tryRoi(region, ok);
    if (!ok || child.mapInto(destination) != SemanticMapError.none)
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
    scope PreparedSemanticMap prepared,
    scope WritableRasterView!float destination
)
{
    auto binding = mapping(n);
    double checksum = 0.0;
    StopWatch watch;
    watch.start();
    foreach (i; 0 .. repetitions)
    {
        const region = window(side, i + round);
        float sample;
        bool ok;
        if (mode == 0)
            ok = mapConservative(conservative, region, binding, destination, sample);
        else if (mode == 1)
            ok = mapVerified(verified, region, binding, destination, sample);
        else
            ok = mapPrepared(prepared, region, destination, sample);
        ensure(ok, "three-way consumer mapping failure");
        checksum += sample;
    }
    watch.stop();
    return TimedSample(cast(ulong)watch.peek.total!"nsecs", checksum);
}

private void runCase(
    size_t n, size_t side, Layout layout, bool hasMask,
    size_t rounds, size_t iterations, size_t warmups,
    bool withPrepared
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

    SemanticMapError preparationError;
    auto prepared = tryPrepareSemanticMap(
        verified, mapping(n), ValueInterpretation.physical, preparationError
    );
    ensure(preparationError == SemanticMapError.none
        && prepared.isPrepared, "M3.2.9 prepared binding");

    auto outputOld = makeSamples(3, side, side, Layout.planar, false);
    auto outputNew = makeSamples(3, side, side, Layout.planar, false);
    auto outputPrepared = makeSamples(3, side, side, Layout.planar, false);
    bool writableOk;
    scope auto writableOld = outputOld.tryWritableView(writableOk);
    ensure(writableOk, "old writable output");
    scope auto writableNew = outputNew.tryWritableView(writableOk);
    ensure(writableOk, "new writable output");
    scope auto writablePrepared = outputPrepared.tryWritableView(writableOk);
    ensure(writableOk, "prepared writable output");

    // Exact oracle on every pixel/plane before any timings.
    foreach (index; 0 .. 4)
    {
        const roi = window(side, index);
        float a, b;
        ensure(mapConservative(conservative, roi, mapping(n), writableOld, a),
            "original mapping oracle");
        ensure(mapVerified(verified, roi, mapping(n), writableNew, b),
            "immutable mapping oracle");
        ensure(a == b, "original and immutable mapping equality");
        checkOracle(outputOld.view(), n, roi, hasMask);
        checkOracle(outputNew.view(), n, roi, hasMask);
        if (withPrepared)
        {
            float p;
            ensure(mapPrepared(prepared, roi, writablePrepared, p),
                "prepared mapping oracle");
            ensure(p == a, "prepared sample equality");
            checkOracle(outputPrepared.view(), n, roi, hasMask);
        }
    }

    foreach (warm; 0 .. warmups)
    foreach (mode; 0 .. (withPrepared ? 3 : 2))
    {
        auto warmed = measure(
            mode, iterations, warm, side, n,
            conservative, verified, prepared,
            mode == 0 ? writableOld
                : mode == 1 ? writableNew : writablePrepared);
        ensure(warmed.checksum == warmed.checksum, "valid warmup");
    }

    foreach (round; 0 .. rounds)
    {
        TimedSample[3] samplesByMode;
        foreach (slot; 0 .. (withPrepared ? 3 : 2))
        {
            const mode = !withPrepared
                ? (round + slot) % 2
                : (round % 2 == 0
                    ? (round / 2 + slot) % 3
                    : (round / 2 + 3 - slot) % 3);
            auto sample = measure(
                mode, iterations, round + warmups, side, n,
                conservative, verified, prepared,
                mode == 0 ? writableOld
                    : mode == 1 ? writableNew : writablePrepared
            );
            samplesByMode[mode] = sample;
            writeln(withPrepared ? "prepared_map," : "consumer_map,",
                n, ",", side, ",",
                layout == Layout.planar ? "planar" : "interleaved",
                ",", hasMask ? "masked" : "unmasked",
                ",", round, ",", slot, ",",
                mode == 0 ? "revalidated_image"
                    : mode == 1 ? "verified_immutable_image"
                    : "prepared_semantic_map",
                ",", iterations, ",", sample.elapsedNs, ",",
                sample.checksum);
        }
        ensure(samplesByMode[0].checksum == samplesByMode[1].checksum,
            "two mapped variants have equal checksums");
        if (withPrepared)
            ensure(samplesByMode[0].checksum == samplesByMode[2].checksum,
                "three mapped variants have equal checksums");
    }
}

private void preparation(size_t n, size_t iterations, bool withPrepared)
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

    if (withPrepared)
    {
        // This stage assumes immutable metadata + its verified view exist.
        // It measures explicit three-channel binding/calibration preparation
        // separately from snapshot and complete image factory construction.
        VerifiedRoiError viewError;
        auto verified = tryMakeValidatedImmutableImage(
            source, ids, meanings, RasterView!ubyte.init, false, viewError
        );
        ensure(viewError == VerifiedRoiError.none, "setup source preflight");
        watch.reset();
        checksum = 0;
        watch.start();
        foreach (i; 0 .. iterations)
        {
            const bound = i % 3 == 0 ? mapping(n)
                : i % 3 == 1
                    ? ColourBinding(n - 2, n - 3, n - 1,
                        DeclaredColour.unspecified)
                    : ColourBinding(n - 3, n - 1, n - 2,
                        DeclaredColour.unspecified);
            SemanticMapError bindError;
            auto prepared = tryPrepareSemanticMap(
                verified, bound, ValueInterpretation.physical, bindError
            );
            ensure(bindError == SemanticMapError.none && prepared.isPrepared,
                "prepare selected-channel calibration");
            checksum += prepared.isPrepared ? i + 1 : 0;
        }
        watch.stop();
        // M3.2.12: identity verification was completed once in the
        // M3.2.6 image factory, in the very same module that owns the
        // private executor; this measures ONLY 3-band scalar binding.
        // The consumer uses three rotating explicit bindings to make
        // hoisting less trivial, but a stronger anti-hoist setup probe
        // is still required before setting release thresholds.
        writeln("consumer_setup,", n,
            ",unified_verified_binding_only,",
            iterations, ",", watch.peek.total!"nsecs", ",", checksum);
    }
}

/++
    Run source-independent, actual mapped-pixel ROI workload. Caller must
    interpret hosted runner timings as functional smoke evidence only.
+/
void runConsumerWorkload(
    bool smoke, size_t iterations, size_t rounds, size_t warmups,
    bool withPrepared = false
)
{
    ensure(iterations > 0 && rounds > 0, "benchmark iterations and rounds");
    writeln(withPrepared
        ? "prepared_schema,channels,roi_side,layout,mask,round,slot,mode,iterations,elapsed_ns,checksum"
        : "consumer_schema,channels,roi_side,layout,mask,round,slot,mode,iterations,elapsed_ns,checksum");

    foreach (n; smoke ? [cast(size_t)3, 17] :
        [cast(size_t)3, 17, 64, 256])
    {
        preparation(n, smoke ? 4 : 100, withPrepared);
        foreach (side; smoke ? [cast(size_t)8, 32] :
            [cast(size_t)8, 32, 64])
        {
            runCase(n, side, Layout.planar, true,
                rounds, iterations, warmups, withPrepared);
            runCase(n, side, Layout.interleaved, false,
                rounds, iterations, warmups, withPrepared);
        }
    }
    writeln(withPrepared
        ? "M3.2.9 PASS: three-way prepared mapping and independent oracle"
        : "M3.2.8 PASS: consumer mapping, mask and metadata preparation");
}

/++
    M3.2.13 preparation challenge, NOT an end-to-end image benchmark.
    Runtime-selected, independently different immutable descriptor sets
    and noninline wrappers resist the easiest identical-input hoisting.
    Exact checksum checks use a separate deterministic oracle outside
    timing. Small values still require machine-code review before claims.
+/
pragma(inline, false)
private size_t challengeBorrow(
    scope RasterView!float source,
    scope ChannelDescriptor[] ids, scope IntrinsicChannel[] meta
)
{
    ImageViewValidationError err;
    auto image = tryMakeImageView!float(
        source, ids, RasterView!ubyte.init, false, err);
    if (err != ImageViewValidationError.none) return 0;
    MetadataBorrowError borrowErr;
    auto borrow = tryBorrowSemanticImage(image, meta, borrowErr);
    return borrowErr == MetadataBorrowError.none
        ? borrow.intrinsic[0].semanticId : 0;
}

pragma(inline, false)
private size_t challengeVerify(
    scope RasterView!float source,
    scope immutable(ChannelDescriptor)[] ids,
    scope immutable(IntrinsicChannel)[] meta
)
{
    VerifiedRoiError err;
    auto image = tryMakeValidatedImmutableImage(
        source, ids, meta, RasterView!ubyte.init, false, err);
    return err == VerifiedRoiError.none ? image.intrinsic[0].semanticId : 0;
}

pragma(inline, false)
private size_t challengeBind(
    scope ValidatedImmutableImage image, ColourBinding binding
)
{
    SemanticMapError err;
    auto plan = tryPrepareSemanticMap(
        image, binding, ValueInterpretation.physical, err);
    return err == SemanticMapError.none && plan.isPrepared ? 1 : 0;
}

pragma(inline, false)
private size_t challengeSnapshot(
    scope RasterView!float source,
    scope ChannelDescriptor[] ids, scope IntrinsicChannel[] meta
)
{
    immutable(ChannelDescriptor)[] frozenIds = ids.idup;
    immutable(IntrinsicChannel)[] frozenMeta = meta.idup;
    return challengeVerify(source, frozenIds, frozenMeta);
}

private uint challengeNext(uint v)
@safe pure nothrow @nogc
{
    return v * 1664525u + 1013904223u;
}

private ColourBinding challengeThree(size_t n, size_t select)
@safe pure nothrow @nogc
{
    if (select % 3 == 0)
        return ColourBinding(n - 1, n - 2, n - 3, DeclaredColour.unspecified);
    if (select % 3 == 1)
        return ColourBinding(n - 2, n - 3, n - 1, DeclaredColour.unspecified);
    return ColourBinding(n - 3, n - 1, n - 2, DeclaredColour.unspecified);
}

private size_t challengeExpected(size_t mode, size_t loops, uint first)
@safe pure nothrow @nogc
{
    size_t sum;
    uint seed = first;
    foreach (i; 0 .. loops)
    {
        seed = challengeNext(seed);
        const selection = cast(size_t)(seed >> 24) % 8;
        sum += mode == 2 ? 1 : 24000 + selection * 1024;
    }
    return sum;
}

/++
    Complementary consumer oracle, not a setup latency measurement.

    All four setup routes must produce *usable* calibrated three-band
    output. We inspect every lane of a 1x1 mapped pixel after each route,
    covering all eight runtime metadata sets and all three bindings.
    In particular, the Prepared path must not be reduced to success=true.
+/
private void challengeCheckObservedPixel(
    scope RasterView!float output, size_t n, size_t choice, size_t permutation
)
{
    size_t[3] selected;
    if (permutation == 0)
        selected = [n - 1, n - 2, n - 3];
    else if (permutation == 1)
        selected = [n - 2, n - 3, n - 1];
    else
        selected = [n - 3, n - 1, n - 2];

    const calScale = scale + cast(float)choice * 0.0625f;
    const calOffset = offset - cast(float)choice;
    foreach (component; 0 .. 3)
    {
        float actual;
        ensure(output.trySample(component, 0, 0, actual),
            "observed prepared output sample");
        const expected = storedValue(selected[component], 0, 0)
            * calScale + calOffset;
        ensure(actual == expected,
            "independent selected-channel physical-value oracle");
    }
}

void runPreparationObservedSmoke()
{
    // This is intentionally outside the setup-only timer. Real pixel
    // consumption proves that all returned views and prepared plans are
    // usable, but combines metadata and a common checked pixel kernel.
    foreach (n; [cast(size_t)3, 17, 64, 256])
    {
        auto lease = makeSamples(n, extent, extent, Layout.planar, true);
        auto source = lease.view();
        auto output = makeSamples(3, 1, 1, Layout.planar, false);
        bool writableOk;
        scope auto writable = output.tryWritableView(writableOk);
        ensure(writableOk, "observed destination writable");
        foreach (choice; 0 .. 8)
        {
            auto ids = new ChannelDescriptor[](n);
            auto meta = new IntrinsicChannel[](n);
            foreach (band; 0 .. n)
            {
                const id = cast(uint)(24000 + choice * 1024 + band);
                ids[band] = ChannelDescriptor(id);
                meta[band] = IntrinsicChannel(
                    id, "NIR", "unknown", true,
                    scale + cast(float)choice * 0.0625f,
                    offset - cast(float)choice);
            }

            ImageViewValidationError imageError;
            auto base = tryMakeImageView!float(
                source, ids, RasterView!ubyte.init, false, imageError);
            ensure(imageError == ImageViewValidationError.none,
                "observed borrow view");
            MetadataBorrowError borrowError;
            auto borrowed = tryBorrowSemanticImage(base, meta, borrowError);
            ensure(borrowError == MetadataBorrowError.none,
                "observed borrow metadata");

            immutable(ChannelDescriptor)[] stableIds = ids.idup;
            immutable(IntrinsicChannel)[] stableMeta = meta.idup;
            VerifiedRoiError verifiedError;
            auto verified = tryMakeValidatedImmutableImage(
                source, stableIds, stableMeta, RasterView!ubyte.init,
                false, verifiedError);
            ensure(verifiedError == VerifiedRoiError.none,
                "observed immutable factory");

            // Separate immutable copies exercise the snapshot route.
            immutable(ChannelDescriptor)[] snapIds = ids.idup;
            immutable(IntrinsicChannel)[] snapMeta = meta.idup;
            VerifiedRoiError snapshotError;
            auto snapshot = tryMakeValidatedImmutableImage(
                source, snapIds, snapMeta, RasterView!ubyte.init,
                false, snapshotError);
            ensure(snapshotError == VerifiedRoiError.none,
                "observed snapshot factory");

            const roi = Region2D(0, 0, 1, 1);
            foreach (permutation; 0 .. 3)
            {
                auto binding = challengeThree(n, permutation);
                float observed;
                ensure(mapConservative(borrowed, roi, binding,
                    writable, observed), "observed borrowed map");
                challengeCheckObservedPixel(output.view(), n, choice, permutation);

                ensure(mapVerified(verified, roi, binding,
                    writable, observed), "observed verified map");
                challengeCheckObservedPixel(output.view(), n, choice, permutation);

                SemanticMapError prepareError;
                auto prepared = tryPrepareSemanticMap(
                    verified, binding, ValueInterpretation.physical, prepareError);
                ensure(prepareError == SemanticMapError.none
                    && prepared.isPrepared, "observed prepared binding");
                ensure(mapPrepared(prepared, roi, writable, observed),
                    "observed prepared map");
                challengeCheckObservedPixel(output.view(), n, choice, permutation);

                ensure(mapVerified(snapshot, roi, binding,
                    writable, observed), "observed snapshot map");
                challengeCheckObservedPixel(output.view(), n, choice, permutation);
            }
        }
    }
    writeln("M3.2.13 PASS: observed four-route calibrated pixel oracle");
}

void runPreparationChallenge(
    bool smoke, size_t loops, size_t rounds, size_t warmups
)
{
    ensure(loops > 0 && rounds > 0, "setup challenge iterations");
    writeln("setup_challenge_schema,channels,round,slot,mode,iterations,elapsed_ns,checksum,expected");

    foreach (n; smoke ? [cast(size_t)3, 64] :
        [cast(size_t)3, 17, 64, 256])
    {
        auto mutableIds = new ChannelDescriptor[][](8);
        auto mutableMeta = new IntrinsicChannel[][](8);
        auto stableIds = new immutable(ChannelDescriptor)[][](8);
        auto stableMeta = new immutable(IntrinsicChannel)[][](8);

        foreach (choice; 0 .. 8)
        {
            auto ids = new ChannelDescriptor[](n);
            auto meanings = new IntrinsicChannel[](n);
            foreach (band; 0 .. n)
            {
                const id = cast(uint)(24000 + choice * 1024 + band);
                ids[band] = ChannelDescriptor(id);
                meanings[band] = IntrinsicChannel(
                    id, "NIR", "unknown", true,
                    scale + cast(float)choice * 0.0625f,
                    offset - cast(float)choice);
            }
            mutableIds[choice] = ids;
            mutableMeta[choice] = meanings;
            stableIds[choice] = ids.idup;
            stableMeta[choice] = meanings.idup;
        }

        auto lease = makeSamples(n, extent, extent, Layout.planar, false);
        auto source = lease.view();
        VerifiedRoiError verifiedError;
        auto verified = tryMakeValidatedImmutableImage(
            source, stableIds[0], stableMeta[0],
            RasterView!ubyte.init, false, verifiedError);
        ensure(verifiedError == VerifiedRoiError.none,
            "setup challenge verified input");

        SemanticMapError invalidError;
        auto bad = tryPrepareSemanticMap(
            verified, ColourBinding(0, 0, 2, DeclaredColour.unspecified),
            ValueInterpretation.physical, invalidError);
        ensure(invalidError == SemanticMapError.invalidBinding
            && !bad.isPrepared, "challenge invalid binding control");

        // Both warm-ups and timed rounds use the same four routes.
        foreach (round; 0 .. rounds + warmups)
        {
            const first = cast(uint)(0x6a09e667u
                + cast(uint)round * 2654435761u);
            foreach (slot; 0 .. 4)
            {
                const mode = (round + slot) % 4;
                uint seed = first;
                size_t checksum;
                StopWatch watch;
                watch.start();
                foreach (i; 0 .. loops)
                {
                    seed = challengeNext(seed);
                    const k = cast(size_t)(seed >> 24) % 8;
                    if (mode == 0)
                        checksum += challengeBorrow(
                            source, mutableIds[k], mutableMeta[k]);
                    else if (mode == 1)
                        checksum += challengeVerify(
                            source, stableIds[k], stableMeta[k]);
                    else if (mode == 2)
                        checksum += challengeBind(
                            verified, challengeThree(n, k));
                    else
                        checksum += challengeSnapshot(
                            source, mutableIds[k], mutableMeta[k]);
                }
                watch.stop();
                const expected = challengeExpected(mode, loops, first);
                ensure(checksum == expected,
                    "anti-hoist preparation independent checksum");
                if (round < warmups) continue;
                const names = [
                    "borrow_validate", "immutable_verify",
                    "unified_binding_only", "snapshot_and_verify"
                ];
                writeln("setup_challenge,", n, ",", round - warmups,
                    ",", slot, ",", names[mode], ",", loops, ",",
                    watch.peek.total!"nsecs", ",", checksum, ",", expected);
            }
        }
    }
    writeln("M3.2.13 PASS: runtime-selected preparation oracle");
}

/++
    M3.2.14 experimental consumer reuse benchmark.

    This measures actual observable pixel operations rather than a
    checksum-only preparation. The input policies intentionally differ:
      immutable: metadata already immutable for both alternatives;
      mutable: one-shot borrows caller-mutable metadata; Prepared takes
               two independent immutable snapshots before verification.
    Therefore the mutable comparison is a consumer policy trade-off,
    not two equivalent ownership guarantees.

    setup_ns, map_ns and total_ns are separately timed *per batch*.
    Total includes phase boundaries, not just the arithmetic sum of
    the two phases. Prepared construction occurs once per batch;
    conservative mapInto revalidates IDs for every mapped ROI.
+/
private struct ReuseBatch
{
    ulong setupNs;
    ulong mappingNs;
    ulong totalNs;
    double checksum;
}

private size_t reuseSelected(size_t n, size_t permutation, size_t component)
@safe pure nothrow @nogc
{
    // Explicit ordering: no assumption that labels dictate channel order.
    if (permutation == 0)
        return n - 1 - component;
    if (permutation == 1)
        return component == 0 ? n - 2
            : component == 1 ? n - 3 : n - 1;
    return component == 0 ? n - 3
        : component == 1 ? n - 1 : n - 2;
}

private void reuseFullPixelOracle(
    scope RasterView!float produced,
    size_t n, size_t choice, size_t permutation,
    Region2D region, bool hasMask
)
{
    const calScale = scale + cast(float)choice * 0.0625f;
    const calOffset = offset - cast(float)choice;
    foreach (component; 0 .. 3)
    foreach (y; 0 .. produced.height)
    foreach (x; 0 .. produced.width)
    {
        float actual;
        ensure(produced.trySample(component, x, y, actual),
            "reuse oracle reads every pixel");
        const xx = region.x + x;
        const yy = region.y + y;
        const expected = hasMask && maskValue(xx, yy) == 0
            ? 0.0f
            : storedValue(reuseSelected(n, permutation, component),
                xx, yy) * calScale + calOffset;
        ensure(actual == expected,
            "independent full-pixel reuse/orientation/calibration oracle");
    }
}

private double reuseExpectedSampleSum(
    size_t n, size_t choice, size_t permutation,
    size_t side, size_t count, size_t absoluteRound, bool hasMask
)
@safe pure nothrow @nogc
{
    const calScale = scale + cast(float)choice * 0.0625f;
    const calOffset = offset - cast(float)choice;
    double total = 0.0;
    foreach (i; 0 .. count)
    {
        const region = window(side, i + absoluteRound);
        const value = hasMask && maskValue(region.x, region.y) == 0
            ? 0.0f
            : storedValue(reuseSelected(n, permutation, 0),
                region.x, region.y) * calScale + calOffset;
        total += value;
    }
    return total;
}

pragma(inline, false)
private ReuseBatch measureReuseBatch(
    bool usePrepared,
    bool callerMutable,
    size_t n, size_t side, size_t reuseCount, size_t absoluteRound,
    size_t permutation,
    scope RasterView!float source,
    scope RasterView!ubyte mask,
    bool hasMask,
    scope ChannelDescriptor[] mutableIds,
    scope IntrinsicChannel[] mutableMetadata,
    scope immutable(ChannelDescriptor)[] stableIds,
    scope immutable(IntrinsicChannel)[] stableMetadata,
    scope WritableRasterView!float destination
)
{
    StopWatch totalWatch, setupWatch, mappingWatch;
    const binding = challengeThree(n, permutation);
    double checksum = 0.0;
    totalWatch.start();

    if (usePrepared)
    {
        setupWatch.start();
        immutable(ChannelDescriptor)[] ids = callerMutable
            ? mutableIds.idup : stableIds;
        immutable(IntrinsicChannel)[] metadata = callerMutable
            ? mutableMetadata.idup : stableMetadata;
        VerifiedRoiError verifyError;
        auto verified = tryMakeValidatedImmutableImage(
            source, ids, metadata, mask, hasMask, verifyError);
        ensure(verifyError == VerifiedRoiError.none,
            "reuse prepared verified factory");
        SemanticMapError bindingError;
        auto prepared = tryPrepareSemanticMap(
            verified, binding, ValueInterpretation.physical, bindingError);
        ensure(bindingError == SemanticMapError.none && prepared.isPrepared,
            "reuse prepared binding");
        setupWatch.stop();

        mappingWatch.start();
        foreach (i; 0 .. reuseCount)
        {
            float sample;
            ensure(mapPrepared(
                prepared, window(side, i + absoluteRound),
                destination, sample), "reuse prepared map");
            checksum += sample;
        }
        mappingWatch.stop();
    }
    else if (callerMutable)
    {
        setupWatch.start();
        ImageViewValidationError viewError;
        auto image = tryMakeImageView!float(
            source, mutableIds, mask, hasMask, viewError);
        ensure(viewError == ImageViewValidationError.none,
            "reuse borrowed mutable image");
        MetadataBorrowError borrowError;
        auto borrowed = tryBorrowSemanticImage(
            image, mutableMetadata, borrowError);
        ensure(borrowError == MetadataBorrowError.none,
            "reuse borrowed mutable metadata");
        setupWatch.stop();

        mappingWatch.start();
        foreach (i; 0 .. reuseCount)
        {
            float sample;
            ensure(mapConservative(
                borrowed, window(side, i + absoluteRound), binding,
                destination, sample), "reuse mutable one-shot map");
            checksum += sample;
        }
        mappingWatch.stop();
    }
    else
    {
        setupWatch.start();
        ImageViewValidationError viewError;
        auto image = tryMakeImageView!float(
            source, stableIds, mask, hasMask, viewError);
        ensure(viewError == ImageViewValidationError.none,
            "reuse borrowed immutable image");
        MetadataBorrowError borrowError;
        auto borrowed = tryBorrowSemanticImage(
            image, stableMetadata, borrowError);
        ensure(borrowError == MetadataBorrowError.none,
            "reuse borrowed immutable metadata");
        setupWatch.stop();

        mappingWatch.start();
        foreach (i; 0 .. reuseCount)
        {
            float sample;
            ensure(mapConservative(
                borrowed, window(side, i + absoluteRound), binding,
                destination, sample), "reuse immutable one-shot map");
            checksum += sample;
        }
        mappingWatch.stop();
    }

    totalWatch.stop();
    return ReuseBatch(
        cast(ulong)setupWatch.peek.total!"nsecs",
        cast(ulong)mappingWatch.peek.total!"nsecs",
        cast(ulong)totalWatch.peek.total!"nsecs",
        checksum);
}


/++
    Research-only GC and Linux rusage delta for *one* measured path.

    Both endpoints are read outside the measured batch and before the
    subsequent full-pixel oracle, so observation calls are excluded from
    the reported setup/map/total StopWatches. They can still perturb
    cache/GC/allocator state between batches: this mode is NOT directly
    comparable to prior uninstrumented M3.2.14 timing.
+/
private struct ReuseRuntimeDelta
{
    ulong allocatedBytes;
    size_t collectionCycles;
    long gcPauseNs;
    long minorFaults;
    long majorFaults;
}

private ReuseRuntimeDelta reuseRuntimeDifference(
    GC.Stats before, GC.ProfileStats beforeProfile,
    GC.Stats after, GC.ProfileStats afterProfile,
    rusage beforeUsage, rusage afterUsage
)
{
    ensure(after.allocatedInCurrentThread >= before.allocatedInCurrentThread,
        "GC allocated-byte counter monotonic");
    ensure(afterProfile.numCollections >= beforeProfile.numCollections,
        "GC collection counter monotonic");
    const pause = (afterProfile.totalPauseTime
        - beforeProfile.totalPauseTime).total!"nsecs";
    ensure(pause >= 0 && afterUsage.ru_minflt >= beforeUsage.ru_minflt
        && afterUsage.ru_majflt >= beforeUsage.ru_majflt,
        "GC pause and Linux page-fault counters monotonic");
    return ReuseRuntimeDelta(
        after.allocatedInCurrentThread - before.allocatedInCurrentThread,
        afterProfile.numCollections - beforeProfile.numCollections,
        cast(long)pause,
        cast(long)(afterUsage.ru_minflt - beforeUsage.ru_minflt),
        cast(long)(afterUsage.ru_majflt - beforeUsage.ru_majflt));
}

/++
    Deterministically counterbalance the *outer* order of all 192 cases
    across independent processes while retaining pairwise fair inputs
    and the existing 2-slot alternating method order inside each case.

    orderSeed must be the run index passed and captured by the XPS runner.
    The uninstrumented entry remains the original M3.2.14 procedure.
+/
private void runConsumerReuseOrdered(
    bool smoke, size_t rounds, size_t warmups,
    size_t orderSeed, bool instrument
)
{
    import core.memory : GC;
    import core.sys.posix.sys.resource : rusage, getrusage, RUSAGE_SELF;

    ensure(rounds > 0 && rounds % 2 == 0,
        "reuse requires positive even rounds to balance paired slots");
    const size_t[] channelCases = smoke ? [cast(size_t)3, 17] :
        [cast(size_t)3, 17, 64, 256];
    const size_t[] sideCases = smoke ? [cast(size_t)8] :
        [cast(size_t)8, 32];
    const size_t[6] reuseCases = [1, 2, 4, 8, 16, 32];
    if (instrument)
        writeln("reuse_gc_schema,case_rank,order_seed,channels,roi_side,layout,mask,policy,reuse,round,slot,mode,setup_ns,map_ns,total_ns,checksum,expected,gc_alloc_bytes,gc_collections,gc_pause_ns,minor_faults,major_faults");
    else
        writeln("reuse_schema,channels,roi_side,layout,mask,policy,reuse,round,slot,mode,setup_ns,map_ns,total_ns,checksum,expected");

    foreach (nRank; 0 .. channelCases.length)
    {
        const n = channelCases[instrument
            ? (nRank + orderSeed) % channelCases.length : nRank];
        foreach (sideRank; 0 .. sideCases.length)
        {
            const side = sideCases[instrument
                ? (sideRank + orderSeed / 2) % sideCases.length : sideRank];
            foreach (layoutRank; 0 .. 2)
            {
                const layout = ((instrument
                    ? (layoutRank + orderSeed) % 2 : layoutRank) == 0)
                    ? Layout.planar : Layout.interleaved;
                const hasMask = layout == Layout.planar;

                auto sourceLease = makeSamples(n, extent, extent, layout, true);
                RasterLease!ubyte maskLease;
                if (hasMask)
                    maskLease = makeMask();
                auto source = sourceLease.view();
                auto mask = hasMask ? maskLease.view() : RasterView!ubyte.init;
                auto outputOnce = makeSamples(3, side, side, Layout.planar, false);
                auto outputPrepared = makeSamples(3, side, side, Layout.planar, false);
                bool writableOk;
                scope auto onceOutput = outputOnce.tryWritableView(writableOk);
                ensure(writableOk, "reuse one-shot writable destination");
                scope auto preparedOutput = outputPrepared.tryWritableView(writableOk);
                ensure(writableOk, "reuse prepared writable destination");

                auto idsByChoice = new ChannelDescriptor[][](8);
                auto metadataByChoice = new IntrinsicChannel[][](8);
                auto stableIdsByChoice = new immutable(ChannelDescriptor)[][](8);
                auto stableMetaByChoice = new immutable(IntrinsicChannel)[][](8);
                foreach (choice; 0 .. 8)
                {
                    auto ids = new ChannelDescriptor[](n);
                    auto meta = new IntrinsicChannel[](n);
                    foreach (band; 0 .. n)
                    {
                        const id = cast(uint)(24000 + choice * 1024 + band);
                        ids[band] = ChannelDescriptor(id);
                        meta[band] = IntrinsicChannel(
                            id, "NIR", "unknown", true,
                            scale + cast(float)choice * 0.0625f,
                            offset - cast(float)choice);
                    }
                    idsByChoice[choice] = ids;
                    metadataByChoice[choice] = meta;
                    stableIdsByChoice[choice] = ids.idup;
                    stableMetaByChoice[choice] = meta.idup;
                }

                foreach (caseSlot; 0 .. 12)
                {
                    // Multiplier 5 is coprime with 12: every policy/reuse
                    // combination occurs once, but in a different order.
                    const caseIndex = instrument
                        ? (caseSlot * 5 + orderSeed * 7) % 12 : caseSlot;
                    const policy = caseIndex / 6;
                    const reuseCount = reuseCases[caseIndex % 6];
                    const caseRank = ((nRank * sideCases.length
                        + sideRank) * 2 + layoutRank) * 12 + caseSlot;
                    foreach (round; 0 .. rounds + warmups)
                    {
                        // Identical metadata/permutation and ROI input per
                        // matched pair regardless of the case ordering.
                        const choice = (round * 5 + reuseCount) % 8;
                        const permutation = (round + reuseCount) % 3;
                        const expected = reuseExpectedSampleSum(
                            n, choice, permutation, side, reuseCount,
                            round, hasMask);
                        ReuseBatch[2] batches;
                        ReuseRuntimeDelta[2] runtimeDeltas;

                        foreach (slot; 0 .. 2)
                        {
                            const mode = (round + slot) % 2;
                            if (instrument)
                            {
                                rusage beforeUsage, afterUsage;
                                ensure(getrusage(RUSAGE_SELF, &beforeUsage) == 0,
                                    "read Linux usage before measured batch");
                                const gcBefore = GC.stats();
                                const profileBefore = GC.profileStats();

                                batches[mode] = measureReuseBatch(
                                    mode == 1, policy == 1, n, side, reuseCount,
                                    round, permutation, source, mask, hasMask,
                                    idsByChoice[choice], metadataByChoice[choice],
                                    stableIdsByChoice[choice],
                                    stableMetaByChoice[choice],
                                    mode == 0 ? onceOutput : preparedOutput
                                );

                                const gcAfter = GC.stats();
                                const profileAfter = GC.profileStats();
                                ensure(getrusage(RUSAGE_SELF, &afterUsage) == 0,
                                    "read Linux usage after measured batch");
                                runtimeDeltas[mode] = reuseRuntimeDifference(
                                    gcBefore, profileBefore, gcAfter, profileAfter,
                                    beforeUsage, afterUsage);
                            }
                            else
                                batches[mode] = measureReuseBatch(
                                    mode == 1, policy == 1, n, side, reuseCount,
                                    round, permutation, source, mask, hasMask,
                                    idsByChoice[choice], metadataByChoice[choice],
                                    stableIdsByChoice[choice], stableMetaByChoice[choice],
                                    mode == 0 ? onceOutput : preparedOutput
                                );

                            ensure(batches[mode].checksum == expected,
                                "reuse independently computed per-batch checksum");
                            // Oracle is outside both the timer and GC delta.
                            reuseFullPixelOracle(
                                mode == 0 ? outputOnce.view()
                                    : outputPrepared.view(),
                                n, choice, permutation,
                                window(side, reuseCount - 1 + round), hasMask);
                            if (!instrument && round >= warmups)
                                writeln("reuse_case,", n, ",", side, ",",
                                    layout == Layout.planar ? "planar" : "interleaved",
                                    ",", hasMask ? "masked" : "unmasked", ",",
                                    policy == 0 ? "immutable" : "mutable_snapshot",
                                    ",", reuseCount, ",", round - warmups,
                                    ",", slot, ",",
                                    mode == 0 ? "one_shot" : "prepared",
                                    ",", batches[mode].setupNs, ",",
                                    batches[mode].mappingNs, ",",
                                    batches[mode].totalNs, ",",
                                    batches[mode].checksum, ",", expected);
                        }
                        ensure(batches[0].checksum == batches[1].checksum,
                            "reuse exact paired observed checksum parity");
                        if (instrument && round >= warmups)
                        {
                            // Print only AFTER both paths are finished:
                            // logging of the first path may allocate and
                            // would otherwise contaminate the second.
                            foreach (slot; 0 .. 2)
                            {
                                const mode = (round + slot) % 2;
                                const x = runtimeDeltas[mode];
                                writeln("reuse_gc_case,", caseRank, ",",
                                    orderSeed, ",", n, ",", side, ",",
                                    layout == Layout.planar ? "planar" : "interleaved",
                                    ",", hasMask ? "masked" : "unmasked", ",",
                                    policy == 0 ? "immutable" : "mutable_snapshot",
                                    ",", reuseCount, ",", round - warmups,
                                    ",", slot, ",",
                                    mode == 0 ? "one_shot" : "prepared", ",",
                                    batches[mode].setupNs, ",",
                                    batches[mode].mappingNs, ",",
                                    batches[mode].totalNs, ",",
                                    batches[mode].checksum, ",", expected, ",",
                                    x.allocatedBytes, ",",
                                    x.collectionCycles, ",", x.gcPauseNs, ",",
                                    x.minorFaults, ",", x.majorFaults);
                            }
                        }
                    }
                }
            }
        }
    }
    writeln(instrument
        ? "M3.2.15 PASS: counterbalanced order and instrumented ROI oracle"
        : "M3.2.14 PASS: paired reuse, full pixels and calibrated oracle");
}

void runConsumerReuseExperiment(bool smoke, size_t rounds, size_t warmups)
{
    runConsumerReuseOrdered(smoke, rounds, warmups, 0, false);
}

void runConsumerReuseGcOrderExperiment(
    bool smoke, size_t rounds, size_t warmups, size_t processSeed
)
{
    runConsumerReuseOrdered(smoke, rounds, warmups, processSeed, true);
}
