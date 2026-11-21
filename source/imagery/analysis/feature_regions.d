/++
 Synchronous region processing for explicitly encoded RGB8 and scalar images.
 Import this module directly to use the feature-region contract.
+/
module imagery.analysis.feature_regions;

import color.oklab : toOklab;
import color.rgb : SRgbd, toLinear;
import color.xyz : toXyzD65;
import raster.region : Region2D;
public import imagery.analysis.feature_contracts :
    FeatureAccess, FeatureCost, FeatureStorage, FeatureUnit, FeatureChannel;
import imagery.analysis.feature_contracts : fixedParameters, describeChannels, featureValidity;
import imagery.analysis.feature_structure : evaluateStructure, structureHalo, structureRequiresRgb,
    squareMorphologyRadius, evaluateSquareMorphology;
import std.algorithm : clamp, min, max;
import std.math : atan2, exp, isFinite, sqrt;
public import imagery.analysis.feature_parameters : LocalStatisticsParams, PathMorphologyParams;

@safe:

enum Feature
{
    luminance, oklab, localStatistics, gradient, distribution, normalizedLuminance,
    localNormalization, gaussian, box, median, bilateral, laplacian,
    clipping, underexposure, sharpness, noise, dynamicRange,
    exposureMatched, clahe, diffusion,
    entropy, localBinaryPattern, cooccurrence, edgeDensity, directedEdges, orientationHistogram,
    gabor, ridge, lineResponse,
    erosion, dilation, opening, closing, topHat, bottomHat, pathOpening, pathClosing,
    openingProfile, closingProfile, relativeDarkness, shadowCandidate, visibility, edgeEvidence,
    gaborFine0, gaborFine45, gaborFine90, gaborFine135,
    gaborCoarse0, gaborCoarse45, gaborCoarse90, gaborCoarse135,
    directedOpening, directedClosing
}

struct Sample
{
    double scalar;
    ubyte[3] rgb;
    bool valid;
}

struct Value
{
    double[3] channels = [0, 0, 0];
    bool valid;
    bool orientationValid;
}

enum ImageEncoding : ubyte { legacy, scalar, sRgb8 }
enum ImageBandRole : ubyte { unspecified, measured, red, green, blue, nearInfrared }

/// Pixel-corner affine [x0, dx, rx, y0, ry, dy] and optional pixel spacing.
struct ImageGridMetadata
{
    string crs;
    bool hasAffine;
    double[6] affine = [0, 0, 0, 0, 0, 0];
    double pixelSizeX = 0, pixelSizeY = 0;
    string pixelUnit;
}

/// Derivation metadata for a resampled grid. The parent grid may itself be
/// derived. The effective output spacing and affine are in spatial.
struct ImageResamplingMetadata
{
    string policy;
    string parentGrid;
    size_t parentLevel, parentWidth, parentHeight;
}

/// Optional facts from the producer. Acquisition time is a caller-supplied
/// ISO 8601 timestamp. A band number is one-based when present.
struct ImageProductMetadata
{
    string provider, sensor, acquisitionTime;
    uint bandNumber;
    bool hasScalarRange;
    double scalarMinimum = 0, scalarMaximum = 0;
}

struct ImageSourceMetadata
{
    ImageEncoding encoding;
    ImageBandRole role;
    ImageGridMetadata spatial;
    ImageResamplingMetadata resampling;
    ImageProductMetadata product;
}

struct Source
{
    string identity, revision, grid, band, unit;
    size_t level, width, height;
    bool rgb;
    /// Fill the supplied row-major buffer synchronously. Throw on read failure.
    void delegate(Region2D, scope Sample[]) @safe read;
    ImageSourceMetadata metadata;
}

package ImageSourceMetadata sourceMetadata(const Source source)
{
    ImageSourceMetadata metadata = source.metadata;
    if (metadata.encoding == ImageEncoding.legacy)
        metadata.encoding = source.rgb ? ImageEncoding.sRgb8 : ImageEncoding.scalar;
    if (metadata.encoding != (source.rgb ? ImageEncoding.sRgb8 : ImageEncoding.scalar) ||
        metadata.role > ImageBandRole.max || (source.rgb && metadata.role != ImageBandRole.unspecified))
        throw new Exception("Source encoding or band role conflicts with its sample model");

    const product = metadata.product;
    if (product.hasScalarRange && (source.rgb || !isFinite(product.scalarMinimum) ||
        !isFinite(product.scalarMaximum) || product.scalarMinimum > product.scalarMaximum))
        throw new Exception("Invalid declared scalar range");
    if (!product.hasScalarRange)
    {
        metadata.product.scalarMinimum = 0;
        metadata.product.scalarMaximum = 0;
    }
    const grid = metadata.spatial;
    if (!isFinite(grid.pixelSizeX) || !isFinite(grid.pixelSizeY) ||
        ((grid.pixelSizeX != 0 || grid.pixelSizeY != 0) &&
            (grid.pixelSizeX <= 0 || grid.pixelSizeY <= 0 || !grid.pixelUnit.length)))
        throw new Exception("Invalid physical pixel spacing");
    if (grid.hasAffine)
    {
        foreach (coefficient; grid.affine)
            if (!isFinite(coefficient))
                throw new Exception("Invalid source affine");
        const determinant = grid.affine[1] * grid.affine[5] - grid.affine[2] * grid.affine[4];
        if (!isFinite(determinant) || determinant == 0)
            throw new Exception("Degenerate source affine");
    }
    else
        metadata.spatial.affine[] = 0;
    return metadata;
}

private void validate(const Source source, Region2D region)
{
    if (source.read is null || region.empty ||
        region.x > source.width || region.width > source.width - region.x ||
        region.y > source.height || region.height > source.height - region.y)
        throw new Exception("Invalid source or region");
    sourceMetadata(source);
}

private auto linearColor(Sample sample)
{
    return SRgbd(sample.rgb[0] / 255.0, sample.rgb[1] / 255.0,
        sample.rgb[2] / 255.0).toLinear;
}

private double scalar(Sample sample, bool rgb)
{
    if (!rgb)
        return sample.scalar;
    const linear = linearColor(sample);
    return 0.2126 * linear.r + 0.7152 * linear.g + 0.0722 * linear.b;
}

package struct Point
{
    double value;
    bool valid;
}

