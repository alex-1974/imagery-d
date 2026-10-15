module app;

// Independently built DUB executable. No private imagery module imports.
// Pixel oracle implements sRGB transfer and Porter-Duff equations separately
// from the color-d functions used by the library under test.
import core.stdc.stdlib : malloc;
import core.memory : GC;
import std.math : pow;
import std.stdio : writeln;

import imagery.presentation.composite :
    DecodedRgbaLayer, RgbaAssociation, RgbaCompositeError, RgbaEncoding,
    ResearchPreparedRgbaContext, tryPrepareRgbaContext,
    tryCompositeRgbaSourceOver, tryCompositeRgbaSourceOverPrepared;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    RasterCopyError, copyInto, tryAdoptMallocResource, tryImportOwnedRaster;
import raster : OwnedRasterImportError, OwnedRasterResourceDisposition;
import color : SRgba8;
import owned_payload_budget : checkOwnedPayloadBudgetContract;
import owned_payload_budget :
    OwnedPayloadPlan, OwnedPayloadStatus, tryPlanOwnedRgbaPayload;
import owned_reservation_probe :
    RoiReservationLedger, TicketPhase, checkReservationLedgerContract;
import owned_delivery_token :
    DeliveryAccounting, OwnedDeliveryCache, OwnedDeliveryHandle;
import owned_delivery_bench : runIndependentDeliveryBenchmark;
import owned_generation_delivery :
    GenerationAccounting, GenerationCache, GenerationDelivery, GenerationPhase;
import generation_memory_linux : MemorySnapshot, sampleGenerationMemory;
import mixed_delivery_schedule :
    plannedMixedHit, mixedSlot, alternateMixedKey, checkMixedDeliverySchedule;

private enum Layout : ubyte { planar, interleaved }
private enum size_t width = 8, height = 6;

private struct Interpretation
{
    RgbaEncoding encoding;
    RgbaAssociation association;
}

private struct Bytes
{
    ubyte r;
    ubyte g;
    ubyte b;
    ubyte a;
}

private void require(bool condition, string explanation)
{
    if (!condition)
        throw new Exception("M3 RGBA compositing consumer: " ~ explanation);
}

// Independent, deterministic image content including hidden RGB when a=0.
private Bytes fixture(size_t layer, size_t x, size_t y,
    Interpretation interpretation)
{
    const uint alphaClass = cast(uint)((x + 2 * y + layer) % 4);
    const uint alpha = alphaClass == 0 ? 0
        : alphaClass == 1 ? 128 : alphaClass == 2 ? 255 : 64;
    uint r = cast(uint)((37 * x + 17 * y + 71 * layer + 13) % 256);
    uint g = cast(uint)((11 * x + 41 * y + 43 * layer + 29) % 256);
    uint b = cast(uint)((19 * x + 23 * y + 97 * layer + 53) % 256);
    if (interpretation.association == RgbaAssociation.premultiplied)
    {
        // These raw bytes represent quantized linear-light premultiplication.
        r = (r * alpha + 127) / 255;
        g = (g * alpha + 127) / 255;
        b = (b * alpha + 127) / 255;
    }
    return Bytes(cast(ubyte)r, cast(ubyte)g,
        cast(ubyte)b, cast(ubyte)alpha);
}

private RasterLease!ubyte makeImage(
    size_t w, size_t h, Layout layout,
    size_t layer, Interpretation interpretation, bool populate
)
{
    const size_t count = w * h * 4;
    auto storage = cast(ubyte*)malloc(count);
    require(storage !is null, "malloc backing");
    OwnedByteResource owned;
    require(tryAdoptMallocResource(storage, count, owned),
        "adopt malloc backing");

    PlaneByteLayout[4] planes;
    foreach (channel; 0 .. 4)
        planes[channel] = layout == Layout.planar
            ? PlaneByteLayout(channel * w * h, cast(ptrdiff_t)w, 1)
            : PlaneByteLayout(channel, cast(ptrdiff_t)(w * 4), 4);

    RasterLease!ubyte lease;
    const result = tryImportOwnedRaster!ubyte(
        owned, planes[], Region2D(0, 0, w, h), lease);
    require(result.ok, "import writable image backing");
    if (populate)
    {
        bool ok;
        scope auto target = lease.tryWritableView(ok);
        require(ok, "create writable image");
        foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            const px = fixture(layer, x, y, interpretation);
            require(target.trySetSample(0, x, y, px.r) &&
                target.trySetSample(1, x, y, px.g) &&
                target.trySetSample(2, x, y, px.b) &&
                target.trySetSample(3, x, y, px.a),
                "populate independent image");
        }
    }
    return lease;
}

// One independent malloc-backed, packed-SRgba8 scratch or target. Ownership
// never escapes the caller; no rewriting of raster's import/provenance rules.
private RasterLease!SRgba8 makeOwnedPacked(size_t w, size_t h)
{
    require(w > 0 && h > 0 && h <= size_t.max / 4 &&
        w <= size_t.max / (h * 4) && w <= cast(size_t)ptrdiff_t.max / 4,
        "bounded packed scratch");
    const bytes = 4 * w * h;
    auto raw = cast(ubyte*)malloc(bytes);
    require(raw !is null, "malloc independent packed scratch backing");
    OwnedByteResource owned;
    require(tryAdoptMallocResource(raw, bytes, owned),
        "adopt packed scratch");
    const PlaneByteLayout[1] plane =
        [PlaneByteLayout(0, cast(ptrdiff_t)(w * 4), 4)];
    RasterLease!SRgba8 lease;
    require(tryImportOwnedRaster!SRgba8(
        owned, plane[], Region2D(0, 0, w, h), lease).ok,
        "import owned packed scratch");
    return lease;
}

// Candidate B: create a NEW owned packed result and publish only after
// the entire prepared image and its packing have completed successfully.
// This is deliberately local to the independent consumer, NOT a public API.
// Caller-supplied target/output overlap rejection is a DIFFERENT contract.
//
// Memory allocation/import failures are handled by the consumer's existing
// checked malloc/import helpers (which throw). Classified RgbaCompositeError
// results below refer to image-domain and sample/packing failures only.
private RgbaCompositeError tryCompositeOwnedPackedResearch(
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
    Region2D roi, ref RasterLease!SRgba8 published)
{
    // The caller retains previous results and must supply an empty output.
    require(published.view().planeCount == 0,
        "owned result must be empty before publication");

    // This also excludes overflow in the existing bounded makeImage helper.
    if (roi.width == 0 || roi.height == 0 ||
        roi.width > cast(size_t)ptrdiff_t.max / 4 ||
        roi.height > size_t.max / 4 ||
        roi.width > size_t.max / (roi.height * 4))
        return RgbaCompositeError.invalidRegion;

    auto scratchFour = makeImage(roi.width, roi.height,
        Layout.interleaved, 2,
        Interpretation(RgbaEncoding.encodedSRgb,
            RgbaAssociation.straight), false);

    bool valid;
    {
        scope auto scratchWriter = scratchFour.tryWritableView(valid);
        require(valid, "owned result internal four-channel writable view");
        const status = tryCompositeRgbaSourceOverPrepared(
            prepared, upper, lower, roi, scratchWriter);
        if (status != RgbaCompositeError.none)
            return status; // Never publish partial scratch.
    }

    // Newly allocated packing buffer will become the RESULT itself.
    // In contrast to the old buffered path, there is no third output buffer
    // and no final packed-scratch -> packed-destination copyInto pass.
    auto stagedPacked = makeOwnedPacked(roi.width, roi.height);
    {
        scope auto src = scratchFour.view();
        scope auto target = stagedPacked.tryWritableView(valid);
        require(valid, "owned result internal packed writable view");
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        {
            ubyte[4] channels;
            foreach (p; 0 .. 4)
                if (!src.trySample(p, x, y, channels[p]))
                    return RgbaCompositeError.sampleFailure;
            if (!target.trySetSample(0, x, y,
                    SRgba8(channels[0], channels[1],
                           channels[2], channels[3])))
                return RgbaCompositeError.sampleFailure;
        }
    }

    // Publish only after ALL computed/packed pixels are valid. Assignment
    // retains raster-d's existing shared backing control, no new free owner.
    published = stagedPacked;
    return RgbaCompositeError.none;
}

private void checkOwnedPackedResult(
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
    Region2D roi, ref RasterLease!ubyte priorReference)
{
    RasterLease!SRgba8 result;
    require(tryCompositeOwnedPackedResearch(
            prepared, upper, lower, roi, result)
        == RgbaCompositeError.none,
        "candidate owned-packed construction succeeds");
    {
        scope auto packed = result.view();
        scope auto expected = priorReference.view();
        require(packed.planeCount == 1 &&
                packed.width == roi.width && packed.height == roi.height,
                "published packed result has exact ROI size");
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        {
            SRgba8 pixel;
            ubyte[4] channels;
            require(packed.trySample(0, x, y, pixel),
                "read published packed pixel");
            foreach (p; 0 .. 4)
                require(expected.trySample(p, x, y, channels[p]),
                    "read independently qualified reference pixel");
            require(pixel == SRgba8(channels[0], channels[1],
                                  channels[2], channels[3]),
                "owned-packed result equals independent four-channel reference");
        }
    }

    // A failed operation must publish NO lease, not a partially written
    // or inert-looking but physically retained result.
    {
        RasterLease!SRgba8 rejected;
        ResearchPreparedRgbaContext inert;
        require(tryCompositeOwnedPackedResearch(
                inert, upper, lower, roi, rejected)
            == RgbaCompositeError.invalidPreparedContext &&
                rejected.view().planeCount == 0,
            "inert context does not publish a result");
        require(tryCompositeOwnedPackedResearch(
                prepared, upper, lower,
                Region2D(size_t.max, 0, 1, 1), rejected)
            == RgbaCompositeError.invalidRegion &&
                rejected.view().planeCount == 0,
            "invalid ROI does not publish a result");
    }

    // Recompute a different region using the SAME configuration; previous
    // packed result must remain owned and byte-for-byte unchanged.
    if (roi.width > 2 && roi.height > 2)
    {
        auto prior = result.view();
        SRgba8 before;
        require(prior.trySample(0, 0, 0, before),
            "read original owned-result before second request");
        RasterLease!SRgba8 second;
        require(tryCompositeOwnedPackedResearch(
                prepared, upper, lower,
                Region2D(roi.x + 1, roi.y + 1, 2, 2), second)
            == RgbaCompositeError.none,
            "owned result supports independent second ROI");
        SRgba8 after;
        require(prior.trySample(0, 0, 0, after) && after == before,
            "second result does not modify first owned result");
        scope auto two = second.view();
        scope auto original = result.view();
        foreach (y; 0 .. 2)
        foreach (x; 0 .. 2)
        {
            SRgba8 actual, expected;
            require(two.trySample(0, x, y, actual) &&
                    original.trySample(0, x + 1, y + 1, expected) &&
                    actual == expected,
                    "second owned result equals original ROI crop");
        }
    }
}

// Research-only feasibility probe: a two-buffer, one-plane copy commit.
// All source color/PM/quantization failures are reported *before* writing
// final packed target. Public raster.copyInto alone proves scratch/dest
// physical nonoverlap and destination injectivity before the copy.
// This is NOT original source/dest overlap REJECTION. With independent
// scratch, all inputs have been consumed before final output mutation.
private void checkBufferedPackedCommit(
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
    Region2D roi,
    ref RasterLease!ubyte priorReference)
{
    auto scratchBytes = makeImage(roi.width, roi.height,
        Layout.interleaved, 2,
        Interpretation(RgbaEncoding.encodedSRgb,
            RgbaAssociation.straight), false);
    auto scratchPacked = makeOwnedPacked(roi.width, roi.height);
    auto destPacked = makeOwnedPacked(roi.width, roi.height);
    // Verify the caller-visible final target is unchanged whenever an
    // image-domain preparation fails before a packed final copy.
    enum auto rejectMarker = SRgba8(203, 19, 71, 137);
    bool writable;
    {
        scope auto finalWriter = destPacked.tryWritableView(writable);
        require(writable, "initialize packed final sentinel");
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
            require(finalWriter.trySetSample(0, x, y, rejectMarker),
                "set packed final sentinel");
    }
    {
        ResearchPreparedRgbaContext inert;
        scope auto scratchWriter = scratchBytes.tryWritableView(writable);
        require(writable, "prepare failure scratch writer");
        require(tryCompositeRgbaSourceOverPrepared(
            inert, upper, lower, roi, scratchWriter)
            == RgbaCompositeError.invalidPreparedContext,
            "inert context blocks final commit");
    }
    {
        scope auto untouched = destPacked.view();
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width) {
            SRgba8 actual;
            require(untouched.trySample(0, x, y, actual) &&
                actual == rejectMarker,
                "invalid prepared computation leaves packed final untouched");
        }
    }
    {
        scope auto scratchTarget = scratchBytes.tryWritableView(writable);
        require(writable, "independent four-plane scratch writer");
        require(tryCompositeRgbaSourceOverPrepared(prepared,
            upper, lower, roi, scratchTarget) == RgbaCompositeError.none,
            "prepare fully checked four-plane output before final commit");
    }
    {
        scope auto four = scratchBytes.view();
        scope auto packedTarget = scratchPacked.tryWritableView(writable);
        require(writable, "independent packed staging writer");
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        {
            ubyte[4] channels;
            foreach (p; 0 .. 4)
                require(four.trySample(p, x, y, channels[p]),
                    "read prepared scratch channels");
            require(packedTarget.trySetSample(0, x, y,
                SRgba8(channels[0], channels[1],
                       channels[2], channels[3])),
                "pack staged complete pixel");
        }
    }
    // Public copy preflights source/destination exact byte overlap,
    // injectivity and shape before writing one packed RGBA sample stream.
    {
        scope auto packedSource = scratchPacked.view();
        scope auto packedDest = destPacked.tryWritableView(writable);
        require(writable, "packed final writer");
        RasterCopyError error;
        require(copyInto(packedSource, 0, packedDest, 0, error)
            && error == RasterCopyError.none,
            "single-plane public copy commit");
    }
    {
        scope auto copied = destPacked.view();
        scope auto expected = priorReference.view();
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        {
            SRgba8 result;
            require(copied.trySample(0, x, y, result),
                "read packed committed pixel");
            ubyte[4] refBytes;
            foreach (p; 0 .. 4)
                require(expected.trySample(p, x, y, refBytes[p]),
                    "read existing four-plane semantic oracle");
            require(result == SRgba8(refBytes[0], refBytes[1],
                refBytes[2], refBytes[3]),
                "buffered one-plane commit is byte-exact");
        }
    }
    // A structurally invalid destination must be rejected by public
    // copyInto *before the first byte of the separate final target* changes.
    {
        auto wrongShape = makeOwnedPacked(roi.width + 1, roi.height);
        {
            bool ok;
            scope auto incorrectWriter = wrongShape.tryWritableView(ok);
            require(ok, "shape-negative target writer");
            foreach (y; 0 .. roi.height)
            foreach (x; 0 .. roi.width + 1)
                require(incorrectWriter.trySetSample(0, x, y, rejectMarker),
                    "shape-negative target marker");
        }
        {
            scope auto source = scratchPacked.view();
            bool ok;
            scope auto invalidWriter = wrongShape.tryWritableView(ok);
            require(ok, "shape-negative writer borrow");
            RasterCopyError error;
            require(!copyInto(source, 0, invalidWriter, 0, error) &&
                error == RasterCopyError.shapeMismatch,
                "public copy rejects mismatched packed target before write");
        }
        {
            scope auto after = wrongShape.view();
            foreach (y; 0 .. roi.height)
            foreach (x; 0 .. roi.width + 1) {
                SRgba8 pixel;
                require(after.trySample(0, x, y, pixel) &&
                    pixel == rejectMarker,
                    "shape mismatch keeps complete packed target unchanged");
            }
        }
    }
    // A deliberately overlapping scratch/destination operation is
    // rejected *without a write*. We check all pixels, not only error.
    {
        scope auto before = scratchPacked.view();
        bool ok;
        scope auto aliasDest = scratchPacked.tryWritableView(ok);
        require(ok, "scratch alias writable view");
        RasterCopyError error;
        require(!copyInto(before, 0, aliasDest, 0, error),
            "same physical scratch/destination rejected");
        require(error == RasterCopyError.sourceDestinationOverlap,
            "precise scratch/target overlap classification");
    }
    {
        scope auto after = scratchPacked.view();
        scope auto output = destPacked.view();
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        {
            SRgba8 prior, post;
            require(after.trySample(0, x, y, prior) &&
                output.trySample(0, x, y, post) &&
                prior == post,
                "overlap rejection leaves all prepared pixels intact");
        }
    }
}

private double decode(double s)
{
    return s <= 0.04045 ? s / 12.92
        : pow((s + 0.055) / 1.055, 2.4);
}

private double encode(double l)
{
    return l <= 0.0031308 ? l * 12.92
        : 1.055 * pow(l, 1.0 / 2.4) - 0.055;
}

