module m3_2_consumer_workload.benchmark;

import core.stdc.stdlib : exit, malloc;
import core.memory : GC;
import core.sys.posix.sys.resource : rusage, getrusage, RUSAGE_SELF;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln, stderr;

import m1_5_image_view.contract :
    ChannelDescriptor, ImageViewValidationError, tryMakeImageView;
import m3_2_channel_metadata.contract :
    IntrinsicChannel, ColourBinding, DeclaredColour,
    ValueInterpretation, SemanticMapError;
import m3_2_retained_metadata.contract :
    BorrowedSemanticImage, MetadataBorrowError, tryBorrowSemanticImage;
import m3_2_metadata_owner.contract : ResearchMetadataState;
import m3_2_metadata_source.contract :
    ResearchLongLivedMetadataSource, SourceRoiError;

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

/++
    M3.2.16: **diagnostic only** counterfactual collector-policy experiment.

    A process runs exactly one policy: normal, collect-before-batch or
    temporarily suspend automatic collections for one measured batch.
    Every policy executes the identical caller-mutable metadata snapshots,
    verified construction, prepared binding, calibrated ROI mapping and
    independent full-pixel oracle. This is *not* a production GC policy.

    GC.disable() still permits allocations and is not an absolute guarantee
    against emergency collection. GC.enable() is paired in scope(exit).
    A manual precollection happens outside the measured StopWatches; its
    cost is recorded separately and must be included in any life-cycle view.
+/
private struct GcInterventionObservation
{
    ReuseBatch batch;
    ReuseRuntimeDelta runtime;
    ulong collectBeforeNs;
    size_t collectBeforeCycles;
    long collectBeforePauseNs;
    size_t heapUsedBefore;
    size_t heapFreeBefore;
    size_t heapUsedAfter;
    size_t heapFreeAfter;
    size_t collectionsAfterEnable;
    long pauseAfterEnableNs;
}

pragma(inline, false)
private GcInterventionObservation measureGcInterventionBatch(
    size_t policy, size_t side, size_t reuseCount, size_t absoluteRound,
    size_t permutation,
    scope RasterView!float source, scope RasterView!ubyte mask,
    scope ChannelDescriptor[] ids, scope IntrinsicChannel[] metadata,
    scope WritableRasterView!float output
)
{
    GcInterventionObservation observation;
    if (policy == 1)
    {
        const pre = GC.profileStats();
        StopWatch collectionWatch;
        collectionWatch.start();
        GC.collect();
        collectionWatch.stop();
        const post = GC.profileStats();
        ensure(post.numCollections >= pre.numCollections
            && post.totalPauseTime >= pre.totalPauseTime,
            "external GC collection statistics monotonic");
        observation.collectBeforeNs =
            cast(ulong)collectionWatch.peek.total!"nsecs";
        observation.collectBeforeCycles =
            post.numCollections - pre.numCollections;
        observation.collectBeforePauseNs =
            (post.totalPauseTime - pre.totalPauseTime).total!"nsecs";
    }

    bool gcSuspended = false;
    if (policy == 2)
    {
        GC.disable();
        gcSuspended = true;
    }
    scope(exit)
    {
        if (gcSuspended)
            GC.enable();
    }

    rusage beforeUsage, afterUsage;
    ensure(getrusage(RUSAGE_SELF, &beforeUsage) == 0,
        "GC intervention rusage before");
    const gcBefore = GC.stats();
    const profileBefore = GC.profileStats();
    observation.heapUsedBefore = gcBefore.usedSize;
    observation.heapFreeBefore = gcBefore.freeSize;
    // measureReuseBatch owns all three timing regions; the counter read,
    // manual collection and GC.disable/enable are deliberately excluded.
    immutable(ChannelDescriptor)[] unusedStableIds;
    immutable(IntrinsicChannel)[] unusedStableMetadata;
    observation.batch = measureReuseBatch(
        true, true, 256, side, reuseCount, absoluteRound,
        permutation, source, mask, true, ids, metadata,
        unusedStableIds, unusedStableMetadata, output);

    const gcAfter = GC.stats();
    const profileAfter = GC.profileStats();
    ensure(getrusage(RUSAGE_SELF, &afterUsage) == 0,
        "GC intervention rusage after");
    observation.heapUsedAfter = gcAfter.usedSize;
    observation.heapFreeAfter = gcAfter.freeSize;
    observation.runtime = reuseRuntimeDifference(
        gcBefore, profileBefore, gcAfter, profileAfter,
        beforeUsage, afterUsage);

    if (gcSuspended)
    {
        GC.enable();
        gcSuspended = false;
    }
    const enabledProfile = GC.profileStats();
    ensure(enabledProfile.numCollections >= profileAfter.numCollections
        && enabledProfile.totalPauseTime >= profileAfter.totalPauseTime,
        "post-enable GC statistics monotonic");
    observation.collectionsAfterEnable =
        enabledProfile.numCollections - profileAfter.numCollections;
    observation.pauseAfterEnableNs =
        (enabledProfile.totalPauseTime - profileAfter.totalPauseTime)
        .total!"nsecs";
    return observation;
}

