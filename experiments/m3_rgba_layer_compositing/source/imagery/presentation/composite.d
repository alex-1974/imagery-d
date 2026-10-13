/++
 Research-only same-grid compositing of two already decoded RGBA byte images.

 All color transfer, alpha association and Porter-Duff mathematics are delegated
 to color-d v0.2.0. Neither the image views nor the destination own pixel memory.
 This is NOT an admitted imagery-d production module.
+/
module imagery.presentation.composite;

import raster : RasterView, WritableRasterView, Region2D;
import color :
    Alpha, LinearSRgbd, Premultiplied, SRgbd, SRgba8,
    premultiply, sourceOver, unpremultiply, tryToSRgba8,
    toLinear, toSRgb;

/// Explicit interpretation of the three RGB byte planes.
enum RgbaEncoding : ubyte
{
    unspecified,
    encodedSRgb,
    linearSRgb
}

/// Explicit relationship between RGB and the fourth, alpha, byte plane.
enum RgbaAssociation : ubyte
{
    unspecified,
    straight,
    premultiplied
}

/++
 Borrowed image layer. The first four bands mean R,G,B,A in that order.

 Encoded sRGB is admitted only with straight alpha; premultiplied input must
 be declared LINEAR sRGB. Byte-normalized linear values are not encoded sRGB.
 The source's RasterLease/storage and descriptor metadata must outlive each call.
+/
struct DecodedRgbaLayer
{
    RasterView!ubyte pixels;
    RgbaEncoding encoding;
    RgbaAssociation association;
}

/// Classified errors from the research adapter.
enum RgbaCompositeError : ubyte
{
    none,
    invalidLayer,
    invalidEncoding,
    invalidRegion,
    invalidOutput,
    invalidOpacity,
    invalidPremultiplication,
    sampleFailure,
    quantizationFailure,
    invalidPreparedContext
}

private bool validDescriptor(scope DecodedRgbaLayer layer)
@safe nothrow @nogc
{
    if (layer.pixels.planeCount != 4 ||
        layer.pixels.width == 0 || layer.pixels.height == 0)
        return false;
    if (layer.encoding == RgbaEncoding.unspecified ||
        layer.association == RgbaAssociation.unspecified)
        return false;
    // No defined interpretation of byte-premultiplied *encoded* sRGB here.
    if (layer.encoding == RgbaEncoding.encodedSRgb &&
        layer.association == RgbaAssociation.premultiplied)
        return false;
    return true;
}

private bool contained(Region2D roi, size_t width, size_t height)
@safe pure nothrow @nogc
{
    return roi.width != 0 && roi.height != 0 &&
        roi.x <= width && roi.y <= height &&
        roi.width <= width - roi.x &&
        roi.height <= height - roi.y;
}

private bool readRgba(
    scope RasterView!ubyte view, size_t x, size_t y,
    out SRgba8 pixel
) @safe nothrow @nogc
{
    pixel = SRgba8.init;
    return
        view.trySample(0, x, y, pixel.r) &&
        view.trySample(1, x, y, pixel.g) &&
        view.trySample(2, x, y, pixel.b) &&
        view.trySample(3, x, y, pixel.a);
}

private Premultiplied!LinearSRgbd asLinearPremultiplied(
    SRgba8 bytes, RgbaEncoding encoding, RgbaAssociation association
) @safe nothrow @nogc
{
    if (encoding == RgbaEncoding.encodedSRgb)
    {
        // A tagged encoded input is always straight alpha.
        const straight = bytes.toAlphaSRgb!double();
        return premultiply(Alpha!LinearSRgbd(
            straight.color.toLinear(), straight.alpha));
    }

    const double alpha = cast(double)bytes.a / 255.0;
    const linear = LinearSRgbd(
        cast(double)bytes.r / 255.0,
        cast(double)bytes.g / 255.0,
        cast(double)bytes.b / 255.0);
    if (association == RgbaAssociation.straight)
        return premultiply(Alpha!LinearSRgbd(linear, alpha));
    return Premultiplied!LinearSRgbd(linear, alpha);
}

private Premultiplied!LinearSRgbd withLayerOpacity(
    Premultiplied!LinearSRgbd source, double opacity
) @safe pure nothrow @nogc
{
    // The user-visible layer opacity scales BOTH associated light and alpha.
    // This is a layer policy; color-d owns premultiplication/source-over.
    return Premultiplied!LinearSRgbd(
        LinearSRgbd(
            source.color.r * opacity,
            source.color.g * opacity,
            source.color.b * opacity),
        source.alpha * opacity);
}

