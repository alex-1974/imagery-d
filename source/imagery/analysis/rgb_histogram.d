/++
 Image-domain per-channel histograms and basic ROI statistics for decoded
 u8 RGB pixels. A raster-d view provides storage, layout and borrow safety.
 No colour transform, luminance conversion, calibration or NoData inference.
+/
module imagery.analysis.rgb_histogram;

import raster : RasterView, Region2D, histogram256;

/++
 Exact 256-bin stored-byte distributions for three channels in R,G,B order.
 Each channel's bins sum to includedPixels. Excluded pixels contribute
 only to excludedPixels (not to bins). The two pixel counts add to the
 nonempty ROI area.

 Extrema and arithmetic means describe included byte values. When no
 pixels are included, all statistics are zero and extrema have no
 observed-sample meaning. This value's .init is empty, not proof of
 successful processing: the return status must be checked.
+/
struct RgbHistogram256
{
    ulong[256][3] bins;
    ulong includedPixels;
    ulong excludedPixels;
    ubyte[3] minimum;
    ubyte[3] maximum;
    // D floating .init is NaN; an empty histogram requires zero means.
    double[3] mean = [0.0, 0.0, 0.0];
}

/++
 Explicit RGB histogram result status. Only none means published success;
 .init == notAttempted, and no public call returns notAttempted.
 Any normally returned failure preserves the caller's previous result.
+/
enum RgbHistogramError : ubyte
{
    /// Initial status, never an attempted operation's return.
    notAttempted,
    /// Complete histogram published.
    none,
    /// Empty image or other than exactly three 8-bit channels.
    invalidSource,
    /// Empty, unrepresentable or out-of-bounds image ROI.
    invalidRegion,
    /// Explicit mask lacks one full-source-size 8-bit plane.
    invalidMask,
    /// A checked sample read or generic raster reduction failed.
    sampleFailure
}

private bool contained(Region2D roi, size_t width, size_t height)
@safe pure nothrow @nogc
{
    return roi.width != 0 && roi.height != 0 &&
        roi.x <= width && roi.y <= height &&
        roi.width <= width - roi.x &&
        roi.height <= height - roi.y;
}

private RgbHistogramError calculate(
    scope RasterView!ubyte rgb,
    Region2D roi,
    scope RasterView!ubyte selection,
    bool hasSelection,
    ref RgbHistogram256 published)
@safe
{
    if (rgb.planeCount != 3 || rgb.width == 0 || rgb.height == 0)
        return RgbHistogramError.invalidSource;
    if (!contained(roi, rgb.width, rgb.height) ||
        roi.width > ulong.max / roi.height)
        return RgbHistogramError.invalidRegion;
    if (hasSelection && (selection.planeCount != 1 ||
        selection.width != rgb.width ||
        selection.height != rgb.height))
        return RgbHistogramError.invalidMask;

    RgbHistogram256 candidate;
    if (!hasSelection)
    {
        bool valid;
        scope auto region = rgb.tryRoi(roi, valid);
        if (!valid)
            return RgbHistogramError.invalidRegion;
        foreach (channel; 0 .. 3)
        {
            const counts = histogram256(region, channel);
            // Plane count and ROI cardinality were checked above. Keep
            // publication transactional if the generic reduction fails.
            if (!counts.ok)
                return RgbHistogramError.sampleFailure;
            candidate.bins[channel] = counts.bins;
        }
        candidate.includedPixels = cast(ulong)roi.width * roi.height;
    }
    else
    {
        // raster-d v0.3 has no masked reduction. This path implements
        // binary image-selection semantics without a temporary raster or
        // one generic histogram invocation per pixel/selected run.
        foreach (y; roi.y .. roi.y + roi.height)
        foreach (x; roi.x .. roi.x + roi.width)
        {
            ubyte active;
            if (!selection.trySample(0, x, y, active))
                return RgbHistogramError.sampleFailure;
            if (active == 0)
            {
                ++candidate.excludedPixels;
                continue;
            }

            foreach (channel; 0 .. 3)
            {
                ubyte value;
                if (!rgb.trySample(channel, x, y, value))
                    return RgbHistogramError.sampleFailure;
                ++candidate.bins[channel][value];
            }
            ++candidate.includedPixels;
        }
    }

    // Both counting paths share image statistics from the exact bins.
    if (candidate.includedPixels != 0)
        foreach (channel; 0 .. 3)
        {
            bool first = true;
            double sum = 0.0;
            foreach (value; 0 .. 256)
            {
                const count = candidate.bins[channel][value];
                if (count == 0)
                    continue;
                if (first)
                {
                    candidate.minimum[channel] = cast(ubyte)value;
                    first = false;
                }
                candidate.maximum[channel] = cast(ubyte)value;
                sum += cast(double)value * count;
            }
            candidate.mean[channel] =
                sum / cast(double)candidate.includedPixels;
        }

    published = candidate;
    return RgbHistogramError.none;
}

