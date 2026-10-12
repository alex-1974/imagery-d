module app;

import core.stdc.stdlib : exit, malloc;
import std.datetime.stopwatch : StopWatch;
import std.stdio : stderr, writeln;

import m1_5_image_view.contract :
    ChannelDescriptor, ImageView, ImageViewValidationError, tryMakeImageView;
import m3_2_channel_metadata.contract :
    IntrinsicChannel, ColourBinding, DeclaredColour,
    ValueInterpretation, SemanticMapError, mapComponentsInto;
import m3_2_retained_metadata.contract :
    MetadataBorrowError, tryBorrowSemanticImage;
import m3_2_roi_xps.benchmark : runXpsRoiBenchmark;
import m3_2_consumer_workload.benchmark :
    runConsumerWorkload, runPreparationChallenge, runPreparationObservedSmoke,
    runConsumerReuseExperiment, runConsumerReuseGcOrderExperiment;
import m3_2_verified_roi.contract :
    VerifiedRoiError, ValidatedImmutableImage, PreparedSemanticMap,
    tryMakeValidatedImmutableImage, tryPrepareSemanticMap;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

private enum Layout : ubyte { planar, interleaved }

private void require(bool condition, string message)
{
    if (!condition)
    {
        stderr.writeln("M3.2.6 FAIL: ", message);
        exit(1);
    }
}

private float inputValue(size_t channel, size_t x, size_t y)
@safe pure nothrow @nogc
{
    return cast(float)(channel * 100 + y * 10 + x);
}

private RasterLease!float rasterFixture(
    size_t channels, Layout layout, bool fill
)
{
    enum size_t width = 7;
    enum size_t height = 5;
    const byteCount = width * height * channels * float.sizeof;
    auto memory = cast(float*)malloc(byteCount);
    require(memory !is null, "allocate source");
    OwnedByteResource resource;
    require(tryAdoptMallocResource(memory, byteCount, resource),
        "adopt source");

    auto planes = new PlaneByteLayout[](channels);
    foreach (i; 0 .. channels)
    {
        if (layout == Layout.planar)
        {
            planes[i] = PlaneByteLayout(
                i * width * height * float.sizeof,
                cast(ptrdiff_t)(width * float.sizeof),
                cast(ptrdiff_t)float.sizeof
            );
        }
        else
        {
            planes[i] = PlaneByteLayout(
                i * float.sizeof,
                cast(ptrdiff_t)(width * channels * float.sizeof),
                cast(ptrdiff_t)(channels * float.sizeof)
            );
        }
    }

    RasterLease!float lease;
    const imported = tryImportOwnedRaster!float(
        resource, planes[], Region2D(0, 0, width, height), lease
    );
    require(imported.ok, "import source");

    if (fill)
    {
        bool ok;
        scope auto writable = lease.tryWritableView(ok);
        require(ok, "writable input");
        foreach (c; 0 .. channels)
        {
            foreach (y; 0 .. height)
            {
                foreach (x; 0 .. width)
                {
                    require(writable.trySetSample(
                        c, x, y, inputValue(c, x, y)
                    ), "fill source");
                }
            }
        }
    }
    return lease;
}

private RasterLease!ubyte validityFixture()
{
    enum size_t width = 7;
    enum size_t height = 5;
    auto memory = cast(ubyte*)malloc(width * height);
    require(memory !is null, "allocate validity");
    foreach (i; 0 .. width * height)
        memory[i] = 255;
    memory[width * height - 1] = 0;

    OwnedByteResource resource;
    require(tryAdoptMallocResource(memory, width * height, resource),
        "adopt validity");
    const PlaneByteLayout[1] planes =
        [PlaneByteLayout(0, cast(ptrdiff_t)width, 1)];
    RasterLease!ubyte lease;
    const imported = tryImportOwnedRaster!ubyte(
        resource, planes[], Region2D(0, 0, width, height), lease
    );
    require(imported.ok, "import validity");
    return lease;
}

private void verifyPixelOutput(
    scope RasterView!float output,
    size_t channelCount,
    bool masked
)
{
    foreach (component; 0 .. 3)
    {
        const channel = channelCount - 1 - component;
        foreach (y; 0 .. output.height)
        {
            foreach (x; 0 .. output.width)
            {
                float observed;
                require(output.trySample(component, x, y, observed),
                    "read mapped pixel");
                const invalid = masked
                    && x == output.width - 1
                    && y == output.height - 1;
                const expected = invalid ? 0.0f :
                    inputValue(channel, x, y) * 0.5f - 10.0f;
                require(observed == expected, "independent pixel oracle");
            }
        }
    }
}

