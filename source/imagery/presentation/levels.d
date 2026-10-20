/++
 General image scalar Levels over borrowed raster views.

 Only already materialized image channels are processed. Ownership, region,
 pixel layout, size and signed strides belong to raster-d; this module does
 not own codecs, image metadata, a scheduler or colour-management machinery.

 The two public overloads differ only by whether an editing-selection mask
 is explicitly supplied. This is the first released source API in
 v0.1.0 under ADR 0006, without a stable ABI or v1.0 compatibility promise.
+/
module imagery.presentation.levels;

import core.stdc.stdlib : malloc, free;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, WritableRasterView, tryAdoptMallocResource,
    tryImportOwnedRaster;
import std.math : pow, sqrt;

/++
 Settings for a scalar normalized-channel Levels adjustment.

 All five values must be finite. Required constraints:
 inputBlack < inputWhite, gamma > 0, and
 0 <= outputBlack <= outputWhite <= 1.
 Inputs are interpreted in the caller-declared numeric channel domain.
 No ICC conversion, sRGB decoding, alpha association or NoData inference.

 `.init` is detectably invalid because its floating fields are NaN;
 passing it to `tryLevelsOwned` returns `LevelsError.invalidParameters`.

 Examples:
 ---
 Levels identity = Levels(0, 1, 1, 0, 1);
 assert(identity.gamma == 1);
 ---
+/
struct Levels
{
    double inputBlack;
    double inputWhite;
    double gamma;
    double outputBlack;
    double outputWhite;
}

/++
 Outcome for owned-result Levels processing.

 `.init` is `notAttempted`: default-initialized statuses NEVER mean
 success. A call succeeds ONLY when it returns `none`. No public method
 returns `notAttempted`. Callers MUST inspect the returned status, not
 infer success from the current value of their destination owner.
 `resultExceedsBudget` means the new float pixel payload alone would
 exceed the caller limit. `allocationFailure` includes detected
 length/stride overflow, malloc failure or failed raster import.
 Ordinary runtime allocation exceptions and OOM errors are not caught.
+/
enum LevelsError : ubyte
{
    /// Default status, not returned by the operation.
    notAttempted,
    /// Full, successful publication of the independently owned result.
    none,
    /// Borrowed source is empty or structurally invalid.
    invalidSource,
    /// Requested nonempty ROI is outside the source.
    invalidRegion,
    /// Levels thresholds, gamma, or output domain are invalid.
    invalidParameters,
    /// Selected-channel count differs from the source channel count.
    invalidChannelSelection,
    /// Explicit editing mask is missing or has the wrong size/plane count.
    invalidMask,
    /// A validated source/output sample read or write failed.
    sampleFailure,
    /// Result size cannot be represented, malloc/adoption/import failed,
    /// or the internally constructed result layout was unusable.
    allocationFailure,
    /// The new float pixel payload exceeds maxResultBytes.
    resultExceedsBudget
}

private bool finite(double x)
@safe pure nothrow @nogc
{
    return x >= -double.max && x <= double.max;
}

private bool contains(Region2D roi, size_t width, size_t height)
@safe pure nothrow @nogc
{
    return roi.width != 0 && roi.height != 0 &&
        roi.x <= width && roi.y <= height &&
        roi.width <= width - roi.x &&
        roi.height <= height - roi.y;
}

private double normalized(T)(T sample)
@safe pure nothrow @nogc
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    static if (is(T == ubyte))
        return cast(double)sample / 255.0;
    else static if (is(T == ushort))
        return cast(double)sample / 65535.0;
    else
        return cast(double)sample;
}

// The sole raw-memory trust boundary validates that bytes is a bounded,
// nonzero requested payload, obtains its pointer exclusively from malloc,
// and adopts that same malloc/free-compatible pointer into an EMPTY
// move-only raster-d owner. The pointer is never exposed to any consumer;
// if adoption returns false, the raw allocation is released exactly once.
// The raster-d token then owns all normal success/returned-failure releases.
// This function does NOT claim to convert fatal OOM Error into a status.
private bool tryCreateOwnedMallocBytes(
    size_t bytes,
    ref OwnedByteResource owned)