private size_t offset(size_t position, int delta, size_t length)
{
    if (delta < 0)
        return position - min(position, cast(size_t)(-delta));
    return position + min(length - 1 - position, cast(size_t)delta);
}

// Statically dispatched sampling over an already populated halo. Unlike a
// delegate, opCall can be inlined into every tap of the kernel.
private struct TileReader
{
    const(Point)[] points;
    size_t x, y, sourceWidth, sourceHeight, windowX, windowY, stride;
    this(const(Point)[] data, size_t px, size_t py, size_t w, size_t h,
        size_t wx, size_t wy, size_t rowStride)
    {
        points=data; x=px; y=py; sourceWidth=w; sourceHeight=h;
        windowX=wx; windowY=wy; stride=rowStride;
    }
    Point opCall(int dx, int dy) const
    {
        const sx = offset(x, dx, sourceWidth) - windowX;
        const sy = offset(y, dy, sourceHeight) - windowY;
        return points[sy * stride + sx];
    }
}

private bool usesLocalMoments(Feature feature)
{
    return feature == Feature.localNormalization || feature == Feature.relativeDarkness ||
        feature == Feature.shadowCandidate;
}

private Value fromLocalMoments(Feature feature, double center, double mean, double deviation)
{
    double response;
    if (feature == Feature.localNormalization)
        response = deviation == 0 ? 0 : (center - mean) / deviation;
    else
    {
        const relative = mean == 0 ? 0 : clamp((mean - center) / mean, 0.0, 1.0);
        response = feature == Feature.relativeDarkness ? relative :
            relative * clamp((0.15 - center) / 0.15, 0.0, 1.0);
    }
    return Value([response, 0, 0], isFinite(response), false);
}

private Value evaluate(Read)(Feature feature, bool rgb, Sample center,
    scope Read sample, LocalStatisticsParams statistics = LocalStatisticsParams.init,
    PathMorphologyParams paths = PathMorphologyParams.init)
{
    Value result;
    if (!center.valid)
        return result;

    final switch (feature)
    {
        case Feature.exposureMatched:
        case Feature.clahe:
        case Feature.normalizedLuminance:
            assert(0, "Use normalizeLuminance() with a fitted profile");
        case Feature.distribution:
            assert(0, "Use distribution() for aggregate output");
        case Feature.oklab:
            const color = linearColor(center).toXyzD65.toOklab;
            result.channels = [color.l, color.a, color.b];
            result.valid = true;
            break;
        case Feature.luminance:
            const point = sample(0, 0);
            result.channels[0] = point.value;
            result.valid = point.valid;
            break;
        case Feature.clipping:
        case Feature.underexposure:
            result.channels[0] = feature == Feature.clipping
                ? (center.rgb[0] == 255 || center.rgb[1] == 255 || center.rgb[2] == 255)
                : sample(0, 0).value <= 0.01;
            result.valid = true;
            break;
        case Feature.localNormalization:
        case Feature.dynamicRange:
        case Feature.relativeDarkness:
        case Feature.shadowCandidate:
        case Feature.localStatistics:
            if (!sample(0, 0).valid)
                return result;
            size_t count;
            double mean = 0, squared = 0, low = double.infinity, high = -double.infinity;
            const radius = cast(int)statistics.radius;
            foreach (dy; -radius .. radius+1)
                foreach (dx; -radius .. radius+1)
                {
                    const point = sample(dx, dy);
                    if (!point.valid)
                        continue;
                    low = min(low, point.value);
                    high = max(high, point.value);
                    const delta = point.value - mean;
                    mean += delta / ++count;
                    squared += delta * (point.value - mean);
                }
            if (count >= statistics.minimumValid && isFinite(mean) && isFinite(squared))
            {
                const deviation = sqrt(max(0.0, squared / count));
                if (usesLocalMoments(feature))
                    return fromLocalMoments(feature, sample(0, 0).value, mean, deviation);
                if (feature == Feature.dynamicRange)
                    result.channels[0] = high - low;
                else
                    result.channels = [mean, deviation, 0];
                result.valid = isFinite(result.channels[0]);
            }
            break;
        case Feature.gaussian:
        case Feature.box:
        case Feature.median:
        case Feature.bilateral:
        case Feature.noise:
            return filter3x3(feature, sample);
        case Feature.laplacian:
        case Feature.diffusion:
        case Feature.sharpness:
            const c = sample(0, 0);
            if (!c.valid)
                return result;
            double response = 0;
            foreach (axis; 0 .. 2)
                foreach (step; [-1, 1])
                {
                    const neighbor = sample(axis == 0 ? step : 0, axis == 1 ? step : 0);
                    if (!neighbor.valid)
                        return result;
                    const delta = neighbor.value - c.value;
                    if (feature == Feature.diffusion)
                        response += delta * exp(-((delta / 0.1) ^^ 2));
                    else
                        response += delta;
                }
            if (feature == Feature.diffusion)
                result.channels[0] = c.value + 0.2 * response;
            else
                result.channels[0] = feature == Feature.sharpness ? absValue(response) : response;
            result.valid = isFinite(response);
            break;
        case Feature.visibility:
            const value = sample(0, 0).value;
            const saturated = center.rgb[0] == 255 || center.rgb[1] == 255 || center.rgb[2] == 255;
            result.channels[0] = saturated ? 0.0 : clamp(value / 0.05, 0.0, 1.0);
            result.valid = true;
            break;
        case Feature.entropy, Feature.localBinaryPattern, Feature.cooccurrence,
             Feature.edgeDensity, Feature.directedEdges, Feature.orientationHistogram,
             Feature.gabor, Feature.ridge, Feature.lineResponse, Feature.erosion, Feature.dilation,
             Feature.opening, Feature.closing, Feature.topHat, Feature.bottomHat, Feature.pathOpening,
             Feature.pathClosing, Feature.openingProfile, Feature.closingProfile,
             Feature.gaborFine0, Feature.gaborFine45, Feature.gaborFine90, Feature.gaborFine135,
             Feature.gaborCoarse0, Feature.gaborCoarse45, Feature.gaborCoarse90, Feature.gaborCoarse135,
             Feature.directedOpening, Feature.directedClosing:
            return evaluateStructure(feature, sample, paths);
        case Feature.edgeEvidence:
        case Feature.gradient:
            const origin = sample(0, 0).value;
            double gx = 0, gy = 0;
            foreach (dy; -1 .. 2)
                foreach (dx; -1 .. 2)
                {
                    const point = sample(dx, dy);
                    if (!point.valid)
                        return result;
                    gx += (point.value - origin) * (dx * (dy == 0 ? 0.25 : 0.125));
                    gy += (point.value - origin) * (dy * (dx == 0 ? 0.25 : 0.125));
                }
            if (!isFinite(gx) || !isFinite(gy))
                return result;
            const scale = max(absValue(gx), absValue(gy));
            if (scale == 0)
            {
                result.valid = true;
                return result;
            }
            const magnitude = scale * sqrt((gx / scale) ^^ 2 + (gy / scale) ^^ 2);
            if (isFinite(magnitude))
            {
                if (feature == Feature.edgeEvidence)
                    result.channels[0] = clamp(magnitude / 0.125, 0.0, 1.0);
                else
                {
                    result.channels = [magnitude, atan2(gy, gx), 0];
                    result.orientationValid = true;
                }
                result.valid = true;
            }
            break;
    }
    return result;
}

