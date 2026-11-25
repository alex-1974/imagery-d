/++
Choose window sizes, line scales and other feature settings. Pass the matching
parameter type to an `Engine` request, or combine families with
`FeatureViewParams`. Read each type's default-state contract before using
`.init` as a request.
+/
module imagery.analysis.feature_parameters;

@safe:

import std.math : isFinite, PI, ceil;
import std.traits : Unqual;

package enum isTileFeatureParameter(T) = is(Unqual!T==LocalStatisticsParams) ||
    is(Unqual!T==PathMorphologyParams) || is(Unqual!T==RidgeParams) ||
    is(Unqual!T==LineResponseParams) || is(Unqual!T==GaborParams) || is(Unqual!T==ShadowParams);

/// Square population-moment window. The defaults reproduce the fixed M6
/// contract. Radius is in pixels, 1..31. minimumValid is in 1..window area.
struct LocalStatisticsParams
{
    /++
     Neighborhood radius in pixels; support width is 2*radius+1.
    +/
    uint radius = 3;
    /++
     Minimum number of usable support positions for a valid output.
    +/
    uint minimumValid = 25;
/++
     Validate before reads, allocation, cache lookup or publication.

     Throws:
     Exception for Invalid local statistics parameters.
    +/
    void validate() const
    {
        if (radius<1 || radius>31 || minimumValid<1 || minimumValid>(2*radius+1)^^2)
            throw new Exception("Invalid local statistics parameters");
    }
}

/// Axis-monotonic paths through the center; length 1..31, lateral step 0..2.
/// All scales are in pixels of the selected source grid.
struct PathMorphologyParams
{
    /++
     Required monotone path length in pixels.
    +/
    uint length = 7;
    /++
     Maximum lateral displacement between successive path positions.
    +/
    uint lateralStep = 1;
    /++
     Validate this parameter value before allocating or evaluating image data.

     Throws:
     Exception if a field lies outside its documented range or selects an unknown enum value.
    +/
    void validate() const
    {
        if (!length || length>31 || lateralStep>2)
            throw new Exception("Invalid path morphology parameters");
    }
}

/// Positive opposite-side contrast over consecutive pixel radii, 1..31.
/// `.init` selects radii 1, 2 and 3. validate throws Exception on invalid input.
struct RidgeParams
{
    /// First across-line radius in pixels, included in the search.
    uint firstRadius = 1;
    /// Last across-line radius in pixels, included in the search.
    uint lastRadius = 3;
/++
     Throw Exception unless 1 <= firstRadius <= lastRadius <= 31.

     Throws:
     Exception for Invalid ridge parameters.
    +/
    void validate() const
    {
        if (!firstRadius || firstRadius > lastRadius || lastRadius > 31)
            throw new Exception("Invalid ridge parameters");
    }
}

/// Select a bounded band of across-line scales.
unittest
{
    import std.exception : assertThrown;
    auto parameters = RidgeParams(2, 7);
    parameters.validate();
    assertThrown!Exception(RidgeParams(4, 3).validate());
}

/// Ridge contrast reduced by minimum along a tangent segment. `.init` uses
/// three tangent positions. alongRadius is in 0..31 pixels; halo is its sum
/// with across.lastRadius. Validation throws Exception before source reads.
struct LineResponseParams
{
    /// Opposite-side radii, in pixels.
    RidgeParams across;
    /// Tangent half-length, in pixels; zero reduces to ridge contrast.
    uint alongRadius = 1;
/++
     Throw Exception for invalid across radii or alongRadius > 31.

     Throws:
     Exception for Invalid line response parameters.
    +/
    void validate() const
    {
        across.validate();
        if (alongRadius > 31)
            throw new Exception("Invalid line response parameters");
    }
}

/// Vary across-line and along-line support independently.
unittest
{
    import std.exception : assertThrown;
    auto parameters = LineResponseParams(RidgeParams(2, 5), 3);
    parameters.validate();
    assertThrown!Exception(LineResponseParams(RidgeParams.init, 32).validate());
}

/// Two-scale, four-angle quadrature bank; `.init` is the original Gabor bank.
/// Wavelengths are increasing pixel lengths in [0.5,16], angles are increasing
/// axial radians from zero inclusive to pi exclusive, sigma/wavelength is in
/// [0.125,2], and square support
/// is ceil(wavelength*supportRatio), at most 32 pixels. The individually named
/// fine/coarse features select the corresponding position in this bank.
/// Validation throws Exception before preparation or source reads.
struct GaborParams
{
    /// Increasing wavelengths in pixels; bank order defines deterministic ties.
    double[2] wavelengths = [2.0, 4.0];
    /// Increasing axial normal angles in radians.
    double[4] angles = [0.0, PI/4, PI/2, 3*PI/4];
    /// Gaussian standard deviation divided by wavelength.
    double sigmaRatio = 0.5;
    /// Square support half-width divided by wavelength, rounded up to pixels.
    double supportRatio = 1.0;
/++
     Throw Exception for nonfinite, unordered or out-of-range settings.