@trusted nothrow @nogc
{
    if (bytes == 0 || owned.ownsResource)
        return false;
    void* memory = malloc(bytes);
    if (memory is null)
        return false;
    if (!tryAdoptMallocResource(memory, bytes, owned))
    {
        free(memory);
        return false;
    }
    return true;
}

// Shared read-only preflight for the private pixel execution and the
// owned-result publisher. Error precedence: source, ROI, selected channels,
// Levels parameters, then optional editing-selection mask.

private LevelsError validateLevels(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    Levels settings,
    scope RasterView!ubyte selection,
    bool hasSelection)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    if (pixels.planeCount == 0 || pixels.width == 0 ||
        pixels.height == 0)
        return LevelsError.invalidSource;

    if (!contains(roi, pixels.width, pixels.height))
        return LevelsError.invalidRegion;

    if (affected.length != pixels.planeCount)
        return LevelsError.invalidChannelSelection;

    if (!finite(settings.inputBlack) ||
        !finite(settings.inputWhite) ||
        !finite(settings.gamma) ||
        !finite(settings.outputBlack) ||
        !finite(settings.outputWhite) ||
        !(settings.inputBlack < settings.inputWhite) ||
        !(settings.gamma > 0.0) ||
        settings.outputBlack < 0.0 ||
        settings.outputWhite > 1.0 ||
        !(settings.outputBlack <= settings.outputWhite))
        return LevelsError.invalidParameters;

    if (hasSelection && (selection.planeCount != 1 ||
        selection.width != pixels.width ||
        selection.height != pixels.height))
        return LevelsError.invalidMask;

    return LevelsError.none;
}

// Private destination execution. The owned public API guarantees a newly
// allocated, non-aliasing output; this loop is never exported as a public
// caller-destination operation. Returned late errors discard the temporary.
private LevelsError executeLevelsInto(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    Levels settings,
    scope RasterView!ubyte selection,
    bool hasSelection,
    scope WritableRasterView!float destination)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    const preflight = validateLevels!T(
        pixels, roi, affected, settings, selection, hasSelection);
    if (preflight != LevelsError.none)
        return preflight;

    // Only our private owner factory supplies this destination. An
    // inconsistent shape is an internal result-construction failure,
    // never an invalid caller-supplied destination (none exists).
    if (destination.planeCount != pixels.planeCount ||
        destination.width != roi.width ||
        destination.height != roi.height)
        return LevelsError.allocationFailure;

    // Both thresholds are finite, but their *difference* may overflow
    // double (for example [-double.max, +double.max]). Preserve the
    // defined normalized Levels mapping for those valid settings.
    const span = settings.inputWhite - settings.inputBlack;
    const spanOverflow = !finite(span);
    const halfSpan = spanOverflow
        ? settings.inputWhite * 0.5 - settings.inputBlack * 0.5
        : 0.0;
    const inverseGamma = 1.0 / settings.gamma;
    // A proven semantically equivalent common case; avoids the substantially
    // more expensive generic pow path when gamma is exactly two.
    // All other valid gamma values continue through the original pow path.
    const gammaTwo = settings.gamma == 2.0;
    const outputSpan = settings.outputWhite - settings.outputBlack;

    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        double strength = 1.0;
        if (hasSelection)
        {
            ubyte coverage;
            if (!selection.trySample(0, x, y, coverage))
                return LevelsError.sampleFailure;
            strength = cast(double)coverage / 255.0;
        }
        foreach (channel; 0 .. pixels.planeCount)
        {
            T raw;
            if (!pixels.trySample(channel, x, y, raw))
                return LevelsError.sampleFailure;

            const original = normalized(raw);
            double result = original;
            if (affected[channel] && strength != 0.0 &&
                finite(original))
            {
                // Clamp against thresholds *before* dividing. This
                // avoids unnecessary overflow and exact-boundary
                // instability. For an overflowing threshold difference,
                // halving both endpoints makes the ratio representable.
                double t;
                if (original <= settings.inputBlack)
                    t = 0.0;
                else if (original >= settings.inputWhite)
                    t = 1.0;
                else if (spanOverflow)
                    t = (original * 0.5 - settings.inputBlack * 0.5) /
                        halfSpan;
                else
                    t = (original - settings.inputBlack) / span;
                if (t < 0.0) t = 0.0;
                if (t > 1.0) t = 1.0;
                const shaped = gammaTwo ? sqrt(t) : pow(t, inverseGamma);
                const mapped = settings.outputBlack + shaped * outputSpan;
                // Full-strength selection must publish the mapped value
                // directly. Computing original + (mapped - original) can
                // catastrophically cancel for large finite float inputs:
                // e.g. -float.max mapped to 0.05 previously became 0.
                result = strength == 1.0
                    ? mapped
                    : original + strength * (mapped - original);
            }
            if (!destination.trySetSample(
                    channel, x - roi.x, y - roi.y, cast(float)result))
                return LevelsError.sampleFailure;
        }
    }

    return LevelsError.none;
}

