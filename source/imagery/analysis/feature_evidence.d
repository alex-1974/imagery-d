/++ Explicitly aligned spectral features and region-level evidence. +/
module imagery.analysis.feature_evidence;

import imagery.analysis.feature_components : ComponentStatistics;
import imagery.analysis.feature_regions : ImageGridMetadata, ImageBandRole, ImageSourceMetadata, Sample, Source, sourceMetadata;
import raster.region : Region2D;
import std.algorithm : min, clamp;
import std.math : isFinite, PI;

@safe:

/++
 Identify a scalar spectral band; measured is the generic default.
+/
enum BandRole {
    /++ Generic measured band. +/
    measured,
    /++ Red band. +/
    red,
    /++ Green band. +/
    green,
    /++ Near-infrared band. +/
    nearInfrared }
/++
 Declare arbitrary measurements or bounded unit reflectance.
+/
enum BandDomain {
    /++ Finite scalar measurements in the declared unit. +/
    measurement,
    /++ Finite reflectance samples in [0,1]. +/
    unitReflectance }

/++
 Pair a scalar Source with its physical band role and numeric domain. `.init` has no usable source.
+/
struct SpectralBand
{
    /++
     Scalar source providing pixels, units and grid identity.
    +/
    Source source;
    /++
     Physical role, checked against explicitly declared source metadata.
    +/
    BandRole role;
    /++
     Numeric domain used to validate each sample.
    +/
    BandDomain domain;
}

/++
 Select a difference, ratio or role-validated normalized spectral response.
+/
enum SpectralFeature {
    /++ First band minus second band, in their common unit. +/
    difference,
    /++ First divided by second; zero denominator is invalid. +/
    ratio,
    /++ Normalized NIR-minus-red response; requires unit reflectance and these band roles. +/
    vegetationResponse,
    /++ Normalized green-minus-NIR response; requires unit reflectance and these band roles. +/
    waterResponse }

/++
 Read a spectral response with explicit validity. `.init` is invalid with value zero.
+/
struct SpectralValue
{
    /++
     Difference, ratio or normalized response; meaningful only when valid.
    +/
    double value = 0;
    /++
     True for a finite result with valid inputs and denominator/domain.
    +/
    bool valid;
}

/++
 Record the identity, sample domain and metadata of one input band.
+/
struct BandProvenance
{
    /++
     Source identity, revision, band identifier and scalar unit.
    +/
    string source, revision, band, unit;
    /++
     Physical input-band role.
    +/
    BandRole role;
    /++
     Input measurement/reflectance domain.
    +/
    BandDomain domain;
    /++
     Validated input sample and spatial facts.
    +/
    ImageSourceMetadata metadata;
}

/++
 Record the two aligned inputs, operation, output domain and pixel extent. `.init` does not identify a completed result.
+/
struct SpectralProvenance
{
    /++
     Input-band provenance in formula order.
    +/
    BandProvenance first, second;
    /++
     Common alignment grid identity.
    +/
    string grid;
    /++
     Common grid: level is its caller-selected identifier; width and height are full dimensions in pixels.
    +/
    size_t level, width, height;
    /++
     Source-pixel region represented by this tile.
    +/
    Region2D extent;
    /++
     Spectral formula used.
    +/
    SpectralFeature feature;
    /++
     Output scalar unit, or dimensionless for ratios/normalized differences.
    +/
    string outputUnit;
    /++
     Version of the spectral formula and validity contract.
    +/
    uint implementationVersion;
    /++
     Common spatial transform and spacing facts.
    +/
    ImageGridMetadata spatial;
    /++
     Canonical formula/domain description.
    +/
    string parameters;
    /++
     Nominal lower and upper output bounds.
    +/
    double minimum = -double.infinity, maximum = double.infinity;
}

/++
 Consume a tile of spectral values synchronously. Copy values to retain them; the slice is borrowed for this call only.
+/
alias SpectralSink = void delegate(Region2D, scope const(SpectralValue)[], SpectralProvenance) @safe;

private BandProvenance origin(const SpectralBand band)
{
    return BandProvenance(band.source.identity, band.source.revision, band.source.band,
        band.source.unit, band.role, band.domain, sourceMetadata(band.source));
}

private bool matchesRole(ImageBandRole declared, BandRole requested)
{
    if (declared == ImageBandRole.unspecified)
        return true;
    final switch (requested)
    {
        case BandRole.measured: return declared == ImageBandRole.measured;
        case BandRole.red: return declared == ImageBandRole.red;
        case BandRole.green: return declared == ImageBandRole.green;
        case BandRole.nearInfrared: return declared == ImageBandRole.nearInfrared;
    }
}

private bool samplesUsable(Sample sample, BandDomain domain)
{
    return sample.valid && isFinite(sample.scalar) &&
        (domain != BandDomain.unitReflectance || (sample.scalar >= 0 && sample.scalar <= 1));
}

/++
 Compute an explicit pairwise spectral response. Signed normalized
   differences describe spectral evidence in [-1, 1].

 Params:
  first = First input in formula or dependency order.
  second = Second input in formula or dependency order.
  region = Source-pixel rectangle to process.
  feature = Analytical operation to evaluate.
  edge = Tile edge in pixels, from 1 through 256.
  sink = Synchronous result consumer; copy borrowed value slices to retain them.

 Throws:
 Exception for Invalid aligned spectral request; Vegetation response requires NIR and red unit reflectance; Water response requires green and NIR unit reflectance.
