/++
 Percentile contrast stretch by relative luminance for decoded RGB8 images.

 The image-domain operation uses color-d's sRGB and XYZ-D65 transfer
 definitions with float arithmetic. RGB8 decoding uses color-d's exact
 reusable byte table; the encoded-sRGB output curve is sampled through
 color-d and linearly interpolated. raster-d scoped data-plane windows execute
 the two pixel passes without per-sample accessor checks. Its 65,536-bin
 histogram is a uniform quantization of XYZ-D65 Y over [0,1]. An optional
 binary mask selects samples for estimating percentile bounds only; every
 pixel in the ROI receives the transform. The compile-time `Clip` argument
 chooses hard linear-sRGB clipping or fail-on-out-of-gamut behavior without a
 runtime policy branch.
+/
module imagery.presentation.luminance_stretch;

import core.stdc.stdlib : malloc, free, calloc;
import core.atomic : MemoryOrder, atomicFetchAdd, atomicLoad, atomicStore;
version (LDC) import core.simd : Vector;
import color.rgb : LinearSRgb, SRgb8DecodeTable, makeSRgb8DecodeTable,
    toSRgb;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    RasterPlaneWindow, WritableRasterPlaneWindow, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster, withPlane,
    withViewsParallelPhases, withPlanesIntoParallel, ParallelRowsResult,
    ParallelRowsOperation;

version (LDC) version = UseVectorKernel;

/// Fixed number of uniform bins covering relative XYZ-D65 Y in [0,1].
enum size_t luminanceStretchBinCount = 65_536;

/// Samples used to interpolate the bounded linear-light sRGB encoding curve.
/// The cache/throughput optimum differs between the supported backends.
version (LDC) private enum size_t srgbEncodeIntervals = 1_024;
else private enum size_t srgbEncodeIntervals = 4_096;

/// Result of RGB luminance percentile stretching.
enum LuminanceStretchError : ubyte
{
    /// Default state; never returned as success.
    notAttempted,
    /// Complete output was published.
    none,
    /// Source is invalid or does not have exactly three RGB planes.
    invalidSource,
    /// ROI is empty or outside the source.
    invalidRegion,
    /// Percentiles must satisfy 0 <= lower < upper <= 100.
    invalidPercentiles,
    /// Optional mask must be a one-plane byte view matching the source size.
    invalidMask,
    /// Source, mask, or destination sample access failed.
    sampleFailure,
    /// Checked size, allocation, adoption or raster import failed.
    allocationFailure,
    /// New float payload exceeds the supplied byte budget.
    resultExceedsBudget,
    /// A transformed value is outside sRGB and Clip was false.
    outOfGamut
}

private bool inside(Region2D roi, size_t width, size_t height)
@safe pure nothrow @nogc
{
    return roi.width != 0 && roi.height != 0 && roi.x <= width &&
        roi.y <= height && roi.width <= width - roi.x &&
        roi.height <= height - roi.y;
}

private bool validSource(RasterView!ubyte pixels)
@safe pure nothrow @nogc
{
    return pixels.width != 0 && pixels.height != 0 &&
        pixels.planeCount == 3;
}

// Keep this conversion in a template body: color-d exposes generic conversion
// functions, whose instances must be emitted by the final consumer module.
private ushort yBinFromLuminance(T)(T y)
@safe pure nothrow @nogc
{
    if (!(y > 0.0))
        return 0;
    if (y >= 1.0)
        return ushort.max;
    return cast(ushort)(y * luminanceStretchBinCount);
}

private ushort yBin(T)(T r, T g, T b)
@safe pure nothrow @nogc
{
    return yBinFromLuminance(relativeLuminance(r, g, b));
}

// Exact XYZ-D65 Y row for linear sRGB. Keeping the scalar hot path as three
// multiply-adds avoids constructing/converting a full color value when only
// luminance is required. The coefficients match color-d's XYZ-D65 matrix.
private T relativeLuminance(T)(T r, T g, T b)
@safe pure nothrow @nogc
{
    enum yr = cast(T)87098 / 409605;
    enum yg = cast(T)175762 / 245763;
    enum yb = cast(T)12673 / 175545;
    return yr * r + yg * g + yb * b;
}

