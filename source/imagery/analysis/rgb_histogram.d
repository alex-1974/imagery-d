/++
 Image-domain per-channel histograms and basic ROI statistics for decoded
 u8 RGB pixels. A raster-d view provides storage, layout and borrow safety.
 No colour transform, luminance conversion, calibration or NoData inference.
+/
module imagery.analysis.rgb_histogram;

import core.int128 : Cent, add, mul, udivmod;
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
    /// Exact frequencies: bins[channel][storedByte], channel order R,G,B.
    ulong[256][3] bins;
    /// Pixels included once in every channel; each channel's bins sum to this.
    ulong includedPixels;
    /// Pixels omitted by the binary mask; zero for the unmasked overload.
    ulong excludedPixels;
    /// Lowest included R,G,B bytes; zero without observed samples.
    ubyte[3] minimum;
    /// Highest included R,G,B bytes; zero without observed samples.
    ubyte[3] maximum;
    /// Arithmetic means of stored R,G,B bytes, rounded in double; zero
    /// without observed samples. No colour-space conversion is applied.
    double[3] mean = [0.0, 0.0, 0.0];
}

// Public records are mutable. Check all three totals before publishing any
// derived value, without allowing a malformed record to overflow a counter.
private bool validBins(const ref RgbHistogram256 histogram)
@safe pure nothrow @nogc
{
    foreach (channel; 0 .. 3)
    {
        ulong total;
        foreach (count; histogram.bins[channel])
        {
            if (count > histogram.includedPixels - total)
                return false;
            total += count;
        }
        if (total != histogram.includedPixels)
            return false;
    }
    return true;
}

/++
 Compute inclusive cumulative counts for each stored RGB byte, through
 that byte. At index 255 each channel equals includedPixels. The result
 remains all zero for a valid all-excluded histogram. A malformed public
 record (any channel total differs from includedPixels) returns false and
 leaves published unchanged. No raster access or allocation occurs.

 Params:
     histogram = Completed RGB histogram returned by tryRgbHistogram256.
     published = Three 256-entry cumulative arrays, assigned on success.
 Returns: true for a valid record, false otherwise.
+/
bool tryRgbCumulativeCounts(
    const ref RgbHistogram256 histogram,
    ref ulong[256][3] published)
@safe pure nothrow @nogc
{
    if (!validBins(histogram))
        return false;
    ulong[256][3] candidate;
    foreach (channel; 0 .. 3)
    {
        ulong cumulative;
        foreach (value; 0 .. 256)
        {
            cumulative += histogram.bins[channel][value];
            candidate[channel][value] = cumulative;
        }
    }
    published = candidate;
    return true;
}

/++
 Find each channel's nearest-rank stored-byte percentile. The percentile
 is an integer from 0 through 100. Zero selects the minimum observed byte;
 for 1..100 the one-based rank is ceil(percentile * includedPixels / 100).
 The smallest byte whose cumulative count reaches that rank is returned.
 This is a discrete order statistic with no interpolation or colour-space
 conversion. An empty selection, percentile above 100, or malformed public
 record returns false and leaves published unchanged. The computation is
 exact for the full ulong count domain without an overflowing product.
 No raster access or allocation occurs.

 Params:
     histogram = Completed RGB histogram returned by tryRgbHistogram256.
     percentile = Whole-number percentile in [0, 100].
     published = R, G, B stored-byte values, assigned on success.
 Returns: true when a nonempty valid record yields all three values.
+/
bool tryRgbPercentile(
    const ref RgbHistogram256 histogram,
    uint percentile,
    ref ubyte[3] published)
@safe pure nothrow @nogc
{
    if (percentile > 100 || histogram.includedPixels == 0 ||
        !validBins(histogram))
        return false;
    const n = histogram.includedPixels;
    const rank = percentile == 0 ? 1UL :
        (n / 100) * percentile +
        ((n % 100) * percentile + 99) / 100;
    ubyte[3] candidate;
    foreach (channel; 0 .. 3)
    {
        ulong cumulative;
        foreach (value; 0 .. 256)
        {
            cumulative += histogram.bins[channel][value];
            if (cumulative >= rank)
            {
                candidate[channel] = cast(ubyte)value;
                break;
            }
        }
    }
    published = candidate;
    return true;
}

