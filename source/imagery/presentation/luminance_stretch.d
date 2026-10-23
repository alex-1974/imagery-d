/++
 Percentile contrast stretch by relative luminance for decoded RGB8 images.

 The image-domain operation uses color-d's encoded-sRGB, linear-sRGB and
 XYZ-D65 conversions. Its 65,536-bin histogram is a uniform quantization of
 XYZ-D65 Y over [0,1]. An optional binary mask selects samples for estimating
 the percentile bounds only; every pixel in the ROI receives the transform.
 The compile-time `Clip` argument chooses hard linear-sRGB clipping or
 fail-on-out-of-gamut behavior without a runtime policy branch.
+/
module imagery.presentation.luminance_stretch;

import core.stdc.stdlib : malloc, free;
import color.rgb : LinearSRgbd, SRgb, SRgbd, toLinear, toSRgb;
import color.xyz : toXyzD65;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

/// Fixed number of uniform bins covering relative XYZ-D65 Y in [0,1].
enum size_t luminanceStretchBinCount = 65_536;

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
private ushort yBinFromLuminance(double y)
@safe pure nothrow @nogc
{
    if (!(y > 0.0))
        return 0;
    if (y >= 1.0)
        return ushort.max;
    return cast(ushort)(y * luminanceStretchBinCount);
}

private ushort yBin(T = double)(ubyte r, ubyte g, ubyte b)
@safe pure nothrow @nogc
{
    const encoded = SRgb!T(
        cast(T)r / 255.0,
        cast(T)g / 255.0,
        cast(T)b / 255.0);
    return yBinFromLuminance(encoded.toLinear.toXyzD65.y);
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

private LuminanceStretchError stretchImpl(bool Clip)(
    scope RasterView!ubyte pixels,
    Region2D roi,
    uint lowerPercentile,
    uint upperPercentile,
    scope RasterView!ubyte selection,
    bool hasSelection,
    size_t maxResultBytes,
    ref RasterLease!float published)
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

    // The bounded 512 KiB frequency table avoids a pixel-sized sorting copy.
    ulong[luminanceStretchBinCount] bins;
    ulong selectedPixels;
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        if (hasSelection)
        {
            ubyte include;
            if (!selection.trySample(0, x, y, include))
                return LuminanceStretchError.sampleFailure;
            if (include == 0)
                continue;
        }
        ubyte r, g, b;
        if (!pixels.trySample(0, x, y, r) ||
            !pixels.trySample(1, x, y, g) ||
            !pixels.trySample(2, x, y, b))
            return LuminanceStretchError.sampleFailure;
        ++bins[yBin(r, g, b)];
        ++selectedPixels;
    }
    if (selectedPixels == 0)
        return LuminanceStretchError.invalidMask;

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
            lowerBin = i + 1; // encode index+1 to distinguish bin zero
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

    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        ubyte r, g, b;
        if (!pixels.trySample(0, x, y, r) ||
            !pixels.trySample(1, x, y, g) ||
            !pixels.trySample(2, x, y, b))
            return LuminanceStretchError.sampleFailure;
        const encoded = SRgbd(
            cast(double)r / 255.0,
            cast(double)g / 255.0,
            cast(double)b / 255.0);
        const linear = encoded.toLinear;
        const yValue = linear.toXyzD65.y;
        double mappedY;
        const inputBin = yBinFromLuminance(yValue);
        if (constantLuminance)
            mappedY = yValue;
        else if (inputBin <= lowerBin)
            mappedY = 0.0;
        else if (inputBin >= upperBin)
            mappedY = 1.0;
        else
            mappedY = cast(double)(inputBin - lowerBin) /
                cast(double)(upperBin - lowerBin);
        const scale = yValue > 0.0 ? mappedY / yValue : 0.0;
        double rr = linear.r * scale;
        double gg = linear.g * scale;
        double bb = linear.b * scale;
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
                return LuminanceStretchError.outOfGamut;
        }
        const outColor = LinearSRgbd(rr, gg, bb).toSRgb;
        if (!output.trySetSample(0, x - roi.x, y - roi.y,
                cast(float)outColor.r) ||
            !output.trySetSample(1, x - roi.x, y - roi.y,
                cast(float)outColor.g) ||
            !output.trySetSample(2, x - roi.x, y - roi.y,
                cast(float)outColor.b))
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
 assigned to the final bin. Percentiles use nearest-rank selection. Bin bounds
 are used as threshold representatives, so the threshold quantization is at
 most 1/65536 in Y. The optional binary mask affects threshold estimation only;
 all pixels in the ROI are transformed.

 `Clip=true` clamps linear RGB to [0,1] before sRGB encoding. `Clip=false`
 returns `outOfGamut` and preserves the prior output if any transformed pixel
 leaves that range. The policy is selected at compile time with `static if`.
 Output is a new ROI-local interleaved `RasterLease!float` of normalized
 encoded-sRGB samples, published only on full success. The byte budget limits
 only the new pixel payload.

 Params:
     Clip = Compile-time out-of-gamut policy; true clamps linear RGB, false
         rejects any result outside the sRGB gamut.
     pixels = Three-plane stored RGB8 image; byte values are encoded sRGB.
     roi = Nonempty in-bounds source region.
     lowerPercentile = Integer percentile in [0,100).
     upperPercentile = Integer percentile in (lowerPercentile,100].
     maxResultBytes = Maximum new float pixel payload.
     published = Output owner replaced only on success.
 Returns: `LuminanceStretchError.none` on success.
+/
LuminanceStretchError tryRgbLuminanceStretchOwned(bool Clip = true)(
    scope RasterView!ubyte pixels,
    Region2D roi,
    uint lowerPercentile,
    uint upperPercentile,
    size_t maxResultBytes,
    ref RasterLease!float published)
@safe
{
    return stretchImpl!Clip(pixels, roi, lowerPercentile, upperPercentile,
        RasterView!ubyte.init, false, maxResultBytes, published);
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
     lowerPercentile = Integer percentile in [0,100).
     upperPercentile = Integer percentile in (lowerPercentile,100].
     selection = One-plane byte mask with the same dimensions as `pixels`.
     maxResultBytes = Maximum new float pixel payload.
     published = Output owner replaced only on success.
 Returns: `LuminanceStretchError.none` on success.
+/
LuminanceStretchError tryRgbLuminanceStretchOwned(bool Clip = true)(
    scope RasterView!ubyte pixels,
    Region2D roi,
    uint lowerPercentile,
    uint upperPercentile,
    scope RasterView!ubyte selection,
    size_t maxResultBytes,
    ref RasterLease!float published)
@safe
{
    return stretchImpl!Clip(pixels, roi, lowerPercentile, upperPercentile,
        selection, true, maxResultBytes, published);
}