private struct LinearPremul
{
    double r;
    double g;
    double b;
    double a;
}

private LinearPremul oracleInput(Bytes value, Interpretation interpretation)
{
    const double alpha = cast(double)value.a / 255.0;
    double r = cast(double)value.r / 255.0;
    double g = cast(double)value.g / 255.0;
    double b = cast(double)value.b / 255.0;
    if (interpretation.encoding == RgbaEncoding.encodedSRgb)
    {
        r = decode(r);
        g = decode(g);
        b = decode(b);
    }
    if (interpretation.association == RgbaAssociation.straight)
    {
        r *= alpha;
        g *= alpha;
        b *= alpha;
    }
    return LinearPremul(r, g, b, alpha);
}

private ubyte nearestByte(double s)
{
    // Expected valid samples all lie in the closed 0..1 domain.
    require(s >= 0.0 && s <= 1.0, "oracle channel in gamut");
    return cast(ubyte)cast(uint)(s * 255.0 + 0.5);
}

private Bytes referencePixel(
    size_t x, size_t y, Interpretation foreground,
    Interpretation background, double opacity
)
{
    const top = oracleInput(fixture(0, x, y, foreground), foreground);
    const bottom = oracleInput(fixture(1, x, y, background), background);
    const double sourceA = top.a * opacity;
    const double factor = 1.0 - sourceA;
    const double alpha = sourceA + bottom.a * factor;
    double r = 0;
    double g = 0;
    double b = 0;
    if (alpha != 0.0)
    {
        r = encode((top.r * opacity + bottom.r * factor) / alpha);
        g = encode((top.g * opacity + bottom.g * factor) / alpha);
        b = encode((top.b * opacity + bottom.b * factor) / alpha);
    }
    return Bytes(nearestByte(r), nearestByte(g), nearestByte(b),
        nearestByte(alpha));
}

private uint delta(ubyte a, ubyte b)
{
    return a >= b ? cast(uint)(a - b) : cast(uint)(b - a);
}

private void requireUntouched(
    ref RasterLease!ubyte lease, size_t w, size_t h,
    ubyte marker
)
{
    scope auto view = lease.view();
    foreach (y; 0 .. h)
    foreach (x; 0 .. w)
    foreach (component; 0 .. 4)
    {
        ubyte observed;
        require(view.trySample(component, x, y, observed) &&
            observed == marker, "rejected operation modified target");
    }
}

private uint execute(
    Layout topLayout, Layout bottomLayout, Layout outputLayout,
    Interpretation topType, Interpretation bottomType,
    Region2D roi, double opacity
)
{
    auto topLease = makeImage(
        width, height, topLayout, 0, topType, true);
    auto bottomLease = makeImage(
        width, height, bottomLayout, 1, bottomType, true);
    auto outLease = makeImage(
        roi.width, roi.height, outputLayout, 2, topType, false);
    auto preparedLease = makeImage(
        roi.width, roi.height, outputLayout, 2, topType, false);

    const top = DecodedRgbaLayer(
        topLease.view(), topType.encoding, topType.association);
    const bottom = DecodedRgbaLayer(
        bottomLease.view(), bottomType.encoding, bottomType.association);
    bool writable;
    scope auto output = outLease.tryWritableView(writable);
    require(writable, "get caller output writer");

    const before = GC.stats().allocatedInCurrentThread;
    const result = tryCompositeRgbaSourceOver(
        top, bottom, roi, opacity, output);
    const after = GC.stats().allocatedInCurrentThread;
    require(result == RgbaCompositeError.none,
        "compose both real images into caller target");
    require(before == after, "no GC bytes in compositing call");

    // Prepare *once*, storing only 256 exact sRGB8 channel values and
    // validated runtime opacity, and reuse for repeated pixel calls.
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(opacity, prepared)
        == RgbaCompositeError.none, "prepare valid runtime opacity");
    bool preparedWritable;
    scope auto preparedOutput =
        preparedLease.tryWritableView(preparedWritable);
    require(preparedWritable, "separate prepared output writer");
    const beforePrepared = GC.stats().allocatedInCurrentThread;
    require(tryCompositeRgbaSourceOverPrepared(
        prepared, top, bottom, roi, preparedOutput)
        == RgbaCompositeError.none, "first scoped prepared ROI mapping");
    require(tryCompositeRgbaSourceOverPrepared(
        prepared, top, bottom, roi, preparedOutput)
        == RgbaCompositeError.none, "second reused prepared ROI mapping");
    const afterPrepared = GC.stats().allocatedInCurrentThread;
    require(beforePrepared == afterPrepared,
        "zero per-thread GC bytes in both prepared calls");

    // A deliberately memory-costly fallback concept: two fresh disjoint
    // scratch buffers and one physically overlap-checked public copy.
    // Do not mistake this for a no-copy zip executor or a public API.
    checkBufferedPackedCommit(prepared, top, bottom, roi, outLease);
    checkOwnedPackedResult(prepared, top, bottom, roi, outLease);

    // A *different* logical ROI packet reuses the same configuration
    // without retaining the first call's borrowed source/destination view.
    const miniRoi = Region2D(roi.x + 1, roi.y + 1, 2, 2);
    auto miniLease = makeImage(
        2, 2, outputLayout, 2, topType, false);
    bool miniWritable;
    scope auto miniOutput = miniLease.tryWritableView(miniWritable);
    require(miniWritable, "separate scoped ROI packet writer");
    require(tryCompositeRgbaSourceOverPrepared(
        prepared, top, bottom, miniRoi, miniOutput)
        == RgbaCompositeError.none,
        "prepared context reuses across distinct ROI sizes/origins");
    scope auto miniReadback = miniLease.view();
    scope auto fullReadback = outLease.view();
    foreach (y; 0 .. 2)
    foreach (x; 0 .. 2)
    foreach (component; 0 .. 4)
    {
        ubyte originalByte, scopedByte;
        require(fullReadback.trySample(component, x + 1, y + 1,
                    originalByte) &&
                miniReadback.trySample(component, x, y, scopedByte) &&
                originalByte == scopedByte,
                "prepared context matches original on second ROI packet");
    }

    uint worst = 0;
    scope auto readback = outLease.view();
    scope auto preparedReadback = preparedLease.view();
    foreach (y; 0 .. roi.height)
    foreach (x; 0 .. roi.width)
    {
        const reference = referencePixel(
            roi.x + x, roi.y + y, topType, bottomType, opacity);
        const ubyte[4] expected = [
            reference.r, reference.g, reference.b, reference.a];
        foreach (component; 0 .. 4)
        {
            ubyte actual;
            require(readback.trySample(component, x, y, actual),
                "read all output pixels");
            ubyte preparedActual;
            require(preparedReadback.trySample(
                component, x, y, preparedActual) &&
                preparedActual == actual,
                "prepared sRGB8 LUT is byte-identical across all 432 scenes");
            const deviation = delta(actual, expected[component]);
            if (deviation > worst) worst = deviation;
            require(deviation <= 1,
                "independent linear-light RGBA/alpha/opacity pixel oracle");
        }
    }

    // Errors that are known in preflight must leave all output samples
    // untouched. Also check NaN opacity (not merely negative values).
    enum ubyte sentinel = 197;
    foreach (y; 0 .. roi.height)
    foreach (x; 0 .. roi.width)
    foreach (component; 0 .. 4)
        require(output.trySetSample(component, x, y, sentinel),
            "set failure marker");

    require(tryCompositeRgbaSourceOver(
        top, bottom, roi, double.nan, output)
        == RgbaCompositeError.invalidOpacity, "reject NaN opacity");
    requireUntouched(outLease, roi.width, roi.height, sentinel);

    // Inert .init and invalid preparations are classified before any write.
    foreach (y; 0 .. roi.height)
    foreach (x; 0 .. roi.width)
    foreach (component; 0 .. 4)
        require(preparedOutput.trySetSample(component, x, y, sentinel),
            "set prepared failure marker");
    ResearchPreparedRgbaContext inert;
    require(tryCompositeRgbaSourceOverPrepared(
        inert, top, bottom, roi, preparedOutput)
        == RgbaCompositeError.invalidPreparedContext,
        "reject inert prepared value");
    requireUntouched(preparedLease, roi.width, roi.height, sentinel);

    foreach (badOpacity; [double.nan, double.infinity, -0.1, 1.1])
    {
        ResearchPreparedRgbaContext invalid;
        require(tryPrepareRgbaContext(badOpacity, invalid)
            == RgbaCompositeError.invalidOpacity,
            "reject invalid prepared opacity");
        require(tryCompositeRgbaSourceOverPrepared(
            invalid, top, bottom, roi, preparedOutput)
            == RgbaCompositeError.invalidPreparedContext,
            "reject failed context preparation");
        requireUntouched(preparedLease, roi.width, roi.height, sentinel);
    }

    require(tryCompositeRgbaSourceOver(
        top, bottom, roi, -0.1, output)
        == RgbaCompositeError.invalidOpacity, "reject negative opacity");
    requireUntouched(outLease, roi.width, roi.height, sentinel);

    require(tryCompositeRgbaSourceOver(
        top, bottom, Region2D(width, height, 2, 2), opacity, output)
        == RgbaCompositeError.invalidRegion, "reject ROI outside source");
    requireUntouched(outLease, roi.width, roi.height, sentinel);

    // Invalid/missing input and destination-shape errors are preflight.
    const missingTop = DecodedRgbaLayer(
        typeof(top.pixels).init, topType.encoding, topType.association);
    require(tryCompositeRgbaSourceOver(
        missingTop, bottom, roi, opacity, output)
        == RgbaCompositeError.invalidLayer, "reject missing RGBA view");
    requireUntouched(outLease, roi.width, roi.height, sentinel);

    const unknownEncoding = DecodedRgbaLayer(
        topLease.view(), RgbaEncoding.unspecified, topType.association);
    require(tryCompositeRgbaSourceOver(
        unknownEncoding, bottom, roi, opacity, output)
        == RgbaCompositeError.invalidEncoding, "reject missing RGB meaning");
    requireUntouched(outLease, roi.width, roi.height, sentinel);

    const unknownAlpha = DecodedRgbaLayer(
        topLease.view(), topType.encoding, RgbaAssociation.unspecified);
    require(tryCompositeRgbaSourceOver(
        unknownAlpha, bottom, roi, opacity, output)
        == RgbaCompositeError.invalidEncoding, "reject missing alpha meaning");
    requireUntouched(outLease, roi.width, roi.height, sentinel);

    bool validSubregion;
    scope auto smallOutput = output.tryRoi(
        Region2D(0, 0, roi.width - 1, roi.height), validSubregion);
    require(validSubregion, "make deliberately undersized writable ROI");
    require(tryCompositeRgbaSourceOver(
        top, bottom, roi, opacity, smallOutput)
        == RgbaCompositeError.invalidOutput, "reject output size mismatch");
    requireUntouched(outLease, roi.width, roi.height, sentinel);

    require(tryCompositeRgbaSourceOver(
        top, bottom, roi, double.infinity, output)
        == RgbaCompositeError.invalidOpacity, "reject infinite opacity");
    requireUntouched(outLease, roi.width, roi.height, sentinel);
    require(tryCompositeRgbaSourceOverPrepared(
        prepared, top, bottom, Region2D(width, height, 2, 2),
        preparedOutput) == RgbaCompositeError.invalidRegion,
        "prepared adapter rejects out-of-bounds region before writes");
    requireUntouched(preparedLease, roi.width, roi.height, sentinel);

    const wrongEncoding = DecodedRgbaLayer(
        topLease.view(), RgbaEncoding.encodedSRgb,
        RgbaAssociation.premultiplied);
    require(tryCompositeRgbaSourceOver(
        wrongEncoding, bottom, roi, opacity, output)
        == RgbaCompositeError.invalidEncoding,
        "reject encoded premultiplied storage");
    requireUntouched(outLease, roi.width, roi.height, sentinel);
    require(tryCompositeRgbaSourceOverPrepared(
        prepared, wrongEncoding, bottom, roi, preparedOutput)
        == RgbaCompositeError.invalidEncoding,
        "prepared adapter rejects encoded-PM interpretation before writes");
    requireUntouched(preparedLease, roi.width, roi.height, sentinel);

    if (topType.association == RgbaAssociation.premultiplied &&
        roi.x == 0 && roi.y == 0)
    {
        bool canWriteTop;
        scope auto topWriter = topLease.tryWritableView(canWriteTop);
        require(canWriteTop, "tamper prepared source");
        // fixture top (0,0) has alpha=0, so RGB=255 is noncanonical.
        require(topWriter.trySetSample(0, 0, 0, 255),
            "introduce noncanonical premultiplied pixel");
        require(tryCompositeRgbaSourceOver(
            top, bottom, roi, opacity, output)
            == RgbaCompositeError.invalidPremultiplication,
            "reject noncanonical premultiplication before writes");
        requireUntouched(outLease, roi.width, roi.height, sentinel);
        require(tryCompositeRgbaSourceOverPrepared(
            prepared, top, bottom, roi, preparedOutput)
            == RgbaCompositeError.invalidPremultiplication,
            "prepared adapter rejects noncanonical premultiplied source");
        requireUntouched(preparedLease, roi.width, roi.height, sentinel);
        RasterLease!SRgba8 invalidPacked;
        require(tryCompositeOwnedPackedResearch(
                prepared, top, bottom, roi, invalidPacked)
            == RgbaCompositeError.invalidPremultiplication &&
                invalidPacked.view().planeCount == 0,
            "invalid premultiplication cannot publish owned output");
    }

    return worst;
}

// Independent source aliases are legitimate read-only inputs: both layers
// borrow a SINGLE ubyte owner. Freshly-owned publication must not alias it.
// This is a different test from rejecting caller-supplied packed output alias.
private void checkOwnedPackedWithSharedOriginalBacking()
{
    enum size_t w = 4, h = 3;
    const meaning = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto original = makeImage(
        w, h, Layout.interleaved, 0, meaning, true);
    const source = DecodedRgbaLayer(original.view(),
        meaning.encoding, meaning.association);
    const roi = Region2D(0, 0, w, h);

    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none, "prepare shared-source opacity");

    auto reference = makeImage(
        w, h, Layout.planar, 2, meaning, false);
    {
        bool ok;
        scope auto target = reference.tryWritableView(ok);
        require(ok && tryCompositeRgbaSourceOverPrepared(
                prepared, source, source, roi, target)
            == RgbaCompositeError.none,
            "same-owned original sources accepted read-only");
    }

    RasterLease!SRgba8 fresh;
    require(tryCompositeOwnedPackedResearch(
            prepared, source, source, roi, fresh)
        == RgbaCompositeError.none,
        "independently owned packed output from shared input");

    {
        scope auto output = fresh.view();
        scope auto expected = reference.view();
        foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            SRgba8 pixel;
            ubyte[4] channels;
            require(output.trySample(0, x, y, pixel),
                "read packed output before source mutation");
            foreach (p; 0 .. 4)
                require(expected.trySample(p, x, y, channels[p]),
                    "read reference from original shared owner");
            require(pixel == SRgba8(channels[0], channels[1],
                channels[2], channels[3]),
                "same-owner original inputs preserve exact pixel math");
        }
    }

    // Source mutation AFTER successful publication is legal: published
    // storage must remain unchanged, unlike a borrowed aliased output.
    {
        bool ok;
        scope auto mutableSource = original.tryWritableView(ok);
        require(ok, "get writable source for independence test");
        foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        foreach (p; 0 .. 4)
            require(mutableSource.trySetSample(p, x, y, 0),
                "change original shared source after publication");
    }
    {
        scope auto output = fresh.view();
        scope auto expected = reference.view();
        foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            SRgba8 pixel;
            ubyte[4] channels;
            require(output.trySample(0, x, y, pixel),
                "read independently retained packed result");
            foreach (p; 0 .. 4)
                require(expected.trySample(p, x, y, channels[p]),
                    "read expected pre-mutation reference");
            require(pixel == SRgba8(channels[0], channels[1],
                channels[2], channels[3]),
                "source mutation cannot modify owned packed result");
        }
    }
}

// Actual end-to-end Candidate B benchmark. The owned-result function above
// is the exact one used by the 432-scene oracle, NOT a duplicate speed kernel.
// Timings are separate whole-call alternatives; they must never be added.
private enum OwnedBenchPath : ubyte
{
    reusedPrepared,
    allocatingOwnedResult,
    allocatingOwnedThenCopy
}

private struct OwnedBenchConfig
{
    size_t width = 192;
    size_t height = 192;
    size_t side = 16;
    size_t rounds = 2;
    size_t iterations = 2;
    Layout layout = Layout.interleaved;
    bool transparent;
}