void runGcInterventionExperiment(
    bool smoke, size_t rounds, size_t warmups, size_t policy,
    size_t roiSide, size_t reuseCount
)
{
    ensure(policy < 3, "GC intervention policy");
    ensure(rounds > 0 && warmups <= rounds,
        "GC intervention bounded rounds and warmups");
    ensure(roiSide == 8 || roiSide == 32,
        "GC intervention supported ROI side");
    ensure(reuseCount == 1 || reuseCount == 4 || reuseCount == 16,
        "GC intervention explicit ROI reuse");
    ensure(!smoke || rounds <= 8,
        "GC diagnostic smoke must stay bounded");

    const names = ["normal", "precollect", "deferred"];
    writeln("gc_intervention_schema,policy,round,channels,roi_side,layout,reuse,setup_ns,map_ns,total_ns,checksum,expected,allocated_bytes,in_batch_collections,in_batch_pause_ns,minor_faults,major_faults,collect_before_ns,collect_before_cycles,collect_before_pause_ns,heap_used_before,heap_free_before,heap_used_after,heap_free_after,after_enable_collections,after_enable_pause_ns");

    enum n = cast(size_t)256;
    auto sourceLease = makeSamples(n, extent, extent, Layout.planar, true);
    auto maskLease = makeMask();
    auto outputLease = makeSamples(3, roiSide, roiSide, Layout.planar, false);
    auto source = sourceLease.view();
    auto validity = maskLease.view();
    bool writableOk;
    scope auto output = outputLease.tryWritableView(writableOk);
    ensure(writableOk, "GC intervention writable output");

    auto idsByChoice = new ChannelDescriptor[][](8);
    auto metaByChoice = new IntrinsicChannel[][](8);
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
        metaByChoice[choice] = meta;
    }
    // Input metadata is prebuilt and held across this entire process.
    // Each measured batch still snapshots *both* mutable arrays.
    foreach (absolute; 0 .. rounds + warmups)
    {
        const choice = (absolute * 5 + reuseCount) % 8;
        const permutation = (absolute + reuseCount) % 3;
        const expected = reuseExpectedSampleSum(
            n, choice, permutation, roiSide, reuseCount, absolute, true);

        auto observation = measureGcInterventionBatch(
            policy, roiSide, reuseCount, absolute, permutation,
            source, validity, idsByChoice[choice], metaByChoice[choice],
            output);
        ensure(observation.batch.checksum == expected,
            "GC policy independent first-pixel checksum");
        reuseFullPixelOracle(
            outputLease.view(), n, choice, permutation,
            window(roiSide, reuseCount - 1 + absolute), true);
        if (absolute < warmups)
            continue;

        writeln("gc_intervention,", names[policy], ",",
            absolute - warmups, ",", n, ",", roiSide, ",planar,",
            reuseCount, ",", observation.batch.setupNs, ",",
            observation.batch.mappingNs, ",", observation.batch.totalNs,
            ",", observation.batch.checksum, ",", expected, ",",
            observation.runtime.allocatedBytes, ",",
            observation.runtime.collectionCycles, ",",
            observation.runtime.gcPauseNs, ",",
            observation.runtime.minorFaults, ",",
            observation.runtime.majorFaults, ",",
            observation.collectBeforeNs, ",",
            observation.collectBeforeCycles, ",",
            observation.collectBeforePauseNs, ",",
            observation.heapUsedBefore, ",",
            observation.heapFreeBefore, ",",
            observation.heapUsedAfter, ",",
            observation.heapFreeAfter, ",",
            observation.collectionsAfterEnable, ",",
            observation.pauseAfterEnableNs);
    }
    writeln("M3.2.16 PASS: calibrated GC counterfactual pixel oracle");
}

