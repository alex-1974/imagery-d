/++
 General image scalar Levels over borrowed raster views.

 Only already materialized image channels are processed. Ownership, region,
 pixel layout, size and signed strides belong to raster-d; this module does
 not own codecs, image metadata, a scheduler or colour-management machinery.

 The two public overloads differ only by whether an editing-selection mask
 is explicitly supplied. This package is a M3 **qualification candidate**
 on an unmerged branch, NOT an accepted released API.
+/
module imagery.presentation.levels;

import core.stdc.stdlib : malloc, free;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, WritableRasterView, tryAdoptMallocResource,
    tryImportOwnedRaster;
import std.math : pow;

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

 `.init` is `none`; callers MUST inspect the returned status, not
 infer success from the current value of their destination owner.
 `resultExceedsBudget` means the new float pixel payload alone would
 exceed the caller limit. `allocationFailure` includes detected
 length/stride overflow, malloc failure or failed raster import.
 Ordinary runtime allocation exceptions and OOM errors are not caught.
+/
enum LevelsError : ubyte
{
    none,
    invalidSource,
    invalidRegion,
    invalidParameters,
    invalidChannelSelection,
    invalidMask,
    invalidDestination,
    sampleFailure,
    allocationFailure,
    resultExceedsBudget
}

private bool finite(double x)
{
    return x >= -double.max && x <= double.max;
}

private bool contains(Region2D roi, size_t width, size_t height)
{
    return roi.width != 0 && roi.height != 0 &&
        roi.x <= width && roi.y <= height &&
        roi.width <= width - roi.x &&
        roi.height <= height - roi.y;
}

private double normalized(T)(T sample)
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    static if (is(T == ubyte))
        return cast(double)sample / 255.0;
    else static if (is(T == ushort))
        return cast(double)sample / 65535.0;
    else
        return cast(double)sample;
}

/++
 Shared semantic preflight for both the existing Into research kernel and the
 separately owned result producer. No pixel writes, allocations or side effects.

 Diagnostic ordering remains the established Into order: source, ROI,
 selected channels, parameters, then optional selection-mask shape.
+/
private LevelsError validateLevels(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    Levels settings,
    scope RasterView!ubyte selection,
    bool hasSelection)
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
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    const preflight = validateLevels!T(
        pixels, roi, affected, settings, selection, hasSelection);
    if (preflight != LevelsError.none)
        return preflight;

    if (destination.planeCount != pixels.planeCount ||
        destination.width != roi.width ||
        destination.height != roi.height)
        return LevelsError.invalidDestination;

    const span = settings.inputWhite - settings.inputBlack;
    const inverseGamma = 1.0 / settings.gamma;
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
                double t = (original - settings.inputBlack) / span;
                if (t < 0.0) t = 0.0;
                if (t > 1.0) t = 1.0;
                const mapped = settings.outputBlack +
                    pow(t, inverseGamma) * outputSpan;
                result = original + strength * (mapped - original);
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

 This prototype can allocate and throw on ordinary runtime allocation failure;
 it is not promised @safe, @nogc or nothrow. A returned allocationFailure
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

    auto memory = malloc(bytes);
    if (memory is null)
        return LevelsError.allocationFailure;

    OwnedByteResource owned;
    if (!tryAdoptMallocResource(memory, bytes, owned))
    {
        free(memory);
        return LevelsError.allocationFailure;
    }

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
 Qualification candidate: no selection mask.
 The absence of a mask is structural; callers do not pass an invalid
 RasterView plus a separate Boolean. The internal eight-argument
 signature above is private and is not proposed as
 a public production signature. Result ownership and payload-budget
 semantics are identical in both forms.
+/
LevelsError tryLevelsOwned(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    Levels settings,
    size_t maxResultBytes,
    ref RasterLease!float published)
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    return tryLevelsOwned!T(
        pixels, roi, affected, settings, RasterView!ubyte.init,
        false, maxResultBytes, published);
}

/++
 Qualification candidate: explicit weighted editing-selection mask.
 The supplied one-plane byte mask must match the entire source's
 dimensions; .init is rejected as invalidMask before allocation.
 This is not a validity/NoData mask and does not specify alpha.
+/
LevelsError tryLevelsOwned(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    Levels settings,
    scope RasterView!ubyte selection,
    size_t maxResultBytes,
    ref RasterLease!float published)
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    return tryLevelsOwned!T(
        pixels, roi, affected, settings, selection,
        true, maxResultBytes, published);
}