private OwnedBenchConfig parseOwnedBench(string[] args)
{
    import std.algorithm.searching : startsWith;
    import std.conv : to;
    OwnedBenchConfig cfg;
    foreach (arg; args)
    {
        if (arg.startsWith("--width="))
            cfg.width = to!size_t(arg[8 .. $]);
        else if (arg.startsWith("--height="))
            cfg.height = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--side="))
            cfg.side = to!size_t(arg[7 .. $]);
        else if (arg.startsWith("--rounds="))
            cfg.rounds = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--iterations="))
            cfg.iterations = to!size_t(arg[13 .. $]);
        else if (arg == "--layout=planar")
            cfg.layout = Layout.planar;
        else if (arg == "--layout=interleaved")
            cfg.layout = Layout.interleaved;
        else if (arg == "--pattern=mixed")
            cfg.transparent = false;
        else if (arg == "--pattern=transparent")
            cfg.transparent = true;
        else
            require(false, "unknown owned benchmark option: " ~ arg);
    }
    require(cfg.side > 0 && cfg.side <= 256 &&
            cfg.width >= 80 && cfg.height >= 100 &&
            cfg.width <= cast(size_t)ptrdiff_t.max / 4 &&
            cfg.width <= size_t.max / cfg.height &&
            cfg.width * cfg.height <= cast(size_t)ptrdiff_t.max / 4 &&
            cfg.side <= cfg.width - 71 &&
            cfg.side <= cfg.height - 91 &&
            cfg.rounds > 0 && cfg.rounds <= 30 &&
            cfg.iterations > 0 && cfg.iterations <= 100,
            "owned benchmark region/repetition bounds");
    return cfg;
}

private Region2D ownedBenchRoi(size_t side, size_t sequence)
@safe pure nothrow @nogc
{
    switch (sequence % 4)
    {
        case 0: return Region2D(5, 7, side, side);
        case 1: return Region2D(18, 23, side, side);
        case 2: return Region2D(41, 53, side, side);
        default: return Region2D(71, 91, side, side);
    }
}

// Variant A here allocates a fresh final target, so comparing A/B includes
// BOTH the extra final-target allocation and the final public copy. It is NOT
// a measure of copyInto alone or of a reused caller target.
private void executeOwnedBenchPath(
    OwnedBenchPath path, ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
    Region2D roi, ref RasterLease!ubyte reusedOutput)
{
    if (path == OwnedBenchPath.reusedPrepared)
    {
        bool writable;
        scope auto target = reusedOutput.tryWritableView(writable);
        require(writable && tryCompositeRgbaSourceOverPrepared(
            prepared, upper, lower, roi, target) == RgbaCompositeError.none,
            "benchmark reused prepared");
        return;
    }
    RasterLease!SRgba8 stage;
    require(tryCompositeOwnedPackedResearch(
        prepared, upper, lower, roi, stage) == RgbaCompositeError.none,
        "benchmark freshly owned packed result");
    if (path == OwnedBenchPath.allocatingOwnedThenCopy)
    {
        auto finalTarget = makeOwnedPacked(roi.width, roi.height);
        scope auto source = stage.view();
        bool writable;
        scope auto target = finalTarget.tryWritableView(writable);
        RasterCopyError error;
        require(writable && copyInto(source, 0, target, 0, error) &&
            error == RasterCopyError.none,
            "benchmark full three-buffer packed commit");
    }
}

private void verifyOwnedBench(
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
    size_t side, ref RasterLease!ubyte reusedOutput)
{
    foreach (sequence; 0 .. 4)
    {
        const roi = ownedBenchRoi(side, sequence);
        executeOwnedBenchPath(
            OwnedBenchPath.reusedPrepared, prepared, upper, lower,
            roi, reusedOutput);
        RasterLease!SRgba8 packed;
        require(tryCompositeOwnedPackedResearch(
            prepared, upper, lower, roi, packed)
            == RgbaCompositeError.none, "benchmark verification owned result");
        auto committed = makeOwnedPacked(side, side);
        {
            scope auto from = packed.view();
            bool writable;
            scope auto into = committed.tryWritableView(writable);
            RasterCopyError error;
            require(writable && copyInto(from, 0, into, 0, error) &&
                error == RasterCopyError.none,
                "benchmark verification packed commit");
        }
        scope auto expected = reusedOutput.view();
        scope auto actualOwned = packed.view();
        scope auto actualCopied = committed.view();
        foreach (y; 0 .. side)
        foreach (x; 0 .. side)
        {
            ubyte[4] parts;
            foreach (c; 0 .. 4)
                require(expected.trySample(c, x, y, parts[c]),
                    "benchmark verification fourplane reference");
            SRgba8 owned, copied;
            require(actualOwned.trySample(0, x, y, owned) &&
                    actualCopied.trySample(0, x, y, copied) &&
                    owned == copied &&
                    owned == SRgba8(parts[0], parts[1], parts[2], parts[3]),
                    "benchmark three-stage exact all-pixel oracle");
        }
    }
}

private ulong ownedBenchChecksum(ref RasterLease!ubyte output, size_t side)
{
    ulong hash = 1469598103934665603UL;
    scope auto view = output.view();
    foreach (y; 0 .. side)
    foreach (x; 0 .. side)
    foreach (component; 0 .. 4)
    {
        ubyte value;
        require(view.trySample(component, x, y, value),
            "benchmark canonical checksum read");
        hash = (hash ^ value) * 1099511628211UL;
    }
    return hash;
}

private string ownedBenchPathName(OwnedBenchPath path)
@safe pure nothrow @nogc
{
    final switch (path)
    {
        case OwnedBenchPath.reusedPrepared:
            return "prepared_reused_output";
        case OwnedBenchPath.allocatingOwnedResult:
            return "owned_allocating_result";
        case OwnedBenchPath.allocatingOwnedThenCopy:
            return "buffered_allocating_final";
    }
}

private void runOwnedBench(string[] args)
{
    import std.datetime.stopwatch : StopWatch;
    const cfg = parseOwnedBench(args);
    const meaning = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto upperLease = makeImage(
        cfg.width, cfg.height, cfg.layout, 0, meaning, true);
    auto lowerLease = makeImage(
        cfg.width, cfg.height, cfg.layout, 1, meaning, true);
    if (cfg.transparent)
    {
        bool upWritable, lowWritable;
        scope auto up = upperLease.tryWritableView(upWritable);
        scope auto low = lowerLease.tryWritableView(lowWritable);
        require(upWritable && lowWritable, "benchmark transparent inputs");
        foreach (y; 0 .. cfg.height)
        foreach (x; 0 .. cfg.width)
            require(up.trySetSample(3, x, y, 0) &&
                    low.trySetSample(3, x, y, 0),
                    "benchmark preserve hidden RGB with transparent alpha");
    }
    const top = DecodedRgbaLayer(
        upperLease.view(), meaning.encoding, meaning.association);
    const bottom = DecodedRgbaLayer(
        lowerLease.view(), meaning.encoding, meaning.association);
    ResearchPreparedRgbaContext prepared;
    StopWatch initTimer;
    initTimer.start();
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none, "benchmark prepare runtime opacity");
    initTimer.stop();
    const initMicroseconds = initTimer.peek.total!"usecs";
    auto reusedOutput = makeImage(
        cfg.side, cfg.side, Layout.interleaved, 2, meaning, false);
    verifyOwnedBench(prepared, top, bottom, cfg.side, reusedOutput);
    const firstRoi = ownedBenchRoi(cfg.side, 0);
    executeOwnedBenchPath(OwnedBenchPath.reusedPrepared,
        prepared, top, bottom, firstRoi, reusedOutput);
    const canonical = ownedBenchChecksum(reusedOutput, cfg.side);

    // Warm the same public code paths before recording any paired rounds.
    foreach (path; [OwnedBenchPath.reusedPrepared,
                    OwnedBenchPath.allocatingOwnedResult,
                    OwnedBenchPath.allocatingOwnedThenCopy])
        foreach (i; 0 .. 4)
            executeOwnedBenchPath(path, prepared, top, bottom,
                ownedBenchRoi(cfg.side, i), reusedOutput);

    writeln("pattern,layout,roi,width,height,pixels,round,iterations,",
            "stage,elapsed_us,thread_gc_bytes,canonical_checksum");
    foreach (round; 0 .. cfg.rounds)
    {
        foreach (step; 0 .. 3)
        {
            const path = cast(OwnedBenchPath)((step + round) % 3);
            const before = GC.stats().allocatedInCurrentThread;
            StopWatch watch;
            watch.start();
            foreach (i; 0 .. cfg.iterations)
                executeOwnedBenchPath(path, prepared, top, bottom,
                    ownedBenchRoi(cfg.side, i % 4), reusedOutput);
            watch.stop();
            const after = GC.stats().allocatedInCurrentThread;
            require(after >= before, "GC allocation counter did not regress");
            writeln(cfg.transparent ? "transparent" : "mixed", ",",
                cfg.layout == Layout.planar ? "planar" : "interleaved",
                ",square", cfg.side, ",", cfg.width, ",", cfg.height, ",",
                cfg.side * cfg.side, ",", round, ",", cfg.iterations, ",",
                ownedBenchPathName(path), ",",
                watch.peek.total!"usecs", ",", after - before, ",",
                canonical);
        }
        verifyOwnedBench(prepared, top, bottom, cfg.side, reusedOutput);
        executeOwnedBenchPath(OwnedBenchPath.reusedPrepared,
            prepared, top, bottom, firstRoi, reusedOutput);
        require(ownedBenchChecksum(reusedOutput, cfg.side) == canonical,
            "benchmark canonical checksum unchanged across rounds");
    }
    writeln("OWNED-BENCH PASS: three independently timed whole-call stages, ",
            "four changing ROI positions, all pixels exact, prepared_init_us=",
            initMicroseconds);
}

// Public pre-commit import failure proof: the armed token is left intact
// and can subsequently be imported exactly once as a valid packed lease.
// raster-d release-after-commit fault injection is NOT publicly exposed.
private void checkPublicImportPrecommitDisposition()
{
    enum size_t bytes = 4;
    auto raw = cast(ubyte*)malloc(bytes);
    require(raw !is null, "allocate public import negative fixture");
    OwnedByteResource token;
    require(tryAdoptMallocResource(raw, bytes, token),
        "adopt genuine import fixture allocation");
    RasterLease!SRgba8 result;
    const PlaneByteLayout[1] bad = [
        PlaneByteLayout(0, 4, 1)
    ];
    const invalid = tryImportOwnedRaster!SRgba8(
        token, bad[], Region2D(0, 0, 1, 1), result);
    require(!invalid.ok &&
        invalid.error == OwnedRasterImportError.invalidPlaneLayout &&
        invalid.resourceDisposition ==
            OwnedRasterResourceDisposition.unchanged &&
        token.ownsResource && result.view().planeCount == 0,
        "precommit layout failure leaves resource token armed");
    const PlaneByteLayout[1] good = [
        PlaneByteLayout(0, 4, 4)
    ];
    const valid = tryImportOwnedRaster!SRgba8(
        token, good[], Region2D(0, 0, 1, 1), result);
    require(valid.ok &&
        valid.resourceDisposition ==
            OwnedRasterResourceDisposition.transferredToLease &&
        !token.ownsResource && result.view().planeCount == 1,
        "valid post-failure import transfers same physical token once");
    bool writable;
    {
        scope auto into = result.tryWritableView(writable);
        require(writable && into.trySetSample(0, 0, 0,
            SRgba8(11, 22, 33, 44)),
            "writable imported packed fixture");
    }
    {
        scope auto from = result.view();
        SRgba8 value;
        require(from.trySample(0, 0, 0, value) &&
            value == SRgba8(11, 22, 33, 44),
            "imported token's valid owner retains data");
    }
}

// Admission + fault-injection research, using the REAL public raster-d
// malloc/adoption/import and the prepared RGBA computation. Ledger tracks
// a consumer's explicit reservation, NOT native allocator free callbacks.
private enum ReservedFault : ubyte
{
    none, beforeFirstAllocation, beforeSecondAllocation, latePackedWrite
}
private enum ReservedResult : ubyte
{
    succeeded, nonemptyOutput, invalidRegion, admissionDenied,
    injectedFailure, imageFailure
}

private ReservedResult runReservedOwnedProbe(
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
    Region2D roi, ref RoiReservationLedger ledger, size_t slot,
    ReservedFault fault, ref RasterLease!SRgba8 published)
{
    if (published.view().planeCount != 0)
        return ReservedResult.nonemptyOutput;

    OwnedPayloadPlan plan;
    const budgetCheck =
        tryPlanOwnedRgbaPayload(roi, size_t.max, plan);
    if (budgetCheck != OwnedPayloadStatus.admissible)
        return ReservedResult.invalidRegion;
    // 128 is explicit EXAMPLE headroom; native metadata size is not
    // bounded by this proof and needs measured/import-specific policy.
    if (!ledger.tryReserve(slot, plan, 128, 64))
        return ReservedResult.admissionDenied;

    bool committed = false;
    scope(exit)
    {
        if (!committed)
            require(ledger.release(slot),
                "release reserved payload on failed producer");
    }
    if (fault == ReservedFault.beforeFirstAllocation)
        return ReservedResult.injectedFailure;

    auto scratch = makeImage(roi.width, roi.height,
        Layout.interleaved, 2,
        Interpretation(RgbaEncoding.encodedSRgb,
            RgbaAssociation.straight), false);
    bool writable;
    {
        scope auto into = scratch.tryWritableView(writable);
        require(writable, "get reserved real scratch target");
        if (tryCompositeRgbaSourceOverPrepared(
            prepared, upper, lower, roi, into) != RgbaCompositeError.none)
            return ReservedResult.imageFailure;
    }
    if (fault == ReservedFault.beforeSecondAllocation)
        return ReservedResult.injectedFailure;

    auto packed = makeOwnedPacked(roi.width, roi.height);
    {
        scope auto from = scratch.view();
        scope auto into = packed.tryWritableView(writable);
        require(writable, "get reserved real packed target");
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        {
            ubyte[4] channels;
            foreach (p; 0 .. 4)
                if (!from.trySample(p, x, y, channels[p]))
                    return ReservedResult.imageFailure;
            if (fault == ReservedFault.latePackedWrite &&
                y == 1 && x == 0)
                return ReservedResult.injectedFailure;
            if (!into.trySetSample(0, x, y,
                SRgba8(channels[0], channels[1],
                       channels[2], channels[3])))
                return ReservedResult.imageFailure;
        }
    }
    // No output becomes visible until all samples were written.
    require(ledger.publish(slot),
        "transition reserved in-flight charge to retained charge");
    published = packed;
    committed = true;
    return ReservedResult.succeeded;
}

// The test interleaves reservations for TWO independent requests but does
// not claim genuine multithreaded safety. It also uses explicit consumer
// release signals, since raster-d does not export last-lease callbacks.
private void checkReservedOwnedFaultContract()
{
    const meaning = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    enum size_t side = 16;
    const roi = Region2D(5, 7, side, side);
    auto upperLease = makeImage(32, 32, Layout.planar, 0, meaning, true);
    auto lowerLease = makeImage(32, 32, Layout.interleaved, 1, meaning, true);
    const upper = DecodedRgbaLayer(upperLease.view(),
        meaning.encoding, meaning.association);
    const lower = DecodedRgbaLayer(lowerLease.view(),
        meaning.encoding, meaning.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none,
        "prepare reserved fault-injection context");

    OwnedPayloadPlan plan;
    require(tryPlanOwnedRgbaPayload(roi, 2048, plan)
        == OwnedPayloadStatus.admissible &&
        checkReservationLedgerContract(plan),
        "two competing ROI reservations and overflow controls");

    // Full result publication cannot occur if the caller's charge is
    // insufficient even by one byte.
    {
        RoiReservationLedger tooSmall = RoiReservationLedger(2175);
        RasterLease!SRgba8 rejected;
        require(runReservedOwnedProbe(prepared, upper, lower, roi,
            tooSmall, 0, ReservedFault.none, rejected)
            == ReservedResult.admissionDenied &&
            tooSmall.charged == 0 && rejected.view().planeCount == 0,
            "insufficient payload+metadata reservation rejects upfront");
    }
    foreach (fault; [ReservedFault.beforeFirstAllocation,
                     ReservedFault.beforeSecondAllocation,
                     ReservedFault.latePackedWrite])
    {
        RoiReservationLedger ledger = RoiReservationLedger(3400);
        RasterLease!SRgba8 rejected;
        require(runReservedOwnedProbe(prepared, upper, lower, roi,
            ledger, 0, fault, rejected)
            == ReservedResult.injectedFailure &&
            ledger.charged == 0 && rejected.view().planeCount == 0 &&
            ledger.phase(0) == TicketPhase.empty,
            "injected failure releases reservation and publishes nothing");
    }
    {
        RoiReservationLedger ledger = RoiReservationLedger(3400);
        RasterLease!SRgba8 rejected;
        ResearchPreparedRgbaContext inert;
        require(runReservedOwnedProbe(inert, upper, lower, roi,
            ledger, 0, ReservedFault.none, rejected)
            == ReservedResult.imageFailure &&
            ledger.charged == 0 && rejected.view().planeCount == 0,
            "real prepared failure aborts admitted ROI");
    }

    RoiReservationLedger ledger = RoiReservationLedger(3400);
    RasterLease!SRgba8 published;
    require(runReservedOwnedProbe(prepared, upper, lower, roi,
        ledger, 0, ReservedFault.none, published)
        == ReservedResult.succeeded &&
        published.view().planeCount == 1 &&
        ledger.charged == 1088 &&
        ledger.phase(0) == TicketPhase.delivered,
        "real owned ROI becomes visible only after full publication");
    // A new request can enter the remaining capacity after the first
    // scratch reservation reduces to retained-output residency.
    RasterLease!SRgba8 second;
    require(runReservedOwnedProbe(prepared, upper, lower, roi,
        ledger, 1, ReservedFault.none, second)
        == ReservedResult.succeeded &&
        ledger.charged == 2176,
        "two distinct owned results retain separate charges");
    {
        scope auto first = published.view();
        scope auto other = second.view();
        foreach (y; 0 .. side)
        foreach (x; 0 .. side)
        {
            SRgba8 a, b;
            require(first.trySample(0, x, y, a) &&
                other.trySample(0, x, y, b) && a == b,
                "two fully published ROIs remain byte identical");
        }
    }
    // A copied lease retains the SAME first backing, but not a second
    // pixel-payload allocation or a new credit. Deliberately keep the
    // first ledger charge until the last retained handle is released.
    auto copiedFirst = published;
    published = RasterLease!SRgba8.init;
    require(ledger.charged == 2176 &&
        copiedFirst.view().planeCount == 1,
        "copied result handle does not duplicate accounting");
    copiedFirst = RasterLease!SRgba8.init;
    require(ledger.release(0) && ledger.charged == 1088,
        "caller signals retirement after its last retained handle");
    second = RasterLease!SRgba8.init;
    require(ledger.release(1) && ledger.charged == 0,
        "both admitted output residencies fully retired");

    // Preexisting destination must be preserved (not out-reset).
    auto occupied = makeOwnedPacked(side, side);
    {
        bool ok;
        scope auto writer = occupied.tryWritableView(ok);
        require(ok && writer.trySetSample(0, 0, 0,
            SRgba8(17, 23, 31, 47)), "mark preexisting packed result");
    }
    require(runReservedOwnedProbe(prepared, upper, lower, roi,
        ledger, 0, ReservedFault.none, occupied)
        == ReservedResult.nonemptyOutput && ledger.charged == 0,
        "reject occupied publication target before reserving");
    {
        scope auto unchanged = occupied.view();
        SRgba8 value;
        require(unchanged.trySample(0, 0, 0, value) &&
            value == SRgba8(17, 23, 31, 47),
            "failure does not replace or change prior owner");
    }
}