/++
    M3.2.17 research-only consumer comparison.

    * immutable: already immutable source metadata is borrowed; verification
      and binding happen once per run. Its original creation is NOT measured.
    * snapshot_once: two immutable arrays copied from caller-mutable inputs
      once; verification/binding once per run, repeated packet reuse.
    * snapshot_each: two snapshots and full verification/binding per packet.

    Identical calibrated masked ROI mapping in all three cases. No attempted
    mutable-to-immutable cast or ownership-freeze shortcut.
+/
private void mapOwnerPackets(
    string policy, ResearchMetadataState state,
    size_t packetCount, size_t side, size_t roiCount,
    scope RasterView!float source, scope RasterView!ubyte mask,
    scope WritableRasterView!float output,
    scope RasterView!float outputRead,
    ulong onceCopyNs, ulong onceCopyAllocated
)
{
    const size_t n = 256;
    const size_t choice = 2;
    const size_t permutation = 1;
    StopWatch setupWatch;
    setupWatch.start();
    VerifiedRoiError verifyError;
    auto verified = tryMakeValidatedImmutableImage(
        source, state.identities, state.metadata, mask, true, verifyError);
    ensure(verifyError == VerifiedRoiError.none,
        "metadata owner verified once");
    SemanticMapError prepareError;
    auto prepared = tryPrepareSemanticMap(
        verified, challengeThree(n, permutation),
        ValueInterpretation.physical, prepareError);
    ensure(prepareError == SemanticMapError.none && prepared.isPrepared,
        "metadata owner prepared once");
    setupWatch.stop();
    const setupOnceNs = cast(ulong)setupWatch.peek.total!"nsecs";

    foreach (packet; 0 .. packetCount)
    {
        const before = GC.stats().allocatedInCurrentThread;
        StopWatch mapWatch;
        double checksum = 0.0;
        mapWatch.start();
        foreach (roi; 0 .. roiCount)
        {
            float sample;
            ensure(mapPrepared(prepared, window(side, roi + packet),
                output, sample), "metadata owner actual ROI map");
            checksum += sample;
        }
        mapWatch.stop();
        const after = GC.stats().allocatedInCurrentThread;
        ensure(after >= before, "metadata owner GC counter monotonic");

        const expected = reuseExpectedSampleSum(
            n, choice, permutation, side, roiCount, packet, true);
        ensure(checksum == expected,
            "metadata owner independently expected pixel checksum");
        reuseFullPixelOracle(outputRead, n, choice, permutation,
            window(side, roiCount - 1 + packet), true);

        writeln("metadata_owner_case,", policy, ",", side, ",", roiCount,
            ",", packet, ",", packet == 0 ? setupOnceNs : 0UL,
            ",", cast(ulong)mapWatch.peek.total!"nsecs",
            ",", checksum, ",", expected, ",",
            after - before, ",",
            packet == 0 ? onceCopyNs : 0UL, ",",
            packet == 0 ? onceCopyAllocated : 0UL);
    }
}