private void comparePixels(
    scope RasterView!float lhs, scope RasterView!float rhs
)
{
    require(lhs.planeCount == rhs.planeCount
        && lhs.width == rhs.width && lhs.height == rhs.height,
        "equal output shape");
    foreach (c; 0 .. lhs.planeCount)
    {
        foreach (y; 0 .. lhs.height)
        {
            foreach (x; 0 .. lhs.width)
            {
                float a, b;
                require(lhs.trySample(c, x, y, a), "read lhs");
                require(rhs.trySample(c, x, y, b), "read rhs");
                require(a == b, "old and validated ROI output equivalence");
            }
        }
    }
}

private void exercise(size_t n, Layout layout, bool masked)
{
    auto editableIds = new ChannelDescriptor[](n);
    auto editableMeaning = new IntrinsicChannel[](n);
    foreach (i; 0 .. n)
    {
        const id = cast(uint)(6000 + i);
        editableIds[i] = ChannelDescriptor(id);
        editableMeaning[i] = IntrinsicChannel(
            id, i % 2 ? "R" : "custom", "opaque",
            true, 0.5f, -10.0f
        );
    }
    // This explicit snapshot happens outside the candidate ROI method.
    immutable(ChannelDescriptor)[] ids = editableIds.idup;
    immutable(IntrinsicChannel)[] meanings = editableMeaning.idup;

    auto primaryLease = rasterFixture(n, layout, true);
    RasterLease!ubyte maskLease;
    if (masked) maskLease = validityFixture();
    auto primary = primaryLease.view();
    auto mask = masked ? maskLease.view() : RasterView!ubyte.init;

    VerifiedRoiError verifiedError;
    auto fast = tryMakeValidatedImmutableImage(
        primary, ids, meanings, mask, masked, verifiedError
    );
    require(verifiedError == VerifiedRoiError.none
        && fast.isVerified && fast.channelCount == n,
        "validated-once factory accepted");

    ImageViewValidationError imageError;
    auto base = tryMakeImageView!float(
        primary, ids, mask, masked, imageError
    );
    require(imageError == ImageViewValidationError.none,
        "baseline M1 image");
    MetadataBorrowError borrowError;
    auto old = tryBorrowSemanticImage(base, meanings, borrowError);
    require(borrowError == MetadataBorrowError.none,
        "old composite borrowed image");

    require(fast.intrinsic.ptr is meanings.ptr,
        "no copied metadata at validated factory");

    // Full versus uneven partitioned image operations: same calibration
    // oracle and same optional validity interpretation for both ROI paths.
    auto oldLease = rasterFixture(3, layout, false);
    auto fastLease = rasterFixture(3, layout, false);
    const binding = ColourBinding(
        n - 1, n - 2, n - 3, DeclaredColour.unspecified
    );
    const Region2D[4] partitions = [
        Region2D(0, 0, 2, 2),
        Region2D(2, 0, 5, 2),
        Region2D(0, 2, 3, 3),
        Region2D(3, 2, 4, 3)
    ];

    bool oldWritableOk;
    scope auto oldWritable = oldLease.tryWritableView(oldWritableOk);
    require(oldWritableOk, "baseline destination writable");
    bool fastWritableOk;
    scope auto fastWritable = fastLease.tryWritableView(fastWritableOk);
    require(fastWritableOk, "fast destination writable");

    foreach (part; partitions)
    {
        bool ok;
        auto childFast = fast.tryRoi(part, ok);
        require(ok && childFast.isVerified, "verified relative ROI");
        require(childFast.intrinsic.ptr is fast.intrinsic.ptr,
            "first ROI shares immutable metadata");

        auto childOld = old.tryRoi(part, ok);
        require(ok, "baseline relative ROI");

        bool oldDstOk;
        auto oldDst = oldWritable.tryRoi(part, oldDstOk);
        require(oldDstOk, "baseline output ROI");
        bool fastDstOk;
        auto fastDst = fastWritable.tryRoi(part, fastDstOk);
        require(fastDstOk, "fast output ROI");

        require(childOld.mapInto(
            binding, ValueInterpretation.physical, oldDst
        ) == SemanticMapError.none, "baseline selected mapping");
        require(childFast.mapInto(
            binding, ValueInterpretation.physical, fastDst
        ) == SemanticMapError.none, "fast selected mapping");

        // Transitive ROI must preserve pointer identity and scoped lifetime.
        bool nestedOk;
        auto nested = childFast.tryRoi(Region2D(0, 0, 1, 1), nestedOk);
        require(nestedOk && nested.channelCount == n,
            "nested validated ROI");
        require(nested.intrinsic.ptr is meanings.ptr,
            "nested ROI shares immutable metadata");
    }

    comparePixels(oldLease.view(), fastLease.view());
    verifyPixelOutput(fastLease.view(), n, masked);

    // Invalid or oversized ROI is not silently clipped. An inert .init
    // value is never confused with a verified capability.
    bool ok;
    auto invalid = fast.tryRoi(Region2D(fast.width, fast.height, 1, 1), ok);
    require(!ok && !invalid.isVerified, "out of bounds rejected");
    auto inert = ValidatedImmutableImage.init;
    auto inertResult = inert.tryRoi(Region2D(0, 0, 0, 0), ok);
    require(!ok && !inertResult.isVerified, "init not verified");
}