/++
 Internal owner/payload publisher, called by the two documented public
 overloads. Produce one independently owned ROI-sized float Levels
 raster, preserving the prior published result on every returned failure.

 The source and selection may be borrowed from any already retained raster-d
 owner. New result storage is always a separate malloc-backed resource imported
 into a raster-d RasterLease. Neither source nor selection storage is written.

 On success, published receives the new complete lease, replacing its previous
 owner through raster-d's reference-counted assignment. On failure, published
 is untouched. Late source/write failures discard the temporary result.

 `maxResultBytes` MUST be supplied by the consumer. It is a strict limit on
 the NEW ROI result's pixel payload only: roi.width * roi.height *
 pixels.planeCount * float.sizeof bytes. Zero never permits a nonempty result;
 a result exactly equal to the limit succeeds. A smaller limit returns
 resultExceedsBudget before any allocation. The limit is NOT a bound on
 total process RSS, GC allocations, raster backing/metadata, source/mask
 residency, an already published owner or application I/O buffers. During a
 replacement call both old and new result payloads may be alive at once.

 Output is intentionally interleaved float samples with the same number of
 channels as source. Caller-chosen selection flags are forwarded without
 changing the mathematical model. No colour-space/alpha metadata is inferred.

 This candidate may allocate or throw on runtime allocation failure.
 It is `@safe` through one reviewed malloc/adoption trust boundary but
 promises neither `@nogc` nor `nothrow`. A returned allocationFailure
 applies to detected overflows, malloc failure and failed raster adoption.