void runMetadataOwnerReuseExperiment(
    size_t policy, size_t packetCount, size_t side, size_t roiCount
)
{
    ensure(policy < 3, "metadata owner policy 0, 1, 2");
    ensure(packetCount > 0 && packetCount <= 8192,
        "metadata owner bounded packets");
    ensure(side == 8 || side == 32,
        "metadata owner side 8 or 32");
    ensure(roiCount == 4 || roiCount == 16,
        "metadata owner ROI counts 4 or 16");

    enum size_t n = 256;
    enum size_t choice = 2;
    enum size_t permutation = 1;
    auto sourceLease = makeSamples(n, extent, extent, Layout.planar, true);
    auto maskLease = makeMask();
    auto outputLease = makeSamples(3, side, side, Layout.planar, false);
    auto source = sourceLease.view();
    auto mask = maskLease.view();
    bool writableOk;
    scope auto output = outputLease.tryWritableView(writableOk);
    ensure(writableOk, "metadata owner destination writable");
    auto outputRead = outputLease.view();

    // Caller-mutable input is built once outside all measured loops.
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

    // Exercise mutable-alias isolation separately from the measured inputs.
    {
        auto testIds = [ChannelDescriptor(42)];
        auto testMeta = [
            IntrinsicChannel(42, "safe", "unknown", true, 2.0f, 1.0f)
        ];
        auto snapshot = ResearchMetadataState.snapshot(
            testIds[], testMeta[]);
        testIds[0] = ChannelDescriptor(999);
        testMeta[0] = IntrinsicChannel(
            999, "mutated", "unknown", true, 8.0f, 9.0f);
        ensure(snapshot.identities[0].semanticId == 42
            && snapshot.metadata[0].semanticId == 42
            && snapshot.metadata[0].scale == 2.0f,
            "mutable aliases cannot alter immutable snapshot");
    }

    writeln("metadata_owner_schema,policy,roi_side,reuse,packet,setup_ns,map_ns,checksum,expected,hot_gc_alloc_bytes,once_copy_ns,once_copy_alloc_bytes");

    if (policy == 0)
    {
        // External genuinely immutable input; its creation is deliberately
        // outside consumer timings, not asserted allocation-free globally.
        immutable(ChannelDescriptor)[] stableIds = ids.idup;
        immutable(IntrinsicChannel)[] stableMeta = meta.idup;
        auto state = ResearchMetadataState.fromImmutable(
            stableIds, stableMeta);
        ensure(state.identities.ptr is stableIds.ptr
            && state.metadata.ptr is stableMeta.ptr,
            "immutable provider path must be zero-copy");
        mapOwnerPackets("immutable", state, packetCount,
            side, roiCount, source, mask, output, outputRead, 0, 0);
    }
    else if (policy == 1)
    {
        const before = GC.stats().allocatedInCurrentThread;
        StopWatch snapshotWatch;
        snapshotWatch.start();
        auto state = ResearchMetadataState.snapshot(ids, meta);
        snapshotWatch.stop();
        const after = GC.stats().allocatedInCurrentThread;
        ensure(after >= before,
            "snapshot once GC counter monotonic");
        mapOwnerPackets("snapshot_once", state, packetCount,
            side, roiCount, source, mask, output, outputRead,
            cast(ulong)snapshotWatch.peek.total!"nsecs", after - before);
    }
    else
    {
        immutable(ChannelDescriptor)[] unusedIds;
        immutable(IntrinsicChannel)[] unusedMeta;
        foreach (packet; 0 .. packetCount)
        {
            const before = GC.stats().allocatedInCurrentThread;
            auto measured = measureReuseBatch(
                true, true, n, side, roiCount, packet, permutation,
                source, mask, true, ids, meta,
                unusedIds, unusedMeta, output);
            const after = GC.stats().allocatedInCurrentThread;
            ensure(after >= before,
                "snapshot each GC counter monotonic");
            const expected = reuseExpectedSampleSum(
                n, choice, permutation, side, roiCount, packet, true);
            ensure(measured.checksum == expected,
                "snapshot each independent checksum");
            reuseFullPixelOracle(outputRead, n, choice, permutation,
                window(side, roiCount - 1 + packet), true);
            writeln("metadata_owner_case,snapshot_each,", side, ",",
                roiCount, ",", packet, ",", measured.setupNs, ",",
                measured.mappingNs, ",", measured.checksum, ",",
                expected, ",", after - before, ",0,0");
        }
    }

    writeln("M3.2.17 PASS: immutable ownership, snapshot isolation and actual ROI pixel oracle");
}