private void testFactoryFailures()
{
    auto source = rasterFixture(3, Layout.planar, true);
    auto maskLease = validityFixture();
    auto primary = source.view();
    immutable(ChannelDescriptor)[3] ids = [
        ChannelDescriptor(1), ChannelDescriptor(2), ChannelDescriptor(3)
    ];
    immutable(IntrinsicChannel)[3] meanings = [
        IntrinsicChannel(1, "", "", false, 0, 0),
        IntrinsicChannel(2, "", "", false, 0, 0),
        IntrinsicChannel(3, "", "", false, 0, 0)
    ];

    VerifiedRoiError error;
    auto bad = tryMakeValidatedImmutableImage(
        primary, ids[], meanings[0 .. 2],
        RasterView!ubyte.init, false, error
    );
    require(error == VerifiedRoiError.descriptorCountMismatch
        && !bad.isVerified, "count mismatch rejected");

    immutable(IntrinsicChannel)[3] wrong = [
        IntrinsicChannel(1, "", "", false, 0, 0),
        IntrinsicChannel(77, "", "", false, 0, 0),
        IntrinsicChannel(3, "", "", false, 0, 0)
    ];
    bad = tryMakeValidatedImmutableImage(
        primary, ids[], wrong[],
        RasterView!ubyte.init, false, error
    );
    require(error == VerifiedRoiError.identityMismatch
        && !bad.isVerified, "identity mismatch rejected");

    bool maskOk;
    auto partialMask = maskLease.view().tryRoi(
        Region2D(0, 0, 3, 2), maskOk
    );
    require(maskOk, "prepare smaller validity");
    bad = tryMakeValidatedImmutableImage(
        primary, ids[], meanings[], partialMask, true, error
    );
    require(error == VerifiedRoiError.imageViewFailure
        && !bad.isVerified, "validity grid mismatch rejected");

    bad = tryMakeValidatedImmutableImage(
        primary, ids[0 .. 2], meanings[0 .. 2],
        RasterView!ubyte.init, false, error
    );
    require(error == VerifiedRoiError.imageViewFailure
        && !bad.isVerified, "raster plane count mismatch rejected");
}

private void bench()
{
    // Preliminary hosted-runner elapsed timings; no production threshold.
    writeln("metric,channels,iterations,elapsed_us,checksum");
    foreach (n; [cast(size_t)3, 17, 64, 256, 1024])
    {
        const size_t repeats = n >= 256 ? 6000 : 12000;
        auto idsBuffer = new ChannelDescriptor[](n);
        auto meaningsBuffer = new IntrinsicChannel[](n);
        foreach (i; 0 .. n)
        {
            const id = cast(uint)(6000 + i);
            idsBuffer[i] = ChannelDescriptor(id);
            meaningsBuffer[i] = IntrinsicChannel(
                id, "opaque", "unit", true, 0.5f, -10.0f
            );
        }
        immutable(ChannelDescriptor)[] ids = idsBuffer.idup;
        immutable(IntrinsicChannel)[] meanings = meaningsBuffer.idup;

        auto rasterLease = rasterFixture(n, Layout.planar, false);
        auto primary = rasterLease.view();
        VerifiedRoiError verifiedError;
        auto fast = tryMakeValidatedImmutableImage(
            primary, ids, meanings, RasterView!ubyte.init,
            false, verifiedError
        );
        require(verifiedError == VerifiedRoiError.none,
            "bench verified preflight");
        ImageViewValidationError imageError;
        auto base = tryMakeImageView!float(
            primary, ids, RasterView!ubyte.init, false, imageError
        );
        require(imageError == ImageViewValidationError.none,
            "bench baseline image preflight");
        MetadataBorrowError borrowError;
        auto old = tryBorrowSemanticImage(base, meanings, borrowError);
        require(borrowError == MetadataBorrowError.none,
            "bench composite preflight");

        // Vary ROI offsets at each iteration to avoid a single repeated
        // constant input. Report elapsed time and visible checksum only;
        // further anti-hoisting/codegen verification remains outstanding.
        const Region2D[4] windows = [
            Region2D(0, 0, 3, 2), Region2D(1, 0, 3, 2),
            Region2D(0, 1, 3, 2), Region2D(2, 2, 3, 2)
        ];

        StopWatch watch;
        size_t baselineChecksum;
        watch.start();
        foreach (i; 0 .. repeats)
        {
            bool success;
            auto r = old.tryRoi(windows[i % 4], success);
            require(success, "baseline ROI benchmark");
            baselineChecksum += r.channelCount + r.intrinsic[i % n].semanticId;
        }
        watch.stop();
        writeln("revalidated_roi,", n, ",", repeats, ",",
            watch.peek.total!"usecs", ",", baselineChecksum);

        watch.reset();
        size_t fastChecksum;
        watch.start();
        foreach (i; 0 .. repeats)
        {
            bool success;
            auto r = fast.tryRoi(windows[i % 4], success);
            require(success, "immutable verified ROI benchmark");
            fastChecksum += r.channelCount + r.intrinsic[i % n].semanticId;
        }
        watch.stop();
        writeln("verified_immutable_roi,", n, ",", repeats, ",",
            watch.peek.total!"usecs", ",", fastChecksum);
        require(baselineChecksum == fastChecksum,
            "same visible control-plane result");
    }
}