+/
void spectralRegions(const SpectralBand first, const SpectralBand second, Region2D region,
    SpectralFeature feature, size_t edge, scope SpectralSink sink)
{
    const a = first.source;
    const b = second.source;
    const firstMetadata = sourceMetadata(a);
    const secondMetadata = sourceMetadata(b);
    if (a.rgb || b.rgb || a.read is null || b.read is null || !a.grid.length ||
        a.grid != b.grid || a.level != b.level || a.width != b.width ||
        a.height != b.height || firstMetadata.spatial != secondMetadata.spatial ||
        cast(uint)first.role > BandRole.max || cast(uint)second.role > BandRole.max ||
        !matchesRole(firstMetadata.role, first.role) || !matchesRole(secondMetadata.role, second.role) ||
        !a.band.length || !b.band.length ||
        !a.identity.length || !b.identity.length || !a.revision.length || !b.revision.length ||
        !a.unit.length || a.unit != b.unit || first.domain != second.domain ||
        (first.domain != BandDomain.measurement && first.domain != BandDomain.unitReflectance) ||
        region.empty || region.x > a.width || region.y > a.height ||
        region.width > a.width - region.x || region.height > a.height - region.y ||
        edge == 0 || edge > 256 || sink is null || cast(uint)feature > SpectralFeature.max)
        throw new Exception("Invalid aligned spectral request");

    if (feature == SpectralFeature.vegetationResponse &&
        (first.domain != BandDomain.unitReflectance ||
            first.role != BandRole.nearInfrared || second.role != BandRole.red))
        throw new Exception("Vegetation response requires NIR and red unit reflectance");
    if (feature == SpectralFeature.waterResponse &&
        (first.domain != BandDomain.unitReflectance ||
            first.role != BandRole.green || second.role != BandRole.nearInfrared))
        throw new Exception("Water response requires green and NIR unit reflectance");

    const capacity = min(edge, region.width) * min(edge, region.height);
    auto left = new Sample[capacity];
    auto right = new Sample[capacity];
    auto output = new SpectralValue[capacity];
    for (size_t y = 0; y < region.height;)
    {
        const height = min(edge, region.height - y);
        for (size_t x = 0; x < region.width;)
        {
            const width = min(edge, region.width - x);
            const tile = Region2D(region.x + x, region.y + y, width, height);
            const count = width * height;
            a.read(tile, left[0 .. count]);
            b.read(tile, right[0 .. count]);
            foreach (i, ref result; output[0 .. count])
            {
                result = SpectralValue.init;
                const one = left[i], two = right[i];
                if (!samplesUsable(one, first.domain) || !samplesUsable(two, second.domain))
                    continue;
                double value;
                final switch (feature)
                {
                    case SpectralFeature.difference:
                        value = one.scalar - two.scalar;
                        break;
                    case SpectralFeature.ratio:
                        if (!two.scalar)
                            continue;
                        value = one.scalar / two.scalar;
                        break;
                    case SpectralFeature.vegetationResponse, SpectralFeature.waterResponse:
                        const total = one.scalar + two.scalar;
                        if (!total)
                            continue;
                        value = (one.scalar - two.scalar) / total;
                        break;
                }
                if (isFinite(value))
                    result = SpectralValue(value, true);
            }
            auto provenance = SpectralProvenance(origin(first), origin(second),
                a.grid, a.level, a.width, a.height, tile, feature,
                feature == SpectralFeature.difference ? a.unit : "1", 1, firstMetadata.spatial,
                feature == SpectralFeature.difference ? "left-minus-right" :
                    feature == SpectralFeature.ratio ? "left-over-right;zero=invalid" :
                    "normalized-difference;zero=invalid");
            if (feature == SpectralFeature.vegetationResponse || feature == SpectralFeature.waterResponse ||
                (feature == SpectralFeature.difference && first.domain == BandDomain.unitReflectance))
            {
                provenance.minimum = -1;
                provenance.maximum = 1;
            }
            else if (feature == SpectralFeature.ratio && first.domain == BandDomain.unitReflectance)
                provenance.minimum = 0;
            sink(tile, output[0 .. count], provenance);
            x += width;
        }
        y += height;
    }
}

/++
 Read dimensionless shape and coverage evidence for a component. `.init` is invalid; these values are measurements rather than object memberships.
+/
struct RegionEvidence
{
    /++
     True when the component measurements support the evidence calculation.
    +/
    bool valid;
    /++
     Bounded shape compactness from area and perimeter.
    +/
    double compactness;
    /++
     Fraction of component pixels meeting the supplied edge threshold.
    +/
    double edgeCoverage;
    /++
     Fraction of component pixels meeting the supplied texture threshold.
    +/
    double textureCoverage;
}

/++
 Region footprint and input-coverage evidence. The perimeter is the
   component's four-connected pixel perimeter.

 Params:
  region = Final component measurements; zero area/perimeter yields an invalid result.

 Returns:
 Bounded compactness and finite-observation coverage fractions; invalid when area or perimeter is zero.
+/
RegionEvidence regionEvidence(const ComponentStatistics region)
{
    if (!region.pixels || !region.perimeter)
        return RegionEvidence.init;
    const perimeter = cast(double)region.perimeter;
    return RegionEvidence(true, clamp(4 * PI * region.pixels / (perimeter * perimeter), 0.0, 1.0),
        clamp(region.edgeSamples / cast(double)region.pixels, 0.0, 1.0),
        clamp(region.textureSamples / cast(double)region.pixels, 0.0, 1.0));
}

/// Measure compactness and finite-observation coverage of a component.
@safe unittest
{
    ComponentStatistics component;
    component.pixels=4; component.perimeter=8;
    component.edgeSamples=2; component.textureSamples=4;
    auto evidence=regionEvidence(component);
    assert(evidence.valid && evidence.edgeCoverage==0.5 && evidence.textureCoverage==1);
    assert(!regionEvidence(ComponentStatistics.init).valid);
}
