/++
 Synchronous region processing for explicitly encoded RGB8 and scalar images.
 Import this module directly to use the feature-region contract.
+/
module imagery.analysis.feature_regions;

import color.oklab : toOklab;
import color.rgb : SRgbd, toLinear;
import color.xyz : toXyzD65;
import raster.region : Region2D;
import imagery.analysis.feature_structure : evaluateStructure, structureHalo, structureRequiresRgb,
    squareMorphologyRadius, evaluateSquareMorphology;
import std.algorithm : clamp, min, max;
import std.math : atan2, exp, isFinite, sqrt;

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

struct Source
{
    string identity, revision, grid, band, unit;
    size_t level, width, height;
    bool rgb;
    /// Fill the supplied row-major buffer synchronously. Throw on read failure.
    void delegate(Region2D, scope Sample[]) @safe read;
}

private void validate(const Source source, Region2D region)
{
    if (source.read is null || region.empty ||
        region.x > source.width || region.width > source.width - region.x ||
        region.y > source.height || region.height > source.height - region.y)
        throw new Exception("Invalid source or region");
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

private Value evaluate(Feature feature, bool rgb, Sample center,
    scope Point delegate(int, int) @safe sample)
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
            foreach (dy; -3 .. 4)
                foreach (dx; -3 .. 4)
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
            if (count >= 25 && isFinite(mean) && isFinite(squared))
            {
                const deviation = sqrt(max(0.0, squared / count));
                if (feature == Feature.relativeDarkness || feature == Feature.shadowCandidate)
                {
                    const centerValue = sample(0, 0).value;
                    const relative = mean == 0 ? 0 : clamp((mean - centerValue) / mean, 0.0, 1.0);
                    result.channels[0] = feature == Feature.relativeDarkness ? relative :
                        relative * clamp((0.15 - centerValue) / 0.15, 0.0, 1.0);
                }
                else if (feature == Feature.dynamicRange)
                    result.channels[0] = high - low;
                else if (feature == Feature.localNormalization)
                    result.channels[0] = deviation == 0 ? 0 : (sample(0, 0).value - mean) / deviation;
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
            return evaluateStructure(feature, sample);
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
private Value filter3x3(Feature feature, scope Point delegate(int, int) @safe sample)
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

/// Fixed operator contract for the tile engine.
struct FeatureDescriptor
{
    Feature feature;
    size_t halo;
    bool usesScalar;
    bool rgbOnly;
    uint implementationVersion;
}

FeatureDescriptor describeTileFeature(Feature feature)
{
    if (cast(size_t)feature > cast(size_t)Feature.max)
        throw new Exception("Unknown feature");
    return FeatureDescriptor(feature, haloFor(feature),
        feature != Feature.oklab && feature != Feature.clipping,
        feature == Feature.oklab || feature == Feature.clipping ||
        feature == Feature.underexposure || feature == Feature.bilateral ||
        feature == Feature.diffusion || feature == Feature.relativeDarkness ||
        feature == Feature.shadowCandidate || feature == Feature.visibility || feature == Feature.edgeEvidence ||
        structureRequiresRgb(feature), featureImplementationVersion);
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
}

package TileIdentity tileIdentity(const Source source, Region2D tile, Feature feature)
{
    return TileIdentity(source.identity, source.revision, source.grid, source.band,
        source.unit, source.level, source.width, source.height, source.rgb, feature,
        tile, featureImplementationVersion);
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
}

private Provenance provenance(const Source source, Region2D extent, Feature feature)
{
    Provenance result = Provenance(source.identity, source.revision, source.grid, source.band,
        source.unit, source.level, extent, feature, featureImplementationVersion);
    result.gridWidth = source.width;
    result.gridHeight = source.height;
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

    private Entry[] cache;
    private MemoryMetrics memory;
    private size_t cacheLimit = 16 * 1024 * 1024;
    size_t hits;
    MemoryMetrics metrics() const { return memory; }

    /// Process an output region with a tile edge in 1..256.
    void run(const Source source, Region2D region, Feature feature,
        size_t edge, scope Sink sink)
    {
        validate(source, region);
        const descriptor = describeTileFeature(feature);
        if (edge == 0 || edge > 256 || sink is null || (!source.rgb && descriptor.rgbOnly))
            throw new Exception("Unsupported feature request");

        const halo = descriptor.halo;
        const morphologyRadius = squareMorphologyRadius(feature);

        // Allocate once on the first miss and reuse for the rest of the request.
        Sample[] input;
        Point[] points, morphologyRows, morphologyIntermediate;
        Value[] output;
        foreachTile(region, edge, (Region2D tile) {
            const key = tileIdentity(source, tile, feature);
            foreach (ref entry; cache)
                if (key.identity.length && key.revision.length && entry.key == key)
                {
                    ++hits;
                    sink(tile, entry.values, provenance(source, tile, feature));
                    return;
                }

            if (input is null)
            {
                const side = edge + 2 * halo;
                input = new Sample[side * side];
                points = new Point[input.length];
                output = new Value[edge * edge];
                memory.scratchAllocations += 3;
                if (morphologyRadius)
                {
                    const wide = edge + 2 * morphologyRadius;
                    morphologyRows = new Point[wide * (edge + 4 * morphologyRadius)];
                    morphologyIntermediate = new Point[wide * wide];
                    memory.scratchAllocations += 2;
                }
                memory.peakTileBytes = max(memory.peakTileBytes,
                    input.length * Sample.sizeof + points.length * Point.sizeof +
                    output.length * Value.sizeof +
                    (morphologyRows.length + morphologyIntermediate.length) * Point.sizeof);
            }

            const left = min(tile.x, halo);
            const top = min(tile.y, halo);
            const width = left + tile.width + min(halo, source.width - tile.x - tile.width);
            const height = top + tile.height + min(halo, source.height - tile.y - tile.height);
            const window = Region2D(tile.x - left, tile.y - top, width, height);
            const length = width * height;
            source.read(window, input[0 .. length]);
            if (descriptor.usesScalar)
                foreach (i, value; input[0 .. length])
                {
                    const measurement = value.valid ? scalar(value, source.rgb) : 0;
                    points[i] = Point(measurement, value.valid && isFinite(measurement));
                }

            auto values = output[0 .. tile.width * tile.height];
            if (morphologyRadius)
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
                            (int dx, int dy) {
                                const sx = offset(tile.x + x, dx, source.width) - window.x;
                                const sy = offset(tile.y + y, dy, source.height) - window.y;
                                return points[sy * width + sx];
                            });
                    }

            const bytes = values.length * Value.sizeof + Entry.sizeof +
                source.identity.length + source.revision.length + source.grid.length +
                source.band.length + source.unit.length;
            if (source.identity.length && source.revision.length && bytes <= cacheLimit)
            {
                while (memory.liveCacheBytes > cacheLimit - bytes)
                {
                    const old = cache[0];
                    memory.liveCacheBytes -= old.values.length * Value.sizeof + Entry.sizeof +
                        old.key.identity.length + old.key.revision.length + old.key.grid.length +
                        old.key.band.length + old.key.unit.length;
                    cache[0] = Entry.init;
                    cache = cache[1 .. $];
                }
                if (cache.capacity <= cache.length)
                    ++memory.cacheIndexGrowths;
                cache ~= Entry(key, values.dup);
                ++memory.cachePayloadAllocations;
                memory.liveCacheBytes += bytes;
                memory.peakCacheBytes = max(memory.peakCacheBytes, memory.liveCacheBytes);
            }
            sink(tile, values, provenance(source, tile, feature));
        });
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
        lowPercent, highPercent, histogram.percentile(lowPercent), histogram.percentile(highPercent));
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
        profile.unit != source.unit || profile.level != source.level)
        throw new Exception("Unusable normalization profile or source mismatch");

    const lower = profile.lowerBound;
    const upper = profile.upperBound;
    const outputLow = match ? reference.lowerBound : 0.0;
    const outputSpan = match ? reference.upperBound - outputLow : 1.0;
    Value[] scratch;
    engine.run(source, region, Feature.luminance, edge,
        (Region2D tile, scope const(Value)[] input, Provenance origin) {
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
            origin.feature = match ? Feature.exposureMatched : Feature.normalizedLuminance;
            origin.exposureReference = reference;
            origin.normalization = profile;
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
            sink(tile, output, origin);
        });
}