version (M326_NEGATIVE_FORGED_CAPABILITY)
{
    import m3_2_channel_metadata.contract : ResearchVerifiedSemanticImage;

    @safe ValidatedImmutableImage negativeForgeValidated()
    {
        // Exact current private constructor arity and argument type:
        // a previous two-argument fixture could reject for the wrong
        // reason after M3.2.11 changed the constructor signature.
        // This must fail for PRIVACY, not argument count mismatch.
        return ValidatedImmutableImage(ResearchVerifiedSemanticImage.init);
    }
}

version (M3212_NEGATIVE_VERIFIED_TOKEN_FORGERY)
{
    import m3_2_channel_metadata.contract : ResearchVerifiedSemanticImage;

    @safe ResearchVerifiedSemanticImage negativeForgeVerifiedToken(
        return scope ImageView!float unchecked,
        return scope immutable(ChannelDescriptor)[] ids,
        return scope immutable(IntrinsicChannel)[] meanings
    )
    {
        // Attempt the exact arity of the private M3.2.12
        // semantic validator token constructor from outside module.
        return ResearchVerifiedSemanticImage(unchecked, ids, meanings);
    }
}


/*
 * M3.2.7 XPS qualification workload. Construction, .idup and resource
 * import are excluded from the timed ROI loops. These remain important
 * separately measured costs; no code here bypasses lifetime constraints.
 */
private void benchXps(string[] args)
{
    import std.conv : to;

    const size_t iterations =
        args.length > 2 ? to!size_t(args[2]) : 50_000;
    const size_t rounds =
        args.length > 3 ? to!size_t(args[3]) : 15;
    const size_t warmups =
        args.length > 4 ? to!size_t(args[4]) : 3;
    require(iterations > 0 && rounds > 0, "nonzero benchmark settings");

    writeln("roi_xps_schema,channels,round,slot,mode,iterations,elapsed_ns,checksum");

    foreach (n; [cast(size_t)3, 17, 64, 256, 1024])
    {
        auto idsBuffer = new ChannelDescriptor[](n);
        auto meaningsBuffer = new IntrinsicChannel[](n);
        foreach (i; 0 .. n)
        {
            const id = cast(uint)(6000 + i);
            idsBuffer[i] = ChannelDescriptor(id);
            meaningsBuffer[i] = IntrinsicChannel(
                id, "opaque", "unit", true, 0.5f, -10.0f
            );
        }
        immutable(ChannelDescriptor)[] ids = idsBuffer.idup;
        immutable(IntrinsicChannel)[] meanings = meaningsBuffer.idup;

        auto lease = rasterFixture(n, Layout.planar, false);
        auto source = lease.view();

        VerifiedRoiError verifiedError;
        auto fast = tryMakeValidatedImmutableImage(
            source, ids, meanings, RasterView!ubyte.init,
            false, verifiedError
        );
        require(verifiedError == VerifiedRoiError.none,
            "XPS candidate preflight");

        ImageViewValidationError viewError;
        auto base = tryMakeImageView!float(
            source, ids, RasterView!ubyte.init, false, viewError
        );
        require(viewError == ImageViewValidationError.none,
            "XPS baseline view preflight");

        MetadataBorrowError borrowError;
        auto conservative = tryBorrowSemanticImage(
            base, meanings, borrowError
        );
        require(borrowError == MetadataBorrowError.none,
            "XPS conservative preflight");

        runXpsRoiBenchmark(
            source, conservative, fast, meanings, n,
            iterations, rounds, warmups
        );
    }
}