private float encodeSrgbFromTable(
    scope const(float)[] table, float linear)
@safe pure nothrow @nogc
{
    if (!(linear > 0.0f))
        return table[0];
    if (linear >= 1.0f)
        return table[$ - 1];
    const scaled = linear * cast(float)srgbEncodeIntervals;
    const index = cast(size_t)scaled;
    const fraction = scaled - cast(float)index;
    const lower = table[index];
    return lower + fraction * (table[index + 1] - lower);
}

version (LDC)
private struct TransformGroup4
{
    float[12] encodedRgb;
    bool outOfGamut;
}

version (LDC)
// LDC otherwise retains a call for every four-pixel group. DMD's generated
// code is unaffected; the measured gain applies to LDC Release on x86-64.
pragma(inline, true)
private TransformGroup4 transformFourPixels(bool Clip)(
    scope const(ubyte[12]) encodedRgb,
    scope const(SRgb8DecodeTable!float) decode,
    scope const(float)[] encode,
    size_t lowerBin,
    size_t upperBin,
    float inverseThresholdRange)
@trusted pure nothrow @nogc
{
    alias F4 = Vector!(float[4]);
    float[4] red, green, blue;
    foreach (lane; 0 .. 4)
    {
        red[lane] = decode[encodedRgb[lane * 3]];
        green[lane] = decode[encodedRgb[lane * 3 + 1]];
        blue[lane] = decode[encodedRgb[lane * 3 + 2]];
    }

    F4 r, g, b;
    foreach (lane; 0 .. 4)
    {
        r[lane] = red[lane];
        g[lane] = green[lane];
        b[lane] = blue[lane];
    }
    const yr = F4([cast(float)87098 / 409605, cast(float)87098 / 409605,
        cast(float)87098 / 409605, cast(float)87098 / 409605]);
    const yg = F4([cast(float)175762 / 245763, cast(float)175762 / 245763,
        cast(float)175762 / 245763, cast(float)175762 / 245763]);
    const yb = F4([cast(float)12673 / 175545, cast(float)12673 / 175545,
        cast(float)12673 / 175545, cast(float)12673 / 175545]);
    const luminance = yr * r + yg * g + yb * b;
    float[4] yValues, mappedValues, safeYValues;
    foreach (lane; 0 .. 4)
        yValues[lane] = luminance[lane];
    foreach (lane; 0 .. 4)
    {
        const y = yValues[lane];
        safeYValues[lane] = y > 0.0f ? y : 1.0f;
        const bin = y <= 0.0f ? 0 : y >= 1.0f ? 65_535 :
            cast(size_t)(y * luminanceStretchBinCount);
        if (upperBin == lowerBin)
            mappedValues[lane] = y;
        else if (bin <= lowerBin)
            mappedValues[lane] = 0.0f;
        else if (bin >= upperBin)
            mappedValues[lane] = 1.0f;
        else
            mappedValues[lane] = cast(float)(bin - lowerBin) *
                inverseThresholdRange;
    }

    F4 mapped, safeY;
    foreach (lane; 0 .. 4)
    {
        mapped[lane] = mappedValues[lane];
        safeY[lane] = safeYValues[lane];
    }
    const scale = mapped / safeY;
    float[4] scaledR, scaledG, scaledB;
    const resultR = r * scale;
    const resultG = g * scale;
    const resultB = b * scale;
    foreach (lane; 0 .. 4)
    {
        scaledR[lane] = resultR[lane];
        scaledG[lane] = resultG[lane];
        scaledB[lane] = resultB[lane];
    }

    TransformGroup4 result;
    foreach (lane; 0 .. 4)
    {
        float rr = scaledR[lane];
        float gg = scaledG[lane];
        float bb = scaledB[lane];
        static if (Clip)
        {
            if (rr < 0.0f) rr = 0.0f;
            if (gg < 0.0f) gg = 0.0f;
            if (bb < 0.0f) bb = 0.0f;
            if (rr > 1.0f) rr = 1.0f;
            if (gg > 1.0f) gg = 1.0f;
            if (bb > 1.0f) bb = 1.0f;
        }
        else
        {
            if (rr < 0.0f || rr > 1.0f || gg < 0.0f || gg > 1.0f ||
                bb < 0.0f || bb > 1.0f)
            {
                result.outOfGamut = true;
                return result;
            }
        }
        result.encodedRgb[lane * 3] = encodeSrgbFromTable(encode, rr);
        result.encodedRgb[lane * 3 + 1] = encodeSrgbFromTable(encode, gg);
        result.encodedRgb[lane * 3 + 2] = encodeSrgbFromTable(encode, bb);
    }
    return result;
}