// Median absolute residual and bilateral smoothing share the same 3×3 stencil.
private Value filter3x3(Read)(Feature feature, scope Read sample)
{
    const center = sample(0, 0);
    Value result;
    if (!center.valid)
        return result;
    double[9] values;
    size_t count;
    double mean = 0, weight = 0;
    foreach (dy; -1 .. 2)
        foreach (dx; -1 .. 2)
        {
            const point = sample(dx, dy);
            if (!point.valid)
                continue;
            values[count++] = point.value;
            double w = feature == Feature.box ? 1 :
                (dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1);
            if (feature == Feature.bilateral)
                w *= exp(-0.5 * ((point.value - center.value) / 0.1) ^^ 2);
            if (w > 0)
            {
                weight += w;
                mean += (w / weight) * (point.value - mean);
            }
        }
    if (count < 5)
        return result;
    if (feature == Feature.median || feature == Feature.noise)
    {
        if (feature == Feature.noise)
        {
            const median = medianOf(values[0 .. count]);
            if (!isFinite(median))
                return result;
            foreach (ref value; values[0 .. count])
                value = absValue(value - median);
        }
        mean = medianOf(values[0 .. count]);
    }
    result.channels[0] = mean;
    result.valid = isFinite(mean);
    return result;
}

private double medianOf(scope double[] values)
{
    import std.algorithm : sort;
    sort(values);
    const mid = values.length / 2;
    return values.length % 2 ? values[mid] : 0.5 * values[mid - 1] + 0.5 * values[mid];
}

private double absValue(double value)
{
    import std.math : abs;
    return abs(value);
}

enum featureImplementationVersion = 1u;

enum FeatureMaturity : ubyte { experimental, qualifiedDevelop, releaseStable }
enum FeatureInput : ubyte { rgb8, rgb8OrScalar }
enum FeatureDomain : ubyte { encodedRgb8, linearLuminance, linearLuminanceOrScalar, decodedColor, encodedRgbAndLinearLuminance }

/// Fixed operator contract for the tile engine.
struct FeatureDescriptor
{
    Feature feature;
    size_t halo;
    bool usesScalar;
    bool rgbOnly;
    uint implementationVersion;
    FeatureAccess access;
    FeatureCost cost;
    FeatureStorage storage;
    /// Pixel-scale semantics use the explicitly selected source level.
    bool usesSelectedLevel = true;
    string parameters;
    string validity;
    FeatureChannel[] channels;
    Feature[2] dependencies;
    size_t dependencyCount;
    FeatureMaturity maturity = FeatureMaturity.qualifiedDevelop;
    FeatureInput input;
    FeatureDomain domain;
    bool cacheableOutput;
}

package FeatureDescriptor describeTileKernel(Feature feature)
{
    if (cast(size_t)feature > cast(size_t)Feature.max)
        throw new Exception("Unknown feature");
    auto result = FeatureDescriptor(feature, haloFor(feature),
        feature != Feature.oklab && feature != Feature.clipping,
        feature == Feature.oklab || feature == Feature.clipping ||
        feature == Feature.underexposure || feature == Feature.bilateral ||
        feature == Feature.diffusion || feature == Feature.relativeDarkness ||
        feature == Feature.shadowCandidate || feature == Feature.visibility || feature == Feature.edgeEvidence ||
        structureRequiresRgb(feature), featureImplementationVersion);
    if (result.usesScalar && feature != Feature.luminance)
    {
        result.dependencies[0] = Feature.luminance;
        result.dependencyCount = 1;
    }
    if (usesLocalMoments(feature) || feature == Feature.edgeEvidence)
    {
        result.dependencies[1] = usesLocalMoments(feature) ? Feature.localStatistics : Feature.gradient;
        result.dependencyCount = 2;
    }
    return result;
}

FeatureDescriptor describeTileFeature(Feature feature)
{
    auto result = describeTileKernel(feature);
    result.parameters = fixedParameters(feature);
    result.input = result.rgbOnly ? FeatureInput.rgb8 : FeatureInput.rgb8OrScalar;
    result.domain = feature == Feature.oklab ? FeatureDomain.decodedColor :
        feature == Feature.clipping ? FeatureDomain.encodedRgb8 :
        feature == Feature.visibility ? FeatureDomain.encodedRgbAndLinearLuminance :
        result.rgbOnly ? FeatureDomain.linearLuminance : FeatureDomain.linearLuminanceOrScalar;
    result.cacheableOutput = true;
    result.channels = describeChannels(feature);
    result.validity = featureValidity(feature);
    const intensive = result.halo >= 4 || feature == Feature.entropy ||
        feature == Feature.cooccurrence ||
        (feature >= Feature.gaborFine0 && feature <= Feature.gaborFine135);
    result.cost = intensive ? FeatureCost.intensive : result.halo ?
        FeatureCost.neighborhood : FeatureCost.low;
    return result;
}