     Throws:
     Exception for Invalid Gabor wavelengths; Invalid Gabor angles; Invalid Gabor envelope or support.
    +/
    void validate() const
    {
        foreach (i, wavelength; wavelengths)
            if (!isFinite(wavelength) || wavelength < 0.5 || wavelength > 16 ||
                (i && wavelength <= wavelengths[i-1]))
                throw new Exception("Invalid Gabor wavelengths");
        foreach (i, angle; angles)
            if (!isFinite(angle) || angle < 0 || angle >= PI ||
                (i && angle <= angles[i-1]))
                throw new Exception("Invalid Gabor angles");
        if (!isFinite(sigmaRatio) || sigmaRatio < 0.125 || sigmaRatio > 2 ||
            !isFinite(supportRatio) || supportRatio <= 0 ||
            ceil(wavelengths[1]*supportRatio) > 32 || ceil(wavelengths[0]*supportRatio) < 1)
            throw new Exception("Invalid Gabor envelope or support");
    }
}

/// Prepare a bank at fractional pixel scales.
unittest
{
    import std.exception : assertThrown;
    auto parameters = GaborParams.init;
    parameters.wavelengths = [1.5, 5.25];
    parameters.sigmaRatio = 0.7;
    parameters.validate();
    parameters.angles[1] = double.nan;
    assertThrown!Exception(parameters.validate());
}

/// Relative darkness multiplied by a linear-luminance ceiling ramp. `.init`
/// preserves the 7x7 window and 0.15 ceiling. Ceiling is dimensionless,
/// greater than zero and at most one.
/// This feature accepts RGB8 only. validate throws Exception on invalid input.
struct ShadowParams
{
    /// Local population moments and minimum valid sample count.
    LocalStatisticsParams window;
    /// Dimensionless linear-luminance ceiling, greater than zero and at most one.
    double luminanceCeiling = 0.15;
/++
     Throw Exception for an invalid window or luminance ceiling.

     Throws:
     Exception for Invalid shadow luminance ceiling.
    +/
    void validate() const
    {
        window.validate();
        if (!isFinite(luminanceCeiling) || luminanceCeiling <= 0 || luminanceCeiling > 1)
            throw new Exception("Invalid shadow luminance ceiling");
    }
}

/// Tune a heuristic score on linear luminance rather than encoded RGB bytes.
unittest
{
    import std.exception : assertThrown;
    auto parameters = ShadowParams(LocalStatisticsParams(2, 11), 0.27);
    parameters.validate();
    assertThrown!Exception(ShadowParams(LocalStatisticsParams.init, 0).validate());
}

/// Source-anchored square CLAHE cells. `.init` preserves 32x32 cells and a
/// clip factor of two. Cell edge is an even pixel count in [8,128]; clipFactor
/// is finite, greater than zero and at most 256. Histogram bins remain 256.
/// Validation throws Exception.
struct ClaheParams
{
    /// Even square cell edge in source pixels, from 8 through 128.
    uint cellEdge = 32;
    /// Bin cap multiplier relative to validCount/256, from zero exclusive to 256.
    double clipFactor = 2;
/++
     Throw Exception for invalid geometry or a nonfinite/out-of-range factor.

     Throws:
     Exception for Invalid CLAHE parameters.
    +/
    void validate() const
    {
        if (cellEdge < 8 || cellEdge > 128 || cellEdge % 2 ||
            !isFinite(clipFactor) || clipFactor <= 0 || clipFactor > 256)
            throw new Exception("Invalid CLAHE parameters");
    }
}

/// Preserve the source grid while changing local histogram support.
unittest
{
    import std.exception : assertThrown;
    auto parameters = ClaheParams(18, 3.5);
    parameters.validate();
    assertThrown!Exception(ClaheParams(9, 2).validate());
}

/// Independent tiled families for one shared-input view. `.init` reproduces
/// all existing defaults. Local statistics, normalization, range, darkness and
/// shadow share `statistics`, including their moment dependencies. Other
/// families are independent; scales are working-grid pixels. CLAHE and fitted
/// global operations keep their dedicated interfaces. This value is freely
/// copyable and owns no input, cache or scratch.
struct FeatureViewParams
{
    /// Common square window for every local-moment feature in this view.
    LocalStatisticsParams statistics;
    /// Axis-monotonic path length and lateral step.
    PathMorphologyParams paths;
    /// Opposite-side ridge radii.
    RidgeParams ridge;
    /// Across-line and along-line response support.
    LineResponseParams line;
    /// Two-scale, four-angle quadrature bank.
    GaborParams gabor;
    /// Shadow ceiling in dimensionless linear luminance greater than zero and at most one.
    double shadowLuminanceCeiling = .15;

/++
     Validate the complete value, including unused families, before reads,
     allocation, cache lookup or publication. Throws Exception on failure.

     Throws:
     Exception if any contained parameter family or the shadow ceiling is invalid, including unused families.
    +/
    void validate() const
    {
        statistics.validate();paths.validate();ridge.validate();line.validate();gabor.validate();
        ShadowParams(statistics,shadowLuminanceCeiling).validate();
    }
}

/// Configure distinct families while retaining one explicit moment window.
unittest
{
    import std.exception : assertThrown;
    FeatureViewParams parameters;
    parameters.statistics=LocalStatisticsParams(5,40);
    parameters.ridge=RidgeParams(2,7);
    parameters.gabor.wavelengths=[1.5,3.5];
    parameters.validate();
    parameters.shadowLuminanceCeiling=double.nan;
    assertThrown!Exception(parameters.validate());
}

/// Default values remain explicit and validate without hidden unit conversion.
unittest
{
    LocalStatisticsParams.init.validate();
    PathMorphologyParams.init.validate();
    RidgeParams.init.validate();
    LineResponseParams.init.validate();
    GaborParams.init.validate();
    ShadowParams.init.validate();
    ClaheParams.init.validate();
    FeatureViewParams.init.validate();
}