private void accumulateHistogram(T)(
    scope const(RasterPlaneWindow!ubyte) red,
    scope const(RasterPlaneWindow!ubyte) green,
    scope const(RasterPlaneWindow!ubyte) blue,
    scope const(RasterPlaneWindow!ubyte) selection,
    bool hasSelection,
    scope const(SRgb8DecodeTable!T) linearByEncodedByte,
    size_t firstRow,
    size_t endRow,
    scope ulong[] bins,
    ref ulong selectedPixels)
@trusted nothrow @nogc
{
    foreach (y; firstRow .. endRow)
    {
        const redRow = red.row(y);
        const greenRow = green.row(y);
        const blueRow = blue.row(y);
        const selectionRow = hasSelection ? selection.row(y) : red.row(y);
        // raster-d v0.5 exposes validated callback-scoped row pointers. Hoist
        // row-base and sample-stride loads out of the pixel loop; the views
        // have already validated the complete affine address ranges.
        auto redData = redRow.data;
        auto greenData = greenRow.data;
        auto blueData = blueRow.data;
        auto selectionData = selectionRow.data;
        const redStride = redRow.sampleStride;
        const greenStride = greenRow.sampleStride;
        const blueStride = blueRow.sampleStride;
        const selectionStride = selectionRow.sampleStride;
        foreach (x; 0 .. red.width)
        {
            if (hasSelection && selectionData[x * selectionStride] == 0)
                continue;
            ++bins[yBin(linearByEncodedByte[redData[x * redStride]],
                linearByEncodedByte[greenData[x * greenStride]],
                linearByEncodedByte[blueData[x * blueStride]])];
            ++selectedPixels;
        }
    }
}

private bool allocOwned(size_t bytes, ref OwnedByteResource owner)
@trusted nothrow @nogc
{
    if (bytes == 0 || owner.ownsResource)
        return false;
    void* memory = malloc(bytes);
    if (memory is null)
        return false;
    if (!tryAdoptMallocResource(memory, bytes, owner))
    {
        free(memory);
        return false;
    }
    return true;
}

private ulong[] workerHistogramSlice(ulong* storage, size_t worker)
@trusted pure nothrow @nogc
{
    const first = worker * luminanceStretchBinCount;
    return storage[first .. first + luminanceStretchBinCount];
}

private ulong* allocateWorkerHistograms(size_t count)
@trusted nothrow @nogc
{
    return cast(ulong*)calloc(count, ulong.sizeof);
}

private void freeWorkerHistograms(ulong* storage)
@trusted nothrow @nogc
{
    free(storage);
}

private LuminanceStretchError stretchImpl(bool Clip, T = double)(
    scope RasterView!ubyte pixels,
    Region2D roi,
    uint lowerPercentile,
    uint upperPercentile,
    scope RasterView!ubyte selection,
    bool hasSelection,
    size_t maxResultBytes,
    ref RasterLease!float published,
    size_t workerLimit,
    size_t minimumChunk)