/++
 Build stored 8-bit R, G and B channel histograms over a nonempty ROI.
 This image-specific operation accepts exactly three channels already
 interpreted by the caller as R, G, B in that order. Planar, interleaved
 and signed-stride raster views are read through raster-d. It does not
 convert transfer functions, infer alpha, compute luma or assign units.

 Unmasked channel counts use raster-d v0.3 histogram256 on a zero-copy
 ROI. The masked overload uses checked sample access because raster-d has
 no masked histogram. Both paths derive statistics from the exact bins.

 The output is a fixed-size stack-compatible value; no pixel backing,
 cache, metadata graph or sample buffer is allocated. On every normally
 returned error, published retains its prior full value. Source storage
 must not be concurrently modified. No nothrow or OOM-Error promise.

 Params:
     rgb = Borrowed u8 R/G/B input, exactly three source planes.
     roi = Nonempty source-bounded rectangle.
     published = Complete statistics published only on success.
 Returns:
     RgbHistogramError.none on success, otherwise a precise error.
 Examples:
 ---
 RgbHistogram256 record;
 assert(RgbHistogramError.init == RgbHistogramError.notAttempted);
 assert(RgbHistogramError.init != RgbHistogramError.none);
 // For a live caller-owned RasterView!ubyte:
 // auto status = tryRgbHistogram256(view, roi, record);
 // if (status == RgbHistogramError.none)
 //     assert(record.bins[0][0] <= record.includedPixels);
 ---
+/
RgbHistogramError tryRgbHistogram256(
    scope RasterView!ubyte rgb,
    Region2D roi,
    ref RgbHistogram256 published)
@safe
{
    return calculate(rgb, roi, RasterView!ubyte.init, false, published);
}

/++
 Build the same histogram with an explicit binary pixel-inclusion mask.

 selection is a borrowed one-channel u8 raster on the FULL source grid.
 A zero byte omits a pixel entirely; ANY nonzero byte (including 1, 128
 or 255) includes each of its three channels exactly ONCE. This is NOT
 the fractional editing-strength behavior of the Levels mask. The mask
 is not inferred from alpha or NoData and is not retained after return.

 All-excluded ROIs return success with zero bins and statistics.
 An invalid mask or failed sample read preserves published.

 Params:
     rgb = Borrowed three-plane stored-u8 RGB input.
     roi = Nonempty rectangle in source coordinates.
     selection = Full-source-size one-plane inclusion mask.
     published = Output record, replaced only on success.
 Returns:
     RgbHistogramError.none or an error preserving the previous record.
+/
RgbHistogramError tryRgbHistogram256(
    scope RasterView!ubyte rgb,
    Region2D roi,
    scope RasterView!ubyte selection,
    ref RgbHistogram256 published)
@safe
{
    return calculate(rgb, roi, selection, true, published);
}