/// Describe both tiled features and dedicated analytical operations.
FeatureDescriptor describeFeature(Feature feature)
{
    if (feature != Feature.distribution && feature != Feature.clahe &&
        feature != Feature.normalizedLuminance && feature != Feature.exposureMatched)
        return describeTileFeature(feature);

    auto result = FeatureDescriptor(feature, 0, true, true, featureImplementationVersion);
    result.input = FeatureInput.rgb8;
    result.domain = FeatureDomain.linearLuminance;
    result.parameters = fixedParameters(feature);
    result.channels = describeChannels(feature);
    result.validity = featureValidity(feature);
    result.cost = FeatureCost.intensive;
    result.dependencies[0] = Feature.luminance;
    result.dependencyCount = 1;
    if (feature == Feature.distribution)
    {
        result.access = FeatureAccess.globalReduction;
        result.storage = FeatureStorage.uint64Histogram;
    }
    else if (feature == Feature.clahe)
        result.access = FeatureAccess.sourceCells;
    else
    {
        result.cacheableOutput = true;
        result.access = FeatureAccess.fittedProfile;
        result.dependencies[1] = Feature.distribution;
        result.dependencyCount = 2;
    }
    return result;
}

private enum featureCount = cast(size_t)Feature.max + 1;

private struct DependencyPlan
{
    Feature[featureCount] ordered;
    bool[featureCount] intermediate;
    size_t length;
}

private DependencyPlan planDependencies(scope const Feature[] requested,
    scope FeatureDescriptor function(Feature) @safe describe = &describeFeatureLinks)
{
    DependencyPlan result;
    ubyte[featureCount] state;
    void visit(Feature feature)
    {
        const descriptor = describe(feature);
        if (state[feature] == 1)
            throw new Exception("Cyclic feature dependencies");
        if (state[feature] == 2)
            return;
        state[feature] = 1;
        foreach (dependency; descriptor.dependencies[0 .. descriptor.dependencyCount])
        {
            result.intermediate[dependency] = true;
            visit(dependency);
        }
        state[feature] = 2;
        result.ordered[result.length++] = feature;
    }
    foreach (feature; requested)
        visit(feature);
    return result;
}

private FeatureDescriptor describeFeatureLinks(Feature feature)
{
    switch (feature)
    {
        case Feature.distribution, Feature.clahe, Feature.normalizedLuminance, Feature.exposureMatched:
            return describeFeature(feature);
        default:
            return describeTileKernel(feature);
    }
}

/// Return transitive dependencies before their outputs, with no duplicates.
Feature[] resolveFeaturePlan(scope const Feature[] requested)
{
    const plan = planDependencies(requested);
    return plan.ordered[0 .. plan.length].dup;
}

@safe unittest
{
    static FeatureDescriptor cyclic(Feature feature) @safe
    {
        FeatureDescriptor descriptor;
        descriptor.dependencies[0] = feature == Feature.gradient ?
            Feature.edgeEvidence : Feature.gradient;
        descriptor.dependencyCount = 1;
        return descriptor;
    }
    import std.exception : assertThrown;
    assertThrown(planDependencies([Feature.gradient], &cyclic));
}

/// Borrowed selection of tiled analytical outputs for one consumer request.
/// Emit in tile order and then selection order. A cold tile shares the
/// largest required input window and one scalar preparation across outputs.
void runFeatureView(ref Engine engine, const Source source, Region2D region,
    scope const Feature[] requested, size_t edge, scope Sink sink)
{
    engine.runView(source, region, requested, edge, sink);
}

// Complete identity for fixed-parameter tile operators. Derived resampling
// policies participate through Source.grid.
package struct TileIdentity
{
    string identity, revision, grid, band, unit;
    size_t level, width, height;
    bool rgb;
    Feature feature;
    Region2D tile;
    uint versionNumber;
    string parameters;
    ImageSourceMetadata metadata;
    size_t halo;
    const(LuminanceProfile)[] fittedProfiles;
}

package TileIdentity tileIdentity(const Source source, Region2D tile, Feature feature)
{
    return TileIdentity(source.identity, source.revision, source.grid, source.band,
        source.unit, source.level, source.width, source.height, source.rgb, feature,
        tile, featureImplementationVersion, fixedParameters(feature), sourceMetadata(source),
        describeFeatureLinks(feature).halo);
}

private size_t haloFor(Feature feature)
{
    final switch (feature)
    {
        case Feature.luminance, Feature.oklab, Feature.clipping, Feature.underexposure:
            return 0;
        case Feature.localStatistics, Feature.localNormalization, Feature.dynamicRange:
            return 3;
        case Feature.gradient, Feature.gaussian, Feature.box, Feature.median,
            Feature.bilateral, Feature.laplacian, Feature.sharpness, Feature.noise, Feature.diffusion:
            return 1;
        case Feature.visibility:
            return 0;
        case Feature.relativeDarkness, Feature.shadowCandidate:
            return 3;
        case Feature.edgeEvidence:
            return 1;
        case Feature.entropy, Feature.localBinaryPattern, Feature.cooccurrence,
             Feature.edgeDensity, Feature.directedEdges, Feature.orientationHistogram,
             Feature.gabor, Feature.ridge, Feature.lineResponse, Feature.erosion, Feature.dilation,
             Feature.opening, Feature.closing, Feature.topHat, Feature.bottomHat, Feature.pathOpening,
             Feature.pathClosing, Feature.openingProfile, Feature.closingProfile,
             Feature.gaborFine0, Feature.gaborFine45, Feature.gaborFine90, Feature.gaborFine135,
             Feature.gaborCoarse0, Feature.gaborCoarse45, Feature.gaborCoarse90, Feature.gaborCoarse135,
             Feature.directedOpening, Feature.directedClosing:
            return structureHalo(feature);
        case Feature.distribution, Feature.normalizedLuminance, Feature.exposureMatched, Feature.clahe:
            throw new Exception("Feature requires its dedicated operation");
    }
}

struct Provenance
{
    string identity, revision, grid, band, unit;
    size_t level;
    Region2D extent;
    Feature feature;
    uint implementationVersion;
    LuminanceProfile normalization;
    LuminanceProfile exposureReference;
    size_t gridWidth, gridHeight;
    ImageSourceMetadata metadata;
    string parameters;
    string validity;
}

private Provenance provenance(const Source source, Region2D extent, Feature feature)
{
    Provenance result = Provenance(source.identity, source.revision, source.grid, source.band,
        source.unit, source.level, extent, feature, featureImplementationVersion);
    result.gridWidth = source.width;
    result.gridHeight = source.height;
    result.metadata = sourceMetadata(source);
    result.parameters = fixedParameters(feature);
    result.validity = featureValidity(feature);
    return result;
}

