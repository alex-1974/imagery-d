/++ Explicitly aligned spectral features and region-level evidence. +/
module imagery.analysis.feature_evidence;

import imagery.analysis.feature_components : ComponentStatistics;
import imagery.analysis.feature_regions : Sample, Source;
import raster.region : Region2D;
import std.algorithm : min, clamp;
import std.math : isFinite, PI;

@safe:

enum BandRole { measured, red, green, nearInfrared }
enum BandDomain { measurement, unitReflectance }

struct SpectralBand
{
    Source source;
    BandRole role;
    BandDomain domain;
}

enum SpectralFeature { difference, ratio, vegetationResponse, waterResponse }

struct SpectralValue
{
    double value = 0;
    bool valid;
}

struct BandProvenance
{
    string source, revision, band, unit;
    BandRole role;
    BandDomain domain;
}

struct SpectralProvenance
{
    BandProvenance first, second;
    string grid;
    size_t level, width, height;
    Region2D extent;
    SpectralFeature feature;
    string outputUnit;
    uint implementationVersion;
}

alias SpectralSink = void delegate(Region2D, scope const(SpectralValue)[], SpectralProvenance) @safe;

private BandProvenance origin(const SpectralBand band)
{
    return BandProvenance(band.source.identity, band.source.revision, band.source.band,
        band.source.unit, band.role, band.domain);
}

private bool samplesUsable(Sample sample, BandDomain domain)
{
    return sample.valid && isFinite(sample.scalar) &&
        (domain != BandDomain.unitReflectance || (sample.scalar >= 0 && sample.scalar <= 1));
}

/// Compute an explicit pairwise spectral response. Signed normalized
/// differences describe spectral evidence in [-1, 1].
void spectralRegions(const SpectralBand first, const SpectralBand second, Region2D region,
    SpectralFeature feature, size_t edge, scope SpectralSink sink)
{
    const a = first.source;
    const b = second.source;
    if (a.rgb || b.rgb || a.read is null || b.read is null || !a.grid.length ||
        a.grid != b.grid || a.level != b.level || a.width != b.width ||
        a.height != b.height || !a.band.length || !b.band.length ||
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
            sink(tile, output[0 .. count], SpectralProvenance(origin(first), origin(second),
                a.grid, a.level, a.width, a.height, tile, feature,
                feature == SpectralFeature.difference ? a.unit : "1", 1));
            x += width;
        }
        y += height;
    }
}

struct RegionEvidence
{
    bool valid;
    double compactness;
    double edgeCoverage;
    double textureCoverage;
}

/// Region footprint and input-coverage evidence. The perimeter is the
/// component's four-connected pixel perimeter.
RegionEvidence regionEvidence(const ComponentStatistics region)
{
    if (!region.pixels || !region.perimeter)
        return RegionEvidence.init;
    const perimeter = cast(double)region.perimeter;
    return RegionEvidence(true, clamp(4 * PI * region.pixels / (perimeter * perimeter), 0.0, 1.0),
        clamp(region.edgeSamples / cast(double)region.pixels, 0.0, 1.0),
        clamp(region.textureSamples / cast(double)region.pixels, 0.0, 1.0));
}
