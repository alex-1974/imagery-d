/++
 R-IM-03a: general image-data tonal adjustment. RESEARCH ONLY.
 No satellite, STAC, spectrum, geographical projection or input-provenance
 formalities are known or required.

 Pixels, strides, layouts and lifetimes belong to raster-d. This
 prototype does NOT enforce physical non-aliasing of input and output;
 independently allocated owners are an experimental precondition.
+/
module imagery.presentation.levels_research;

import raster : RasterView, WritableRasterView, Region2D;
import std.math : pow;

/// Input thresholds and output limits are specified in the scalar channel
/// domain [0,1]. This is NOT an implicit sRGB or linear-light conversion.
struct ResearchLevels
{
    double inputBlack;
    double inputWhite;
    double gamma;
    double outputBlack;
    double outputWhite;
}

enum ResearchLevelsError : ubyte
{
    none,
    invalidSource,
    invalidRegion,
    invalidParameters,
    invalidChannelSelection,
    invalidMask,
    invalidDestination,
    sampleFailure
}

private bool finite(double x)
{
    return x >= -double.max && x <= double.max;
}

private bool contains(Region2D roi, size_t width, size_t height)
{
    return roi.width != 0 && roi.height != 0 &&
        roi.x <= width && roi.y <= height &&
        roi.width <= width - roi.x &&
        roi.height <= height - roi.y;
}

private double normalized(T)(T sample)
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    static if (is(T == ubyte))
        return cast(double)sample / 255.0;
    else static if (is(T == ushort))
        return cast(double)sample / 65535.0;
    else
        return cast(double)sample;
}

/++
 Apply selected-channel Levels and optional selection-opacity mask to
 **already provided image data**. All coordinates are image-local, never
 world/geographical coordinates. ROI source origin maps to (0,0) of the
 supplied ROI-sized output. The result is explicitly float normalized
 channel samples; integer inputs are first divided by their type maximum.

 For a selected finite channel value v:
     t = clamp((v - inputBlack) / (inputWhite - inputBlack), 0, 1)
     corrected = outputBlack
                 + pow(t, 1 / gamma) * (outputWhite - outputBlack)
     output = v + selectionOpacity * (corrected - v)

 "selectionOpacity" is mask/255, or 1 without a selection mask.
 Channels not explicitly selected are copied as normalized float values.
 NaN and positive/negative infinity float samples are copied unchanged even if selected:
 this is a deliberate numeric propagation rule, NOT implicit NoData,
 alpha or a replacement for a separate validity mask.

 This experiment does not assume RGB, channel order or alpha location.
 To leave alpha untouched, the *consumer* leaves that channel unselected.
 The consumer also declares whether scalar levels operate on encoded,
 linear-light, photographic, grayscale or other scalar data. No colour
 transfer conversion occurs here.

 A preflight rejection performs NO writes to the existing destination.
 Late sample/read/write failure may leave a partial destination, and
 physical overlap with input/mask is NOT rejected. In particular, do not
 admit this exact destination-writing research signature as a public API
 without resolving alias/publish-on-success semantics.

 No hidden whole-image materialization or per-pixel heap allocation is
 deliberately performed here; no total @nogc, malloc or RSS claim.
+/
ResearchLevelsError tryLevelsIntoResearch(T)(
    scope RasterView!T pixels,
    Region2D roi,
    scope const(bool)[] affected,
    ResearchLevels settings,
    scope RasterView!ubyte selection,
    bool hasSelection,
    scope WritableRasterView!float destination)
if (is(T == ubyte) || is(T == ushort) || is(T == float))
{
    if (pixels.planeCount == 0 || pixels.width == 0 ||
        pixels.height == 0)
        return ResearchLevelsError.invalidSource;

    if (!contains(roi, pixels.width, pixels.height))
        return ResearchLevelsError.invalidRegion;

    if (affected.length != pixels.planeCount)
        return ResearchLevelsError.invalidChannelSelection;

    if (!finite(settings.inputBlack) ||
        !finite(settings.inputWhite) ||
        !finite(settings.gamma) ||
        !finite(settings.outputBlack) ||
        !finite(settings.outputWhite) ||
        !(settings.inputBlack < settings.inputWhite) ||
        !(settings.gamma > 0.0) ||
        settings.outputBlack < 0.0 ||
        settings.outputWhite > 1.0 ||
        !(settings.outputBlack <= settings.outputWhite))
        return ResearchLevelsError.invalidParameters;

    if (hasSelection && (selection.planeCount != 1 ||
        selection.width != pixels.width ||
        selection.height != pixels.height))
        return ResearchLevelsError.invalidMask;

    if (destination.planeCount != pixels.planeCount ||
        destination.width != roi.width ||
        destination.height != roi.height)
        return ResearchLevelsError.invalidDestination;

    const span = settings.inputWhite - settings.inputBlack;
    const inverseGamma = 1.0 / settings.gamma;
    const outputSpan = settings.outputWhite - settings.outputBlack;

    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        double strength = 1.0;
        if (hasSelection)
        {
            ubyte coverage;
            if (!selection.trySample(0, x, y, coverage))
                return ResearchLevelsError.sampleFailure;
            strength = cast(double)coverage / 255.0;
        }
        foreach (channel; 0 .. pixels.planeCount)
        {
            T raw;
            if (!pixels.trySample(channel, x, y, raw))
                return ResearchLevelsError.sampleFailure;

            const original = normalized(raw);
            double result = original;
            if (affected[channel] && strength != 0.0 &&
                finite(original))
            {
                double t = (original - settings.inputBlack) / span;
                if (t < 0.0) t = 0.0;
                if (t > 1.0) t = 1.0;
                const mapped = settings.outputBlack +
                    pow(t, inverseGamma) * outputSpan;
                result = original + strength * (mapped - original);
            }
            if (!destination.trySetSample(
                    channel, x - roi.x, y - roi.y, cast(float)result))
                return ResearchLevelsError.sampleFailure;
        }
    }

    return ResearchLevelsError.none;
}