/++
    M3.2.18: prove source adapter lifetime, stale mutable alias
    isolation, explicitly refreshed metadata and ordered 3-lane
    first/last pixel observations for *each* mapped ROI.

    This is a correctness/GC-allocation probe, not a claim that
    reconstructing a Prepared binding for each packet is optimal.
+/
void runMetadataSourceOrderedExperiment(
    size_t provider, size_t packetCount, size_t side, size_t roiCount
)
{
    ensure(provider < 2, "ordered metadata provider enum");
    ensure(packetCount > 0 && packetCount <= 8192,
        "ordered metadata packet bound");
    ensure(side == 8 || side == 32,
        "ordered metadata ROI side");
    ensure(roiCount == 4 || roiCount == 16,
        "ordered metadata ROI count");

    enum size_t n = 256;
    enum size_t permutation = 1;
    auto sourceLease = makeSamples(n, extent, extent, Layout.planar, true);
    auto maskLease = makeMask();
    auto outputLease = makeSamples(3, side, side, Layout.planar, false);
    auto source = sourceLease.view();
    auto validity = maskLease.view();
    bool writableOk;
    scope auto output = outputLease.tryWritableView(writableOk);
    ensure(writableOk, "ordered metadata output writable");
    auto outputRead = outputLease.view();

    auto ids = new ChannelDescriptor[](n);
    auto meta = new IntrinsicChannel[](n);
    foreach (band; 0 .. n)
    {
        const id = cast(uint)(24000 + 2 * 1024 + band);
        ids[band] = ChannelDescriptor(id);
        meta[band] = IntrinsicChannel(id, "NIR", "unknown", true,
            scale + 2.0f * 0.0625f, offset - 2.0f);
    }

    // Construction is intentionally outside the packet timings.
    ResearchLongLivedMetadataSource oldSource;
    if (provider == 0)
    {
        immutable(ChannelDescriptor)[] immIds = ids.idup;
        immutable(IntrinsicChannel)[] immMeta = meta.idup;
        oldSource = ResearchLongLivedMetadataSource.fromImmutable(
            immIds, immMeta);
        ensure(oldSource.identities.ptr is immIds.ptr
            && oldSource.metadata.ptr is immMeta.ptr,
            "ordered source does not duplicate immutable provider backing");
    }
    else
        oldSource = ResearchLongLivedMetadataSource.snapshot(ids, meta);

    // Mutate *the entire* original caller metadata after the owner is
    // created. Old semantics cannot change through the old aliases.
    foreach (band; 0 .. n)
    {
        const id = ids[band].semanticId;
        meta[band] = IntrinsicChannel(id, "REFRESHED", "unknown", true,
            scale + 3.0f * 0.0625f, offset - 3.0f);
    }

    ResearchLongLivedMetadataSource newSource;
    if (provider == 0)
    {
        immutable(ChannelDescriptor)[] refreshedIds = ids.idup;
        immutable(IntrinsicChannel)[] refreshedMeta = meta.idup;
        newSource = ResearchLongLivedMetadataSource.fromImmutable(
            refreshedIds, refreshedMeta);
    }
    else
        newSource = ResearchLongLivedMetadataSource.snapshot(ids, meta);

    ensure(oldSource.channelCount == n && newSource.channelCount == n
        && oldSource.metadata[254].scale == scale + 2.0f * 0.0625f
        && newSource.metadata[254].scale == scale + 3.0f * 0.0625f
        && oldSource.metadata[254].sourceLabel == "NIR"
        && newSource.metadata[254].sourceLabel == "REFRESHED",
        "old metadata owner unchanged and refreshed semantics distinct");

    auto windows = new Region2D[](roiCount);
    auto first = new float[](roiCount * 3);
    auto last = new float[](roiCount * 3);
    const policy = provider == 0 ? "immutable" : "snapshot";
    writeln("metadata_source_packet_schema,policy,phase,packet,roi_side,reuse,elapsed_ns,hot_gc_bytes");
    writeln("metadata_source_roi_schema,policy,phase,packet,roi,roi_side,reuse,x,y,first0,first1,first2,last0,last1,last2");
    foreach (phase; 0 .. 2)
    {
        const choice = phase == 0 ? cast(size_t)2 : cast(size_t)3;
        const phaseName = phase == 0 ? "original" : "refreshed";
        auto adapter = phase == 0 ? oldSource : newSource;
        foreach (packet; 0 .. packetCount)
        {
            foreach (index; 0 .. roiCount)
                windows[index] = window(side, packet + index);
            const before = GC.stats().allocatedInCurrentThread;
            StopWatch watch;
            watch.start();
            const status = adapter.tryMapOrderedInto(
                source, validity, true, challengeThree(n, permutation),
                ValueInterpretation.physical,
                windows[], output, first[], last[]);
            watch.stop();
            const after = GC.stats().allocatedInCurrentThread;
            ensure(status == SourceRoiError.none,
                "metadata source prepared ROI mapping");
            ensure(after == before,
                "metadata source mapping has no GC allocations");

            // A separate physical-value oracle for *every* emitted lane
            // and both opposed ROI corners, regardless of mask state.
            const calScale = scale + cast(float)choice * 0.0625f;
            const calOffset = offset - cast(float)choice;
            foreach (index, region; windows)
            {
                foreach (component; 0 .. 3)
                {
                    const c = reuseSelected(n, permutation, component);
                    const firstExpected = maskValue(region.x, region.y) == 0
                        ? 0.0f
                        : storedValue(c, region.x, region.y)
                            * calScale + calOffset;
                    const endX = region.x + side - 1;
                    const endY = region.y + side - 1;
                    const lastExpected = maskValue(endX, endY) == 0
                        ? 0.0f
                        : storedValue(c, endX, endY)
                            * calScale + calOffset;
                    ensure(first[index * 3 + component] == firstExpected
                        && last[index * 3 + component] == lastExpected,
                        "ordered source every ROI lane independent oracle");
                }
                writeln("metadata_source_roi,", policy, ",", phaseName,
                    ",", packet, ",", index, ",", side, ",", roiCount,
                    ",", region.x, ",", region.y, ",",
                    first[index * 3], ",", first[index * 3 + 1], ",",
                    first[index * 3 + 2], ",",
                    last[index * 3], ",", last[index * 3 + 1], ",",
                    last[index * 3 + 2]);
            }
            // Existing full-pixel oracle still checks all samples of
            // all three channels of the final output buffer.
            reuseFullPixelOracle(
                outputRead, n, choice, permutation, windows[$ - 1], true);
            writeln("metadata_source_packet,", policy, ",", phaseName,
                ",", packet, ",", side, ",", roiCount, ",",
                cast(ulong)watch.peek.total!"nsecs", ",",
                after - before);
        }
    }
    writeln("M3.2.18 PASS: immutable source lifetime and all ordered ROI lanes");
}


