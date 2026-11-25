/++
Measure excess green and red/green chromaticities in RGB8 images. Call
`rgbIndices` with an explicit encoded or linear `RgbIndexDomain`. Inspect
`chromaticityValid` before using chromaticity values for black pixels.
+/
module imagery.analysis.colour_indices;

import color.rgb : SRgbd, toLinear;
import std.math : isFinite;

@safe:

/// Domain in which the formula is evaluated. Input is always encoded sRGB8.
enum RgbIndexDomain {
    /++ Evaluate the formula on sRGB bytes divided by 255, without transfer decoding. +/
    encoded,
    /++ Decode sRGB transfer before evaluating the formula. +/
    linear }

/// Independent validity for a black pixel, whose chromaticity is undefined.
struct RgbIndices
{
    /// Excess green 2G-R-B in the selected domain; range [-2,2].
    double excessGreen;
    /// Red chromaticity R/(R+G+B) in the selected encoded or linear domain.
    double r;
    /// Green chromaticity G/(R+G+B) in the selected encoded or linear domain.
    double g;
    /// False for black. Excess green remains a valid zero for black.
    bool chromaticityValid;
}

/++
 Compute excess green and normalized red/green chromaticities from RGB8.

   Use these as photographic color measurements, without inferring spectral
   band roles or object classes. Excess green is 2G-R-B in [-2,2]. Chromaticities
   are R/(R+G+B) and G/(R+G+B). Black has zero excess green and undefined
   chromaticities, indicated by chromaticityValid=false. The required domain
   chooses byte normalization alone or sRGB transfer decoding.

 Params:
  rgb = Encoded sRGB8 input; no physical spectral-band roles are inferred.
  domain = Explicit encoded versus linear formula domain.

 Returns:
 Excess green and red/green chromaticities with an independent black-pixel chromaticity flag.

 Throws:
 Exception if domain is not a declared RgbIndexDomain value.
+/
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