/++
 Source-over the upper layer onto the lower layer in linear light.

 Both inputs must describe the SAME logical 0,0-anchored image grid and
 remain resident for the call. `roi` is relative to that shared image grid;
 the four-band caller-owned destination covers exactly the ROI dimensions.
 Output is ALWAYS STRAIGHT encoded sRGB RGBA8, not premultiplied. In the
 fully transparent case its invisible RGB is canonicalized to zero.

 The operation makes no hidden full-frame copy, allocation, scheduling,
 color-space inference, NoData interpretation, or renderer decision. The
 caller MUST provide source/output storage that does not overlap: current
 public raster-d view APIs do not certify noalias, so this requirement is
 explicitly NOT checked or proven by this research function.

 Invalid metadata, shape, ROI, opacity or noncanonical linear-premultiplied
 pixel data are rejected before the first output write. The preflight for
 premultiplied input is an additional O(ROI pixels) pass. An unexpected
 sample/access or final numeric quantization failure during the output pass
 is not transactional, so already written pixels may remain in the output.

 Params:
     upper = Borrowed foreground image with explicit RGB/alpha meaning.
     lower = Borrowed background image on the same pixel grid.
     roi = Nonempty selected region in that image grid.
     opacity = Extra overall upper-layer opacity, finite in [0, 1].
     output = Four-band caller-owned, non-aliasing RGBA8 destination.

 Returns:
     Classified status; `none` only after all ROI pixels were written.
+/
RgbaCompositeError tryCompositeRgbaSourceOver(
    scope DecodedRgbaLayer upper,
    scope DecodedRgbaLayer lower,
    Region2D roi,
    double opacity,
    scope WritableRasterView!ubyte output
) @safe nothrow @nogc
{
    if (upper.pixels.planeCount != 4 ||
        lower.pixels.planeCount != 4 ||
        upper.pixels.width == 0 || upper.pixels.height == 0 ||
        upper.pixels.width != lower.pixels.width ||
        upper.pixels.height != lower.pixels.height)
        return RgbaCompositeError.invalidLayer;
    if (!validDescriptor(upper) || !validDescriptor(lower))
        return RgbaCompositeError.invalidEncoding;
    if (!contained(roi, upper.pixels.width, upper.pixels.height))
        return RgbaCompositeError.invalidRegion;
    if (output.planeCount != 4 ||
        output.width != roi.width || output.height != roi.height)
        return RgbaCompositeError.invalidOutput;
    // Also rejects NaN and +/- infinity, without std.math allocations.
    if (!(opacity >= 0.0 && opacity <= 1.0))
        return RgbaCompositeError.invalidOpacity;

    // The byte-premultiplied LINEAR representation must be canonical.
    // Check all relevant pixels before ANY caller-output mutation.
    foreach (index; 0 .. 2)
    {
        const layer = index == 0 ? upper : lower;
        if (layer.association != RgbaAssociation.premultiplied)
            continue;
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        {
            SRgba8 pixel;
            if (!readRgba(layer.pixels, roi.x + x, roi.y + y, pixel))
                return RgbaCompositeError.sampleFailure;
            if (pixel.r > pixel.a ||
                pixel.g > pixel.a || pixel.b > pixel.a)
                return RgbaCompositeError.invalidPremultiplication;
        }
    }

    foreach (y; 0 .. roi.height)
    foreach (x; 0 .. roi.width)
    {
        SRgba8 top;
        SRgba8 bottom;
        if (!readRgba(upper.pixels, roi.x + x, roi.y + y, top) ||
            !readRgba(lower.pixels, roi.x + x, roi.y + y, bottom))
            return RgbaCompositeError.sampleFailure;

        const foreground = withLayerOpacity(
            asLinearPremultiplied(top, upper.encoding, upper.association),
            opacity);
        const background = asLinearPremultiplied(
            bottom, lower.encoding, lower.association);

        const mixed = sourceOver(foreground, background);
        const straight = unpremultiply(mixed);
        SRgba8 stored;
        if (!tryToSRgba8(
            Alpha!SRgbd(straight.color.toSRgb(), straight.alpha), stored))
            return RgbaCompositeError.quantizationFailure;

        if (!output.trySetSample(0, x, y, stored.r) ||
            !output.trySetSample(1, x, y, stored.g) ||
            !output.trySetSample(2, x, y, stored.b) ||
            !output.trySetSample(3, x, y, stored.a))
            return RgbaCompositeError.sampleFailure;
    }

    return RgbaCompositeError.none;
}

/++
 Research-only, nonowning **configuration** for repeated same-math source-over.

 This value contains a bounded 256-entry, runtime-created sRGB8 decoding
 table and one validated layer opacity; it owns **no raster storage**, borrows
 no views, holds no mutable global state, and needs no GC allocation.
 Its inert .init cannot perform compositing. It is not an admitted public API.

 The exact LUT entries come from released color-d runtime conversions, not
 CTFE/approximate transfer formulas. The context can be reused for independent
 ROI calls while all RasterLease owners remain external to it.
+/
struct ResearchPreparedRgbaContext
{
private:
    double[256] decoded;
    double opacity;
    bool initialized;

    // Suppress external positional aggregate forging.
    this(double opacity) @safe nothrow @nogc
    {
        this.opacity = opacity;
    }
}

/++
 Prepare a caller-owned research context (2048 data bytes) once.

 An invalid opacity returns invalidOpacity and leaves the out parameter at
 its inert .init. No source or output view is stored or captured.