/* M3.2.9 independent source-independent safety and oracle fixtures. */
private void preparedCorrectness()
{
    foreach (n; [cast(size_t)3, 17, 64, 256])
    foreach (layout; [Layout.planar, Layout.interleaved])
    foreach (masked; [false, true])
    {
        auto idsBuffer = new ChannelDescriptor[](n);
        auto meaningBuffer = new IntrinsicChannel[](n);
        foreach (i; 0 .. n)
        {
            const id = cast(uint)(6000 + i);
            idsBuffer[i] = ChannelDescriptor(id);
            meaningBuffer[i] = IntrinsicChannel(
                id, "band", "unknown", true, 0.5f, -10.0f);
        }
        immutable(ChannelDescriptor)[] ids = idsBuffer.idup;
        immutable(IntrinsicChannel)[] meanings = meaningBuffer.idup;
        auto pixels = rasterFixture(n, layout, true);
        RasterLease!ubyte maskLease;
        if (masked)
            maskLease = validityFixture();
        auto view = pixels.view();
        auto mask = masked ? maskLease.view() : RasterView!ubyte.init;

        VerifiedRoiError createError;
        auto validated = tryMakeValidatedImmutableImage(
            view, ids, meanings, mask, masked, createError);
        require(createError == VerifiedRoiError.none,
            "prepared image factory");

        const binding = ColourBinding(
            n - 1, n - 2, n - 3, DeclaredColour.unspecified);
        SemanticMapError prepErr;
        auto prepared = tryPrepareSemanticMap(
            validated, binding, ValueInterpretation.physical, prepErr);
        require(prepErr == SemanticMapError.none && prepared.isPrepared,
            "prepared capability construction");

        ImageViewValidationError imageError;
        auto base = tryMakeImageView!float(
            view, ids, mask, masked, imageError);
        require(imageError == ImageViewValidationError.none,
            "prepared old image factory");
        MetadataBorrowError borrowError;
        auto conservative = tryBorrowSemanticImage(
            base, meanings, borrowError);
        require(borrowError == MetadataBorrowError.none,
            "prepared original compound borrow");

        auto a = rasterFixture(3, Layout.planar, false);
        auto b = rasterFixture(3, Layout.planar, false);
        auto d = rasterFixture(3, Layout.planar, false);
        bool ok;
        scope auto dstA = a.tryWritableView(ok);
        require(ok, "prepared baseline destination");
        scope auto dstB = b.tryWritableView(ok);
        require(ok, "prepared verified destination");
        scope auto dstD = d.tryWritableView(ok);
        require(ok, "prepared prepared destination");
        require(conservative.mapInto(
            binding, ValueInterpretation.physical, dstA)
            == SemanticMapError.none, "old physical map");
        require(validated.mapInto(
            binding, ValueInterpretation.physical, dstB)
            == SemanticMapError.none, "validated physical map");
        require(prepared.mapInto(dstD) == SemanticMapError.none,
            "prepared physical map");

        comparePixels(a.view(), b.view());
        comparePixels(a.view(), d.view());
        verifyPixelOutput(d.view(), n, masked);

        // Keep a previously prepared binding across nested ROIs:
        // no image descriptor or selected-band revalidation here.
        auto part = Region2D(1, 1, 3, 2);
        bool childOk;
        auto first = prepared.tryRoi(part, childOk);
        require(childOk && first.isPrepared, "prepared child ROI");
        auto nested = first.tryRoi(Region2D(0, 0, 2, 1), childOk);
        require(childOk && nested.isPrepared, "prepared nested ROI");
        auto small = rasterFixture(3, Layout.planar, false);
        // Destination must be exactly 2x1, not a view into a 7x5
        // parent with mismatched logical extent.
        auto smallOwner = rasterFixture(3, Layout.planar, false);
        bool writableOk;
        scope auto smallOutput = smallOwner.tryWritableView(writableOk);
        require(writableOk, "prepared small writable");
        scope auto smallRoi = smallOutput.tryRoi(
            Region2D(0, 0, 2, 1), writableOk);
        require(writableOk, "prepared small destination ROI");
        require(nested.mapInto(smallRoi) == SemanticMapError.none,
            "nested prepared mapping");
        foreach (component; 0 .. 3)
        foreach (x; 0 .. 2)
        {
            float got;
            require(smallRoi.trySample(component, x, 0, got),
                "nested read");
            const sx = x + 1;
            const sy = cast(size_t)1;
            const expected = masked && ((sx + sy) % 11 == 0)
                ? 0.0f
                : inputValue(n - 1 - component, sx, sy) * 0.5f - 10.0f;
            require(got == expected, "nested exact value oracle");
        }
        require(prepared.mapInto(smallRoi)
            == SemanticMapError.destinationMismatch,
            "bad destination rejected before writes");
        auto invalid = prepared.tryRoi(
            Region2D(7, 5, 1, 1), childOk);
        require(!childOk && !invalid.isPrepared,
            "invalid prepared ROI never appears valid");
    }

    // Negative cases are tested on an otherwise verified source.
    auto source = rasterFixture(3, Layout.planar, true);
    immutable(ChannelDescriptor)[3] ids = [
        ChannelDescriptor(1), ChannelDescriptor(2), ChannelDescriptor(3)];
    immutable(IntrinsicChannel)[3] uncalibrated = [
        IntrinsicChannel(1, "", "", false, 0, 0),
        IntrinsicChannel(2, "", "", false, 0, 0),
        IntrinsicChannel(3, "", "", false, 0, 0)];
    VerifiedRoiError verifyError;
    auto image = tryMakeValidatedImmutableImage(
        source.view(), ids[], uncalibrated[],
        RasterView!ubyte.init, false, verifyError);
    require(verifyError == VerifiedRoiError.none,
        "prepare failure source valid");
    SemanticMapError err;
    auto binding = ColourBinding(
        0, 1, 2, DeclaredColour.unspecified);
    auto failed = tryPrepareSemanticMap(
        image, binding, ValueInterpretation.physical, err);
    require(err == SemanticMapError.missingCalibration
        && !failed.isPrepared, "missing calibration fails");
    auto stored = tryPrepareSemanticMap(
        image, binding, ValueInterpretation.stored, err);
    require(err == SemanticMapError.none && stored.isPrepared,
        "stored mode needs no calibration");
    failed = tryPrepareSemanticMap(
        image, ColourBinding(0, 0, 2, DeclaredColour.unspecified),
        ValueInterpretation.stored, err);
    require(err == SemanticMapError.invalidBinding && !failed.isPrepared,
        "duplicate component rejected");
    failed = tryPrepareSemanticMap(
        image, ColourBinding(0, 1, 9, DeclaredColour.unspecified),
        ValueInterpretation.stored, err);
    require(err == SemanticMapError.invalidBinding && !failed.isPrepared,
        "out-of-range binding rejected");
    failed = tryPrepareSemanticMap(
        ValidatedImmutableImage.init, binding,
        ValueInterpretation.stored, err);
    require(err == SemanticMapError.metadataCountMismatch
        && !failed.isPrepared, "unverified image cannot prepare");

    auto storedOutput = rasterFixture(3, Layout.planar, false);
    bool writableOk;
    scope auto dst = storedOutput.tryWritableView(writableOk);
    require(writableOk, "prepared stored output");
    require(stored.mapInto(dst) == SemanticMapError.none,
        "stored mode maps correctly");
    foreach (c; 0 .. 3)
    foreach (y; 0 .. 5)
    foreach (x; 0 .. 7)
    {
        float got;
        require(storedOutput.view().trySample(c, x, y, got), "stored read");
        require(got == inputValue(c, x, y),
            "stored mode leaves samples uncalibrated");
    }
    PreparedSemanticMap inert;
    require(!inert.isPrepared
        && inert.mapInto(dst) == SemanticMapError.metadataCountMismatch,
        "default-inert prepared capability");

    immutable(IntrinsicChannel)[3] nonfinite = [
        IntrinsicChannel(1, "", "", true, float.nan, 0),
        IntrinsicChannel(2, "", "", true, 1, 0),
        IntrinsicChannel(3, "", "", true, 1, 0)];
    image = tryMakeValidatedImmutableImage(
        source.view(), ids[], nonfinite[],
        RasterView!ubyte.init, false, verifyError);
    require(verifyError == VerifiedRoiError.none,
        "nonfinite source identity still valid");
    failed = tryPrepareSemanticMap(
        image, binding, ValueInterpretation.physical, err);
    require(err == SemanticMapError.invalidCalibration
        && !failed.isPrepared, "NaN calibration rejected");

    // A one-channel image is structurally valid but cannot satisfy the
    // explicitly required distinct three-component binding.
    auto onePixel = rasterFixture(1, Layout.planar, true);
    immutable(ChannelDescriptor)[1] oneId = [ChannelDescriptor(18)];
    immutable(IntrinsicChannel)[1] oneMeaning = [
        IntrinsicChannel(18, "one", "unknown", true, 1.0f, 0.0f)
    ];
    auto one = tryMakeValidatedImmutableImage(
        onePixel.view(), oneId[], oneMeaning[],
        RasterView!ubyte.init, false, verifyError);
    require(verifyError == VerifiedRoiError.none,
        "single-band input remains valid");
    failed = tryPrepareSemanticMap(
        one, binding, ValueInterpretation.stored, err);
    require(err == SemanticMapError.invalidBinding
        && !failed.isPrepared,
        "three-band binding cannot be prepared on one band");

    immutable(IntrinsicChannel)[3] infiniteOffset = [
        IntrinsicChannel(1, "", "", true, 1.0f, float.infinity),
        IntrinsicChannel(2, "", "", true, 1.0f, 0.0f),
        IntrinsicChannel(3, "", "", true, 1.0f, 0.0f)
    ];
    image = tryMakeValidatedImmutableImage(
        source.view(), ids[], infiniteOffset[],
        RasterView!ubyte.init, false, verifyError);
    require(verifyError == VerifiedRoiError.none,
        "infinite calibration metadata passes identity validation");
    failed = tryPrepareSemanticMap(
        image, binding, ValueInterpretation.physical, err);
    require(err == SemanticMapError.invalidCalibration
        && !failed.isPrepared,
        "infinite calibration rejected before output writes");

    // M3.2.10: validate one-shot error priority independently of the
    // shared pixel execution path; preflight must not write any samples.
    ImageViewValidationError oneShotViewError;
    auto original = tryMakeImageView!float(
        source.view(), ids[], RasterView!ubyte.init,
        false, oneShotViewError
    );
    require(oneShotViewError == ImageViewValidationError.none,
        "one-shot error precedence view");
    auto tooFew = rasterFixture(2, Layout.planar, false);
    scope auto invalidDestination = tooFew.tryWritableView(writableOk);
    require(writableOk, "invalid-destination fixture writable");

    immutable(IntrinsicChannel)[3] wrongIds = [
        IntrinsicChannel(1, "", "", true, 1.0f, 0.0f),
        IntrinsicChannel(900, "", "", true, 1.0f, 0.0f),
        IntrinsicChannel(3, "", "", true, 1.0f, 0.0f)
    ];
    require(mapComponentsInto(
        original, wrongIds[], binding, ValueInterpretation.physical,
        invalidDestination
    ) == SemanticMapError.metadataIdentityMismatch,
        "metadata identity still precedes destination mismatch");

    require(mapComponentsInto(
        original, uncalibrated[], binding,
        ValueInterpretation.physical, invalidDestination
    ) == SemanticMapError.destinationMismatch,
        "destination mismatch still precedes missing calibration");

    // Destination mutation must not occur when *preflight* fails.
    require(invalidDestination.trySetSample(0, 0, 0, 123.0f),
        "write sentinel");
    require(mapComponentsInto(
        original, uncalibrated[], binding, ValueInterpretation.physical,
        invalidDestination
    ) == SemanticMapError.destinationMismatch,
        "repeat bad preflight");
    float sentinel;
    require(tooFew.view().trySample(0, 0, 0, sentinel)
        && sentinel == 123.0f,
        "one-shot preflight preserved destination");

    writeln("M3.2.9 PASS: prepared mapping and failure oracle");
}