// Closed-world consumer of two result leases: raster-d remains the ONLY
// owner of pixel backing. The ledger is an accounting record, not a second
// reference counter. This consumer never exposes a copyable RasterLease.
private struct ScopedRoiDeliveryConsumer
{
    @disable this(this); // do not duplicate the consumer accounting owner

private:
    RoiReservationLedger ledger_;
    RasterLease!SRgba8[2] delivered_;

public:
    this(size_t capacity)
    {
        ledger_ = RoiReservationLedger(capacity);
    }

    size_t charged() const
    {
        return ledger_.charged;
    }

    TicketPhase state(size_t slot) const
    {
        return ledger_.phase(slot);
    }

    ReservedResult produce(
        ref const ResearchPreparedRgbaContext prepared,
        scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
        Region2D roi, size_t slot)
    {
        if (slot >= delivered_.length)
            return ReservedResult.admissionDenied;
        // The producing lease stays local until the complete result is
        // accepted in the consumer. No owner reference escapes to clients.
        RasterLease!SRgba8 candidate;
        auto outcome = runReservedOwnedProbe(
            prepared, upper, lower, roi,
            ledger_, slot, ReservedFault.none, candidate);
        if (outcome != ReservedResult.succeeded)
            return outcome;
        require(delivered_[slot].view().planeCount == 0,
            "no pre-existing accounted owner in occupied slot");
        delivered_[slot] = candidate; // raster-d shares one genuine backing
        candidate = RasterLease!SRgba8.init;
        return ReservedResult.succeeded;
    }

    bool trySample(size_t slot, size_t x, size_t y, out SRgba8 pixel)
    {
        if (slot >= delivered_.length ||
            ledger_.phase(slot) != TicketPhase.delivered)
            return false;
        scope auto borrowed = delivered_[slot].view();
        return borrowed.trySample(0, x, y, pixel);
    }

    bool retire(size_t slot)
    {
        if (slot >= delivered_.length ||
            ledger_.phase(slot) != TicketPhase.delivered)
            return false;
        // This is the sole public-facing retirement point; no raw lease
        // was ever exported, so all retaining lease handles are internal.
        // Call only when external readers have finished (single-threaded).
        delivered_[slot] = RasterLease!SRgba8.init;
        return ledger_.release(slot);
    }
}

private void checkClosedOwnerDeliveryContract()
{
    static assert(!__traits(compiles, {
        ScopedRoiDeliveryConsumer original =
            ScopedRoiDeliveryConsumer(3400);
        auto duplicate = original;
    }), "consumer accounting owner must not be copyable");

    const meaning = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto upperLease = makeImage(
        32, 32, Layout.interleaved, 0, meaning, true);
    auto lowerLease = makeImage(
        32, 32, Layout.planar, 1, meaning, true);
    const upper = DecodedRgbaLayer(upperLease.view(),
        meaning.encoding, meaning.association);
    const lower = DecodedRgbaLayer(lowerLease.view(),
        meaning.encoding, meaning.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none,
        "prepare closed-owner result contract");

    ScopedRoiDeliveryConsumer consumer =
        ScopedRoiDeliveryConsumer(3400);
    const Region2D roi = Region2D(5, 7, 16, 16);
    SRgba8 unavailable;
    require(!consumer.trySample(0, 0, 0, unavailable),
        "consumer does not yield pixels before publication");
    require(consumer.produce(prepared, upper, lower, roi, 0)
        == ReservedResult.succeeded &&
        consumer.charged == 1088 &&
        consumer.state(0) == TicketPhase.delivered,
        "first result retained only inside consumer");
    require(consumer.produce(prepared, upper, lower, roi, 0)
        == ReservedResult.admissionDenied &&
        consumer.charged == 1088,
        "cannot overwrite existing accounted result");
    require(consumer.produce(prepared, upper, lower, roi, 1)
        == ReservedResult.succeeded &&
        consumer.charged == 2176,
        "second independently retained result is admitted");

    // Both consumers read precisely the same semantic image; only
    // per-pixel copies escape, never a separately retaining raster lease.
    foreach (y; 0 .. 16)
    foreach (x; 0 .. 16)
    {
        SRgba8 first, second;
        require(consumer.trySample(0, x, y, first) &&
            consumer.trySample(1, x, y, second) &&
            first == second,
            "opaque delivery retains byte exact independent ROIs");
    }
    require(!consumer.trySample(2, 0, 0, unavailable),
        "invalid slot is not a borrowable owner");
    require(consumer.retire(0) &&
        consumer.charged == 1088 &&
        !consumer.trySample(0, 0, 0, unavailable),
        "retiring first closed owner releases its charge");
    require(!consumer.retire(0) && consumer.charged == 1088,
        "double retirement rejected");
    require(consumer.retire(1) &&
        consumer.charged == 0 &&
        !consumer.trySample(1, 0, 0, unavailable),
        "last closed owner retires with exact budget refund");
    require(consumer.produce(prepared, upper, lower, roi, 0)
        == ReservedResult.succeeded &&
        consumer.charged == 1088,
        "retired slot can be admitted again");
    require(consumer.retire(0) && consumer.charged == 0,
        "reused slot closes without leaked budget");
}

// M2 cache-eviction pressure test under the SAME closed-world restriction:
// one private cache lease + one private subscriber lease may reference one
// raster-d backing. The two retains never become two pixel allocations.
private struct ScopedCacheSubscriberProbe
{
    @disable this(this);

private:
    RoiReservationLedger ledger_;
    RasterLease!SRgba8[2] cached_;
    RasterLease!SRgba8[2] subscribed_;

public:
    this(size_t capacity)
    {
        ledger_ = RoiReservationLedger(capacity);
    }

    size_t charged() const
    {
        return ledger_.charged;
    }

    bool produce(
        ref const ResearchPreparedRgbaContext prepared,
        scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
        Region2D roi, size_t slot)
    {
        if (slot >= cached_.length ||
            cached_[slot].view().planeCount != 0 ||
            subscribed_[slot].view().planeCount != 0)
            return false;
        RasterLease!SRgba8 local;
        if (runReservedOwnedProbe(prepared, upper, lower,
                roi, ledger_, slot, ReservedFault.none, local)
            != ReservedResult.succeeded)
            return false;
        cached_[slot] = local;
        local = RasterLease!SRgba8.init;
        return true;
    }

    bool addSubscriber(size_t slot)
    {
        if (slot >= cached_.length ||
            cached_[slot].view().planeCount == 0 ||
            subscribed_[slot].view().planeCount != 0)
            return false;
        subscribed_[slot] = cached_[slot];
        return true;
    }

    bool tryRead(
        size_t slot, bool fromSubscriber, size_t x, size_t y,
        out SRgba8 sample)
    {
        if (slot >= cached_.length)
            return false;
        if (fromSubscriber)
        {
            scope auto view = subscribed_[slot].view();
            return view.trySample(0, x, y, sample);
        }
        scope auto view = cached_[slot].view();
        return view.trySample(0, x, y, sample);
    }

    bool evict(size_t slot)
    {
        if (slot >= cached_.length ||
            cached_[slot].view().planeCount == 0)
            return false;
        cached_[slot] = RasterLease!SRgba8.init;
        // Subscriber retains the SAME raster-d owner after cache eviction.
        // Account for it until the subscriber's own private lease retires.
        return subscribed_[slot].view().planeCount == 0
            ? ledger_.release(slot) : true;
    }

    bool retireSubscriber(size_t slot)
    {
        if (slot >= cached_.length ||
            subscribed_[slot].view().planeCount == 0)
            return false;
        subscribed_[slot] = RasterLease!SRgba8.init;
        return cached_[slot].view().planeCount == 0
            ? ledger_.release(slot) : true;
    }
}

private void checkCacheEvictionWithRetainedSubscriber()
{
    static assert(!__traits(compiles, {
        ScopedCacheSubscriberProbe owner =
            ScopedCacheSubscriberProbe(3400);
        auto copy = owner;
    }), "cache/subscriber owner must not be copyable");

    const meaning = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto upperLease = makeImage(
        32, 32, Layout.planar, 0, meaning, true);
    auto lowerLease = makeImage(
        32, 32, Layout.interleaved, 1, meaning, true);
    const upper = DecodedRgbaLayer(upperLease.view(),
        meaning.encoding, meaning.association);
    const lower = DecodedRgbaLayer(lowerLease.view(),
        meaning.encoding, meaning.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none, "cache/subscriber prepared context");

    ScopedCacheSubscriberProbe cache =
        ScopedCacheSubscriberProbe(3400);
    const roi = Region2D(5, 7, 16, 16);
    require(cache.produce(prepared, upper, lower, roi, 0) &&
        cache.charged == 1088,
        "cache result A carries one delivered physical payload charge");
    require(cache.addSubscriber(0) &&
        cache.charged == 1088 &&
        !cache.addSubscriber(0),
        "subscriber retain shares same physical resource and charge");
    SRgba8 before;
    require(cache.tryRead(0, true, 0, 0, before),
        "subscriber samples source while cache retains same backing");
    require(cache.evict(0) &&
        cache.charged == 1088,
        "cache eviction does not prematurely refund external retention");
    SRgba8 after;
    require(!cache.tryRead(0, false, 0, 0, after) &&
        cache.tryRead(0, true, 0, 0, after) &&
        after == before,
        "delivered subscriber remains intact after cache eviction");
    require(!cache.evict(0) && cache.charged == 1088,
        "double eviction rejected with pending subscriber");

    // New viewport coverage can reuse the cache's vacated slot number only
    // after its old subscriber retires. It can use another finite slot now.
    require(cache.produce(prepared, upper, lower, roi, 1) &&
        cache.charged == 2176,
        "new cache result B admitted while old A remains delivered");
    foreach (y; 0 .. 16)
    foreach (x; 0 .. 16)
    {
        SRgba8 oldDelivered, newCached;
        require(cache.tryRead(0, true, x, y, oldDelivered) &&
            cache.tryRead(1, false, x, y, newCached) &&
            oldDelivered == newCached,
            "subscriber after eviction stays byte-identical to new result");
    }
    require(!cache.produce(prepared, upper, lower, roi, 0) &&
        cache.charged == 2176,
        "cannot reuse accounting slot while old subscriber retains owner");
    require(cache.evict(1) && cache.charged == 1088,
        "unsubscribed cache B refunds its payload on eviction");
    require(cache.retireSubscriber(0) && cache.charged == 0,
        "retiring final controlled subscriber refunds A physical payload");
    require(!cache.retireSubscriber(0) &&
        !cache.evict(1) && cache.charged == 0,
        "last-ref retirement and eviction are idempotent refusals");
    require(cache.produce(prepared, upper, lower, roi, 0) &&
        cache.charged == 1088 && cache.evict(0) &&
        cache.charged == 0,
        "old accounting slot may be reused after complete retirement");
}

// Issue #74: two independently retained subscribers of one REAL raster-d
// backing. The fixed slots describe accounting PARTICIPANTS, not physical
// raster owners or a recreation of raster-d's reference counter.
// Research-only: no raw RasterLease escapes, no concurrency claim.
private struct ScopedMultiSubscriberCacheProbe
{
    @disable this(this);

private:
    RoiReservationLedger ledger_;
    RasterLease!SRgba8[2] cached_;
    RasterLease!SRgba8[2][2] subscribers_;

    bool hasAnySubscriber(size_t region)
    {
        // Kept outside methods with mutable leases: the safe read-only
        // public RasterLease.view() does not require raw owner inspection.
        return subscribers_[region][0].view().planeCount != 0 ||
            subscribers_[region][1].view().planeCount != 0;
    }

public:
    this(size_t capacity)
    {
        ledger_ = RoiReservationLedger(capacity);
    }

    size_t charged() const
    {
        return ledger_.charged;
    }

    bool produce(
        ref const ResearchPreparedRgbaContext prepared,
        scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
        Region2D roi, size_t slot)
    {
        if (slot >= cached_.length ||
            cached_[slot].view().planeCount != 0 ||
            hasAnySubscriber(slot))
            return false;
        RasterLease!SRgba8 freshlyOwned;
        if (runReservedOwnedProbe(
                prepared, upper, lower, roi, ledger_,
                slot, ReservedFault.none, freshlyOwned)
            != ReservedResult.succeeded)
            return false;
        cached_[slot] = freshlyOwned;
        freshlyOwned = RasterLease!SRgba8.init;
        return true;
    }

    bool retainSubscriber(size_t slot, size_t subscriber)
    {
        if (slot >= cached_.length ||
            subscriber >= subscribers_[slot].length ||
            cached_[slot].view().planeCount == 0 ||
            subscribers_[slot][subscriber].view().planeCount != 0)
            return false;
        // A real independent raster-d retain of the SAME backing.
        subscribers_[slot][subscriber] = cached_[slot];
        return true;
    }

    bool trySample(size_t slot, size_t subscriber,
        size_t x, size_t y, out SRgba8 pixel)
    {
        if (slot >= cached_.length ||
            subscriber >= subscribers_[slot].length)
            return false;
        scope auto borrow = subscribers_[slot][subscriber].view();
        return borrow.trySample(0, x, y, pixel);
    }

    bool tryCachedSample(size_t slot, size_t x, size_t y,
        out SRgba8 pixel)
    {
        if (slot >= cached_.length)
            return false;
        scope auto borrow = cached_[slot].view();
        return borrow.trySample(0, x, y, pixel);
    }

    bool evict(size_t slot)
    {
        if (slot >= cached_.length ||
            cached_[slot].view().planeCount == 0)
            return false;
        cached_[slot] = RasterLease!SRgba8.init;
        // Eviction removes ONLY the cache owner. Both independently
        // delivered subscribers can still retain the same backing.
        if (!hasAnySubscriber(slot))
            return ledger_.release(slot);
        return true;
    }

    // Includes cancellation/unsubscribe: no separate reference count is
    // maintained; inspect ONLY the fixed set of controlled handles.
    bool retireSubscriber(size_t slot, size_t subscriber)
    {
        if (slot >= cached_.length ||
            subscriber >= subscribers_[slot].length ||
            subscribers_[slot][subscriber].view().planeCount == 0)
            return false;
        subscribers_[slot][subscriber] = RasterLease!SRgba8.init;
        if (cached_[slot].view().planeCount == 0 &&
            !hasAnySubscriber(slot))
            return ledger_.release(slot);
        return true;
    }
}