/// Receives a completed tile. Its values are borrowed for this call.
alias Sink = void delegate(Region2D, scope const(Value)[], Provenance) @safe;

struct MemoryMetrics
{
    size_t scratchAllocations;
    size_t cachePayloadAllocations;
    size_t cacheIndexGrowths;
    size_t liveCacheBytes;
    size_t peakCacheBytes;
    size_t peakTileBytes;
    size_t sourceTileReads;
    size_t scalarTilePreparations;
    size_t dependencyTileHits;
    size_t featureEvaluations;
    size_t dependencyEvaluations;
    size_t dependencyCacheHits;
    size_t dependencyCacheMisses;
    size_t peakDependencyBytes;
}

/// Sequential feature processing with private, exact-region reuse.
struct Engine
{
    @disable this(this);
    private struct Entry
    {
        TileIdentity key;
        Value[] values;
    }

    private static size_t entryBytes(const TileIdentity key, size_t count)
    {
        size_t bytes = count * Value.sizeof + Entry.sizeof + key.identity.length + key.revision.length +
            key.grid.length + key.band.length + key.unit.length + key.parameters.length +
            key.metadata.spatial.crs.length + key.metadata.spatial.pixelUnit.length +
            key.metadata.resampling.policy.length + key.metadata.resampling.parentGrid.length +
            key.metadata.product.provider.length + key.metadata.product.sensor.length +
            key.metadata.product.acquisitionTime.length;
        foreach (ref profile; key.fittedProfiles)
            bytes += LuminanceProfile.sizeof + profile.identity.length + profile.revision.length +
                profile.grid.length + profile.band.length + profile.unit.length +
                profile.metadata.spatial.crs.length + profile.metadata.spatial.pixelUnit.length +
                profile.metadata.resampling.policy.length + profile.metadata.resampling.parentGrid.length +
                profile.metadata.product.provider.length + profile.metadata.product.sensor.length +
                profile.metadata.product.acquisitionTime.length;
        return bytes;
    }

    private Entry[] cache;
    private MemoryMetrics memory;
    private Value[] findCached(const TileIdentity key)
    {
        if (key.identity.length && key.revision.length)
            foreach (ref entry; cache)
                if (entry.key == key)
                    return entry.values;
        return null;
    }

    private Value[] storeCached(const TileIdentity key, scope const(Value)[] values, bool retain = false)
    {
        const bytes = entryBytes(key, values.length);
        if (!key.identity.length || !key.revision.length || bytes > cacheLimit)
            return retain ? values.dup : null;

        while (memory.liveCacheBytes > cacheLimit - bytes)
        {
            const old = cache[0];
            memory.liveCacheBytes -= entryBytes(old.key, old.values.length);
            cache[0] = Entry.init;
            cache = cache[1 .. $];
        }
        if (cache.capacity <= cache.length)
            ++memory.cacheIndexGrowths;
        auto stored = values.dup;
        cache ~= Entry(key, stored);
        ++memory.cachePayloadAllocations;
        memory.liveCacheBytes += bytes;
        memory.peakCacheBytes = max(memory.peakCacheBytes, memory.liveCacheBytes);
        return stored;
    }

    private size_t cacheLimit = 16 * 1024 * 1024;
    size_t hits;
    MemoryMetrics metrics() const { return memory; }

    /// Process an output region with a tile edge in 1..256.
    void run(const Source source, Region2D region, Feature feature,
        size_t edge, scope Sink sink)
    {
        Feature[1] requested = [feature];
        runView(source, region, requested[], edge, sink);
    }

    /// Request local statistics, standardization, range, darkness or shadow
    /// with an explicit window. Parameters participate in cache identity and
    /// provenance. Default parameters preserve the original fixed identity.
    void run(const Source source, Region2D region, Feature feature, size_t edge,
        LocalStatisticsParams parameters, scope Sink sink)
    {
        parameters.validate();
        if (feature!=Feature.localStatistics && feature!=Feature.localNormalization &&
            feature!=Feature.dynamicRange && feature!=Feature.relativeDarkness &&
            feature!=Feature.shadowCandidate) throw new Exception("Feature does not use local statistics parameters");
        Feature[1] requested=[feature];
        runView(source,region,requested[],edge,sink,parameters);
    }

    /// Configurable path opening/closing. Halo follows length and lateral step.
    void run(const Source source, Region2D region, Feature feature, size_t edge,
        PathMorphologyParams parameters, scope Sink sink)
    {
        parameters.validate();
        if (feature!=Feature.pathOpening && feature!=Feature.pathClosing)
            throw new Exception("Feature does not use path parameters");
        Feature[1] requested=[feature];
        runView(source,region,requested[],edge,sink,LocalStatisticsParams.init,parameters);
    }