/++
    M3.2.19 correctness-only failure-state qualification. Unlike
    performance experiments, this explicitly checks destination
    first-sample and observation-buffer writes on every preflight
    failure and checks partial effects after the *first* valid ROI
    followed by an invalid second ROI. No public API is modified.
+/
private void expectSourceCase(
    string caseName,
    SourceRoiError expected,
    ResearchLongLivedMetadataSource owner,
    scope RasterView!float source,
    scope RasterView!ubyte validity,
    bool hasValidity,
    ColourBinding binding,
    scope const(Region2D)[] regions,
    scope WritableRasterView!float destination,
    scope float[] first, scope float[] last,
    bool pristinePreflight, bool partialProgress = false
)
{
    enum float untouched = -12345.0f;
    ensure(destination.trySetSample(0, 0, 0, untouched),
        "M3.2.19 set destination sentinel");
    first[] = untouched;
    last[] = untouched;
    const before = GC.stats().allocatedInCurrentThread;
    const got = owner.tryMapOrderedInto(
        source, validity, hasValidity, binding,
        ValueInterpretation.physical, regions,
        destination, first, last);
    const after = GC.stats().allocatedInCurrentThread;
    ensure(got == expected, "M3.2.19 expected failure classification: " ~ caseName);
    ensure(after == before, "M3.2.19 @nogc failure/success path: " ~ caseName);
    float observed;
    ensure(destination.trySample(0, 0, 0, observed),
        "M3.2.19 inspect output sentinel");

    if (pristinePreflight)
    {
        ensure(observed == untouched,
            "M3.2.19 preflight must not write destination: " ~ caseName);
        foreach (value; first)
            ensure(value == untouched, "M3.2.19 untouched first samples");
        foreach (value; last)
            ensure(value == untouched, "M3.2.19 untouched last samples");
    }
    if (partialProgress)
    {
        ensure(observed != untouched,
            "M3.2.19 first successful ROI has already written output");
        ensure(first[0] != untouched && last[0] != untouched,
            "M3.2.19 first ROI observations present");
        ensure(first[3] == untouched && last[3] == untouched,
            "M3.2.19 later invalid ROI has no observations");
    }
    writeln("metadata_source_failure,", caseName, ",", got);
}