version (M329_NEGATIVE_FORGED_PREPARED)
{
    import m3_2_channel_metadata.contract : ResearchCheckedExecution;

    @safe PreparedSemanticMap forgePrepared()
    {
        // Exact current private constructor arity and argument type.
        // This test MUST be rejected for visibility, never for an
        // outdated argument count or a missing import.
        return PreparedSemanticMap(ResearchCheckedExecution.init);
    }
}

void main(string[] args)
{
    testFactoryFailures();
    foreach (n; [cast(size_t)3, 4, 17, 64, 256])
    {
        exercise(n, Layout.planar, true);
        exercise(n, Layout.interleaved, false);
    }
    writeln("M3.2.6 PASS: immutable verified-once ROI/negative cases");

    if (args.length > 1
        && (args[1] == "--reuse-gc-order-smoke"
            || args[1] == "--reuse-gc-order-benchmark"))
    {
        import std.conv : to;
        const smoke = args[1] == "--reuse-gc-order-smoke";
        const size_t rounds = args.length > 2
            ? to!size_t(args[2]) : (smoke ? 2 : 8);
        const size_t warmups = args.length > 3
            ? to!size_t(args[3]) : (smoke ? 1 : 2);
        const size_t processSeed = args.length > 4
            ? to!size_t(args[4]) : 0;
        runConsumerReuseGcOrderExperiment(
            smoke, rounds, warmups, processSeed);
        return;
    }

    if (args.length > 1
        && (args[1] == "--reuse-consumer-smoke"
            || args[1] == "--reuse-consumer-benchmark"))
    {
        import std.conv : to;
        const smoke = args[1] == "--reuse-consumer-smoke";
        const size_t rounds = args.length > 2
            ? to!size_t(args[2]) : (smoke ? 2 : 8);
        const size_t warmups = args.length > 3
            ? to!size_t(args[3]) : (smoke ? 1 : 2);
        runConsumerReuseExperiment(smoke, rounds, warmups);
        return;
    }

    if (args.length > 1 && args[1] == "--setup-observed-smoke")
    {
        runPreparationObservedSmoke();
        return;
    }

    if (args.length > 1 &&
        (args[1] == "--setup-challenge-smoke"
         || args[1] == "--setup-challenge"))
    {
        import std.conv : to;
        const bool smoke = args[1] == "--setup-challenge-smoke";
        const size_t loops = args.length > 2
            ? to!size_t(args[2]) : (smoke ? 24 : 20000);
        const size_t rounds = args.length > 3
            ? to!size_t(args[3]) : (smoke ? 2 : 12);
        const size_t warmups = args.length > 4
            ? to!size_t(args[4]) : (smoke ? 1 : 2);
        runPreparationChallenge(smoke, loops, rounds, warmups);
        return;
    }

    if (args.length > 1 && args[1] == "--prepared-smoke")
    {
        preparedCorrectness();
        return;
    }

    if (args.length > 1 && args[1] == "--benchmark")
        bench();
    else if (args.length > 1 && args[1] == "--benchmark-xps")
        benchXps(args);
    else if (args.length > 1 &&
        (args[1] == "--prepared-consumer-smoke" ||
         args[1] == "--prepared-consumer-benchmark"))
    {
        import std.conv : to;
        const bool smoke = args[1] == "--prepared-consumer-smoke";
        const size_t iterations = args.length > 2
            ? to!size_t(args[2]) : (smoke ? 2 : 12);
        const size_t rounds = args.length > 3
            ? to!size_t(args[3]) : (smoke ? 2 : 12);
        const size_t warmups = args.length > 4
            ? to!size_t(args[4]) : (smoke ? 1 : 2);
        runConsumerWorkload(smoke, iterations, rounds, warmups, true);
    }
    else if (args.length > 1 &&
        (args[1] == "--consumer-smoke" ||
         args[1] == "--consumer-benchmark"))
    {
        import std.conv : to;
        const bool smoke = args[1] == "--consumer-smoke";
        const size_t iterations = args.length > 2
            ? to!size_t(args[2]) : (smoke ? 2 : 64);
        const size_t rounds = args.length > 3
            ? to!size_t(args[3]) : (smoke ? 1 : 9);
        const size_t warmups = args.length > 4
            ? to!size_t(args[4]) : (smoke ? 0 : 2);
        runConsumerWorkload(smoke, iterations, rounds, warmups);
    }
}


/*
 * M3.2.11 compile-negative fixtures: ordinary external @safe code
 * cannot call the raw kernel or forge its sealed execution capability.
 */
version (M3211_NEGATIVE_DIRECT_KERNEL)
{
    import m3_2_channel_metadata.contract;
    import raster : WritableRasterView;

    @safe SemanticMapError negativeDirectKernelCall()
    {
        return m3_2_channel_metadata.contract.researchExecuteCheckedPixels(
            ImageView!float.init,
            [cast(size_t)0, 1, 2],
            [1.0f, 1.0f, 1.0f],
            [0.0f, 0.0f, 0.0f],
            ValueInterpretation.stored,
            WritableRasterView!float.init
        );
    }
}

version (M3211_NEGATIVE_FORGED_EXECUTION)
{
    import m3_2_channel_metadata.contract : ResearchCheckedExecution;

    @safe ResearchCheckedExecution negativeForgeExecutor()
    {
        return ResearchCheckedExecution(
            ImageView!float.init,
            [cast(size_t)0, 1, 2],
            [1.0f, 1.0f, 1.0f],
            [0.0f, 0.0f, 0.0f],
            ValueInterpretation.stored
        );
    }
}

