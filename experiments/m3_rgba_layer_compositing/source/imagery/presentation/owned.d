/++
 Research-only candidate-B seam, compiled as part of the INDEPENDENT M3 DUB
 experiment, NOT as an admitted imagery-d production module.

 This intentionally does not own a cache, accounting ledger, backing refcount,
 general allocator, scheduler, source or cancel token. It only adapts the
 already-qualified color math to a newly owned packed SRgba8 result.

 Errors in *image semantics* return RgbaCompositeError. Native pixel malloc,
 adoption and raster import failures currently throw Exception; arbitrary
 druntime Error-level OOM is NOT promised recoverable. Public API names,
 error representation and allocation policy have NOT been accepted.
+/
module imagery.presentation.owned;

import core.stdc.stdlib : malloc, free;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import color : SRgba8;
import imagery.presentation.composite :
    DecodedRgbaLayer, ResearchPreparedRgbaContext, RgbaCompositeError,
    tryPreflightRgbaSourceOverPrepared,
    tryCompositeRgbaSourceOverPreparedStagedChecked;

/// Checked pixel-request sizes for the current two-buffer research producer.
/// The bound is not a physical RSS, allocator/GC metadata or quota guarantee.
private bool checkedRgbaBytes(Region2D roi, out size_t bytes)
@safe pure nothrow @nogc
{
    bytes = 0;
    if (roi.width == 0 || roi.height == 0 ||
        roi.width > cast(size_t)ptrdiff_t.max / 4 ||
        roi.height > size_t.max / 4 ||
        roi.width > size_t.max / (roi.height * 4))
        return false;
    bytes = 4 * roi.width * roi.height;
    return true;
}

// Resource adoption transfers ownership exactly once. Failed import is
// delegated to raster-d's OWNED resource disposition: 'unchanged' leaves
// token release to its destructor; 'releasedAfterCommit' must NOT be freed
// again here. Neither helper creates its own raster backing owner.
private RasterLease!ubyte newPrivateScratch(
    size_t width, size_t height, size_t bytes)
{
    auto raw = cast(ubyte*)malloc(bytes);
    if (raw is null)
        throw new Exception("M3 owned research scratch malloc failed");
    OwnedByteResource owned;
    if (!tryAdoptMallocResource(raw, bytes, owned))
    {
        free(raw);
        throw new Exception("M3 owned research scratch adoption failed");
    }
    PlaneByteLayout[4] planes;
    foreach (channel; 0 .. 4)
        planes[channel] = PlaneByteLayout(
            channel, cast(ptrdiff_t)(width * 4), 4);
    RasterLease!ubyte lease;
    const result = tryImportOwnedRaster!ubyte(
        owned, planes[], Region2D(0, 0, width, height), lease);
    if (!result.ok)
        throw new Exception("M3 owned research scratch import failed");
    return lease;
}

private RasterLease!SRgba8 newPrivatePacked(
    size_t width, size_t height, size_t bytes)
{
    auto raw = cast(ubyte*)malloc(bytes);
    if (raw is null)
        throw new Exception("M3 owned research packed malloc failed");
    OwnedByteResource owned;
    if (!tryAdoptMallocResource(raw, bytes, owned))
    {
        free(raw);
        throw new Exception("M3 owned research packed adoption failed");
    }
    const PlaneByteLayout[1] plane =
        [PlaneByteLayout(0, cast(ptrdiff_t)(width * 4), 4)];
    RasterLease!SRgba8 lease;
    const result = tryImportOwnedRaster!SRgba8(
        owned, plane[], Region2D(0, 0, width, height), lease);
    if (!result.ok)
        throw new Exception("M3 owned research packed import failed");
    return lease;
}

/++
 Create a wholly new, complete packed RGBA result for one synchronous ROI.

 This is a SEPARATELY COMPILED RESEARCH ADMISSION PROBE, not approved public
 imagery-d API. The caller must retain both source owners throughout the
 call and must not concurrently mutate the sources. Views are borrowed for
 this call only. Both sources may share one backing because the result owns
 fresh separate storage.

 Output is straight encoded sRGB, alpha-zero RGB canonicalized to black.
 The caller's 'published' RasterLease must be empty; if nonempty, return
 invalidOutput WITHOUT changing it. Do not change this parameter to 'out':
 D would reset a still-live prior owner before the body can reject it.

 A full input/PM preflight happens BEFORE either native pixel malloc.
 The staged emitter checks PM bytes again at the actual point of use, in
 one of four compile-time-specialized loops; a later failure may mutate
 PRIVATE scratch but no result is published. The packing output is not
 published until it is fully written. Ordinary copied raster leases still
 follow raster-d's existing non-atomic lifetime contract.

 Requested ROI pixel memory: 4N scratch + 4N packed = 8N peak,
 4N retained. This is NOT an admission reservation or peak RSS bound.
 Image semantic failures are classified. malloc/adoption/import failures
 may throw Exception; Error-class metadata OOM is not promised recoverable.
+/
RgbaCompositeError tryCompositeOwnedRgbaResearch(
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper,
    scope DecodedRgbaLayer lower,
    Region2D roi,
    ref RasterLease!SRgba8 published)
{
    // Required before any overwrite of a possibly live result owner.
    if (published.view().planeCount != 0)
        return RgbaCompositeError.invalidOutput;

    size_t bytes;
    if (!checkedRgbaBytes(roi, bytes))
        return RgbaCompositeError.invalidRegion;

    const status = tryPreflightRgbaSourceOverPrepared(
        prepared, upper, lower, roi);
    if (status != RgbaCompositeError.none)
        return status;

    auto scratch = newPrivateScratch(roi.width, roi.height, bytes);
    {
        bool writable;
        scope auto writer = scratch.tryWritableView(writable);
        if (!writable)
            return RgbaCompositeError.invalidOutput;
        const composed = tryCompositeRgbaSourceOverPreparedStagedChecked(
            prepared, upper, lower, roi, writer);
        if (composed != RgbaCompositeError.none)
            return composed;
    }

    auto packed = newPrivatePacked(roi.width, roi.height, bytes);
    {
        scope auto source = scratch.view();
        bool writable;
        scope auto target = packed.tryWritableView(writable);
        if (!writable)
            return RgbaCompositeError.invalidOutput;
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        {
            ubyte[4] rgba;
            foreach (band; 0 .. 4)
                if (!source.trySample(band, x, y, rgba[band]))
                    return RgbaCompositeError.sampleFailure;
            if (!target.trySetSample(0, x, y,
                    SRgba8(rgba[0], rgba[1], rgba[2], rgba[3])))
                return RgbaCompositeError.sampleFailure;
        }
    }
    // Publication is the ONE and ONLY externally visible state transition.
    // scratch and local packed owner destructors use raster-d RAII.
    published = packed;
    return RgbaCompositeError.none;
}