    private void runView(const Source source, Region2D region,
        scope const Feature[] requested, size_t edge, scope Sink sink,
        LocalStatisticsParams statistics = LocalStatisticsParams.init,
        PathMorphologyParams paths = PathMorphologyParams.init)
    {
        if (!requested.length)
            return;
        validate(source, region);
        if (edge == 0 || edge > 256 || sink is null)
            throw new Exception("Unsupported feature request");

        const plan = planDependencies(requested);
        bool localFeature(Feature f) {
            return f==Feature.localStatistics || f==Feature.localNormalization ||
                f==Feature.dynamicRange || f==Feature.relativeDarkness || f==Feature.shadowCandidate;
        }
        size_t requestedHalo(Feature f) {
            if (localFeature(f)) return statistics.radius;
            if (f==Feature.pathOpening || f==Feature.pathClosing)
                return (paths.length-1)*max(1u,paths.lateralStep);
            return describeTileKernel(f).halo;
        }
        string parameterIdentity(Feature f) {
            import std.conv : to;
            if (localFeature(f) && statistics!=LocalStatisticsParams.init)
                return "radius="~statistics.radius.to!string~";minimum-valid="~
                    statistics.minimumValid.to!string~";variance=population;border=clamp"~
                    (f==Feature.shadowCandidate?";luminance-ceiling=0.15":"");
            if ((f==Feature.pathOpening || f==Feature.pathClosing) && paths!=PathMorphologyParams.init)
                return "element=axis-monotonic-path;length="~paths.length.to!string~
                    ";lateral-step="~paths.lateralStep.to!string~";border=clamp";
            return fixedParameters(f);
        }
        Provenance originFor(Region2D tile, Feature f) {
            auto result=provenance(source,tile,f);
            result.parameters=parameterIdentity(f);
            return result;
        }
        size_t halo;
        int maxMorphologyRadius;
        bool usesScalar;
        foreach (feature; plan.ordered[0 .. plan.length])
        {
            const descriptor = describeTileKernel(feature);
            if (!source.rgb && descriptor.rgbOnly)
                throw new Exception("Feature view is incompatible with the sample model");
            halo = max(halo, requestedHalo(feature));
            maxMorphologyRadius = max(maxMorphologyRadius, squareMorphologyRadius(feature));
            usesScalar |= descriptor.usesScalar;
        }

        // Allocate once on the first miss and reuse for the rest of the request.
        Sample[] input;
        Point[] points, morphologyRows, morphologyIntermediate;
        Value[] output;
        foreachTile(region, edge, (Region2D tile) {
            const left = min(tile.x, halo);
            const top = min(tile.y, halo);
            const width = left + tile.width + min(halo, source.width - tile.x - tile.width);
            const height = top + tile.height + min(halo, source.height - tile.y - tile.height);
            const window = Region2D(tile.x - left, tile.y - top, width, height);
            const length = width * height;
            bool prepared;
            Value[][featureCount] intermediates;
            size_t dependencyBytes;
            const count = tile.width * tile.height;
            void compute(Feature feature, bool dependency)
            {
                auto key = tileIdentity(source, tile, feature);
                key.parameters=parameterIdentity(feature);
                key.halo=requestedHalo(feature);
                auto cached = intermediates[feature];
                if (cached is null)
                    cached = findCached(key);
                if (dependency)
                {
                    if (cached is null)
                        ++memory.dependencyCacheMisses;
                    else
                        ++memory.dependencyCacheHits;
                }
                if (cached !is null)
                {
                    if (plan.intermediate[feature] && feature != Feature.luminance && intermediates[feature] is null)
                    {
                        intermediates[feature] = cached;
                        dependencyBytes += cached.length * Value.sizeof;
                        memory.peakDependencyBytes = max(memory.peakDependencyBytes, dependencyBytes);
                    }
                    if (!dependency)
                    {
                        ++hits;
                        sink(tile, cached, originFor(tile, feature));
                    }
                    return;
                }

                const descriptor = describeTileKernel(feature);
                foreach (needed; descriptor.dependencies[0 .. descriptor.dependencyCount])
                    if (needed != Feature.luminance)
                        compute(needed, true);

                if (!prepared)
                {
                    if (input is null)
                    {
                        const side = edge + 2 * halo;
                        input = new Sample[side * side];
                        points = new Point[input.length];
                        output = new Value[edge * edge];
                        memory.scratchAllocations += 3;
                        if (maxMorphologyRadius)
                        {
                            const wide = edge + 2 * maxMorphologyRadius;
                            morphologyRows = new Point[wide * (edge + 4 * maxMorphologyRadius)];
                            morphologyIntermediate = new Point[wide * wide];
                            memory.scratchAllocations += 2;
                        }
                        memory.peakTileBytes = max(memory.peakTileBytes,
                            input.length * Sample.sizeof + points.length * Point.sizeof +
                            output.length * Value.sizeof +
                            (morphologyRows.length + morphologyIntermediate.length) * Point.sizeof);
                    }

                    source.read(window, input[0 .. length]);
                    ++memory.sourceTileReads;
                    if (usesScalar)
                    {
                        ++memory.scalarTilePreparations;
                        foreach (i, value; input[0 .. length])
                        {
                            const measurement = value.valid ? scalar(value, source.rgb) : 0;
                            points[i] = Point(measurement, value.valid && isFinite(measurement));
                        }
                    }
                    prepared = true;
                }
                const morphologyRadius = squareMorphologyRadius(feature);

                auto values = output[0 .. tile.width * tile.height];
                const derived = descriptor.dependencyCount == 2;
                const intermediate = derived ? intermediates[descriptor.dependencies[1]] : null;

                if (intermediate !is null)
                {
                    ++memory.dependencyTileHits;
                    foreach (i, prior; intermediate)
                    {
                        values[i] = Value.init;
                        if (!prior.valid)
                            continue;
                        if (feature == Feature.edgeEvidence)
                            values[i] = Value([clamp(prior.channels[0] / 0.125, 0.0, 1.0), 0, 0], true, false);
                        else
                        {
                            const center = points[(i / tile.width + top) * width + i % tile.width + left];
                            values[i] = fromLocalMoments(feature, center.value,
                                prior.channels[0], prior.channels[1]);
                        }
                    }
                }
                else if (morphologyRadius)
                    evaluateSquareMorphology(feature, cast(int)tile.width, cast(int)tile.height,
                        (int x, int y) {
                            const sx = offset(tile.x, x, source.width) - window.x;
                            const sy = offset(tile.y, y, source.height) - window.y;
                            return points[sy * width + sx];
                        }, morphologyRows, morphologyIntermediate, values);
                else
                    foreach (y; 0 .. tile.height)
                        foreach (x; 0 .. tile.width)
                        {
                            const center = input[(y + top) * width + x + left];
                            values[y * tile.width + x] = evaluate(feature, source.rgb, center,
                                TileReader(points[0 .. length], tile.x+x, tile.y+y,
                                    source.width, source.height, window.x, window.y, width), statistics, paths);
                        }

                if (dependency)
                    ++memory.dependencyEvaluations;
                else
                    ++memory.featureEvaluations;

                auto retained = storeCached(key, values, dependency ||
                    (plan.intermediate[feature] && feature != Feature.luminance));
                if (dependency || (plan.intermediate[feature] && feature != Feature.luminance))
                {
                    intermediates[feature] = retained;
                    dependencyBytes += count * Value.sizeof;
                    memory.peakDependencyBytes = max(memory.peakDependencyBytes, dependencyBytes);
                }
                if (!dependency)
                    sink(tile, values, originFor(tile, feature));
            }
            bool[featureCount] emitted;
            foreach (feature; requested)
                if (!emitted[feature])
                {
                    compute(feature, false);
                    emitted[feature] = true;
                }
        });
    }
}