@safe
{
    if (!validSource(pixels))
        return LuminanceStretchError.invalidSource;
    if (!inside(roi, pixels.width, pixels.height))
        return LuminanceStretchError.invalidRegion;
    if (lowerPercentile >= upperPercentile || upperPercentile > 100)
        return LuminanceStretchError.invalidPercentiles;
    if (hasSelection && (selection.width != pixels.width ||
            selection.height != pixels.height || selection.planeCount != 1))
        return LuminanceStretchError.invalidMask;

    // Each raster-d callback owns a private histogram and selected count.
    ulong* workerBins;
    const activeWorkerSlots = workerLimit == 0 ? 1 : workerLimit;
    auto workerSelected = new shared ulong[activeWorkerSlots];
    if (luminanceStretchBinCount > size_t.max / activeWorkerSlots)
        return LuminanceStretchError.allocationFailure;
    workerBins = allocateWorkerHistograms(
        luminanceStretchBinCount * activeWorkerSlots);
    if (workerBins is null)
        return LuminanceStretchError.allocationFailure;
    workerSelected = new ulong[activeWorkerSlots];
    scope(exit) freeWorkerHistograms(workerBins);
    // color-d provides the exact reusable 256-entry table for RGB8 input.
    const linearByEncodedByte = makeSRgb8DecodeTable!T();
    bool sourceRegionValid;
    scope auto sourceRoi = pixels.tryRoi(roi, sourceRegionValid);
    if (!sourceRegionValid)
        return LuminanceStretchError.invalidRegion;
    RasterView!ubyte selectionRoi;
    if (hasSelection)
    {
        bool selectionRegionValid;
        selectionRoi = selection.tryRoi(roi, selectionRegionValid);
        if (!selectionRegionValid)
            return LuminanceStretchError.invalidMask;
    }
    ulong selectedPixels;
    RasterView!ubyte[2] analysisViews;
    const(size_t)[][] analysisPlanes;
    RasterPlaneWindow!ubyte[][] analysisWindows;
    if (hasSelection)
    {
        analysisViews = [sourceRoi, selectionRoi];
        analysisPlanes = [[0, 1, 2], [0]];
        analysisWindows = [new RasterPlaneWindow!ubyte[3],
            new RasterPlaneWindow!ubyte[1]];
    }
    else
    {
        analysisViews = [sourceRoi, sourceRoi];
        analysisPlanes = [[0, 1, 2], [0]];
        analysisWindows = [new RasterPlaneWindow!ubyte[3],
            new RasterPlaneWindow!ubyte[1]];
    }
    // Accumulate worker-private histograms through raster-d's validated
    // multi-view phase executor. A second read-only view aliases RGB plane 0
    // when there is no selection mask.
    ulong[luminanceStretchBinCount] bins;
    const histogramReady = withViewsParallelPhases(
        analysisViews[], analysisPlanes, analysisWindows,
        workerLimit, minimumChunk,
        delegate(scope RasterPlaneWindow!ubyte[][] sources,
            scope ParallelRowsOperation operation) @safe nothrow
        {
            if (operation.forRows(
                delegate(size_t worker, size_t firstRow, size_t endRow) nothrow
                {
                    const workerSlot = worker;
                    ulong localSelected;
                    auto workerHistogram = workerHistogramSlice(workerBins, workerSlot);
                    accumulateHistogram(sources[0][0], sources[0][1],
                        sources[0][2], sources[1][0], hasSelection,
                        linearByEncodedByte, firstRow, endRow,
                        workerHistogram, localSelected);
                    atomicFetchAdd!(MemoryOrder.acq_rel)(
                        workerSelected[workerSlot], localSelected);
                    return true;
                }) != ParallelRowsResult.completed)
                return false;

            foreach (worker; 0 .. activeWorkerSlots)
                selectedPixels += atomicLoad!(MemoryOrder.acq)(
                    workerSelected[worker]);
            if (selectedPixels == 0) return false;
            foreach (worker; 0 .. activeWorkerSlots)
                foreach (bin; 0 .. luminanceStretchBinCount)
                    bins[bin] += workerHistogramSlice(workerBins, worker)[bin];
            return true;
        });
    if (!histogramReady)
        return selectedPixels == 0 ? LuminanceStretchError.invalidMask : LuminanceStretchError.sampleFailure;
    if (selectedPixels == 0)
        return LuminanceStretchError.invalidMask;
    ulong histogramTotal;
    foreach (count; bins) histogramTotal += count;
    if (histogramTotal != selectedPixels)
        return LuminanceStretchError.sampleFailure;

    const lowerRank = lowerPercentile == 0 ? 1UL :
        (selectedPixels / 100) * lowerPercentile +
        ((selectedPixels % 100) * lowerPercentile + 99) / 100;
    const upperRank = (selectedPixels / 100) * upperPercentile +
        ((selectedPixels % 100) * upperPercentile + 99) / 100;
    size_t lowerBin, upperBin;
    ulong cumulative;
    foreach (i; 0 .. luminanceStretchBinCount)
    {
        cumulative += bins[i];
        if (lowerBin == 0 && cumulative >= lowerRank)
            lowerBin = i + 1;
        if (cumulative >= upperRank)
        {
            upperBin = i;
            break;
        }
    }
    --lowerBin;
    const constantLuminance = upperBin == lowerBin;
    if (upperBin < lowerBin)
        return LuminanceStretchError.invalidPercentiles;
    const inverseThresholdRange = constantLuminance ? 0.0f :
        1.0f / cast(float)(upperBin - lowerBin);

    if (roi.width > size_t.max / roi.height)
        return LuminanceStretchError.allocationFailure;
    const count = roi.width * roi.height;
    if (count > size_t.max / 3 / float.sizeof)
        return LuminanceStretchError.allocationFailure;
    const bytes = count * 3 * float.sizeof;
    if (bytes > cast(size_t)ptrdiff_t.max)
        return LuminanceStretchError.allocationFailure;
    if (bytes > maxResultBytes)
        return LuminanceStretchError.resultExceedsBudget;

    OwnedByteResource owner;
    if (!allocOwned(bytes, owner))
        return LuminanceStretchError.allocationFailure;
    auto layouts = new PlaneByteLayout[](3);
    foreach (channel; 0 .. 3)
        layouts[channel] = PlaneByteLayout(
            channel * float.sizeof,
            cast(ptrdiff_t)(roi.width * 3 * float.sizeof),
            cast(ptrdiff_t)(3 * float.sizeof));
    RasterLease!float temporary;
    if (!tryImportOwnedRaster!float(owner, layouts[],
            Region2D(0, 0, roi.width, roi.height), temporary).ok)
        return LuminanceStretchError.allocationFailure;
    bool writable;
    scope auto output = temporary.tryWritableView(writable);
    if (!writable)
        return LuminanceStretchError.allocationFailure;

    // Generate a small per-call encoding table through color-d. Its setup
    // cost is amortized over the ROI and removes three powf calls per pixel.
    float[srgbEncodeIntervals + 1] srgbEncodeTable;
    foreach (index; 0 .. srgbEncodeTable.length)
    {
        const linear = cast(T)index / cast(T)srgbEncodeIntervals;
        srgbEncodeTable[index] = cast(float)LinearSRgb!T(
            linear, linear, linear).toSRgb.r;
    }

    size_t[3] sourcePlanes = [0, 1, 2];
    size_t[3] destinationPlanes = [0, 1, 2];
    RasterPlaneWindow!ubyte[3] sourceWindows;
    WritableRasterPlaneWindow!float[3] destinationWindows;
    shared int transformFailed;
    // raster-d validates the interleaved sibling output planes as disjoint
    // affine sample sets and joins every worker before releasing the borrows.
    // workerLimit == 0 keeps the operation serial and avoids thread creation.
    const processed = withPlanesIntoParallel(sourceRoi, sourcePlanes[], output,
        destinationPlanes[], sourceWindows[], destinationWindows[],
        workerLimit, minimumChunk,
        delegate(scope const(RasterPlaneWindow!ubyte)[] sources,
            scope WritableRasterPlaneWindow!float[] destinations,
            size_t firstRow, size_t endRow)
            @trusted nothrow
        {
            foreach (y; firstRow .. endRow)
            {
                            const sourceRed = sources[0].row(y);
                            const sourceGreen = sources[1].row(y);
                            const sourceBlue = sources[2].row(y);
                            auto destinationRed = destinations[0].row(y);
                            auto destinationGreen = destinations[1].row(y);
                            auto destinationBlue = destinations[2].row(y);
                            auto sourceRedData = sourceRed.data;
                            auto sourceGreenData = sourceGreen.data;
                            auto sourceBlueData = sourceBlue.data;
                            const sourceRedStride = sourceRed.sampleStride;
                            const sourceGreenStride = sourceGreen.sampleStride;
                            const sourceBlueStride = sourceBlue.sampleStride;
                            auto destinationRedData = destinationRed.data;
                            auto destinationGreenData = destinationGreen.data;
                            auto destinationBlueData = destinationBlue.data;
                            const destinationRedStride = destinationRed.sampleStride;
                            const destinationGreenStride = destinationGreen.sampleStride;
                            const destinationBlueStride = destinationBlue.sampleStride;
                            size_t x;
                            version (UseVectorKernel)
                            {
                                static if (T.sizeof == float.sizeof)
                                {
                                    for (; roi.width - x >= 4; x += 4)
                                    {
                                        ubyte[12] encoded;
                                        foreach (lane; 0 .. 4)
                                        {
                                            encoded[lane * 3] = sourceRedData[(x + lane) * sourceRedStride];
                                            encoded[lane * 3 + 1] = sourceGreenData[(x + lane) * sourceGreenStride];
                                            encoded[lane * 3 + 2] = sourceBlueData[(x + lane) * sourceBlueStride];
                                        }
                                        const transformed = transformFourPixels!Clip(
                                            encoded, linearByEncodedByte,
                                            srgbEncodeTable[], lowerBin, upperBin,
                                            inverseThresholdRange);
                                        if (transformed.outOfGamut)
                                        {
                                            atomicStore!(MemoryOrder.rel)(transformFailed, 1);
                                            return false;
                                        }
                                        foreach (lane; 0 .. 4)
                                        {
                                            destinationRedData[(x + lane) * destinationRedStride] =
                                                transformed.encodedRgb[lane * 3];
                                            destinationGreenData[(x + lane) * destinationGreenStride] =
                                                transformed.encodedRgb[lane * 3 + 1];
                                            destinationBlueData[(x + lane) * destinationBlueStride] =
                                                transformed.encodedRgb[lane * 3 + 2];
                                        }
                                    }
                                }
                            }
                            for (; x < roi.width; ++x)
                            {
                                const linearR = linearByEncodedByte[sourceRedData[x * sourceRedStride]];
                                const linearG = linearByEncodedByte[sourceGreenData[x * sourceGreenStride]];
                                const linearB = linearByEncodedByte[sourceBlueData[x * sourceBlueStride]];
                                const yValue = relativeLuminance(
                                    linearR, linearG, linearB);
                                T mappedY;
                                const inputBin = yBinFromLuminance(yValue);
                                if (constantLuminance)
                                    mappedY = yValue;
                                else if (inputBin <= lowerBin)
                                    mappedY = cast(T)0.0;
                                else if (inputBin >= upperBin)
                                    mappedY = cast(T)1.0;
                                else
                                    mappedY = cast(T)(inputBin - lowerBin) *
                                        cast(T)inverseThresholdRange;
                                const scale = yValue > 0.0 ? mappedY / yValue : cast(T)0.0;
                                T rr = linearR * scale;
                                T gg = linearG * scale;
                                T bb = linearB * scale;
                                static if (Clip)
                                {
                                    if (rr < 0.0) rr = 0.0;
                                    if (gg < 0.0) gg = 0.0;
                                    if (bb < 0.0) bb = 0.0;
                                    if (rr > 1.0) rr = 1.0;
                                    if (gg > 1.0) gg = 1.0;
                                    if (bb > 1.0) bb = 1.0;
                                }
                                else static if (!Clip)
                                {
                                    if (rr < 0.0 || rr > 1.0 || gg < 0.0 || gg > 1.0 ||
                                        bb < 0.0 || bb > 1.0)
                                    {
                                        atomicStore!(MemoryOrder.rel)(transformFailed, 1);
                                        return false;
                                    }
                                }
                                const outR = encodeSrgbFromTable(
                                    srgbEncodeTable[], cast(float)rr);
                                const outG = encodeSrgbFromTable(
                                    srgbEncodeTable[], cast(float)gg);
                                const outB = encodeSrgbFromTable(
                                    srgbEncodeTable[], cast(float)bb);
                                destinationRedData[x * destinationRedStride] = outR;
                                destinationGreenData[x * destinationGreenStride] = outG;
                                destinationBlueData[x * destinationBlueStride] = outB;
                            }
            }
            return atomicLoad!(MemoryOrder.acq)(transformFailed) == 0;
        });
    if (!processed)
    {
        if (atomicLoad!(MemoryOrder.acq)(transformFailed) != 0)
            return LuminanceStretchError.outOfGamut;
        return LuminanceStretchError.sampleFailure;
    }
    published = temporary;
    return LuminanceStretchError.none;
}

