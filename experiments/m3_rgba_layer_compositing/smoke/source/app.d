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
import color : SRgba8;

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

void main()
{
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