+/
private LevelsError tryLevelsOwned(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    Levels settings,
    scope RasterView!ubyte selection,
    bool hasSelection,
    size_t maxResultBytes,
    ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    // All ordinary structural/semantic errors are classified without
    // allocating. An invalid source, ROI, gamma or mask cannot provoke an
    // unnecessary or huge output allocation first.
    const preflight = validateLevels!T(
        pixels, roi, affected, settings, selection, hasSelection);
    if (preflight != LevelsError.none)
        return preflight;

    const bands = pixels.planeCount;

    // Independently bound requested payload and signed raster strides.
    // After successful ROI validation, neither dimension can be zero.
    if (roi.width > size_t.max / roi.height)
        return LevelsError.allocationFailure;
    const count = roi.width * roi.height;
    if (bands > size_t.max / count / float.sizeof)
        return LevelsError.allocationFailure;
    const bytes = count * bands * float.sizeof;
    if (bytes > cast(size_t)ptrdiff_t.max)
        return LevelsError.allocationFailure;
    // Enforce the consumer's result payload budget before malloc or
    // allocating any plane-descriptor metadata.
    if (bytes > maxResultBytes)
        return LevelsError.resultExceedsBudget;

    OwnedByteResource owned;
    if (!tryCreateOwnedMallocBytes(bytes, owned))
        return LevelsError.allocationFailure;

    auto layouts = new PlaneByteLayout[](bands);
    foreach (c; 0 .. bands)
        layouts[c] = PlaneByteLayout(
            c * float.sizeof,
            cast(ptrdiff_t)(roi.width * bands * float.sizeof),
            cast(ptrdiff_t)(bands * float.sizeof));

    RasterLease!float temporary;
    const imported = tryImportOwnedRaster!float(
        owned, layouts[], Region2D(0, 0, roi.width, roi.height), temporary);
    if (!imported.ok)
        return LevelsError.allocationFailure;

    bool writable;
    scope auto output = temporary.tryWritableView(writable);
    if (!writable)
        return LevelsError.allocationFailure;

    const status = executeLevelsInto!T(
        pixels, roi, affected, settings, selection, hasSelection, output);
    if (status != LevelsError.none)
        return status;

    // The old owner is replaced ONLY after the entire operation succeeds.
    published = temporary;
    return LevelsError.none;
}
 
/++
 Create one independently owned ROI-local Levels result without an edit mask.

 Each selected finite input channel is transformed by
 `t = clamp((v-inputBlack)/(inputWhite-inputBlack), 0, 1)`
 and `outputBlack + pow(t, 1/gamma)*(outputWhite-outputBlack)`.
 Unselected channels are copied as normalized float samples; float
 NaN and infinities pass through unchanged. ubyte/ushort inputs are
 normalized by 255/65535. Alpha is never inferred or protected
 automatically; callers must leave its channel unselected when needed.
 No colour transfer or NoData handling occurs.

 This candidate is `@safe` through an audited, private, minimal
 `@trusted` malloc/resource-adoption boundary. The public overload
 accepts only raster-d borrowed, validated sample views and publishes
 a new raster-d-owned lease; no raw storage address is exposed. The
 `@safe` attribute is a compiler-checked source contract, not a
 `nothrow` or `@nogc` promise. Fatal OOM/Error unwind is not
 guaranteed. Neither borrower nor output may be concurrently mutated.

 The output is an interleaved `RasterLease!float`, sized exactly to the ROI,
 with the same channel count as the input. Source and mask (if any) are borrowed;
 `published` is replaced only after full success. Previously published
 ownership is unchanged on **returned** failures, including late sample
 failures; no guarantee is made for exceptions or OOM Errors.

 `maxResultBytes` caps **only new pixel payload**, exactly
 ROI width * height * channel count * float.sizeof; it does not cover
 source, prior output, metadata, allocator/GC overhead or app I/O.
 Size/stride overflow is checked before output allocation. The operation
 may allocate and throw; no `@nogc` or `nothrow` claim is made.
 Complexity: O(ROI pixels * input channels), O(ROI pixels * channels)
 new owned float payload plus descriptor metadata.

 Params:
     pixels = Borrowed source view, `ubyte`, `ushort` or `float`.
     roi = Nonempty source-local region fully inside the source.
     affected = One Boolean per source channel; true applies Levels.
     settings = Finite Levels settings; `Levels.init` is invalid.
     maxResultBytes = Maximum new float output pixel payload, in bytes.
     published = Existing or empty `RasterLease!float`, replaced only on
                 successful completion. Must remain live throughout the call.

 Returns:
     `LevelsError.none` on success. Structural/parameter/ROI errors and a
     too-small budget are classified before allocation; allocation/import
     failure returns `allocationFailure` when it is returned normally.
     No status implies success except `none`. In particular,
     `LevelsError.init == LevelsError.notAttempted` is NOT a success.

 Examples:
 ---
 import core.stdc.stdlib : malloc;
 import raster : OwnedByteResource, PlaneByteLayout, RasterLease,
                 Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
 auto memory = cast(ubyte*)malloc(1);
 assert(memory !is null);
 OwnedByteResource backing;
 assert(tryAdoptMallocResource(memory, 1, backing));
 PlaneByteLayout[] layout = [PlaneByteLayout(0, 1, 1)];
 RasterLease!ubyte input;
 assert(tryImportOwnedRaster!ubyte(
     backing, layout, Region2D(0, 0, 1, 1), input).ok);
 bool writable;
 {
     scope auto writer = input.tryWritableView(writable);
     assert(writable && writer.trySetSample(0, 0, 0, 128));
 }
 bool[1] chosen = [true];
 RasterLease!float output;
 auto status = tryLevelsOwned!ubyte(
     input.view(), Region2D(0, 0, 1, 1), chosen[],
     Levels(0, 1, 1, 0, 1), float.sizeof, output);
 assert(status == LevelsError.none);
 scope auto view = output.view();
 float result;
 assert(view.trySample(0, 0, 0, result));
 assert(result > 0.501f && result < 0.503f);
 ---