/++
 Stretch an RGB8 ROI using percentile bounds from a 65,536-bin XYZ-D65-Y
 histogram. Encoded input bytes are interpreted as sRGB; alpha and metadata
 are not inferred. Y is measured after decoding to linear light. Each pixel is
 scaled uniformly in linear RGB, preserving chromaticity until optional hard
 clipping. Black pixels remain black because their chromaticity is undefined.

 The histogram bins are uniform on [0,1], with bin `floor(Y*65536)` and 1.0
 assigned to the final bin. Percentiles use nearest-rank selection. The bin
 width is 1/65536 in computed float Y; values close to a boundary follow float
 rounding. Bin bounds are used as threshold representatives. The optional
 binary mask affects threshold estimation only; all pixels in the ROI are
 transformed.

 `Clip=true` clamps linear RGB to [0,1] before sRGB encoding. `Clip=false`
 returns `outOfGamut` and preserves the prior output if any transformed pixel
 leaves that range. The policy is selected at compile time with `static if`.
 Output is a new ROI-local interleaved `RasterLease!float` of normalized
 encoded-sRGB samples, published only on full success. The calculation uses
 float arithmetic. Output encoding linearly interpolates a compiler-tuned
 table (4,096 intervals for DMD and 1,024 for LDC) sampled through color-d.
 The byte budget limits only the new pixel
 payload.

 Params:
     Clip = Compile-time out-of-gamut policy; true clamps linear RGB, false
         rejects any result outside the sRGB gamut.
     pixels = Three-plane stored RGB8 image; byte values are encoded sRGB.
     roi = Nonempty in-bounds source region.
     lowerPercentile = Integer percentile from 0 through 99.
     upperPercentile = Integer percentile greater than lowerPercentile and
         at most 100.
     maxResultBytes = Maximum new float pixel payload.
     published = Output owner replaced only on success.
     workerLimit = Requested worker cap passed to raster-d's bounded row
         executor. Zero selects sequential execution.
     minimumChunk = Minimum logical rows per scheduled chunk; defaults to 32.
 Returns: `LuminanceStretchError.none` on success.