void runMetadataSourceFailureMatrix()
{
    enum size_t n = 3;
    auto sourceLease = makeSamples(n, extent, extent, Layout.planar, true);
    auto validityLease = makeMask();
    auto outputLease = makeSamples(3, 8, 8, Layout.planar, false);
    auto wrongPlaneLease = makeSamples(2, 8, 8, Layout.planar, false);
    auto wrongSizeLease = makeSamples(3, 4, 4, Layout.planar, false);
    auto source = sourceLease.view();
    auto mask = validityLease.view();
    bool ok, wrongOk, smallOk;
    scope auto outView = outputLease.tryWritableView(ok);
    scope auto wrongPlanes = wrongPlaneLease.tryWritableView(wrongOk);
    scope auto wrongSize = wrongSizeLease.tryWritableView(smallOk);
    ensure(ok && wrongOk && smallOk, "M3.2.19 writable destination fixtures");

    auto ids = [ChannelDescriptor(1), ChannelDescriptor(2),
                ChannelDescriptor(3)];
    auto meta = [
        IntrinsicChannel(1, "A", "unknown", true, 0.5f, -4.0f),
        IntrinsicChannel(2, "B", "unknown", true, 0.5f, -4.0f),
        IntrinsicChannel(3, "C", "unknown", true, 0.5f, -4.0f)
    ];
    auto good = ResearchLongLivedMetadataSource.snapshot(ids, meta);
    const binding = mapping(n);

    const Region2D[1] valid = [Region2D(0, 0, 8, 8)];
    const Region2D[1] zeroArea = [Region2D(0, 0, 0, 8)];
    const Region2D[1] outsideGrid = [Region2D(extent, extent, 8, 8)];
    const Region2D[2] laterInvalid =
        [Region2D(0, 0, 8, 8), Region2D(extent, extent, 8, 8)];
    float[3] first;
    float[3] last;
    float[4] tooMany;
    float[6] firstTwo, lastTwo;
    float[0] none;
    const Region2D[0] emptyWindow = [];
    alias E = SourceRoiError;

    expectSourceCase("empty-windows", E.sampleBuffer,
        good, source, mask, true, binding,
        emptyWindow[], outView, none[], none[], true);
    expectSourceCase("short-first", E.sampleBuffer,
        good, source, mask, true, binding,
        valid[], outView, none[], last[], true);
    expectSourceCase("short-last", E.sampleBuffer,
        good, source, mask, true, binding,
        valid[], outView, first[], none[], true);
    expectSourceCase("extra-first", E.sampleBuffer,
        good, source, mask, true, binding,
        valid[], outView, tooMany[], last[], true);

    expectSourceCase("init-owner", E.invalidImage,
        ResearchLongLivedMetadataSource.init, source, mask, true,
        binding, valid[], outView, first[], last[], true);
    auto shortIds = ids[0 .. 2];
    auto shortMeta = meta[0 .. 2];
    auto shortOwner =
        ResearchLongLivedMetadataSource.snapshot(shortIds, shortMeta);
    expectSourceCase("metadata-count", E.invalidImage,
        shortOwner, source, mask, true, binding,
        valid[], outView, first[], last[], true);

    auto wrongIds = ids.dup;
    wrongIds[1] = ChannelDescriptor(999);
    auto invalidOwner =
        ResearchLongLivedMetadataSource.snapshot(wrongIds, meta);
    expectSourceCase("semantic-id", E.invalidImage,
        invalidOwner, source, mask, true, binding,
        valid[], outView, first[], last[], true);

    expectSourceCase("invalid-validity-view", E.invalidImage,
        good, source, RasterView!ubyte.init, true, binding,
        valid[], outView, first[], last[], true);

    const invalidBinding = ColourBinding(
        n, 1, 0, DeclaredColour.unspecified);
    expectSourceCase("invalid-binding", E.invalidBinding,
        good, source, mask, true, invalidBinding,
        valid[], outView, first[], last[], true);

    auto noCalibration = meta.dup;
    noCalibration[2].hasCalibration = false;
    auto missingCal =
        ResearchLongLivedMetadataSource.snapshot(ids, noCalibration);
    expectSourceCase("missing-calibration", E.invalidBinding,
        missingCal, source, mask, true, binding,
        valid[], outView, first[], last[], true);

    expectSourceCase("zero-area", E.invalidRegion,
        good, source, mask, true, binding,
        zeroArea[], outView, first[], last[], true);
    expectSourceCase("off-grid", E.invalidRegion,
        good, source, mask, true, binding,
        outsideGrid[], outView, first[], last[], true);
    expectSourceCase("wrong-destination-extent", E.invalidRegion,
        good, source, mask, true, binding,
        valid[], wrongSize, first[], last[], true);
    expectSourceCase("wrong-destination-planes", E.mappingFailure,
        good, source, mask, true, binding,
        valid[], wrongPlanes, first[], last[], true);

    // This is deliberately *not* an all-ROI transaction.
    expectSourceCase("later-invalid-partial-progress", E.invalidRegion,
        good, source, mask, true, binding,
        laterInvalid[], outView, firstTwo[], lastTwo[], false, true);

    expectSourceCase("successful-map", E.none,
        good, source, mask, true, binding,
        valid[], outView, first[], last[], false);
    // The real full-pixel independent source formula covers all lanes.
    foreach (component; 0 .. 3)
    foreach (y; 0 .. 8)
    foreach (x; 0 .. 8)
    {
        float got;
        ensure(outputLease.view().trySample(component, x, y, got),
            "M3.2.19 full output read");
        const expected = maskValue(x, y) == 0 ? 0.0f
            : storedValue(n - 1 - component, x, y) * 0.5f - 4.0f;
        ensure(got == expected, "M3.2.19 independent full-pixel oracle");
    }

    writeln("M3.2.19 PASS: failure precedence, pristine preflight, " ~
        "partial-progress contract, full-pixel oracle, no-GC calls");
}