private void checkTwoIndependentRetainedSubscribers()
{
    static assert(!__traits(compiles, {
        ScopedMultiSubscriberCacheProbe original =
            ScopedMultiSubscriberCacheProbe(3400);
        auto copied = original;
    }), "accounting cache must not duplicate its owning participant set");

    const interpretation = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto topOwner = makeImage(
        32, 32, Layout.planar, 0, interpretation, true);
    auto bottomOwner = makeImage(
        32, 32, Layout.interleaved, 1, interpretation, true);
    const top = DecodedRgbaLayer(topOwner.view(),
        interpretation.encoding, interpretation.association);
    const bottom = DecodedRgbaLayer(bottomOwner.view(),
        interpretation.encoding, interpretation.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none,
        "prepare two-subscriber compositor");

    const roi = Region2D(5, 7, 16, 16);
    ScopedMultiSubscriberCacheProbe cache =
        ScopedMultiSubscriberCacheProbe(3400);
    SRgba8 missing;
    require(!cache.trySample(0, 0, 0, 0, missing) &&
        !cache.retainSubscriber(0, 0) &&
        !cache.retireSubscriber(0, 0) &&
        cache.charged == 0,
        "prepublication subscribe/read/retire rejected");
    require(cache.produce(prepared, top, bottom, roi, 0) &&
        cache.charged == 1088,
        "ROI A publishes and charges one physical backing");
    require(cache.retainSubscriber(0, 0) &&
        cache.retainSubscriber(0, 1) &&
        cache.charged == 1088 &&
        !cache.retainSubscriber(0, 0) &&
        !cache.retainSubscriber(0, 2),
        "two independent A subscribers retain one backing, no double charge");

    require(cache.evict(0) && cache.charged == 1088,
        "eviction of A's cache owner must keep delivered charge");
    SRgba8 firstA, secondA;
    require(!cache.tryCachedSample(0, 0, 0, missing) &&
        cache.trySample(0, 0, 0, 0, firstA) &&
        cache.trySample(0, 1, 0, 0, secondA) &&
        firstA == secondA &&
        !cache.evict(0),
        "both subscriber owners survive cache eviction intact");

    require(cache.produce(prepared, top, bottom, roi, 1) &&
        cache.charged == 2176,
        "ROI B admitted while A remains delivered");
    // Retain B independently to verify it, too, survives eviction.
    require(cache.retainSubscriber(1, 1) &&
        cache.evict(1) &&
        cache.charged == 2176,
        "ROI B delivered subscriber survives own cache eviction");

    foreach (y; 0 .. 16)
    foreach (x; 0 .. 16)
    {
        SRgba8 a0, a1, b1;
        require(cache.trySample(0, 0, x, y, a0) &&
            cache.trySample(0, 1, x, y, a1) &&
            cache.trySample(1, 1, x, y, b1) &&
            a0 == a1 && a1 == b1,
            "two A subscribers and independent B retain byte-exact pixels");
    }
    require(!cache.produce(prepared, top, bottom, roi, 0) &&
        !cache.produce(prepared, top, bottom, roi, 1) &&
        cache.charged == 2176,
        "cannot reuse a logical slot with a live delivered subscriber");
    require(cache.retireSubscriber(0, 0) &&
        cache.charged == 2176 &&
        !cache.trySample(0, 0, 0, 0, missing) &&
        !cache.retireSubscriber(0, 0),
        "unsubscribe/cancel A subscriber 0 without freeing A prematurely");
    SRgba8 afterCancel;
    require(cache.trySample(0, 1, 0, 0, afterCancel) &&
        afterCancel == secondA &&
        cache.charged == 2176,
        "A subscriber 1 remains live after subscriber 0 cancels");

    require(cache.retireSubscriber(1, 1) &&
        cache.charged == 1088 &&
        !cache.trySample(1, 1, 0, 0, missing),
        "B last controlled retain refunds only B's resident charge");
    require(cache.produce(prepared, top, bottom, roi, 1) &&
        cache.charged == 2176 &&
        cache.evict(1) &&
        cache.charged == 1088,
        "freed B slot can produce/evict anew with A still pinned");
    require(cache.retireSubscriber(0, 1) &&
        cache.charged == 0 &&
        !cache.trySample(0, 1, 0, 0, missing) &&
        !cache.retireSubscriber(0, 1),
        "last controlled A subscriber refunds exactly once");
    require(cache.produce(prepared, top, bottom, roi, 0) &&
        cache.charged == 1088 &&
        cache.evict(0) &&
        cache.charged == 0,
        "A slot reusable when all controlled owners have retired");

    ScopedMultiSubscriberCacheProbe insufficient =
        ScopedMultiSubscriberCacheProbe(2175);
    require(!insufficient.produce(prepared, top, bottom, roi, 0) &&
        insufficient.charged == 0,
        "admission deficit cannot publish or retain an uncharged result");
}

// A separate independent-consumer @safe compilation contract. The
// consumer can read and explicitly retain a live capability without
// receiving a raw RasterLease or borrowing beyond the handle lifetime.
private @safe bool checkSafeDeliveryRead(
    ref OwnedDeliveryHandle owner, out SRgba8 sample)
{
    return owner.trySample(0, 0, sample);
}

private @safe bool checkSafeDeliveryRetain(ref OwnedDeliveryHandle owner)
{
    OwnedDeliveryHandle borrowedOwner;
    return owner.tryRetain(borrowedOwner) && borrowedOwner.close();
}

// Issue #74: independent, move-only Delivery RAII values that survive
// cache-owner scope. Physical storage remains raster-d's genuine backing;
// the GC-managed shared control record carries only accounting metadata.
private void checkIndependentDeliveryHandles()
{
    import std.algorithm.mutation : move;
    static assert(!__traits(compiles, {
        OwnedDeliveryHandle first;
        auto copied = first;
    }), "implicit copying of a resource-bearing delivery is forbidden");
    static assert(!__traits(compiles, {
        OwnedDeliveryCache cache = OwnedDeliveryCache(3400);
        auto copied = cache;
    }), "implicit copying of a charged cache is forbidden");

    const meaning = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto upperLease = makeImage(
        32, 32, Layout.planar, 0, meaning, true);
    auto lowerLease = makeImage(
        32, 32, Layout.interleaved, 1, meaning, true);
    const top = DecodedRgbaLayer(upperLease.view(),
        meaning.encoding, meaning.association);
    const bottom = DecodedRgbaLayer(lowerLease.view(),
        meaning.encoding, meaning.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none,
        "prepare independent owned delivery");
    const Region2D roi = Region2D(5, 7, 16, 16);
    OwnedDeliveryHandle original, survivingA, survivingB;
    DeliveryAccounting meter;

    {
        OwnedDeliveryCache cache = OwnedDeliveryCache(3400);
        meter = cache.auditForResearch();
        require(meter !is null && meter.charged == 0,
            "unowned accounting metadata starts empty");

        RasterLease!SRgba8 firstOwner;
        require(runReservedOwnedProbe(prepared, top, bottom, roi,
            cache.producerLedger(), 0, ReservedFault.none, firstOwner)
            == ReservedResult.succeeded &&
            cache.adoptCompleted(0, firstOwner) &&
            firstOwner.view().planeCount == 0 &&
            meter.charged == 1088,
            "adopt real ROI A with one backing and charge");
        require(cache.tryDeliver(0, original) &&
            original.tryRetain(survivingA) &&
            original.tryRetain(survivingB) &&
            meter.externalRetains(0) == 3 &&
            meter.charged == 1088,
            "three independent delivery handles hold one backing");
        OwnedDeliveryHandle occupied;
        require(!cache.tryDeliver(2, occupied) &&
            !original.tryRetain(original) &&
            !cache.tryDeliver(0, original) &&
            meter.externalRetains(0) == 3,
            "invalid delivery, self-retain and occupied output refused");

        require(cache.evict(0) && meter.charged == 1088,
            "cache evicted but all independent deliveries remain pinned");
        RasterLease!SRgba8 secondOwner;
        require(runReservedOwnedProbe(prepared, top, bottom, roi,
            cache.producerLedger(), 1, ReservedFault.none, secondOwner)
            == ReservedResult.succeeded &&
            cache.adoptCompleted(1, secondOwner) &&
            cache.tryDeliver(1, occupied) &&
            cache.evict(1) &&
            meter.charged == 2176,
            "new B independently admitted and retained past eviction");

        foreach (y; 0 .. 16)
        foreach (x; 0 .. 16)
        {
            SRgba8 a, aCopy, b;
            require(original.trySample(x, y, a) &&
                survivingA.trySample(x, y, aCopy) &&
                occupied.trySample(x, y, b) &&
                a == aCopy && aCopy == b,
                "retained movable deliveries preserve every RGBA sample");
        }
        require(original.close() && !original.live() &&
            !original.close() && meter.externalRetains(0) == 2 &&
            meter.charged == 2176,
            "explicit first close is idempotent and does not refund A");
        require(occupied.close() && meter.charged == 1088,
            "B last independent delivery refunds only B");

        // Test compiler-supported explicit MOVE rather than inferring
        // implicit copy-constructor behavior for dynamic containers.
        auto movedA = move(survivingA);
        require(!survivingA.live() && movedA.live() &&
            meter.externalRetains(0) == 2 &&
            meter.charged == 1088,
            "move transfers one accounting participation without duplicating");
        {
            OwnedDeliveryHandle scoped;
            require(movedA.tryRetain(scoped) &&
                meter.externalRetains(0) == 3 &&
                meter.charged == 1088,
                "scoped retained delivery increments participants only");
            SRgba8 px;
            require(scoped.trySample(0, 0, px),
                "scoped delivery borrows valid physical backing");
        }
        require(meter.externalRetains(0) == 2 &&
            meter.charged == 1088,
            "RAII scope exit retires one delivery automatically");
        require(movedA.close() &&
            meter.externalRetains(0) == 1 &&
            meter.charged == 1088,
            "scope can retire its moved independent handle");

        // The final A subscription remains outside the cache scope.
        // No returned raster-d lease, backing pointer or borrowed view
        // escaped through the DeliveryHandle API.
    }

    require(meter.charged == 1088 &&
        meter.externalRetains(0) == 1 && survivingB.live(),
        "subscriber keeps its own backing/account after cache destruction");
    SRgba8 stillAvailable;
    require(survivingB.trySample(0, 0, stillAvailable),
        "independent delivery survives lifetime of producing cache");
    SRgba8 safeSample;
    require(checkSafeDeliveryRead(survivingB, safeSample) &&
        safeSample == stillAvailable &&
        checkSafeDeliveryRetain(survivingB),
        "@safe public-facing delivery read and explicit retain contract");
    // The control-plane class is allocated once per cache. Explicit
    // retain and close of existing delivery values should create NO new
    // GC-allocated metadata object in this steady-state consumer loop.
    const gcBeforeDeliveryRetains = GC.stats().allocatedInCurrentThread;
    foreach (iteration; 0 .. 256)
    {
        OwnedDeliveryHandle transientRetain;
        require(survivingB.tryRetain(transientRetain) &&
            transientRetain.close(),
            "explicit retained participant lives and retires");
    }
    const gcAfterDeliveryRetains = GC.stats().allocatedInCurrentThread;
    require(gcBeforeDeliveryRetains == gcAfterDeliveryRetains &&
        meter.externalRetains(0) == 1 && meter.charged == 1088,
        "256 delivery retain/close operations allocate zero GC bytes");
    require(survivingB.close() && !survivingB.live() &&
        meter.charged == 0 && meter.externalRetains(0) == 0,
        "last independently retained delivery releases credit exactly once");

    // RAII without explicit close: destruction of independent survivors
    // should release credit even if cache has already disappeared.
    {
        OwnedDeliveryHandle autoClosed;
        {
            OwnedDeliveryCache cache = OwnedDeliveryCache(2176);
            meter = cache.auditForResearch();
            RasterLease!SRgba8 staged;
            require(runReservedOwnedProbe(prepared, top, bottom, roi,
                cache.producerLedger(), 0, ReservedFault.none, staged)
                == ReservedResult.succeeded &&
                cache.adoptCompleted(0, staged) &&
                cache.tryDeliver(0, autoClosed) &&
                cache.evict(0),
                "prepare delivery whose RAII destructor runs after cache");
        }
        require(meter.charged == 1088 && autoClosed.live(),
            "post-cache RAII survivor still charged");
    }
    require(meter.charged == 0 && meter.externalRetains(0) == 0,
        "survivor destructor refunds last controlled credit after cache");
}

// Separate, reusable benchmark entry point. It measures ONLY the cost of
// an existing retained RasterLease vs an independently accounted delivery,
// not raster production, full-memory admission, or the RGBA pixel kernel.
private void runDeliveryBenchmarkMode(string[] options)
{
    import std.conv : to;
    import std.string : startsWith;
    import owned_delivery_bench : runIndependentDeliveryBenchmark;

    size_t rounds = 7;
    size_t iterations = 100_000;
    size_t warmups = 2;
    foreach (arg; options)
    {
        if (arg.startsWith("--rounds="))
            rounds = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--iterations="))
            iterations = to!size_t(arg[13 .. $]);
        else if (arg.startsWith("--warmups="))
            warmups = to!size_t(arg[10 .. $]);
        else
            require(false, "unrecognized delivery benchmark argument");
    }
    const beforeMetadata = GC.stats().allocatedInCurrentThread;
    OwnedDeliveryCache cache = OwnedDeliveryCache(4096);
    const afterMetadata = GC.stats().allocatedInCurrentThread;
    require(afterMetadata >= beforeMetadata,
        "accounting control GC allocation measure monotonic");

    enum size_t side = 16;
    OwnedPayloadPlan plan;
    require(tryPlanOwnedRgbaPayload(
        Region2D(0, 0, side, side), 2048, plan)
            == OwnedPayloadStatus.admissible &&
        cache.producerLedger().tryReserve(0, plan, 128, 64) &&
        cache.producerLedger().publish(0),
        "benchmark fixture reserves a representative ROI delivery charge");
    auto packed = makeOwnedPacked(side, side);
    {
        bool writable;
        scope auto writer = packed.tryWritableView(writable);
        require(writable && writer.trySetSample(0, 0, 0,
            SRgba8(17, 23, 31, 47)), "benchmark fixture valid first pixel");
    }
    require(cache.adoptCompleted(0, packed),
        "benchmark adopts actual public raster-d packed lease");
    OwnedDeliveryHandle delivery;
    require(cache.tryDeliver(0, delivery),
        "benchmark retains accounting and underlying public raster-d lease");

    // Independent physical baseline backing with identical sample type,
    // layout and reference-counted retaining implementation.
    auto rawBaseline = makeOwnedPacked(side, side);
    require(rawBaseline.view().planeCount == 1 &&
        cache.auditForResearch().charged == 1088,
        "benchmark starts with one independently charged delivery");

    writeln("DELIVERY-METADATA research_cache_control_gc_thread_bytes=",
        afterMetadata - beforeMetadata);
    runIndependentDeliveryBenchmark(
        rawBaseline, delivery, rounds, iterations, warmups);

    // Semantic postflight excluded from timing.
    SRgba8 actual;
    require(delivery.trySample(0, 0, actual) &&
        actual == SRgba8(17, 23, 31, 47),
        "benchmark preserves the real materialized RGBA bytes");
    require(cache.evict(0) &&
        cache.auditForResearch().charged == 1088 &&
        delivery.close() &&
        cache.auditForResearch().charged == 0,
        "benchmark postflight releases backing before final budget refund");
}

// Issue #74: consumer-shaped paired operations, not merely naked
// retain/release. The "raw" path is a weaker closed-world baseline and
// does not support independently transferable accounting semantics.
private enum DeliveryWorkflowStage : ubyte
{
    hotRaw, hotControlled, churnRaw, churnControlled
}

private string deliveryWorkflowName(DeliveryWorkflowStage stage)
{
    final switch (stage)
    {
    case DeliveryWorkflowStage.hotRaw: return "hot_raw_two_subscribers";
    case DeliveryWorkflowStage.hotControlled:
        return "hot_controlled_two_subscribers";
    case DeliveryWorkflowStage.churnRaw: return "roi_raw_evicted";
    case DeliveryWorkflowStage.churnControlled:
        return "roi_controlled_evicted";
    }
}