+/
LuminanceStretchError tryRgbLuminanceStretchOwned(bool Clip = true)(
    scope RasterView!ubyte pixels,
    Region2D roi,
    uint lowerPercentile,
    uint upperPercentile,
    size_t maxResultBytes,
    ref RasterLease!float published,
    size_t workerLimit = 0,
    size_t minimumChunk = 32)
@safe
{
    return stretchImpl!(Clip, float)(pixels, roi, lowerPercentile, upperPercentile,
        RasterView!ubyte.init, false, maxResultBytes, published, workerLimit, minimumChunk);
}

/++
 Same operation with a binary mask used only to estimate percentile bounds.
 Mask bytes equal to zero are excluded from the histogram; any nonzero byte is
 included once. Every pixel in `roi` is transformed regardless of mask value.

 Params:
     Clip = Compile-time out-of-gamut policy; true clamps linear RGB, false
         rejects any result outside the sRGB gamut.
     pixels = Three-plane stored RGB8 image; byte values are encoded sRGB.
     roi = Nonempty in-bounds source region.
     lowerPercentile = Integer percentile from 0 through 99.
     upperPercentile = Integer percentile greater than lowerPercentile and
         at most 100.
     selection = One-plane byte mask with the same dimensions as `pixels`.
     maxResultBytes = Maximum new float pixel payload.
     published = Output owner replaced only on success.
     workerLimit = Requested worker cap passed to raster-d's bounded row
         executor. Zero selects sequential execution.
     minimumChunk = Minimum logical rows per scheduled chunk; defaults to 32.
 Returns: `LuminanceStretchError.none` on success.
+/
LuminanceStretchError tryRgbLuminanceStretchOwned(bool Clip = true)(
    scope RasterView!ubyte pixels,
    Region2D roi,
    uint lowerPercentile,
    uint upperPercentile,
    scope RasterView!ubyte selection,
    size_t maxResultBytes,
    ref RasterLease!float published,
    size_t workerLimit = 0,
    size_t minimumChunk = 32)
@safe
{
    return stretchImpl!(Clip, float)(pixels, roi, lowerPercentile, upperPercentile,
        selection, true, maxResultBytes, published, workerLimit, minimumChunk);
}
