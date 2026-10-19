/++
 Research-only, owned-result boundary for a single image Levels operation.

 The caller borrows source pixels and optional editing selection. This function
 constructs a fresh raster-d-owned float result and publishes it only when the
 existing Levels kernel has finished successfully. It does not create a second
 pixel algorithm, codec, metadata hierarchy or raster ownership implementation.

 The code is a M3 admission probe, NOT an admitted public imagery-d API.
+/
module imagery.presentation.levels_owned_research;

import core.stdc.stdlib : malloc, free;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import imagery.presentation.levels_research :
    ResearchLevels, ResearchLevelsError, tryLevelsIntoResearch,
    validateLevelsResearch;

/++
 Produce one independently owned, ROI-sized three-or-N-channel float Levels
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
ResearchLevelsError tryLevelsOwnedResearch(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    ResearchLevels settings,
    scope RasterView!ubyte selection,
    bool hasSelection,
    size_t maxResultBytes,
    ref RasterLease!float published)
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    // All ordinary structural/semantic errors are classified without
    // allocating. An invalid source, ROI, gamma or mask cannot provoke an
    // unnecessary or huge output allocation first.
    const preflight = validateLevelsResearch!T(
        pixels, roi, affected, settings, selection, hasSelection);
    if (preflight != ResearchLevelsError.none)
        return preflight;

    const bands = pixels.planeCount;

    // Independently bound requested payload and signed raster strides.
    // After successful ROI validation, neither dimension can be zero.
    if (roi.width > size_t.max / roi.height)
        return ResearchLevelsError.allocationFailure;
    const count = roi.width * roi.height;
    if (bands > size_t.max / count / float.sizeof)
        return ResearchLevelsError.allocationFailure;
    const bytes = count * bands * float.sizeof;
    if (bytes > cast(size_t)ptrdiff_t.max)
        return ResearchLevelsError.allocationFailure;
    // Enforce the consumer's result payload budget before malloc or
    // allocating any plane-descriptor metadata.
    if (bytes > maxResultBytes)
        return ResearchLevelsError.resultExceedsBudget;

    auto memory = malloc(bytes);
    if (memory is null)
        return ResearchLevelsError.allocationFailure;

    OwnedByteResource owned;
    if (!tryAdoptMallocResource(memory, bytes, owned))
    {
        free(memory);
        return ResearchLevelsError.allocationFailure;
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
        return ResearchLevelsError.allocationFailure;

    bool writable;
    scope auto output = temporary.tryWritableView(writable);
    if (!writable)
        return ResearchLevelsError.allocationFailure;

    const status = tryLevelsIntoResearch!T(
        pixels, roi, affected, settings, selection, hasSelection, output);
    if (status != ResearchLevelsError.none)
        return status;

    // The old owner is replaced ONLY after the entire operation succeeds.
    published = temporary;
    return ResearchLevelsError.none;
}
 
/++
 Research admission probe: no selection mask.
 The absence of a mask is structural; callers do not pass an invalid
 RasterView plus a separate Boolean. The legacy eight-argument research
 signature above is retained for existing evidence and is not proposed as
 a public production signature. Result ownership and payload-budget
 semantics are identical in both forms.
+/
ResearchLevelsError tryLevelsOwnedResearch(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    ResearchLevels settings,
    size_t maxResultBytes,
    ref RasterLease!float published)
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    return tryLevelsOwnedResearch!T(
        pixels, roi, affected, settings, RasterView!ubyte.init,
        false, maxResultBytes, published);
}

/++
 Research admission probe: explicit weighted editing-selection mask.
 The supplied one-plane byte mask must match the entire source's
 dimensions; .init is rejected as invalidMask before allocation.
 This is not a validity/NoData mask and does not specify alpha.
+/
ResearchLevelsError tryLevelsOwnedResearch(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    ResearchLevels settings,
    scope RasterView!ubyte selection,
    size_t maxResultBytes,
    ref RasterLease!float published)
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    return tryLevelsOwnedResearch!T(
        pixels, roi, affected, settings, selection,
        true, maxResultBytes, published);
}