private size_t executeDeliveryWorkflow(
    DeliveryWorkflowStage stage, size_t iterations,
    ref RasterLease!SRgba8 hotRaw, ref OwnedDeliveryCache hotCache,
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
    Region2D roi, size_t capacity)
{
    size_t digest;
    foreach (i; 0 .. iterations)
    {
        const size_t x = i % roi.width;
        const size_t y = (i / roi.width) % roi.height;
        SRgba8 first, second;
        final switch (stage)
        {
        case DeliveryWorkflowStage.hotRaw:
        {
            RasterLease!SRgba8 a = hotRaw;
            RasterLease!SRgba8 b = hotRaw;
            {
                scope auto av = a.view();
                scope auto bv = b.view();
                require(av.trySample(0, x, y, first) &&
                    bv.trySample(0, x, y, second),
                    "two hot baseline subscribers read same real raster");
            }
            a = RasterLease!SRgba8.init;
            b = RasterLease!SRgba8.init;
            break;
        }
        case DeliveryWorkflowStage.hotControlled:
        {
            OwnedDeliveryHandle a, b;
            require(hotCache.tryDeliver(0, a) &&
                hotCache.tryDeliver(0, b),
                "two hot controlled subscribers deliver same backing");
            require(a.trySample(x, y, first) &&
                b.trySample(x, y, second),
                "two hot controlled subscribers read RGBA");
            require(a.close() && b.close(),
                "hot controlled subscribers independently retired");
            break;
        }
        case DeliveryWorkflowStage.churnRaw:
        {
            RoiReservationLedger ledger = RoiReservationLedger(capacity);
            RasterLease!SRgba8 cached;
            require(runReservedOwnedProbe(prepared, upper, lower, roi,
                ledger, 0, ReservedFault.none, cached)
                == ReservedResult.succeeded,
                "baseline materializes real composited ROI");
            RasterLease!SRgba8 a = cached;
            RasterLease!SRgba8 b = cached;
            cached = RasterLease!SRgba8.init; // eviction
            {
                scope auto av = a.view();
                require(av.trySample(0, x, y, first),
                    "baseline retained subscriber A remains readable");
            }
            a = RasterLease!SRgba8.init;
            {
                scope auto bv = b.view();
                require(bv.trySample(0, x, y, second),
                    "baseline retained subscriber B survives A retirement");
            }
            b = RasterLease!SRgba8.init;
            require(ledger.release(0) && ledger.charged == 0,
                "closed-world baseline refunds only after last owner");
            break;
        }
        case DeliveryWorkflowStage.churnControlled:
        {
            OwnedDeliveryCache cache = OwnedDeliveryCache(capacity);
            RasterLease!SRgba8 produced;
            require(runReservedOwnedProbe(prepared, upper, lower, roi,
                cache.producerLedger(), 0, ReservedFault.none, produced)
                == ReservedResult.succeeded &&
                cache.adoptCompleted(0, produced),
                "controlled materializes and adopts real composited ROI");
            OwnedDeliveryHandle a, b;
            require(cache.tryDeliver(0, a) &&
                cache.tryDeliver(0, b) && cache.evict(0),
                "two controlled subscribers survive cache eviction");
            require(a.trySample(x, y, first) && a.close(),
                "controlled subscriber A reads then cancels");
            require(cache.auditForResearch().charged != 0 &&
                b.trySample(x, y, second) && b.close() &&
                cache.auditForResearch().charged == 0,
                "B survives A and refunds only after final controlled lease");
            break;
        }
        }
        require(first == second, "workload paired subscriber pixel identity");
        // Observable through postflight, preventing a dead pixel-read loop.
        digest += first == SRgba8.init
            ? (x + 1) * (y + 1) : (x + 1) * (y + 1) + 1;
    }
    return digest;
}

// End-to-end per-ROI delivery performance experiment. Real prepared source-
// over + malloc-backed public RasterLease import in cold cycles; fixed hot
// materializations in hit cycles. Timed paths include real sampled pixels.
private void runDeliveryWorkflowBenchmarkMode(string[] options)
{
    import std.conv : to;
    import std.string : startsWith;
    import std.datetime.stopwatch : StopWatch;

    size_t rounds = 7;
    size_t hotIterations = 100_000;
    size_t churnIterations = 24;
    size_t warmups = 1;
    size_t side = 16;
    foreach (arg; options)
    {
        if (arg.startsWith("--rounds="))
            rounds = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--hot-iterations="))
            hotIterations = to!size_t(arg[17 .. $]);
        else if (arg.startsWith("--churn-iterations="))
            churnIterations = to!size_t(arg[19 .. $]);
        else if (arg.startsWith("--warmups="))
            warmups = to!size_t(arg[10 .. $]);
        else if (arg.startsWith("--side="))
            side = to!size_t(arg[7 .. $]);
        else
            require(false, "unknown delivery workflow benchmark argument");
    }
    require(rounds >= 1 && rounds <= 50 &&
        hotIterations >= 1 && hotIterations <= 10_000_000 &&
        churnIterations >= 1 && churnIterations <= 100_000 &&
        warmups <= 10 && (side == 16 || side == 64),
        "bounded side/round/count for consumer workflow benchmark");
    const capacity = 8 * side * side + 128;
    const Region2D roi = Region2D(3, 4, side, side);
    const meaning = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto upperOwner = makeImage(side + 8, side + 8,
        Layout.planar, 0, meaning, true);
    auto lowerOwner = makeImage(side + 8, side + 8,
        Layout.interleaved, 1, meaning, true);
    const upper = DecodedRgbaLayer(upperOwner.view(),
        meaning.encoding, meaning.association);
    const lower = DecodedRgbaLayer(lowerOwner.view(),
        meaning.encoding, meaning.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none,
        "prepared source-over used in both workflow variants");

    // Hot baseline and controlled cached ROI both contain genuine completed
    // result pixels; neither is freshly composited in a timed hot loop.
    RoiReservationLedger baselineLedger = RoiReservationLedger(capacity);
    RasterLease!SRgba8 hotRaw;
    require(runReservedOwnedProbe(prepared, upper, lower, roi,
        baselineLedger, 0, ReservedFault.none, hotRaw)
        == ReservedResult.succeeded,
        "hot baseline produced a complete RGBA ROI");
    OwnedDeliveryCache hotCache = OwnedDeliveryCache(capacity);
    RasterLease!SRgba8 hotControlled;
    require(runReservedOwnedProbe(prepared, upper, lower, roi,
        hotCache.producerLedger(), 0, ReservedFault.none, hotControlled)
        == ReservedResult.succeeded &&
        hotCache.adoptCompleted(0, hotControlled),
        "hot controlled cache received the same semantic ROI");

    // Complete independent pixel comparison before any benchmark timing.
    foreach (y; 0 .. side)
    foreach (x; 0 .. side)
    {
        SRgba8 baseline, controlled;
        {
            scope auto rawView = hotRaw.view();
            require(rawView.trySample(0, x, y, baseline),
                "raw cache baseline preflight sample");
        }
        OwnedDeliveryHandle delivered;
        require(hotCache.tryDeliver(0, delivered) &&
            delivered.trySample(x, y, controlled) &&
            delivered.close() &&
            baseline == controlled,
            "real hot cache candidates byte-identical before timing");
    }

    foreach (unused; 0 .. warmups)
    foreach (stage; [DeliveryWorkflowStage.hotRaw,
        DeliveryWorkflowStage.hotControlled,
        DeliveryWorkflowStage.churnRaw,
        DeliveryWorkflowStage.churnControlled])
        executeDeliveryWorkflow(stage,
            stage == DeliveryWorkflowStage.hotRaw ||
            stage == DeliveryWorkflowStage.hotControlled
                ? hotIterations : churnIterations,
            hotRaw, hotCache, prepared, upper, lower, roi, capacity);

    writeln("experiment,side,round,stage,iterations,elapsed_us,",
        "thread_gc_bytes,digest");
    foreach (round; 0 .. rounds)
    {
        // Rotate all four stages so neither baseline nor the allocating
        // candidate always sees the first/last temporal slot.
        foreach (offset; 0 .. 4)
        {
            const stage = cast(DeliveryWorkflowStage)((round + offset) % 4);
            const iterations =
                stage == DeliveryWorkflowStage.hotRaw ||
                stage == DeliveryWorkflowStage.hotControlled
                    ? hotIterations : churnIterations;
            const beforeGc = GC.stats().allocatedInCurrentThread;
            StopWatch watch;
            watch.start();
            const digest = executeDeliveryWorkflow(stage, iterations,
                hotRaw, hotCache, prepared, upper, lower, roi, capacity);
            watch.stop();
            const afterGc = GC.stats().allocatedInCurrentThread;
            require(afterGc >= beforeGc && digest > 0,
                "workload benchmark completed and GC counter monotonic");
            writeln("m3_delivery_workflow,", side, ",", round, ",",
                deliveryWorkflowName(stage), ",", iterations, ",",
                watch.peek.total!"usecs", ",", afterGc - beforeGc,
                ",", digest);
        }
    }
    require(hotCache.auditForResearch().charged == 4 * side * side + 64 &&
        hotCache.evict(0) && hotCache.auditForResearch().charged == 0,
        "controlled hot cache cleanly refunds after all delivered readers");
    hotRaw = RasterLease!SRgba8.init;
    require(baselineLedger.release(0) && baselineLedger.charged == 0,
        "raw hot baseline releases after all closed-world readers");
    writeln("DELIVERY-WORKFLOW PASS: paired two-subscriber hot hits and ",
        "materialize/evict/refund cycles use real raster-d backings");
}

// Issue #74: deterministic finite-cache mixed workload. Both paths use
// real raster-d retained owner copies and identical image-domain producers.
private struct MixedStats
{
    size_t hits, misses, evictions, retains, refunds, digest;
}

private Region2D mixedRegion(size_t key, size_t side)
{
    return Region2D(3 + key, 4 + key, side, side);
}

private size_t mixedSampleCode(SRgba8 pixel, size_t key)
{
    return cast(size_t)pixel.r + (cast(size_t)pixel.g << 8) +
        (cast(size_t)pixel.b << 16) + (cast(size_t)pixel.a << 24) +
        key * 65537;
}

private MixedStats mixedRaw(
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
    size_t side, size_t requests, size_t hitPercent,
    size_t subscribers, size_t budget)
{
    RoiReservationLedger ledger = RoiReservationLedger(budget);
    RasterLease!SRgba8[2] cache;
    size_t[2] keys = [0, 1];
    foreach (slot; 0 .. 2)
        require(runReservedOwnedProbe(prepared, upper, lower,
            mixedRegion(keys[slot], side), ledger, slot,
            ReservedFault.none, cache[slot]) == ReservedResult.succeeded,
            "raw mixed cache seed from actual source-over");
    MixedStats stats;
    foreach (i; 0 .. requests)
    {
        const slot = mixedSlot(i);
        const x = i % side, y = (i / side) % side;
        if (plannedMixedHit(i, hitPercent))
            ++stats.hits;
        else
        {
            RasterLease!SRgba8 stranded = cache[slot];
            cache[slot] = RasterLease!SRgba8.init; // Eviction.
            SRgba8 oldPixel;
            {
                scope auto view = stranded.view();
                require(view.trySample(0, x, y, oldPixel),
                    "evicted raw raster retained by independent subscriber");
            }
            stats.digest += mixedSampleCode(oldPixel, keys[slot]);
            stranded = RasterLease!SRgba8.init;
            require(ledger.release(slot),
                "raw ledger refunds only after last known owner");
            ++stats.refunds;
            ++stats.evictions;
            ++stats.misses;
            ++stats.retains;
            keys[slot] = alternateMixedKey(keys[slot]);
            require(runReservedOwnedProbe(prepared, upper, lower,
                mixedRegion(keys[slot], side), ledger, slot,
                ReservedFault.none, cache[slot]) == ReservedResult.succeeded,
                "raw slot reuses only after last owner disappears");
        }

        RasterLease!SRgba8[4] readers;
        SRgba8 first;
        foreach (subscriber; 0 .. subscribers)
        {
            readers[subscriber] = cache[slot];
            ++stats.retains;
            SRgba8 value;
            {
                scope auto view = readers[subscriber].view();
                require(view.trySample(0, x, y, value),
                    "raw mixed subscribed read");
            }
            if (subscriber == 0) first = value;
            else require(first == value, "raw mixed subscriber pixel identity");
            stats.digest += mixedSampleCode(value, keys[slot]);
        }
        foreach (subscriber; 0 .. subscribers)
            readers[subscriber] = RasterLease!SRgba8.init;
    }
    foreach (slot; 0 .. 2)
    {
        cache[slot] = RasterLease!SRgba8.init;
        require(ledger.release(slot), "raw final mixed cache refund");
    }
    require(ledger.charged == 0, "raw mixed ledger empty after cleanup");
    return stats;
}

private MixedStats mixedControlled(
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper, scope DecodedRgbaLayer lower,
    size_t side, size_t requests, size_t hitPercent,
    size_t subscribers, size_t budget)
{
    OwnedDeliveryCache cache = OwnedDeliveryCache(budget);
    auto audit = cache.auditForResearch();
    size_t[2] keys = [0, 1];
    foreach (slot; 0 .. 2)
    {
        RasterLease!SRgba8 produced;
        require(runReservedOwnedProbe(prepared, upper, lower,
            mixedRegion(keys[slot], side), cache.producerLedger(), slot,
            ReservedFault.none, produced) == ReservedResult.succeeded &&
            cache.adoptCompleted(slot, produced),
            "controlled mixed cache seed from actual source-over");
    }
    MixedStats stats;
    foreach (i; 0 .. requests)
    {
        const slot = mixedSlot(i);
        const x = i % side, y = (i / side) % side;
        if (plannedMixedHit(i, hitPercent))
            ++stats.hits;
        else
        {
            OwnedDeliveryHandle stranded;
            require(cache.tryDeliver(slot, stranded),
                "old controlled ROI retained before cache eviction");
            const chargedBefore = audit.charged;
            require(cache.evict(slot) && audit.charged == chargedBefore,
                "controlled cache eviction cannot refund live subscriber");
            SRgba8 oldPixel;
            require(stranded.trySample(x, y, oldPixel),
                "evicted controlled ROI remains independently readable");
            stats.digest += mixedSampleCode(oldPixel, keys[slot]);
            require(stranded.close() && audit.charged < chargedBefore,
                "last controlled owner refunds old charge exactly once");
            ++stats.refunds;
            ++stats.evictions;
            ++stats.misses;
            ++stats.retains;
            keys[slot] = alternateMixedKey(keys[slot]);
            RasterLease!SRgba8 produced;
            require(runReservedOwnedProbe(prepared, upper, lower,
                mixedRegion(keys[slot], side), cache.producerLedger(), slot,
                ReservedFault.none, produced) == ReservedResult.succeeded &&
                cache.adoptCompleted(slot, produced),
                "controlled slot reuses only after last owner disappears");
        }

        OwnedDeliveryHandle[4] readers;
        SRgba8 first;
        foreach (subscriber; 0 .. subscribers)
        {
            require(cache.tryDeliver(slot, readers[subscriber]),
                "controlled mixed independent subscription");
            ++stats.retains;
            SRgba8 value;
            require(readers[subscriber].trySample(x, y, value),
                "controlled mixed subscriber read");
            if (subscriber == 0) first = value;
            else require(first == value,
                "controlled mixed subscribers see identical RGBA");
            stats.digest += mixedSampleCode(value, keys[slot]);
        }
        foreach (subscriber; 0 .. subscribers)
            require(readers[subscriber].close(),
                "each mixed controlled subscriber retires once");
    }
    foreach (slot; 0 .. 2)
        require(cache.evict(slot), "controlled final mixed eviction");
    require(audit.charged == 0 &&
        audit.externalRetains(0) == 0 && audit.externalRetains(1) == 0,
        "mixed cache and delivered accounting both empty");
    return stats;
}