@safe unittest
{
    Engine engine;
    const region = Region2D(1, 3, 1, 1);
    auto source = Source("source", "revision", "grid", "band", "m", 1, 10, 12, true);
    auto original = tileIdentity(source, region, Feature.gradient);
    engine.storeCached(original, [Value([0, 0, 0], true, false)]);
    assert(engine.findCached(original) !is null);
    foreach (change; 0 .. 17)
    {
        auto altered = original;
        switch (change)
        {
            case 0: altered.identity = "other"; break;
            case 1: altered.revision = "other"; break;
            case 2: altered.grid = "other"; break;
            case 3: ++altered.level; break;
            case 4: ++altered.width; break;
            case 5: ++altered.height; break;
            case 6: altered.band = "other"; break;
            case 7: altered.unit = "other"; break;
            case 8: altered.metadata.encoding = ImageEncoding.scalar; break;
            case 9: ++altered.tile.x; break;
            case 10: altered.feature = Feature.localStatistics; break;
            case 11: altered.parameters ~= ";border=zero"; break;
            case 12: ++altered.halo; break;
            case 13: altered.metadata.resampling.policy = "nearest"; break;
            case 14: altered.metadata.resampling.parentGrid = "parent"; break;
            case 15: ++altered.versionNumber; break;
            case 16: altered.fittedProfiles = [LuminanceProfile.init]; break;
            default: assert(0);
        }
        assert(engine.findCached(altered) is null);
    }
}

private void foreachTile(Region2D region, size_t edge, scope void delegate(Region2D) @safe callback)
{
    for (size_t y = 0; y < region.height;)
    {
        const height = min(edge, region.height - y);
        for (size_t x = 0; x < region.width;)
        {
            const width = min(edge, region.width - x);
            callback(Region2D(region.x + x, region.y + y, width, height));
            x += width;
        }
        y += height;
    }
}

struct Distribution
{
    Provenance origin;
    ulong[256] bins;
    ulong count;
    /// Mean and population variance of valid linear samples, NaN when empty.
    double mean;
    double variance;

    // Integral percentile in 1..100, with nearest-rank semantics.
    int percentile(uint percent) const
    {
        if (percent == 0 || percent > 100 || count == 0)
            return -1;
        const rank = count / 100 * percent + ((count % 100) * percent + 99) / 100;
        ulong cumulative;
        foreach (i, bin; bins)
            if ((cumulative += bin) >= rank)
                return cast(int)i;
        return -1;
    }
}

Distribution distribution(const Source source, Region2D region)
{
    validate(source, region);
    if (!source.rgb || region.width > ulong.max / region.height)
        throw new Exception("Distribution requires a bounded RGB extent");
    Distribution result;
    result.origin = provenance(source, region, Feature.distribution);
    double mean = 0, squared = 0;
    auto buffer = new Sample[256 * 256];
    foreachTile(region, 256, (Region2D tile) {
        auto samples = buffer[0 .. tile.width * tile.height];
        source.read(tile, samples);
        foreach (sample; samples)
            if (sample.valid)
            {
                const value = scalar(sample, true);
                ++result.bins[luminanceBin(value)];
                const delta = value - mean;
                mean += delta / ++result.count;
                squared += delta * (value - mean);
            }
    });
    if (result.count)
    {
        result.mean = mean;
        result.variance = max(0.0, squared / result.count);
    }
    return result;
}


/// Source-specific bounds fitted from a fixed histogram analysis extent.
struct LuminanceProfile
{
    private bool fitted;
    private string identity, revision, grid, band, unit;
    private size_t level;
    private Region2D extent;
    private size_t width, height;
    private uint lowPercent, highPercent;
    private int lowBin, highBin;
    private ImageSourceMetadata metadata;

    bool usable() const { return fitted && lowBin < highBin; }
    Region2D analysisExtent() const { return extent; }
    string sourceIdentity() const { return identity; }
    string sourceRevision() const { return revision; }
    uint lowerPercentile() const { return lowPercent; }
    uint upperPercentile() const { return highPercent; }
    double lowerBound() const { return usable ? lowBin / 256.0 : double.nan; }
    double upperBound() const { return usable ? (highBin + 1) / 256.0 : double.nan; }
}

/// Fit nearest-rank bounds from valid linear luminance on the analysis extent.
/// Empty distributions and percentiles in the same bin yield an unusable profile.
LuminanceProfile fitLuminance(const Source source, Region2D analysisExtent,
    uint lowPercent, uint highPercent)
{
    if (!source.identity.length || !source.revision.length ||
        lowPercent == 0 || lowPercent >= highPercent || highPercent > 100)
        throw new Exception("Normalization requires source identity, revision and ordered percentiles");
    const histogram = distribution(source, analysisExtent);
    return LuminanceProfile(true, source.identity, source.revision, source.grid, source.band,
        source.unit, source.level, analysisExtent, source.width, source.height,
        lowPercent, highPercent, histogram.percentile(lowPercent), histogram.percentile(highPercent), histogram.origin.metadata);
}

/// Produce clipped analytical luminance in [0, 1], preserving validity.
/// The same profile may be applied to multiple regions of the fitted revision.
void normalizeLuminance(ref Engine engine, const Source source, Region2D region,
    const LuminanceProfile profile, size_t edge, scope Sink sink)
{
    applyLuminanceProfile(engine, source, region, profile, LuminanceProfile.init, false,
        edge, sink);
}

/// Map source percentile bounds to the corresponding bounds of a reference image.
void matchExposure(ref Engine engine, const Source source, Region2D region,
    const LuminanceProfile profile, const LuminanceProfile reference, size_t edge, scope Sink sink)
{
    if (!reference.usable || profile.lowerPercentile != reference.lowerPercentile ||
        profile.upperPercentile != reference.upperPercentile)
        throw new Exception("Exposure matching requires compatible percentile profiles");
    applyLuminanceProfile(engine, source, region, profile, reference, true, edge, sink);
}