+/
RgbaCompositeError tryPrepareRgbaContext(
    double opacity, out ResearchPreparedRgbaContext prepared
) @safe nothrow @nogc
{
    // Reject NaN and infinities without importing std.math.
    if (!(opacity >= 0.0 && opacity <= 1.0))
        return RgbaCompositeError.invalidOpacity;

    foreach (i; 0 .. 256)
    {
        const ubyte channel = cast(ubyte)i;
        const p = SRgba8(channel, channel, channel, 255)
            .toAlphaSRgb!double();
        prepared.decoded[i] = p.color.toLinear().r;
    }
    prepared.opacity = opacity;
    prepared.initialized = true;
    return RgbaCompositeError.none;
}

private Premultiplied!LinearSRgbd asPreparedPremultiplied(
    SRgba8 value, RgbaEncoding encoding, RgbaAssociation association,
    ref const ResearchPreparedRgbaContext prepared
) @safe nothrow @nogc
{
    if (encoding == RgbaEncoding.encodedSRgb)
    {
        // The supported encoded-sRGB input is necessarily straight alpha.
        const straight = value.toAlphaSRgb!double();
        const linear = LinearSRgbd(
            prepared.decoded[value.r],
            prepared.decoded[value.g],
            prepared.decoded[value.b]);
        return premultiply(Alpha!LinearSRgbd(linear, straight.alpha));
    }
    // Keep the original color-d based interpretation of linear/PM bytes.
    return asLinearPremultiplied(value, encoding, association);
}

/++
 Execute multiple borrowed, same-grid RGBA ROIs with one prepared configuration.

 This is an *independent research variant* of tryCompositeRgbaSourceOver.
 The caller provides fresh scope-borrowed source/output views **on every call**;
 the prepared object never owns or retains those raster views.
 Source/output physical nonoverlap remains an explicit **caller precondition**.
 Unlike public raster.zipTransformInto, this function does NOT prove noalias.
 It does preserve the old research adapter's classified result semantics:
 known invalid descriptors/opacities/linear-PM bytes are rejected before writes;
 exceptional read/write/quantization failures may leave partial output.
 No general product API, transactional guarantee, new scheduler, or internal
 raster execution adapter is being introduced.

 Output is straight encoded sRGB RGBA8, canonical black for final alpha=0.
+/
RgbaCompositeError tryCompositeRgbaSourceOverPrepared(
    ref const ResearchPreparedRgbaContext prepared,
    scope DecodedRgbaLayer upper,
    scope DecodedRgbaLayer lower,
    Region2D roi,
    scope WritableRasterView!ubyte output
) @safe nothrow @nogc
{
    if (!prepared.initialized)
        return RgbaCompositeError.invalidPreparedContext;
    if (upper.pixels.planeCount != 4 ||
        lower.pixels.planeCount != 4 ||
        upper.pixels.width == 0 || upper.pixels.height == 0 ||
        upper.pixels.width != lower.pixels.width ||
        upper.pixels.height != lower.pixels.height)
        return RgbaCompositeError.invalidLayer;
    if (!validDescriptor(upper) || !validDescriptor(lower))
        return RgbaCompositeError.invalidEncoding;
    if (!contained(roi, upper.pixels.width, upper.pixels.height))
        return RgbaCompositeError.invalidRegion;
    if (output.planeCount != 4 ||
        output.width != roi.width || output.height != roi.height)
        return RgbaCompositeError.invalidOutput;

    // The same fail-before-first-write check as the original research path.
    foreach (index; 0 .. 2)
    {
        const layer = index == 0 ? upper : lower;
        if (layer.association != RgbaAssociation.premultiplied)
            continue;
        foreach (y; 0 .. roi.height)
        foreach (x; 0 .. roi.width)
        {
            SRgba8 pixel;
            if (!readRgba(layer.pixels, roi.x + x, roi.y + y, pixel))
                return RgbaCompositeError.sampleFailure;
            if (pixel.r > pixel.a ||
                pixel.g > pixel.a || pixel.b > pixel.a)
                return RgbaCompositeError.invalidPremultiplication;
        }
    }

    foreach (y; 0 .. roi.height)
    foreach (x; 0 .. roi.width)
    {
        SRgba8 top;
        SRgba8 bottom;
        if (!readRgba(upper.pixels, roi.x + x, roi.y + y, top) ||
            !readRgba(lower.pixels, roi.x + x, roi.y + y, bottom))
            return RgbaCompositeError.sampleFailure;

        const foreground = withLayerOpacity(
            asPreparedPremultiplied(top, upper.encoding, upper.association,
                prepared), prepared.opacity);
        const background = asPreparedPremultiplied(
            bottom, lower.encoding, lower.association, prepared);
        const mixed = sourceOver(foreground, background);
        const straight = unpremultiply(mixed);
        SRgba8 stored;
        if (!tryToSRgba8(
            Alpha!SRgbd(straight.color.toSRgb(), straight.alpha), stored))
            return RgbaCompositeError.quantizationFailure;

        if (!output.trySetSample(0, x, y, stored.r) ||
            !output.trySetSample(1, x, y, stored.g) ||
            !output.trySetSample(2, x, y, stored.b) ||
            !output.trySetSample(3, x, y, stored.a))
            return RgbaCompositeError.sampleFailure;
    }
    return RgbaCompositeError.none;
}