private void runMixedDeliveryBenchmarkMode(string[] options)
{
    import std.conv : to;
    import std.string : startsWith;
    import std.datetime.stopwatch : StopWatch;

    size_t side = 16, rounds = 7, requests = 200, warmups = 1;
    size_t hitPercent = 75, subscribers = 2;
    foreach (arg; options)
    {
        if (arg.startsWith("--side=")) side = to!size_t(arg[7 .. $]);
        else if (arg.startsWith("--rounds="))
            rounds = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--requests="))
            requests = to!size_t(arg[11 .. $]);
        else if (arg.startsWith("--warmups="))
            warmups = to!size_t(arg[10 .. $]);
        else if (arg.startsWith("--hit="))
            hitPercent = to!size_t(arg[6 .. $]);
        else if (arg.startsWith("--subscribers="))
            subscribers = to!size_t(arg[14 .. $]);
        else require(false, "unknown mixed benchmark CLI flag");
    }
    require(checkMixedDeliverySchedule() && (side == 16 || side == 64) &&
        (hitPercent == 25 || hitPercent == 75 || hitPercent == 95) &&
        (subscribers == 1 || subscribers == 2 || subscribers == 4) &&
        rounds >= 1 && rounds <= 50 && warmups <= 10 &&
        requests >= 100 && requests <= 1_000_000 && requests % 100 == 0,
        "mixed benchmark side, request counts, and coverage bounds");

    const capacity = 12 * side * side + 192;
    const interpretation = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto upperOwner = makeImage(side + 12, side + 12, Layout.planar,
        0, interpretation, true);
    auto lowerOwner = makeImage(side + 12, side + 12, Layout.interleaved,
        1, interpretation, true);
    const upper = DecodedRgbaLayer(upperOwner.view(),
        interpretation.encoding, interpretation.association);
    const lower = DecodedRgbaLayer(lowerOwner.view(),
        interpretation.encoding, interpretation.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared) == RgbaCompositeError.none,
        "mixed benchmark prepared compositor");

    foreach (warmup; 0 .. warmups)
    {
        auto a = mixedRaw(prepared, upper, lower, side, requests,
            hitPercent, subscribers, capacity);
        auto b = mixedControlled(prepared, upper, lower, side, requests,
            hitPercent, subscribers, capacity);
        require(a == b, "warmup paths execute identical ROI/pixel trace");
    }

    writeln("experiment,side,hit_percent,subscribers,round,variant,",
        "requests,hits,misses,evictions,retains,refunds,elapsed_us,",
        "thread_gc_bytes,digest");
    foreach (round; 0 .. rounds)
    {
        MixedStats[2] pair;
        foreach (step; 0 .. 2)
        {
            const path = (round + step) % 2;
            const beforeGc = GC.stats().allocatedInCurrentThread;
            StopWatch watch;
            watch.start();
            pair[path] = path == 0
                ? mixedRaw(prepared, upper, lower, side, requests,
                    hitPercent, subscribers, capacity)
                : mixedControlled(prepared, upper, lower, side, requests,
                    hitPercent, subscribers, capacity);
            watch.stop();
            const afterGc = GC.stats().allocatedInCurrentThread;
            const result = pair[path];
            require(afterGc >= beforeGc &&
                result.hits == requests * hitPercent / 100 &&
                result.hits + result.misses == requests &&
                result.evictions == result.misses &&
                result.refunds == result.misses &&
                result.retains == requests * subscribers + result.misses &&
                result.digest != 0,
                "mixed counter and iteration/gc attribution correct");
            writeln("m3_delivery_mixed,", side, ",", hitPercent, ",",
                subscribers, ",", round, ",", path == 0 ? "raw" :
                "controlled", ",", requests, ",", result.hits, ",",
                result.misses, ",", result.evictions, ",",
                result.retains, ",", result.refunds, ",",
                watch.peek.total!"usecs", ",",
                afterGc - beforeGc, ",", result.digest);
        }
        require(pair[0] == pair[1],
            "matched raw/controlled workload, ownership and RGBA digest");
    }
    writeln("DELIVERY-MIXED PASS: deterministic exact-rate hits, ",
        "two-slot collisions, variable subscribers and retained eviction");
}

// Standalone @safe consumer compilation contract for the research delivery:
// only value-pixel reads and explicit retained participants, never raw owner
// or borrowed raster views, are exposed to the outside consumer.
private @safe bool readAndRetainGeneration(
    ref GenerationDelivery handle, out SRgba8 pixel)
{
    GenerationDelivery temporary;
    return handle.trySample(0, 0, pixel) &&
        handle.tryRetain(temporary) && temporary.close();
}

// Production-real ROI helper for independent bounded generation accounting.
// No user-visible buffer is published until source-over/import succeeded.
// Failed producer reservations are credited back via scope(exit) in release
// configurations too; the accounting is distinct from raster-d ownership.
private bool produceOwnedGeneration(
    ref GenerationCache cache, size_t slot, Region2D roi,
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer top, scope DecodedRgbaLayer bottom,
    out size_t generation, bool injectFailure = false)
{
    OwnedPayloadPlan plan;
    if (tryPlanOwnedRgbaPayload(roi, size_t.max, plan)
            != OwnedPayloadStatus.admissible ||
        !cache.tryReserve(slot, plan, 128, 64, generation))
        return false;
    bool published;
    scope(exit)
    {
        if (!published)
            require(cache.abort(slot, generation),
                "aborted generation releases exactly its pending charge");
    }
    if (injectFailure)
        return false;
    RasterLease!SRgba8 completed;
    if (tryCompositeOwnedPackedResearch(prepared, top, bottom,
        roi, completed) != RgbaCompositeError.none)
        return false;
    if (!cache.adoptCompleted(slot, generation, completed))
        return false;
    published = true;
    return true;
}

// Unlike the previous two-ticket cache, generation identity is never the
// cache-slot index. The old A lease can outlive eviction, new B can occupy
// slot 0, and both independent charges remain live.
private void checkIndependentRasterGenerations()
{
    import std.algorithm.mutation : move;

    static assert(!__traits(compiles, {
        GenerationDelivery a;
        auto duplicated = a;
    }), "multiple generation delivery participants forbid implicit copy");
    static assert(!__traits(compiles, {
        GenerationCache a = GenerationCache(10_000);
        auto duplicated = a;
    }), "multiple generation cache owners forbid implicit copy");

    const interpretation = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto upperOwner = makeImage(40, 40, Layout.planar,
        0, interpretation, true);
    auto lowerOwner = makeImage(40, 40, Layout.interleaved,
        1, interpretation, true);
    const top = DecodedRgbaLayer(upperOwner.view(),
        interpretation.encoding, interpretation.association);
    const bottom = DecodedRgbaLayer(lowerOwner.view(),
        interpretation.encoding, interpretation.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none,
        "prepare real multigeneration RGBA composer");

    const Region2D aRoi = Region2D(3, 4, 16, 16);
    const Region2D bRoi = Region2D(4, 5, 16, 16);
    const Region2D cRoi = Region2D(5, 6, 16, 16);
    const Region2D dRoi = Region2D(6, 7, 16, 16);
    GenerationDelivery a0, a1, b0, c0, d0;
    GenerationAccounting proof;
    size_t aId, bId, cId, dId;
    size_t metadataGcBytes;
    {
        const gcBeforeMetadata = GC.stats().allocatedInCurrentThread;
        GenerationCache cache = GenerationCache(10_000);
        const gcAfterMetadata = GC.stats().allocatedInCurrentThread;
        require(gcAfterMetadata >= gcBeforeMetadata,
            "multigeneration metadata GC counter monotonic");
        metadataGcBytes = gcAfterMetadata - gcBeforeMetadata;
        proof = cache.auditForResearch();
        require(proof !is null && proof.charged == 0,
            "one bounded metadata object starts uncharged");

        require(produceOwnedGeneration(cache, 0, aRoi,
                prepared, top, bottom, aId) &&
            aId != 0 && proof.charged == 1088 &&
            proof.active == 1 &&
            cache.tryDeliver(0, a0) &&
            a0.tryRetain(a1) &&
            proof.subscribers(aId) == 2,
            "generation A adopts one real backing and two true leases");
        require(cache.evict(0) &&
            proof.charged == 1088 && a0.live() && a1.live(),
            "evicted generation A keeps its physical backing and charge");

        // SAME CACHE SLOT, different generation and physical pixels.
        require(produceOwnedGeneration(cache, 0, bRoi,
                prepared, top, bottom, bId) &&
            bId > aId && bId != aId &&
            proof.active == 2 && proof.charged == 2176 &&
            cache.tryDeliver(0, b0) && cache.evict(0),
            "B admits into old A slot WHILE two A subscribers still live");

        require(produceOwnedGeneration(cache, 0, cRoi,
                prepared, top, bottom, cId) &&
            cId > bId && proof.active == 3 &&
            proof.charged == 3264 &&
            cache.tryDeliver(0, c0) && cache.evict(0),
            "third independent generation shares same logical slot safely");

        SRgba8 safePixel;
        require(readAndRetainGeneration(a0, safePixel) &&
            proof.subscribers(aId) == 2,
            "@safe external consumer may read and explicitly retain/retire");
        SRgba8 aPixel, aCopy, bPixel, cPixel;
        require(a0.trySample(0, 0, aPixel) &&
            a1.trySample(0, 0, aCopy) &&
            b0.trySample(0, 0, bPixel) &&
            c0.trySample(0, 0, cPixel) &&
            aPixel == aCopy &&
            a0.generationForResearch == aId &&
            b0.generationForResearch == bId &&
            c0.generationForResearch == cId,
            "each old delivered handle keeps identity and readable pixels");
        foreach (y; 0 .. 16)
        foreach (x; 0 .. 16)
        {
            SRgba8 first, second;
            require(a0.trySample(x, y, first) &&
                a1.trySample(x, y, second) && first == second,
                "all retained A pixels identical despite two successors");
        }

        // All three fixed generation records are accounted, so admission
        // fails cleanly before producing the next image.
        OwnedPayloadPlan plan;
        require(tryPlanOwnedRgbaPayload(dRoi, size_t.max, plan)
                == OwnedPayloadStatus.admissible,
            "plan next independent real ROI");
        size_t rejected;
        const beforeRejected = proof.charged;
        require(!cache.tryReserve(0, plan, 128, 64, rejected) &&
            rejected == 0 && proof.charged == beforeRejected,
            "full generation-record table rejects without mutated credit");

        require(a0.close() && !a0.close() &&
            proof.charged == 3264 && proof.subscribers(aId) == 1,
            "first A release cannot refund or destroy second A subscriber");
        // Explicit move is supported; arbitrary implicit D array/AA copies
        // must never become a resource-owning public contract.
        auto movedA = move(a1);
        require(!a1.live() && movedA.live() &&
            movedA.generationForResearch == aId &&
            proof.charged == 3264,
            "moving A does not create/retire any subscription");
        require(movedA.close() && proof.phase(aId) == GenerationPhase.vacant &&
            proof.charged == 2176 && proof.active == 2,
            "last A owner alone releases A charge and metadata ticket");

        // Recycle the now-empty metadata RECORD, not generation ID.
        require(produceOwnedGeneration(cache, 0, dRoi,
                prepared, top, bottom, dId) &&
            dId > cId && dId != aId && proof.charged == 3264 &&
            cache.tryDeliver(0, d0) && cache.evict(0),
            "new D ticket has fresh monotonic ID after A record reuse");
        SRgba8 bAfter, cAfter, dAfter;
        require(b0.trySample(0, 0, bAfter) &&
            c0.trySample(0, 0, cAfter) &&
            d0.trySample(0, 0, dAfter) &&
            proof.subscribers(bId) == 1 &&
            proof.subscribers(cId) == 1 &&
            proof.subscribers(dId) == 1,
            "B C D all survive slot eviction/republication");
    }

    require(proof.charged == 3264 && proof.active == 3 &&
        b0.live() && c0.live() && d0.live(),
        "three generations keep charges after cache owner destruction");
    SRgba8 afterCache;
    require(b0.trySample(0, 0, afterCache) &&
        c0.trySample(0, 0, afterCache) &&
        d0.trySample(0, 0, afterCache),
        "each generation still owns its physical backing after cache");
    require(b0.close() && proof.charged == 2176 &&
        proof.phase(bId) == GenerationPhase.vacant &&
        c0.close() && proof.charged == 1088 &&
        d0.close() && proof.charged == 0 && proof.active == 0,
        "generation refunds independent of slot and final close order");

    // Budget rejection must account for OLD delivered bytes PLUS the
    // NEW producer peak: 1088 + 2176 > 3263, but =3264 succeeds.
    {
        GenerationCache limited = GenerationCache(3263);
        auto account = limited.auditForResearch();
        size_t firstId, secondId;
        GenerationDelivery first;
        require(produceOwnedGeneration(limited, 0, aRoi, prepared,
            top, bottom, firstId) &&
            limited.tryDeliver(0, first) && limited.evict(0) &&
            account.charged == 1088,
            "constrained cache pins old generation after eviction");
        OwnedPayloadPlan plan;
        require(tryPlanOwnedRgbaPayload(bRoi, size_t.max, plan)
            == OwnedPayloadStatus.admissible, "plan budget rejection ROI");
        size_t refused;
        require(!limited.tryReserve(0, plan, 128, 64, refused) &&
            refused == 0 && account.charged == 1088,
            "exact peak-budget deficit rejects WITHOUT side effects");
        require(first.close() && account.charged == 0,
            "closing last old owner restores full capacity");
        require(produceOwnedGeneration(limited, 0, bRoi, prepared,
            top, bottom, secondId) && secondId > firstId &&
            account.charged == 1088 && limited.evict(0) &&
            account.charged == 0,
            "new generation succeeds after old charge refund");
    }

    // Global pressure is shared across BOTH cache slots. A still-retained
    // generation must continue consuming budget even when a different slot
    // attempts to publish; final old-owner close may unblock admission.
    {
        GenerationCache twoSlots = GenerationCache(3400);
        auto meter = twoSlots.auditForResearch();
        GenerationDelivery oldA, currentB, slotOne;
        size_t firstId, secondId, thirdId;
        require(produceOwnedGeneration(twoSlots, 0, aRoi,
            prepared, top, bottom, firstId) &&
            twoSlots.tryDeliver(0, oldA) &&
            twoSlots.evict(0) &&
            produceOwnedGeneration(twoSlots, 0, bRoi,
                prepared, top, bottom, secondId) &&
            twoSlots.tryDeliver(0, currentB) &&
            meter.charged == 2176,
            "global budget accounts old retired A and current B together");

        OwnedPayloadPlan crossSlotPlan;
        require(tryPlanOwnedRgbaPayload(cRoi, size_t.max, crossSlotPlan)
            == OwnedPayloadStatus.admissible, "plan second-cache-slot ROI");
        size_t refused;
        require(!twoSlots.tryReserve(1, crossSlotPlan, 128, 64, refused) &&
            refused == 0 && meter.charged == 2176,
            "second slot admission blocked by OLD generation in first slot");
        require(oldA.close() && meter.charged == 1088 &&
            produceOwnedGeneration(twoSlots, 1, cRoi,
                prepared, top, bottom, thirdId) &&
            twoSlots.tryDeliver(1, slotOne) &&
            meter.charged == 2176,
            "last old A release unblocks different cache slot");
        require(twoSlots.evict(0) && twoSlots.evict(1) &&
            meter.charged == 2176 &&
            currentB.close() && meter.charged == 1088 &&
            slotOne.close() && meter.charged == 0,
            "independent B/C charges correctly survive cross-slot eviction");
    }

    // Destruction of a live stack delivery *after* its producing cache is
    // gone must release the last charge without explicit close().
    {
        GenerationAccounting accounting;
        {
            GenerationDelivery autoClosed;
            {
                GenerationCache shortCache = GenerationCache(2176);
                accounting = shortCache.auditForResearch();
                size_t autoId;
                require(produceOwnedGeneration(shortCache, 0, aRoi,
                        prepared, top, bottom, autoId) &&
                    shortCache.tryDeliver(0, autoClosed) &&
                    shortCache.evict(0) &&
                    accounting.charged == 1088,
                    "prepare RAII-delivery surviving generation cache owner");
            }
            require(autoClosed.live() && accounting.charged == 1088,
                "cache exit does not refund last external generation owner");
        }
        require(accounting.charged == 0 && accounting.active == 0,
            "generation delivery RAII destructor refunds after cache exit");
    }

    // Failed production and exiting with pending reservation must both
    // refund peak credit without publishing a raster or carrying a lease.
    {
        GenerationAccounting audit;
        {
            GenerationCache cache = GenerationCache(2176);
            audit = cache.auditForResearch();
            OwnedPayloadPlan validPlan;
            require(tryPlanOwnedRgbaPayload(aRoi, size_t.max, validPlan)
                == OwnedPayloadStatus.admissible,
                "forged-plan checks start with valid source plan");
            auto undercharged = validPlan;
            undercharged.retainedPayloadBytes = 1;
            size_t rejectedId;
            require(!cache.tryReserve(0, undercharged, 128, 64, rejectedId) &&
                rejectedId == 0 && audit.charged == 0,
                "forged cheap retained bytes cannot undercharge a generation");
            auto overflowing = validPlan;
            overflowing.pixels = size_t.max;
            require(!cache.tryReserve(0, overflowing, 128, 64, rejectedId) &&
                rejectedId == 0 && audit.charged == 0,
                "forged overflowing pixels cannot bypass checked peak cost");

            size_t injected;
            require(!produceOwnedGeneration(cache, 0, aRoi,
                prepared, top, bottom, injected, true) &&
                audit.charged == 0 &&
                audit.phase(injected) == GenerationPhase.vacant,
                "failed producer aborts pending reservation in release");
            OwnedPayloadPlan plan;
            require(tryPlanOwnedRgbaPayload(aRoi, size_t.max, plan)
                == OwnedPayloadStatus.admissible, "pending test plan");
            size_t pending;
            require(cache.tryReserve(0, plan, 128, 64, pending) &&
                audit.phase(pending) == GenerationPhase.reserved &&
                audit.charged == 2176,
                "pending generation independently holds peak charge");
        }
        require(audit.charged == 0 && audit.active == 0,
            "cache scope destructor refunds never-published peak credit");
    }

    writeln("M3 RGBA multigeneration GC metadata observation: ",
        metadataGcBytes, " bytes per three-ticket control record");
    writeln("M3 RGBA multigeneration PASS: 4 generation identities, ",
        "3 simultaneous surviving rasters, checked peak budget, ",
        "abort, record reuse, post-cache RAII and exact last-owner refund");
}

