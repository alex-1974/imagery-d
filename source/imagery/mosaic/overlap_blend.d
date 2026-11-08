/++ Explicit linear-light RGB8 overlap blending. +/
module imagery.mosaic.overlap_blend;

import color : LinearSRgbd, SRgb8, makeSRgb8DecodeTable, toSRgb,
    tryToSRgb8;
import core.stdc.stdlib : free, malloc;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

enum OverlapBlendError : ubyte
{
    notAttempted, none, invalidSource, invalidWeights, invalidRegion,
    resultExceedsBudget, allocationFailure, sampleFailure
}

private bool allocate(size_t bytes, out OwnedByteResource owner) @trusted
{
    auto memory = malloc(bytes);
    if (memory is null || !tryAdoptMallocResource(memory, bytes, owner))
    {
        if (memory !is null) free(memory);
        return false;
    }
    return true;
}

/** Blend two aligned encoded-sRGB RGB8 views using an explicit u8 weight map. */
OverlapBlendError tryBlendLinearSrgbOverlapOwned(
    scope RasterView!ubyte sourceA, scope RasterView!ubyte sourceB,
    scope RasterView!ubyte weights, Region2D roi, size_t maxResultBytes,
    ref RasterLease!ubyte published)
@safe
{
    if (sourceA.planeCount != 3 || sourceB.planeCount != 3 ||
        sourceA.width == 0 || sourceA.height == 0 ||
        sourceB.width != sourceA.width || sourceB.height != sourceA.height)
        return OverlapBlendError.invalidSource;
    if (weights.planeCount != 1 || weights.width != sourceA.width ||
        weights.height != sourceA.height)
        return OverlapBlendError.invalidWeights;
    if (roi.width == 0 || roi.height == 0 || roi.x > sourceA.width ||
        roi.y > sourceA.height || roi.width > sourceA.width - roi.x ||
        roi.height > sourceA.height - roi.y)
        return OverlapBlendError.invalidRegion;
    if (roi.width > size_t.max / roi.height)
        return OverlapBlendError.allocationFailure;
    const pixels = roi.width * roi.height;
    if (pixels > size_t.max / 3) return OverlapBlendError.allocationFailure;
    const bytes = pixels * 3;
    if (bytes > maxResultBytes) return OverlapBlendError.resultExceedsBudget;
    if (bytes > cast(size_t)ptrdiff_t.max ||
        roi.width > cast(size_t)ptrdiff_t.max / 3)
        return OverlapBlendError.allocationFailure;

    OwnedByteResource resource;
    if (!allocate(bytes, resource)) return OverlapBlendError.allocationFailure;
    PlaneByteLayout[3] layouts;
    foreach (component; 0 .. 3)
        layouts[component] = PlaneByteLayout(component,
            cast(ptrdiff_t)(roi.width * 3), 3);
    RasterLease!ubyte temporary;
    if (!tryImportOwnedRaster!ubyte(resource, layouts[],
        Region2D(0, 0, roi.width, roi.height), temporary).ok)
        return OverlapBlendError.allocationFailure;
    bool writable;
    scope auto output = temporary.tryWritableView(writable);
    if (!writable) return OverlapBlendError.allocationFailure;

    const decode = makeSRgb8DecodeTable!double();
    foreach (dy; 0 .. roi.height)
    foreach (dx; 0 .. roi.width)
    {
        ubyte weight;
        ubyte[3] a, b;
        if (!weights.trySample(0, roi.x + dx, roi.y + dy, weight))
            return OverlapBlendError.sampleFailure;
        foreach (component; 0 .. 3)
            if (!sourceA.trySample(component, roi.x + dx, roi.y + dy,
                    a[component]) ||
                !sourceB.trySample(component, roi.x + dx, roi.y + dy,
                    b[component]))
                return OverlapBlendError.sampleFailure;
        const factor = cast(double)weight / 255.0;
        const linear = LinearSRgbd(
            decode[a[0]] * (1.0 - factor) + decode[b[0]] * factor,
            decode[a[1]] * (1.0 - factor) + decode[b[1]] * factor,
            decode[a[2]] * (1.0 - factor) + decode[b[2]] * factor);
        SRgb8 encoded;
        if (!tryToSRgb8(linear.toSRgb, encoded) ||
            !output.trySetSample(0, dx, dy, encoded.r) ||
            !output.trySetSample(1, dx, dy, encoded.g) ||
            !output.trySetSample(2, dx, dy, encoded.b))
            return OverlapBlendError.sampleFailure;
    }
    published = temporary;
    return OverlapBlendError.none;
}
