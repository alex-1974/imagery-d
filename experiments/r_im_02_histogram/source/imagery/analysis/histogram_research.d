/++
 R-IM-02a bounded histogram research prototype.
 This module is NOT a public imagery-d API and has no package-root export.
 Only raster-d owns the pixel buffers and checked raster layouts.
 Input views are borrowed for this synchronous call.
+/
module imagery.analysis.histogram_research;

import raster : RasterView, Region2D;

enum HistogramMeaning : ubyte
{
    stored,
    physical
}

enum HistogramError : ubyte
{
    none,
    invalidSource,
    invalidRegion,
    invalidMask,
    invalidRange,
    invalidCalibration,
    sampleFailure
}

/++
 The deliberately fixed 8-bin record makes a conservative first contract
 probe possible without introducing a bin allocator or generic statistics
 framework. The bins cover [minimum, maximum), with maximum EXCLUDED.
 Mask value zero means invalid; nonzero means valid. For valid samples:
 NaN or positive/negative infinity are counted in nonFinite; finite values outside the
 interval are counted in outsideRange; neither enters a histogram bin.
 On every error the caller's previous 'result' is unchanged.

 .init is a valid empty accumulator, NOT proof that processing succeeded.
+/
struct Histogram8
{
    ulong[8] bins;
    ulong counted;
    ulong masked;
    ulong nonFinite;
    ulong outsideRange;
}

private bool finite(double x)
{
    return x >= -double.max && x <= double.max;
}

private bool contained(Region2D roi, size_t width, size_t height)
{
    return roi.width != 0 && roi.height != 0 &&
        roi.x <= width && roi.y <= height &&
        roi.width <= width - roi.x &&
        roi.height <= height - roi.y;
}

/++
 Build a complete eight-bin histogram for one checked source band/ROI.

 This is an operation-contract EXPERIMENT, not a candidate general fixed-bin
 production signature. There is no pixel-output allocation and no mask/NoData
 inference; physical interpretation uses a caller-provided scale/offset only
 when 'meaning == physical'. Masks and pixel grids must coincide.

 Failure is output-transactional for the accumulator, provided inputs are
 not concurrently mutated. No concurrency/snapshot or total process-memory
 claim is made. Does not retain any source view.

 The implementation may be used with ubyte, ushort or float samples.
+/
HistogramError tryHistogram8Research(T)(
    scope RasterView!T input,
    size_t band,
    Region2D roi,
    scope RasterView!ubyte mask,
    bool hasMask,
    HistogramMeaning meaning,
    double scale,
    double offset,
    double minimum,
    double maximum,
    ref Histogram8 result)
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    if (input.planeCount == 0 || band >= input.planeCount ||
        input.width == 0 || input.height == 0)
        return HistogramError.invalidSource;

    if (!contained(roi, input.width, input.height))
        return HistogramError.invalidRegion;

    if (hasMask && (mask.planeCount != 1 ||
        mask.width != input.width || mask.height != input.height))
        return HistogramError.invalidMask;

    if (!finite(minimum) || !finite(maximum) ||
        !(minimum < maximum) || !finite(maximum - minimum))
        return HistogramError.invalidRange;

    if (meaning == HistogramMeaning.physical &&
        (!finite(scale) || !finite(offset)))
        return HistogramError.invalidCalibration;

    Histogram8 candidate;
    const span = maximum - minimum;

    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        if (hasMask)
        {
            ubyte active;
            if (!mask.trySample(0, x, y, active))
                return HistogramError.sampleFailure;
            if (active == 0)
            {
                ++candidate.masked;
                continue;
            }
        }

        T raw;
        if (!input.trySample(band, x, y, raw))
            return HistogramError.sampleFailure;

        double value = cast(double)raw;
        if (meaning == HistogramMeaning.physical)
            value = value * scale + offset;

        if (!finite(value))
        {
            ++candidate.nonFinite;
            continue;
        }
        if (value < minimum || value >= maximum)
        {
            ++candidate.outsideRange;
            continue;
        }
        // Half-open bins, except for rounded normalized ratios that land
        // exactly on 8.0 although the input was strictly below maximum.
        const normalized = (value - minimum) / span;
        size_t bin = cast(size_t)(normalized * 8.0);
        if (bin >= 8)
            bin = 7;
        ++candidate.bins[bin];
        ++candidate.counted;
    }

    // Publish only after all source accesses and classifications succeed.
    result = candidate;
    return HistogramError.none;
}