// Issue #74 cancellation model: serialized, synchronous explicit close.
// This tests delivery participants independently, including old-generation
// subscribers retained AFTER their cache slot was replaced. It DOES NOT
// claim thread-safe callbacks or cancellation races.
private void checkGenerationCancellationOrder()
{
    const meaning = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto topOwner = makeImage(40, 40, Layout.planar, 0, meaning, true);
    auto bottomOwner = makeImage(40, 40, Layout.interleaved,
        1, meaning, true);
    const top = DecodedRgbaLayer(topOwner.view(),
        meaning.encoding, meaning.association);
    const bottom = DecodedRgbaLayer(bottomOwner.view(),
        meaning.encoding, meaning.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared) ==
        RgbaCompositeError.none, "cancellation prepared RGBA fixture");

    GenerationCache cache = GenerationCache(10_000);
    auto account = cache.auditForResearch();
    size_t aId, bId, cId;
    const roiA = Region2D(3, 4, 16, 16);
    const roiB = Region2D(4, 5, 16, 16);
    const roiC = Region2D(5, 6, 16, 16);
    GenerationDelivery a0, a1, a2, b0, c0;
    require(produceOwnedGeneration(cache, 0, roiA, prepared,
            top, bottom, aId) &&
        produceOwnedGeneration(cache, 1, roiB, prepared,
            top, bottom, bId) &&
        cache.tryDeliver(0, a0) &&
        cache.tryDeliver(0, a1) &&
        cache.tryDeliver(1, b0) &&
        account.charged == 2176 &&
        account.subscribers(aId) == 2 &&
        account.subscribers(bId) == 1,
        "two cache slots and three subscribers own genuine retained RGBA");

    // A new owner must not overwrite a live output handle, or silently
    // increment charges/refcounts on a failed attempted retain.
    require(!cache.tryDeliver(1, a1) && !a0.tryRetain(a1) &&
        account.charged == 2176 && account.subscribers(aId) == 2 &&
        account.subscribers(bId) == 1,
        "delivery into live output and duplicate retain are inert failures");

    require(cache.evict(0) &&
        produceOwnedGeneration(cache, 0, roiC, prepared,
            top, bottom, cId) &&
        cache.tryDeliver(0, c0) &&
        account.charged == 3264 &&
        account.active == 3 &&
        cId > bId && bId > aId,
        "old A and live B coexist with new slot-zero generation C");

    // Explicit retain on an already evicted A is legal while A remains
    // independently alive, and creates no additional image backing.
    require(a0.tryRetain(a2) &&
        account.subscribers(aId) == 3 &&
        account.charged == 3264,
        "evicted A subscriber can gain independent controlled owner");

    // Pure control-plane churn should not allocate a GC object per
    // subscriber. Use fixed stack storage; every temporary closes.
    const beforeGc = GC.stats().allocatedInCurrentThread;
    foreach (unused; 0 .. 256)
    {
        GenerationDelivery temporary;
        require(a2.tryRetain(temporary) && temporary.close(),
            "temporary canceled old A subscription exactly once");
    }
    const afterGc = GC.stats().allocatedInCurrentThread;
    require(afterGc >= beforeGc && afterGc - beforeGc == 0 &&
        account.subscribers(aId) == 3 &&
        account.charged == 3264,
        "256 cancellation cycles require no per-retain GC allocation");

    SRgba8 firstA, laterA, newerC;
    require(a0.trySample(0, 0, firstA) &&
        a2.trySample(0, 0, laterA) &&
        c0.trySample(0, 0, newerC) &&
        firstA == laterA,
        "cancelable old A continues to expose unchanged real pixels");

    require(a1.close() && account.subscribers(aId) == 2 &&
        account.charged == 3264 &&
        b0.close() && account.subscribers(bId) == 0 &&
        account.charged == 3264,
        "cancel A1 and B0 without refund while owners remain");
    // The B cache still owns B even after its LAST external subscriber
    // canceled. A's three-generation accounting remains fully charged.
    require(cache.evict(1) && account.charged == 2176 &&
        account.phase(bId) == GenerationPhase.vacant,
        "B refunds exactly when its cache owner also retires");
    require(a0.close() && !a0.close() &&
        account.charged == 2176 && account.subscribers(aId) == 1,
        "idempotent-in-effect A0 cancel cannot double refund old A");
    require(a2.close() &&
        account.charged == 1088 &&
        account.phase(aId) == GenerationPhase.vacant &&
        account.subscribers(cId) == 1,
        "last A cancellation refunds only old generation charge");
    require(cache.evict(0) &&
        account.charged == 1088 && c0.live() &&
        c0.trySample(0, 0, newerC) &&
        c0.close() && account.charged == 0 &&
        account.active == 0,
        "C outlives cache eviction and final cancel returns all credit");
    writeln("M3 RGBA generation cancellation PASS: 3 generations, ",
        "old/subscribed-after-eviction retain, out-of-order cancels, ",
        "256 zero-GC retain/close pairs and no double refund");
}

// Issue #74: process-wide memory/residency diagnostics for THREE live,
// same-slot raster generations. Research only. This profile deliberately
// excludes concurrency and reports Linux RSS/HWM and glibc mallinfo2 as
// observations rather than asserting a native memory bound.
private struct GenerationMemoryPoint
{
    MemorySnapshot measured;
    size_t generations;
    size_t chargedExample;
    size_t requestedLivePayload;
}

private void captureGenerationMemory(
    ref GenerationMemoryPoint point, GenerationAccounting meter,
    size_t payloadBytes)
{
    point.measured = sampleGenerationMemory();
    require(point.measured.ok,
        "Linux /proc/self/status and glibc mallinfo2 memory sample");
    point.generations = meter is null ? 0 : meter.active;
    point.chargedExample = meter is null ? 0 : meter.charged;
    point.requestedLivePayload = point.generations * payloadBytes;
}

private void runGenerationMemoryMode(string[] options)
{
    import std.conv : to;
    import std.string : startsWith;

    size_t side = 256;
    foreach (arg; options)
    {
        if (arg.startsWith("--side="))
            side = to!size_t(arg[7 .. $]);
        else
            require(false, "unknown generation-memory diagnostic argument");
    }
    require(side == 16 || side == 64 || side == 256 || side == 512,
        "bounded independent generation memory ROI size");
    const size_t payload = 4 * side * side;
    const size_t capacity = 20 * side * side + 4096;
    const interpretation = Interpretation(
        RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    auto topOwner = makeImage(side + 12, side + 12,
        Layout.planar, 0, interpretation, true);
    auto bottomOwner = makeImage(side + 12, side + 12,
        Layout.interleaved, 1, interpretation, true);
    const top = DecodedRgbaLayer(topOwner.view(),
        interpretation.encoding, interpretation.association);
    const bottom = DecodedRgbaLayer(bottomOwner.view(),
        interpretation.encoding, interpretation.association);
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none,
        "memory diagnostic prepared real source-over");
    // Touch /proc and glibc samplers before the recorded baseline, so
    // one-time sampling initialization is not misattributed to a cache.
    require(sampleGenerationMemory().ok,
        "warm Linux glibc memory instrumentation");

    GenerationMemoryPoint[10] points;
    const string[10] phases = [
        "fixtures", "accounting", "a_live", "a_evicted",
        "ab_live", "abc_live", "cache_exited",
        "a_closed", "b_closed", "c_closed"
    ];
    GenerationDelivery a, b, c;
    GenerationAccounting meter;
    size_t aId, bId, cId;
    captureGenerationMemory(points[0], meter, payload);
    {
        GenerationCache cache = GenerationCache(capacity);
        meter = cache.auditForResearch();
        captureGenerationMemory(points[1], meter, payload);
        require(produceOwnedGeneration(cache, 0,
                Region2D(3, 4, side, side), prepared,
                top, bottom, aId) && cache.tryDeliver(0, a) &&
            meter.charged == payload + 64,
            "real A ROI published with independent generation charge");
        captureGenerationMemory(points[2], meter, payload);
        require(cache.evict(0) && meter.charged == payload + 64,
            "old A still retains its pixels when evicted");
        captureGenerationMemory(points[3], meter, payload);
        require(produceOwnedGeneration(cache, 0,
                Region2D(4, 5, side, side), prepared,
                top, bottom, bId) && cache.tryDeliver(0, b) &&
            cache.evict(0) && bId > aId &&
            meter.charged == 2 * (payload + 64),
            "new B backing published over retained A");
        captureGenerationMemory(points[4], meter, payload);
        require(produceOwnedGeneration(cache, 0,
                Region2D(5, 6, side, side), prepared,
                top, bottom, cId) && cache.tryDeliver(0, c) &&
            cache.evict(0) && cId > bId &&
            meter.charged == 3 * (payload + 64),
            "A/B/C simultaneously retain three physical backings");
        captureGenerationMemory(points[5], meter, payload);
        SRgba8 pa, pb, pc;
        require(a.trySample(0, 0, pa) &&
            b.trySample(0, 0, pb) && c.trySample(0, 0, pc),
            "physical sampled pixels remain readable in three generations");
    }
    captureGenerationMemory(points[6], meter, payload);
    require(meter.charged == 3 * (payload + 64) &&
        meter.active == 3, "cache death cannot refund subscriber owners");
    require(a.close() && meter.charged == 2 * (payload + 64),
        "A final physical owner retired first");
    captureGenerationMemory(points[7], meter, payload);
    require(b.close() && meter.charged == payload + 64,
        "B final physical owner retired second");
    captureGenerationMemory(points[8], meter, payload);
    require(c.close() && meter.charged == 0 && meter.active == 0,
        "C final owner retired; metadata tickets all vacant");
    captureGenerationMemory(points[9], meter, payload);

    // No RSS or malloc counters have equality assertions: glibc may hold
    // freed blocks in arenas, GC can retain metadata, and VmHWM only rises.
    require(points[1].measured.gcAllocatedByCurrentThread >=
        points[0].measured.gcAllocatedByCurrentThread,
        "GC allocation count monotonic around control construction");
    const gcClass = points[1].measured.gcAllocatedByCurrentThread -
        points[0].measured.gcAllocatedByCurrentThread;
    foreach (index; 0 .. points.length)
    {
        // Linux /proc may report a *lower* VmHWM after a native mmap
        // backing is retired (observed in the pinned 256-ROI CI trace).
        // Preserve each number as-is. Only require internal coherence
        // of each individual resident/HWM sample, not monotonicity.
        require(points[index].measured.vmHwmKiB >=
            points[index].measured.vmRssKiB,
            "individual process HWM sample must cover current RSS");
    }

    writeln("experiment,side,phase,active_generations,requested_live_",
        "payload_bytes,illustrative_charge_bytes,thread_gc_cumulative_",
        "bytes,glibc_malloc_used_bytes,glibc_mmap_bytes,glibc_free_bytes,",
        "vmrss_kib,vmhwm_kib");
    foreach (index; 0 .. points.length)
    {
        const p = points[index];
        writeln("m3_generation_memory,", side, ",", phases[index], ",",
            p.generations, ",", p.requestedLivePayload, ",",
            p.chargedExample, ",",
            p.measured.gcAllocatedByCurrentThread, ",",
            p.measured.mallocUsedBytes, ",",
            p.measured.mallocMappedBytes, ",",
            p.measured.mallocFreeBytes, ",",
            p.measured.vmRssKiB, ",", p.measured.vmHwmKiB);
    }
    writeln("M3 GENERATION MEMORY PASS: real A/B/C source-over backings, ",
        "three independently retained generations, zero terminal ",
        "accounting charge; observed control GC allocation=", gcClass);
}

void main(string[] args)
{
    require(checkOwnedPayloadBudgetContract(),
        "owned payload budget preflight and failure-state contract");
    if (args.length > 1 && args[1] == "--generation-memory")
    {
        runGenerationMemoryMode(args[2 .. $]);
        return;
    }
    if (args.length > 1 && args[1] == "--delivery-mixed-bench")
    {
        runMixedDeliveryBenchmarkMode(args[2 .. $]);
        return;
    }
    if (args.length > 1 && args[1] == "--delivery-workflow-bench")
    {
        runDeliveryWorkflowBenchmarkMode(args[2 .. $]);
        return;
    }
    if (args.length > 1 && args[1] == "--delivery-bench")
    {
        runDeliveryBenchmarkMode(args[2 .. $]);
        return;
    }
    if (args.length > 1 && args[1] == "--owned-bench")
    {
        runOwnedBench(args[2 .. $]);
        return;
    }
    require(args.length == 1, "unknown consumer command argument");
    checkReservedOwnedFaultContract();
    checkPublicImportPrecommitDisposition();
    checkClosedOwnerDeliveryContract();
    checkCacheEvictionWithRetainedSubscriber();
    checkTwoIndependentRetainedSubscribers();
    checkIndependentDeliveryHandles();
    checkIndependentRasterGenerations();
    checkGenerationCancellationOrder();
    writeln("M3 RGBA independent delivery PASS: move-only handles, ",
        "cache-outliving RAII, two subscribers, 256 zero-GC retains");
    writeln("M3 RGBA two-subscriber retention PASS: independent A/A/B ",
        "leases survive eviction and cancel; charge returns at last owner");
    writeln("M3 RGBA reservation/fault PASS: two ROI requests, ",
        "three injected failures, and public import precommit ownership");
    const Interpretation[3] formats = [
        Interpretation(RgbaEncoding.encodedSRgb, RgbaAssociation.straight),
        Interpretation(RgbaEncoding.linearSRgb, RgbaAssociation.straight),
        Interpretation(RgbaEncoding.linearSRgb, RgbaAssociation.premultiplied)
    ];
    const Region2D[2] rois = [
        Region2D(0, 0, width, height),
        Region2D(2, 1, 4, 3)
    ];
    const double[3] opacities = [0.0, 0.37, 1.0];

    size_t scenes = 0;
    size_t samples = 0;
    uint greatestDeviation = 0;

    foreach (topLayout; [Layout.planar, Layout.interleaved])
    foreach (bottomLayout; [Layout.planar, Layout.interleaved])
    foreach (outputLayout; [Layout.planar, Layout.interleaved])
    foreach (topType; formats)
    foreach (bottomType; formats)
    foreach (opacity; opacities)
    foreach (roi; rois)
    {
        const worst = execute(topLayout, bottomLayout, outputLayout,
            topType, bottomType, roi, opacity);
        if (worst > greatestDeviation)
            greatestDeviation = worst;
        ++scenes;
        samples += roi.width * roi.height * 4;
    }

    checkOwnedPackedWithSharedOriginalBacking();

    require(scenes == 432, "coverage matrix scene count");
    require(samples == 51_840, "all-pixel oracle count");
    writeln("M3 RGBA owned-packed result PASS: ", scenes,
        " byte-exact scenes, no partial publication on tested errors");
    writeln("M3 RGBA prepared consumer PASS: ", scenes,
        " byte-exact scenes with reusable runtime opacity; inert/invalid ",
        "context rejected before writes and no GC bytes in prepared calls");
    writeln("M3 RGBA composite consumer PASS: ", scenes,
        " scenes, ", samples, " independently checked RGBA samples, ",
        "max channel delta ", greatestDeviation,
        ", preflight untouched, zero mapped GC");
}

// DIP1000 compilation MUST reject returning a borrowed view whose local
// RasterLease has already expired. Guard exists only in negative DUB config.
version (M3_RGBA_COMPOSITE_NEGATIVE_ESCAPE)
{
    @safe DecodedRgbaLayer illegalEscapedCompositeLayer()
    {
        RasterLease!ubyte local;
        return DecodedRgbaLayer(local.view(),
            RgbaEncoding.encodedSRgb, RgbaAssociation.straight);
    }
}


version (M3_RGBA_PREPARED_NEGATIVE_FORGE)
{
    @safe void illegalPreparedForge()
    {
        // The constructor is deliberately private to the research module.
        auto forged = ResearchPreparedRgbaContext(0.37);
    }
}

version (M3_RGBA_PREPARED_NEGATIVE_FIELD_MUTATION)
{
    @safe void illegalPreparedMutation()
    {
        ResearchPreparedRgbaContext prepared;
        prepared.opacity = 0.37; // private field outside imagery module
    }
}


version (M3_RGBA_DELIVERY_NEGATIVE_RAW_LEASE_ESCAPE)
{
    // This must fail compilation: raster-d lease ownership is PRIVATE to
    // the research DeliveryHandle and must not escape through a consumer.
    @safe RasterLease!SRgba8 illegalRawDeliveryOwner(
        ref OwnedDeliveryHandle handle)
    {
        return handle.backing_;
    }
}

version (M3_RGBA_DELIVERY_NEGATIVE_IMPLICIT_COPY)
{
    // D containers cannot silently duplicate participation in accounting.
    @safe void illegalImplicitDeliveryCopy(
        ref OwnedDeliveryHandle handle)
    {
        auto copied = handle;
    }
}

version (M3_RGBA_GENERATION_NEGATIVE_RAW_LEASE_ESCAPE)
{
    // Private generation backing must NEVER escape a delivery handle.
    @safe RasterLease!SRgba8 illegalGenerationRawLease(
        ref GenerationDelivery handle)
    {
        return handle.lease_;
    }
}

version (M3_RGBA_GENERATION_NEGATIVE_IMPLICIT_COPY)
{
    @safe void illegalGenerationCopy(ref GenerationDelivery handle)
    {
        auto duplicated = handle;
    }
}
