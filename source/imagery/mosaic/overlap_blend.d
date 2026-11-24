/++ Explicit linear-light RGB8 overlap blending. +/
module imagery.mosaic.overlap_blend;

import color : LinearSRgbd, SRgb8, makeSRgb8Decoder, toSRgb,
    tryToSRgb8;
import core.stdc.stdlib : free, malloc;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

/++
 Report weighted overlap-blend status. `.init` is notAttempted; none denotes a completed result.
+/
enum OverlapBlendError : ubyte
{
    /++ No operation has completed; this is the default sentinel. +/
    notAttempted,
    /++ The operation completed successfully. +/
    none,
    /++ Source shape, identity or sample descriptor is invalid. +/
    invalidSource,
    /++ Blend weights are invalid or cannot define the requested combination. +/
    invalidWeights,
    /++ The requested pixel rectangle is empty or outside the source extent. +/
    invalidRegion,
    /++ Required retained output storage exceeds the caller’s budget. +/
    resultExceedsBudget,
    /++ Storage allocation or owned-raster construction failed. +/
    allocationFailure,
    /++ A raster sample could not be read or written. +/
    sampleFailure
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

/++
 Blend two aligned encoded-sRGB RGB8 views using an explicit u8 weight map.

 Params:
  sourceA = First borrowed source raster.
  sourceB = Second borrowed source raster with matching dimensions.
  weights = Explicit per-source or per-sample weights as described by the blend contract.
  roi = Nonempty half-open source-pixel rectangle, fully contained in the input.
  maxResultBytes = Maximum requested retained output pixel/payload bytes, excluding allocator overhead unless stated above.
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
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

    const decode = makeSRgb8Decoder!double();
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

/// Blend two views with explicit source weights.
@system unittest
{
    import core.stdc.stdlib : malloc;
    import raster : OwnedByteResource,PlaneByteLayout,RasterLease,Region2D,
        tryAdoptMallocResource,tryImportOwnedRaster;
    auto memory=cast(ubyte*)malloc(3);
    assert(memory !is null);
    memory[0]=0; memory[1]=127; memory[2]=255;
    OwnedByteResource owner;
    assert(tryAdoptMallocResource(memory,3,owner));
    PlaneByteLayout[3] layouts;
    foreach(c;0..3) layouts[c]=PlaneByteLayout(c,3,3);
    RasterLease!ubyte input;
    assert(tryImportOwnedRaster!ubyte(owner,layouts[],Region2D(0,0,1,1),input).ok);
    auto weightMemory=cast(ubyte*)malloc(1);
    assert(weightMemory !is null);
    weightMemory[0]=128;
    OwnedByteResource weightOwner;
    assert(tryAdoptMallocResource(weightMemory,1,weightOwner));
    PlaneByteLayout[1] weightLayout=[PlaneByteLayout(0,1,1)];
    RasterLease!ubyte weights;
    assert(tryImportOwnedRaster!ubyte(weightOwner,weightLayout[],Region2D(0,0,1,1),weights).ok);
    RasterLease!ubyte result;
    assert(tryBlendLinearSrgbOverlapOwned(input.view,input.view,weights.view,
        Region2D(0,0,1,1),3,result)==OverlapBlendError.none);
    ubyte blue;
    assert(result.view.trySample(2,0,0,blue) && blue==255);
}