private void applyLuminanceProfile(ref Engine engine, const Source source, Region2D region,
    const LuminanceProfile profile, const LuminanceProfile reference, bool match,
    size_t edge, scope Sink sink)
{
    if (!source.rgb || !profile.usable || sink is null ||
        profile.width != source.width || profile.height != source.height ||
        profile.identity != source.identity || profile.revision != source.revision ||
        profile.grid != source.grid || profile.band != source.band ||
        profile.unit != source.unit || profile.level != source.level ||
        profile.metadata != sourceMetadata(source))
        throw new Exception("Unusable normalization profile or source mismatch");

    const lower = profile.lowerBound;
    const upper = profile.upperBound;
    const outputLow = match ? reference.lowerBound : 0.0;
    const outputSpan = match ? reference.upperBound - outputLow : 1.0;
    Value[] scratch;
    const fitted = match ? [profile, reference] : [profile];
    const feature = match ? Feature.exposureMatched : Feature.normalizedLuminance;
    engine.run(source, region, Feature.luminance, edge,
        (Region2D tile, scope const(Value)[] input, Provenance origin) {
            auto key = tileIdentity(source, tile, feature);
            key.fittedProfiles = fitted;
            origin.feature = feature;
            origin.parameters = fixedParameters(feature);
            origin.validity = featureValidity(feature);
            origin.exposureReference = reference;
            origin.normalization = profile;
            const cached = engine.findCached(key);
            if (cached !is null)
            {
                ++engine.hits;
                sink(tile, cached, origin);
                return;
            }

            if (scratch is null)
                scratch = new Value[edge * edge];
            auto output = scratch[0 .. input.length];
            foreach (i, value; input)
            {
                output[i] = Value.init;
                output[i].valid = value.valid;
                if (value.valid)
                    output[i].channels[0] = outputLow + outputSpan * clamp((value.channels[0] - lower) / (upper - lower),
                        0.0, 1.0);
            }
            engine.storeCached(key, output);
            sink(tile, output, origin);
        });
}


private enum claheCell = 32;

private struct ClaheMap
{
    bool initialized, valid, identity;
    double[256] cdf;
}

private size_t luminanceBin(double value)
{
    return min(255, cast(size_t)(value * 256));
}

private void fitCell(const Source source, size_t x, size_t y,
    scope Sample[] scratch, ref ClaheMap map)
{
    map = ClaheMap.init;
    map.initialized = true;
    const left = x * claheCell;
    const top = y * claheCell;
    const width = min(claheCell, source.width - left);
    const height = min(claheCell, source.height - top);
    auto samples = scratch[0 .. width * height];
    source.read(Region2D(left, top, width, height), samples);
    uint[256] bins;
    uint count, occupied;
    foreach (sample; samples)
        if (sample.valid)
        {
            const bin = luminanceBin(scalar(sample, true));
            occupied += bins[bin] == 0;
            ++bins[bin];
            ++count;
        }
    map.valid = count != 0;
    map.identity = occupied <= 1;
    if (map.identity)
        return;

    const limit = max(1u, (2 * count + 255) / 256);
    uint excess;
    foreach (ref bin; bins)
    {
        excess += bin - min(bin, limit);
        bin = min(bin, limit);
    }
    const remainder = excess % 256;
    uint cumulative;
    foreach (i, bin; bins)
    {
        const extra = ((i + 1) * remainder) / 256 - (i * remainder) / 256;
        cumulative += bin + excess / 256 + cast(uint)extra;
        map.cdf[i] = cast(double)cumulative / count;
    }
}

private struct CellAxis
{
    size_t first, second;
    double fraction;
}

private CellAxis cellAxis(size_t pixel, size_t length)
{
    const last = (length - 1) / claheCell;
    if (pixel < claheCell / 2 || last == 0)
        return CellAxis(0, 0, 0);
    const shifted = pixel - claheCell / 2;
    const first = min(last, shifted / claheCell);
    return CellAxis(first, min(last, first + 1), (shifted % claheCell + 0.5) / claheCell);
}

/// Fixed-grid CLAHE on RGB8 linear luminance. Cell centers are anchored
/// to the source, with bilinear interpolation across nonempty neighboring cells.
void equalizeLuminanceLocally(ref Engine engine, const Source source, Region2D region,
    size_t edge, scope Sink sink)
{
    if (!source.rgb || sink is null)
        throw new Exception("CLAHE requires RGB8 and an output sink");

    Sample[claheCell * claheCell] cellScratch;
    // A tile of up to 256 pixels can intersect at most ten interpolation
    // cells per axis, including the two bordering cell centers.
    enum maxMapsPerAxis = 256 / claheCell + 2;
    ClaheMap[maxMapsPerAxis * maxMapsPerAxis] maps;
    Value[] scratch;
    engine.run(source, region, Feature.luminance, edge,
        (Region2D tile, scope const(Value)[] input, Provenance origin) {
            if (scratch is null)
                scratch = new Value[edge * edge];
            auto output = scratch[0 .. input.length];
            const firstCellX = cellAxis(tile.x, source.width).first;
            const firstCellY = cellAxis(tile.y, source.height).first;
            foreach (ref map; maps)
                map.initialized = false;
            foreach (i, value; input)
            {
                output[i] = Value.init;
                if (!value.valid)
                    continue;
                const x = cellAxis(tile.x + i % tile.width, source.width);
                const y = cellAxis(tile.y + i / tile.width, source.height);
                const bin = luminanceBin(value.channels[0]);
                double sum = 0, weights = 0;
                foreach (j, cy; [y.first, y.second])
                    foreach (k, cx; [x.first, x.second])
                    {
                        const weight = (k ? x.fraction : 1 - x.fraction) *
                            (j ? y.fraction : 1 - y.fraction);
                        if (weight == 0)
                            continue;
                        const index = (cy - firstCellY) * maxMapsPerAxis + cx - firstCellX;
                        auto map = &maps[index];
                        if (!map.initialized)
                            fitCell(source, cx, cy, cellScratch[], *map);
                        if (map.valid)
                        {
                            sum += weight * (map.identity ? value.channels[0] : map.cdf[bin]);
                            weights += weight;
                        }
                    }
                if (weights > 0)
                {
                    output[i].channels[0] = sum / weights;
                    output[i].valid = true;
                }
            }
            origin.feature = Feature.clahe;
            origin.parameters = fixedParameters(origin.feature);
            origin.validity = featureValidity(origin.feature);
            sink(tile, output, origin);
        });
}
