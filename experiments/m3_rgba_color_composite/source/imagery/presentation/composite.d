module imagery.presentation.composite;

// Optional research image adapter: color mathematics belongs to color-d.
// This module MUST NOT be imported by the base imagery package.d/all.d,
// which has no color-d dependency.
import color.alpha : Alpha, Premultiplied, premultiply;
import color.composite : sourceOver;
import color.rgb : SRgbd, LinearSRgbd, toLinear;
import imagery.presentation.tiles : RgbaAlphaAssociation;
import raster : RasterView, WritableRasterView, Region2D;

/++ Explicit colour interpretation; .init is invalid. +/
enum RgbaCompositeSpace : ubyte
{
    unspecified,
    encodedSRgb,
    linearSRgb
}

/++
    Borrowed common-grid RGBA image. Four ordered components must represent
    R,G,B,alpha and the declared source association/colour space.

    For encodedSRgb, only straight alpha is accepted. Nonlinear encoded
    premultiplication is NOT silently converted or relabelled as linear.
    For linearSRgb, straight and premultiplied alpha are accepted.
+/
struct RgbaCompositeLayer
{
    RasterView!double pixels;
    RgbaCompositeSpace space;
    RgbaAlphaAssociation association;
}

enum RgbaCompositeError : ubyte
{
    none,
    invalidImage,
    invalidColourSemantics,
    invalidRegion,
    destinationMismatch,
    invalidAlpha,
    invalidPremultiplied,
    sampleFailure
}

private bool validSemantics(RgbaCompositeLayer layer)
@safe pure nothrow @nogc
{
    if (layer.association != RgbaAlphaAssociation.straight &&
        layer.association != RgbaAlphaAssociation.premultiplied)
        return false;

    if (layer.space == RgbaCompositeSpace.encodedSRgb)
        return layer.association == RgbaAlphaAssociation.straight;

    return layer.space == RgbaCompositeSpace.linearSRgb;
}

// Converts one pixel to the ONLY colour-d sourceOver input type,
// premultiplied linear-light RGB. No gamut mapping, clipping or encoding.
// This operation is called only after validating alpha and association.
private bool readPremultiplied(
    scope RgbaCompositeLayer layer, size_t x, size_t y,
    out Premultiplied!LinearSRgbd value
) @safe nothrow @nogc
{
    double r, g, b, a;
    if (!layer.pixels.trySample(0, x, y, r) ||
        !layer.pixels.trySample(1, x, y, g) ||
        !layer.pixels.trySample(2, x, y, b) ||
        !layer.pixels.trySample(3, x, y, a))
        return false;
    if (layer.association == RgbaAlphaAssociation.premultiplied)
    {
        value = Premultiplied!LinearSRgbd(LinearSRgbd(r, g, b), a);
    }
    else if (layer.space == RgbaCompositeSpace.encodedSRgb)
    {
        value = premultiply(Alpha!LinearSRgbd(
            SRgbd(r, g, b).toLinear, a));
    }
    else
    {
        value = premultiply(Alpha!LinearSRgbd(LinearSRgbd(r, g, b), a));
    }
    return true;
}

/++
    Composes FOREGROUND over BACKGROUND into linear-light premultiplied RGBA.

    All pixel mathematics and sRGB transfer use the *released* color-d:
    color.rgb.toLinear, color.alpha.premultiply, color.composite.sourceOver.
    The output is ALWAYS linearSRgb + premultiplied; caller owns four
    double-channel output planes and must retain both source leases.

    Samples, alpha and geometry are validated before any output is written;
    late destination sample failures are nontransactional. No hidden byte
    rounding, clipping, colour conversion to encoded output, layer opacity,
    fetching, caching, imageio, renderer, or buffer allocation occurs.
    Sources/destination should not overlap; overlap safety is NOT guaranteed.
    The output dimensions are precisely sourceRoi.width/height.
+/
RgbaCompositeError tryCompositeSourceOver(
    scope RgbaCompositeLayer foreground,
    scope RgbaCompositeLayer background,
    Region2D sourceRoi,
    scope WritableRasterView!double output
) @safe nothrow @nogc
{
    if (foreground.pixels.planeCount != 4 ||
        background.pixels.planeCount != 4 ||
        foreground.pixels.width == 0 ||
        foreground.pixels.height == 0 ||
        foreground.pixels.width != background.pixels.width ||
        foreground.pixels.height != background.pixels.height)
        return RgbaCompositeError.invalidImage;
    if (!validSemantics(foreground) || !validSemantics(background))
        return RgbaCompositeError.invalidColourSemantics;

    const width = foreground.pixels.width;
    const height = foreground.pixels.height;
    if (sourceRoi.width == 0 || sourceRoi.height == 0 ||
        sourceRoi.x > width || sourceRoi.y > height ||
        sourceRoi.width > width - sourceRoi.x ||
        sourceRoi.height > height - sourceRoi.y)
        return RgbaCompositeError.invalidRegion;

    if (output.planeCount != 4 ||
        output.width != sourceRoi.width ||
        output.height != sourceRoi.height)
        return RgbaCompositeError.destinationMismatch;

    // Preflight the entire requested image to avoid partial writes on
    // malformed alpha and noncanonical alpha=0 premultiplied input.
    foreach (y; sourceRoi.y .. sourceRoi.y + sourceRoi.height)
    foreach (x; sourceRoi.x .. sourceRoi.x + sourceRoi.width)
    {
        foreach (layerIndex; 0 .. 2)
        {
            const layer = layerIndex == 0 ? foreground : background;
            double alpha;
            if (!layer.pixels.trySample(3, x, y, alpha))
                return RgbaCompositeError.sampleFailure;
            if (!(alpha >= 0.0 && alpha <= 1.0))
                return RgbaCompositeError.invalidAlpha;

            if (layer.association == RgbaAlphaAssociation.premultiplied &&
                alpha == 0.0)
            {
                foreach (c; 0 .. 3)
                {
                    double component;
                    if (!layer.pixels.trySample(c, x, y, component))
                        return RgbaCompositeError.sampleFailure;
                    if (component != 0.0)
                        return RgbaCompositeError.invalidPremultiplied;
                }
            }
        }
    }

    foreach (y; 0 .. sourceRoi.height)
    foreach (x; 0 .. sourceRoi.width)
    {
        Premultiplied!LinearSRgbd fore, back;
        if (!readPremultiplied(
                foreground, sourceRoi.x + x, sourceRoi.y + y, fore) ||
            !readPremultiplied(
                background, sourceRoi.x + x, sourceRoi.y + y, back))
            return RgbaCompositeError.sampleFailure;

        const result = sourceOver(fore, back);
        if (!output.trySetSample(0, x, y, result.color.r) ||
            !output.trySetSample(1, x, y, result.color.g) ||
            !output.trySetSample(2, x, y, result.color.b) ||
            !output.trySetSample(3, x, y, result.alpha))
            return RgbaCompositeError.sampleFailure;
    }
    return RgbaCompositeError.none;
}
