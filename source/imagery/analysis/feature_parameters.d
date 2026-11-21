/++ Typed parameters for variable-window feature requests. +/
module imagery.analysis.feature_parameters;

@safe:

/// Square population-moment window. The defaults reproduce the fixed M6
/// contract. Radius is in pixels, 1..31. minimumValid is in 1..window area.
struct LocalStatisticsParams
{
    uint radius = 3;
    uint minimumValid = 25;
    /// Validate before reads, allocation, cache lookup or publication.
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
    uint length = 7;
    uint lateralStep = 1;
    void validate() const
    {
        if (!length || length>31 || lateralStep>2)
            throw new Exception("Invalid path morphology parameters");
    }
}

/// Default values remain explicit and validate without hidden unit conversion.
unittest
{
    LocalStatisticsParams.init.validate();
    PathMorphologyParams.init.validate();
}