/++
 Build a per-channel RGB8 contrast-stretch lookup table from two observed
 nearest-rank percentiles. Each channel maps its lower observed byte to 0,
 its upper observed byte to 255, and clamps outside that interval. Interior
 bytes use linear interpolation rounded to nearest integer, with ties up.
 If both percentiles select the same byte in a channel, that channel's
 entire table is the identity: no arbitrary black/white choice is made.

 The histogram's binary mask, if any, selects pixels only for estimating
 these three pairs of thresholds. This table has no pixel-selection rule:
 a consumer decides which image pixels to transform. Applying it to stored
 RGB bytes does not perform colour management, gamma correction or alpha
 processing. The table is a fixed-size value; no raster is read and no
 allocation occurs. Invalid percentile order, an empty selection or a
 malformed public histogram record returns false and preserves published.

 Params:
     histogram = Completed RGB histogram returned by tryRgbHistogram256.
     lowerPercentile = Integer lower nearest-rank percentile in [0, 100].
     upperPercentile = Integer upper nearest-rank percentile in [0, 100],
         strictly greater than lowerPercentile.
     published = Mapping indexed as [channel][storedByte], assigned on success.
 Returns: true when the full lookup table is published.
+/
bool tryRgbPercentileStretchLut(
    const ref RgbHistogram256 histogram,
    uint lowerPercentile,
    uint upperPercentile,
    ref ubyte[256][3] published)
@safe pure nothrow @nogc
{
    if (lowerPercentile >= upperPercentile || upperPercentile > 100)
        return false;
    ubyte[3] lower, upper;
    if (!tryRgbPercentile(histogram, lowerPercentile, lower) ||
        !tryRgbPercentile(histogram, upperPercentile, upper))
        return false;

    ubyte[256][3] candidate;
    foreach (channel; 0 .. 3)
    {
        const lo = cast(uint)lower[channel];
        const hi = cast(uint)upper[channel];
        foreach (value; 0 .. 256)
        {
            uint mapped;
            if (lo == hi)
                mapped = cast(uint)value;
            else if (value <= lo)
                mapped = 0;
            else if (value >= hi)
                mapped = 255;
            else
                mapped = ((cast(uint)value - lo) * 255 +
                    (hi - lo) / 2) / (hi - lo);
            candidate[channel][value] = cast(ubyte)mapped;
        }
    }
    published = candidate;
    return true;
}

/++
 Build a separate equalization lookup table for each stored RGB8 channel.
 For a nonconstant channel, the first observed byte maps to 0 and each
 later byte maps to roundHalfUp(255 * (CDF(byte) - CDF(first)) /
 (includedPixels - CDF(first))). Bytes before the first observed byte map
 to 0. A channel with only one observed byte gets an identity table, so a
 flat channel is not arbitrarily recoloured. Integer arithmetic is exact
 through the full ulong count domain; no floating-point CDF is formed.

 A histogram's optional binary mask only determines which samples estimate
 the distribution. This table itself does not choose output pixels. Applying
 it independently to stored RGB channels may change colour relationships;
 there is no luminance, transfer-function, ICC, alpha or NoData inference.
 A malformed public histogram or empty selection returns false and preserves
 published. No raster is read or allocated.

 Params:
     histogram = Completed RGB histogram returned by tryRgbHistogram256.
     published = Mapping indexed as [channel][storedByte], assigned on success.
 Returns: true when all three lookup tables are published.
+/
bool tryRgbEqualizationLut(
    const ref RgbHistogram256 histogram,
    ref ubyte[256][3] published)
@safe pure nothrow @nogc
{
    if (histogram.includedPixels == 0 || !validBins(histogram))
        return false;
    ubyte[256][3] candidate;
    foreach (channel; 0 .. 3)
    {
        ulong firstCount;
        foreach (count; histogram.bins[channel])
            if (count != 0)
            {
                firstCount = count;
                break;
            }
        if (firstCount == histogram.includedPixels)
        {
            foreach (value; 0 .. 256)
                candidate[channel][value] = cast(ubyte)value;
            continue;
        }

        Cent denominator;
        denominator.lo = histogram.includedPixels - firstCount;
        Cent factor;
        factor.lo = 255;
        Cent half;
        half.lo = denominator.lo / 2;
        ulong cumulative;
        foreach (value; 0 .. 256)
        {
            cumulative += histogram.bins[channel][value];
            if (cumulative <= firstCount)
                candidate[channel][value] = 0;
            else
            {
                Cent count;
                count.lo = cumulative - firstCount;
                Cent remainder;
                const quotient = udivmod(
                    add(mul(count, factor), half), denominator, remainder);
                candidate[channel][value] = cast(ubyte)quotient.lo;
            }
        }
    }
    published = candidate;
    return true;
}

