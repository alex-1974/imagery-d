/++ Explicit RGB indices for photographic and scientific consumers. +/
module imagery.analysis.colour_indices;

import color.rgb : SRgbd, toLinear;
import std.math : isFinite;

@safe:

/// Domain in which the formula is evaluated. Input is always encoded sRGB8.
enum RgbIndexDomain { encoded, linear }

/// Independent validity for a black pixel, whose chromaticity is undefined.
struct RgbIndices
{
    /// Excess green 2G-R-B in the selected domain; range [-2,2].
    double excessGreen;
    /// R/(R+G+B), G/(R+G+B) in the selected domain.
    double r, g;
    /// False for black. Excess green remains a valid zero for black.
    bool chromaticityValid;
}

/// Compute colour indices with a required evaluation domain. No band roles
/// are inferred. An invalid enum throws before computation.
RgbIndices rgbIndices(ubyte[3] rgb, RgbIndexDomain domain)
{
    if (cast(uint)domain > RgbIndexDomain.max)
        throw new Exception("Invalid RGB index domain");
    double r = rgb[0]/255.0, g = rgb[1]/255.0, b = rgb[2]/255.0;
    if (domain == RgbIndexDomain.linear)
    {
        const linear = SRgbd(r,g,b).toLinear;
        r = linear.r; g = linear.g; b = linear.b;
    }
    const total = r+g+b;
    return RgbIndices(2*g-r-b, total > 0 ? r/total : 0,
        total > 0 ? g/total : 0, total > 0);
}

/// Green, neutral and black have explicit analytic results.
unittest
{
    foreach (domain; [RgbIndexDomain.encoded, RgbIndexDomain.linear])
    {
        const green = rgbIndices([0,255,0],domain);
        assert(green.excessGreen == 2 && green.r == 0 && green.g == 1);
        const neutral = rgbIndices([128,128,128],domain);
        assert(neutral.excessGreen == 0 && neutral.r == neutral.g);
        const black = rgbIndices([0,0,0],domain);
        assert(black.excessGreen == 0 && !black.chromaticityValid);
    }
    assert(rgbIndices([64,128,32],RgbIndexDomain.linear).g !=
        rgbIndices([64,128,32],RgbIndexDomain.encoded).g);
}
