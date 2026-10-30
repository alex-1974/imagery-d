/++
 Normalized image-domain brightness and contrast mapping.

 This module defines the numeric contract independently of raster layout:
 `brightness` shifts normalized values by [-1, 1], while `contrast` scales
 around the midpoint and must be finite. Values are clipped to [0, 1].
 It performs no colour conversion, alpha inference or NoData handling.
+/
module imagery.presentation.brightness_contrast;

import std.math : isFinite;

struct BrightnessContrast
{
    double brightness;
    double contrast;
}

enum BrightnessContrastError : ubyte
{
    none,
    invalidParameters,
    nonFiniteSample
}

bool valid(BrightnessContrast settings)
@safe pure nothrow @nogc
{
    return isFinite(settings.brightness) && isFinite(settings.contrast) &&
        settings.brightness >= -1.0 && settings.brightness <= 1.0 &&
        settings.contrast >= -1.0;
}

BrightnessContrastError tryMapNormalized(
    double input,
    BrightnessContrast settings,
    out double output)
@safe pure nothrow @nogc
{
    if (!valid(settings))
        return BrightnessContrastError.invalidParameters;
    if (!isFinite(input))
        return BrightnessContrastError.nonFiniteSample;

    double mapped = (input - 0.5) * (1.0 + settings.contrast) +
        0.5 + settings.brightness;
    if (mapped < 0.0)
        mapped = 0.0;
    else if (mapped > 1.0)
        mapped = 1.0;
    output = mapped;
    return BrightnessContrastError.none;
}

unittest
{
    double output;
    assert(tryMapNormalized(0.25, BrightnessContrast(0, 0), output) ==
        BrightnessContrastError.none);
    assert(output == 0.25);
    assert(tryMapNormalized(0.25, BrightnessContrast(0.1, 0), output) ==
        BrightnessContrastError.none);
    assert(output == 0.35);
    assert(tryMapNormalized(0.25, BrightnessContrast(0, 1), output) ==
        BrightnessContrastError.none);
    assert(output == 0.0);
    assert(tryMapNormalized(double.nan, BrightnessContrast(0, 0), output) ==
        BrightnessContrastError.nonFiniteSample);
    assert(!valid(BrightnessContrast(double.nan, 0)));
}