/// Work entirely from an already completed histogram. A two-pixel channel
/// has its lower value at the 50th nearest rank and upper value at the 51st.
@safe unittest
{
    RgbHistogram256 h;
    h.includedPixels = 2;
    h.bins[0][10] = 1;
    h.bins[0][200] = 1;
    h.bins[1][0] = 2;
    h.bins[2][255] = 2;
    ulong[256][3] cumulative;
    assert(tryRgbCumulativeCounts(h, cumulative));
    assert(cumulative[0][9] == 0 && cumulative[0][10] == 1 &&
        cumulative[0][199] == 1 && cumulative[0][200] == 2);
    foreach (channel; 0 .. 3)
        assert(cumulative[channel][255] == h.includedPixels);
    ubyte[3] values;
    assert(tryRgbPercentile(h, 0, values) && values == [10, 0, 255]);
    assert(tryRgbPercentile(h, 50, values) && values == [10, 0, 255]);
    assert(tryRgbPercentile(h, 51, values) && values == [200, 0, 255]);
    assert(tryRgbPercentile(h, 100, values) && values == [200, 0, 255]);
    ubyte[256][3] lut;
    assert(tryRgbPercentileStretchLut(h, 0, 100, lut));
    assert(lut[0][9] == 0 && lut[0][10] == 0 &&
        lut[0][105] == 128 && lut[0][200] == 255 &&
        lut[0][255] == 255);
    // Both constant channels have identity lookup tables.
    foreach (value; 0 .. 256)
        assert(lut[1][value] == value && lut[2][value] == value);
    assert(tryRgbEqualizationLut(h, lut));
    assert(lut[0][9] == 0 && lut[0][10] == 0 &&
        lut[0][199] == 0 && lut[0][200] == 255);
    foreach (value; 0 .. 256)
        assert(lut[1][value] == value && lut[2][value] == value);
}

@safe unittest
{
    RgbHistogram256 h;
    ulong[256][3] cumulative;
    assert(tryRgbCumulativeCounts(h, cumulative));
    ubyte[3] values = [7, 8, 9];
    assert(!tryRgbPercentile(h, 50, values) && values == [7, 8, 9]);

    // Public records may be edited; reject inconsistent counts without
    // publishing partial data, including at the ulong boundary.
    h.includedPixels = ulong.max;
    foreach (channel; 0 .. 3)
        h.bins[channel][255] = ulong.max;
    assert(tryRgbPercentile(h, 100, values) && values == [255, 255, 255]);
    assert(!tryRgbPercentile(h, 101, values) && values == [255, 255, 255]);
    ubyte[256][3] lut;
    lut[0][0] = 17;
    assert(!tryRgbPercentileStretchLut(h, 50, 50, lut) && lut[0][0] == 17);
    assert(tryRgbPercentileStretchLut(h, 1, 99, lut) && lut[0][0] == 0);
    h.bins[1][0] = 1;
    cumulative[0][0] = 42;
    assert(!tryRgbCumulativeCounts(h, cumulative) && cumulative[0][0] == 42);
    assert(!tryRgbPercentile(h, 50, values) && values == [255, 255, 255]);
    lut[0][0] = 17;
    assert(!tryRgbPercentileStretchLut(h, 1, 99, lut) && lut[0][0] == 17);
    assert(!tryRgbEqualizationLut(h, lut) && lut[0][0] == 17);
}