+/
LevelsError tryLevelsOwned(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    Levels settings,
    size_t maxResultBytes,
    ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    return tryLevelsOwned!T(
        pixels, roi, affected, settings, RasterView!ubyte.init,
        false, maxResultBytes, published);
}

/++
 Apply the same owned scalar Levels operation with a graded edit mask.

 The `selection` view must be one-plane `RasterView!ubyte` with the
 **full source dimensions**. Every byte defines weight `mask/255.0`
 and the result is `original + weight * (adjusted-original)`.
 A zero weight copies the input unchanged (normalized for integers).
 A `RasterView!ubyte.init` mask is rejected as `invalidMask` before
 output allocation. This is an editing-selection mask, not validity,
 NoData, opacity or an alpha-association rule.

 Params:
     pixels = Borrowed input source view of `ubyte`, `ushort` or `float`.
     roi = Nonempty source-local region.
     affected = One Boolean per input channel.
     settings = Valid finite Levels parameters.
     selection = Explicit single-plane, full-source-sized byte edit mask.
     maxResultBytes = Maximum new result float pixel payload in bytes.
     published = Live previous/empty output owner; replaced only on success.

 Returns:
     `LevelsError.none` on success; other returned errors preserve
     `published`. Same ownership, resource, nonfinite and exception
     limitations as the unmasked overload.
+/
LevelsError tryLevelsOwned(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    Levels settings,
    scope RasterView!ubyte selection,
    size_t maxResultBytes,
    ref RasterLease!float published)
@safe
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    return tryLevelsOwned!T(
        pixels, roi, affected, settings, selection,
        true, maxResultBytes, published);
}


// Executable copy of the unmasked Ddoc consumer example above. The larger
// independent DUB consumer covers layouts, masks, source types and ROI laws.
unittest
{
    auto memory = cast(ubyte*)malloc(1);
    assert(memory !is null);
    OwnedByteResource backing;
    assert(tryAdoptMallocResource(memory, 1, backing));
    PlaneByteLayout[] layout = [PlaneByteLayout(0, 1, 1)];
    RasterLease!ubyte input;
    assert(tryImportOwnedRaster!ubyte(
        backing, layout, Region2D(0, 0, 1, 1), input).ok);
    bool writable;
    {
        scope auto writer = input.tryWritableView(writable);
        assert(writable && writer.trySetSample(0, 0, 0, 128));
    }
    bool[1] chosen = [true];
    RasterLease!float output;
    auto status = tryLevelsOwned!ubyte(
        input.view(), Region2D(0, 0, 1, 1), chosen[],
        Levels(0, 1, 1, 0, 1), float.sizeof, output);
    assert(status == LevelsError.none);
    scope auto view = output.view();
    float result;
    assert(view.trySample(0, 0, 0, result));
    assert(result > 0.501f && result < 0.503f);
}