@safe unittest
{
    RgbHistogram256 h;
    h.includedPixels = ulong.max;
    foreach (channel; 0 .. 3)
    {
        h.bins[channel][0] = 1;
        h.bins[channel][128] = (ulong.max - 1) / 2;
        h.bins[channel][255] = (ulong.max - 1) / 2;
    }
    ubyte[256][3] lut;
    assert(tryRgbEqualizationLut(h, lut));
    foreach (channel; 0 .. 3)
    {
        assert(lut[channel][0] == 0);
        assert(lut[channel][128] == 128);
        assert(lut[channel][255] == 255);
    }
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
 Build an RGB histogram using an explicit validity/NoData mask.

 Unlike the selection-mask overload, zero means that the source sample is not
 valid and must not contribute to statistics; nonzero means valid. The mask
 does not alter pixels and is not an editing-selection or alpha policy. The
 caller is responsible for constructing it from source-specific NoData rules.
+/
RgbHistogramError tryRgbHistogram256WithValidity(
    scope RasterView!ubyte rgb,
    Region2D roi,
    scope RasterView!ubyte validity,
    ref RgbHistogram256 published)
@safe
{
    return calculate(rgb, roi, validity, true, published);
}

unittest
{
    // The validity entry point intentionally has the same counting mechanics
    // as a selection mask, but its public name makes the semantic distinction
    // explicit to Dunia and other consumers.
    RgbHistogram256 value;
    auto empty = RasterView!ubyte.init;
    assert(tryRgbHistogram256WithValidity(empty, Region2D.init, empty, value) ==
        RgbHistogramError.invalidSource);
}

/// Count two stored RGB pixels, then include only the first using a
/// binary mask. Allocation here belongs to the consumer, not the histogram.
@system unittest
{
    import core.stdc.stdlib : malloc;
    import raster : OwnedByteResource, PlaneByteLayout, RasterLease,
        tryAdoptMallocResource, tryImportOwnedRaster;

    // The consumer creates a retained, interleaved two-pixel RGB raster.
    auto bytes = cast(ubyte*)malloc(6);
    assert(bytes !is null);
    bytes[0 .. 6] = [cast(ubyte)0, 64, 255, 128, 192, 17];
    OwnedByteResource owned;
    assert(tryAdoptMallocResource(bytes, 6, owned));
    const PlaneByteLayout[3] channels = [
        PlaneByteLayout(0, 6, 3), PlaneByteLayout(1, 6, 3),
        PlaneByteLayout(2, 6, 3)
    ];
    RasterLease!ubyte image;
    assert(tryImportOwnedRaster!ubyte(owned, channels[],
        Region2D(0, 0, 2, 1), image).ok);

    RgbHistogram256 result;
    const roi = Region2D(0, 0, 2, 1);
    assert(tryRgbHistogram256(image.view(), roi, result) ==
        RgbHistogramError.none);
    assert(result.includedPixels == 2 && result.excludedPixels == 0);
    assert(result.bins[0][0] == 1 && result.bins[0][128] == 1);
    assert(result.minimum == [0, 64, 17]);
    assert(result.maximum == [128, 192, 255]);
    assert(result.mean == [64.0, 128.0, 136.0]);

    auto maskBytes = cast(ubyte*)malloc(2);
    assert(maskBytes !is null);
    maskBytes[0 .. 2] = [cast(ubyte)1, 0];
    OwnedByteResource maskOwned;
    assert(tryAdoptMallocResource(maskBytes, 2, maskOwned));
    const PlaneByteLayout[1] maskPlane = [PlaneByteLayout(0, 2, 1)];
    RasterLease!ubyte mask;
    assert(tryImportOwnedRaster!ubyte(maskOwned, maskPlane[], roi, mask).ok);
    assert(tryRgbHistogram256(image.view(), roi, mask.view(), result) ==
        RgbHistogramError.none);
    assert(result.includedPixels == 1 && result.excludedPixels == 1);
    assert(result.mean == [0.0, 64.0, 255.0]); // mask byte 1 includes once

    const previous = result;
    assert(tryRgbHistogram256(image.view(), Region2D(2, 0, 1, 1), result)
        == RgbHistogramError.invalidRegion);
    assert(result == previous); // returned failure preserves publication
}

/++
 Build the same histogram with an explicit binary pixel-inclusion mask.

 selection is a borrowed one-channel u8 raster on the FULL source grid.
 A zero byte omits a pixel entirely; ANY nonzero byte (including 1, 128
 or 255) includes each of its three channels exactly ONCE. This is NOT
 the fractional editing-strength behavior of the Levels mask. The mask
 is not inferred from alpha or NoData and is not retained after return.

 All-excluded ROIs return success with zero bins and statistics.
 An invalid mask or failed sample read preserves published. See the
 unmasked overload's compiled example for both forms and failure handling.

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
