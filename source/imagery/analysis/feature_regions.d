/++
 Synchronous region processing for explicitly encoded RGB8 and scalar images.
 Import this module directly to use the feature-region contract.
+/
module imagery.analysis.feature_regions;

import color.oklab : toOklab;
import color.rgb : SRgbd, toLinear;
import color.xyz : toXyzD65;
import raster.region : Region2D;
import raster : RasterPlaneWindow;
public import imagery.analysis.feature_contracts :
    FeatureAccess, FeatureCost, FeatureStorage, FeatureUnit, FeatureChannel;
import imagery.analysis.feature_contracts : fixedParameters, describeChannels, featureValidity;
import imagery.analysis.feature_structure : evaluateStructure, structureHalo, structureRequiresRgb,
    squareMorphologyRadius, evaluateSquareMorphologyInto, StructuralOptions, prepareGabor, GaborMember;
import std.algorithm : clamp, min, max;
import std.traits : Unqual;
import std.math : atan2, exp, isFinite, sqrt;
version(ImageryProfile) import core.time : MonoTime;
public import imagery.analysis.feature_parameters : LocalStatisticsParams, PathMorphologyParams,
    RidgeParams, LineResponseParams, GaborParams, ShadowParams, ClaheParams, FeatureViewParams;
import imagery.analysis.window_kernels : WindowMoments, evaluateWindows;
import imagery.analysis.feature_parameters : isTileFeatureParameter;
import imagery.analysis.path_kernels : PathWorkspace, evaluatePathsInto;
import imagery.analysis.feature_output32 : Float32TileOutput;
import imagery.analysis.row_kernels : RowKernelScratch,basicRowFeature,structuralRowFeature;
import imagery.analysis.planar_cache : PlanarTileCache;
public import imagery.analysis.planar_cache : PlanarCacheMetrics;
public import imagery.analysis.feature_worker32 : FeaturePlanes32;

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

// Compile-time output policy shared by the float64 engine and prepared SoA
// workers. No virtual/delegate dispatch is introduced in pixel loops.
package struct ValueTileOutput
{
    Value[] values;
    pragma(inline,true)
    void initialize(size_t count,bool valid) scope nothrow @nogc {
        values[0..count]=Value([0,0,0],valid,false);
    }
    pragma(inline,true)
    bool mathematicalValid(size_t i) const scope nothrow @nogc { return values[i].valid; }
    pragma(inline,true)
    double scalarAt(size_t i) const scope nothrow @nogc { return values[i].channels[0]; }
    pragma(inline,true)
    void setValue(size_t i,Value value) scope nothrow @nogc { values[i]=value; }
    pragma(inline,true)
    void setFiniteValue(size_t i,Value value) scope nothrow @nogc {values[i]=value;}
    pragma(inline,true)
    void setScalar(size_t i,double value) scope nothrow @nogc {values[i].channels[0]=value;}
    pragma(inline,true)
    ValueTileOutput row(size_t start,size_t count) return scope nothrow @nogc {return ValueTileOutput(values[start..start+count]);}
    pragma(inline,true)
    void putChannel(size_t i,size_t channel,double value) scope nothrow @nogc { values[i].channels[channel]=value; }
    pragma(inline,true)
    void invalidate(size_t i) scope nothrow @nogc { values[i]=Value.init; }
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

/// A scalar provider lends a raster-d window only during this callback. The
/// callback must not escape. Nested raster views/slices still have a semantic
/// borrow lifetime; DIP1000 does not prove deep non-escape of every view copy.
alias ScalarPlaneConsumer(T)=void delegate(scope ref const RasterPlaneWindow!T) @safe nothrow @nogc;

struct Source
{
    string identity, revision, grid, band, unit;
    size_t level, width, height;
    bool rgb;
    /// Fill the supplied row-major buffer synchronously. Throw on read failure.
    void delegate(Region2D, scope Sample[]) @safe read;
    ImageSourceMetadata metadata;
    /// Optional scalar-only transport of the exact requested halo window.
    /// Return true after exactly one synchronous consumer call, or false with
    /// no call to use read. Every sample must have the same value and validity
    /// as read; sources with an explicit invalid mask must decline this path.
    /// The backing must remain unchanged throughout the callback. No owning
    /// lease is transferred. Both transports and .init are optional/null.
    bool delegate(Region2D,scope ScalarPlaneConsumer!double) @safe readPlane;
    /// Float32 variant of readPlane, promoted exactly to the working Float64.
    bool delegate(Region2D,scope ScalarPlaneConsumer!float) @safe readPlane32;
}

/// Ordinary sources need only read. Borrowing is optional and does not change
/// source identity, units, cache keys or full-precision numerical semantics.
@safe unittest
{
    Source source;
    assert(source.readPlane is null&&source.readPlane32 is null);
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

private auto linearColor(Sample sample) nothrow @nogc
{
    return SRgbd(sample.rgb[0] / 255.0, sample.rgb[1] / 255.0,
        sample.rgb[2] / 255.0).toLinear;
}

private double scalar(Sample sample, bool rgb) nothrow @nogc
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

// Image-owned scalar working samples. This private carrier does not expose
// raster layout/ownership machinery. Point remains the register-level sampler
// result; owned tile transport stores separate numeric and validity planes.
private struct ScalarTile
{
    double[] samples;
    ubyte[] validity;
    enum sampleBytes=double.sizeof+ubyte.sizeof;
    pragma(inline,true)
    size_t length() const nothrow @nogc {return samples.length;}
    void reserve(size_t count) {
        auto values=new double[count];auto mask=new ubyte[count];
        samples=values;validity=mask;
    }
    pragma(inline,true)
    Point opIndex(size_t i) const nothrow @nogc {return Point(samples[i],validity[i]!=0);}
    pragma(inline,true)
    void opIndexAssign(Point value,size_t i) nothrow @nogc {
        samples[i]=value.value;validity[i]=cast(ubyte)value.valid;
    }
    pragma(inline,true)
    ScalarTile opSlice(size_t begin,size_t end) nothrow @nogc {
        return ScalarTile(samples[begin..end],validity[begin..end]);
    }
}

// Named boundaries for optional deterministic phase attribution. Ordinary
// builds inline these wrappers; the diagnostic version retains call frames.
version(ImageryInstructionPhases) private enum inlinePhaseBoundaries=false;
else private enum inlinePhaseBoundaries=true;

pragma(inline,inlinePhaseBoundaries)
private void imageryEngineSourceRead(const Source source,Region2D region,scope Sample[] output)
{source.read(region,output);}

private alias ScalarPlaneProvider(T)=bool delegate(Region2D,scope ScalarPlaneConsumer!T) @safe;

pragma(inline,inlinePhaseBoundaries)
private bool imageryEngineSourceBorrow64(
    scope ScalarPlaneProvider!double provide,
    Region2D region,scope ScalarPlaneConsumer!double consume)
{return provide(region,consume);}

pragma(inline,inlinePhaseBoundaries)
private bool imageryEngineSourceBorrow32(
    scope ScalarPlaneProvider!float provide,
    Region2D region,scope ScalarPlaneConsumer!float consume)
{return provide(region,consume);}

pragma(inline,inlinePhaseBoundaries)
private void imageryEnginePrepareSamples(scope const(Sample)[] input,bool rgb,
    ref ScalarTile points) nothrow @nogc
{
    foreach(i,value;input) {
        const measurement=value.valid?scalar(value,rgb):0;
        points[i]=Point(measurement,value.valid&&isFinite(measurement));
    }
}

pragma(inline,inlinePhaseBoundaries)
private bool imageryEnginePreparePlane64(ref RowKernelScratch rows,
    scope ref const RasterPlaneWindow!double plane,Region2D tile,Region2D window,
    size_t width,size_t height,size_t halo) nothrow @nogc
{return rows.loadPlane!double(plane,tile,window,width,height,halo);}

pragma(inline,inlinePhaseBoundaries)
private bool imageryEnginePreparePlane32(ref RowKernelScratch rows,
    scope ref const RasterPlaneWindow!float plane,Region2D tile,Region2D window,
    size_t width,size_t height,size_t halo) nothrow @nogc
{return rows.loadPlane!float(plane,tile,window,width,height,halo);}

pragma(inline,inlinePhaseBoundaries)
private void imageryEngineCacheExchange(ref PlanarTileCache cache,const TileIdentity key,
    ref float[][3] planes,ref ubyte[] valid,ref ubyte[] oriented,ref ubyte[] range,out FeaturePlanes32 output)
{cache.exchange(key,planes,valid,oriented,range,output);}

pragma(inline,inlinePhaseBoundaries)
private Value[] imageryEngineCacheValues(ref Engine engine,const TileIdentity key,
    scope const(Value)[] values,bool keep)
{return engine.storeCached(key,values,keep);}

pragma(inline,inlinePhaseBoundaries)
private void imageryEngineSinkValues(scope Sink sink,Region2D tile,
    scope const(Value)[] values,Provenance origin)
{sink(tile,values,origin);}

pragma(inline,inlinePhaseBoundaries)
private void imageryEngineSinkPlanes(scope PlanarSink sink,Region2D tile,
    scope FeaturePlanes32 values,Provenance origin)
{sink(tile,values,origin);}

pragma(inline,true)
private size_t offset(size_t position, int delta, size_t length) nothrow @nogc
{
    if (delta < 0)
        return position - min(position, cast(size_t)(-delta));
    return position + min(length - 1 - position, cast(size_t)delta);
}

// Statically dispatched sampling over an already populated halo. Unlike a
// delegate, opCall can be inlined into every tap of the kernel.
private struct TileReader
{
    ScalarTile points;
    size_t x, y, sourceWidth, sourceHeight, windowX, windowY, stride;
    this(ScalarTile data, size_t px, size_t py, size_t w, size_t h,
        size_t wx, size_t wy, size_t rowStride) nothrow @nogc
    {
        points=data; x=px; y=py; sourceWidth=w; sourceHeight=h;
        windowX=wx; windowY=wy; stride=rowStride;
    }
    pragma(inline,true)
    Point opCall(int dx, int dy) const nothrow @nogc
    {
        const sx = offset(x, dx, sourceWidth) - windowX;
        const sy = offset(y, dy, sourceHeight) - windowY;
        return points[sy * stride + sx];
    }
}

package bool usesLocalMoments(Feature feature) nothrow @nogc
{
    return feature == Feature.localNormalization || feature == Feature.relativeDarkness ||
        feature == Feature.shadowCandidate;
}

package Value fromLocalMoments(Feature feature, double center, double mean, double deviation,
    double shadowCeiling = 0.15) nothrow @nogc
{
    double response;
    if (feature == Feature.localNormalization)
        response = deviation == 0 ? 0 : (center - mean) / deviation;
    else
    {
        const relative = mean == 0 ? 0 : clamp((mean - center) / mean, 0.0, 1.0);
        response = feature == Feature.relativeDarkness ? relative :
            relative * clamp((shadowCeiling - center) / shadowCeiling, 0.0, 1.0);
    }
    return Value([response, 0, 0], isFinite(response), false);
}

package Value evaluate(Read)(Feature feature, bool rgb, Sample center,
    scope Read sample, LocalStatisticsParams statistics = LocalStatisticsParams.init,
    PathMorphologyParams paths = PathMorphologyParams.init,
    scope const StructuralOptions shapes = StructuralOptions.init, double shadowCeiling = 0.15)
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
                    return fromLocalMoments(feature, sample(0, 0).value, mean, deviation, shadowCeiling);
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
            return evaluateStructure(feature, sample, paths, shapes);
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

private double medianOf(scope double[] values) nothrow @nogc
{
    import std.algorithm : sort;
    sort(values);
    const mid = values.length / 2;
    return values.length % 2 ? values[mid] : 0.5 * values[mid - 1] + 0.5 * values[mid];
}

private double absValue(double value) nothrow @nogc
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

/// Describe the explicit planar publication policy for a tiled feature. Numeric
/// definitions/units remain those of the float64 kernel; final float32 rounding,
/// representability and three mask planes are separate output semantics.
FeatureDescriptor describePlanarFeature(Feature feature)
{
    auto result=describeTileFeature(feature);result.storage=FeatureStorage.float32Planes;
    result.parameters~=";publication=float32;overflow=range-mask;underflow=clear-axis;v=1";
    result.validity~=";float32-overflow=invalid-with-range-mask;axis-requires-nonzero-float32-strength";
    return result;
}

/// Select float32 publication explicitly and copy only retained snapshots.
@safe unittest
{
    Source source;source.identity="planar-example";source.revision="1";source.grid="pixels";
    source.width=source.height=4;source.band="temperature";source.unit="K";
    source.read=(Region2D region,scope Sample[] samples) @safe {samples[]=Sample(273.25,[0,0,0],true);};
    Engine engine;size_t count;
    engine.runPlanar(source,Region2D(0,0,4,4),Feature.luminance,4,
        (Region2D tile,scope FeaturePlanes32 planes,Provenance origin) @safe {
            assert(planes.channels[0][0]==273.25f&&planes.validity[0]&&origin.unit=="K");count+=planes.width*planes.height;
        });
    assert(count==16&&describePlanarFeature(Feature.luminance).storage==FeatureStorage.float32Planes);
    const reads=engine.metrics.sourceTileReads;
    engine.runPlanar(source,Region2D(0,0,4,4),Feature.luminance,4,
        (Region2D tile,scope FeaturePlanes32 planes,Provenance origin) @safe {assert(planes.channels[0][0]==273.25f);});
    assert(engine.planarMetrics.hits==1&&engine.metrics.sourceTileReads==reads);
    assert(engine.metrics.liveCacheBytes+engine.planarMetrics.retainedBytes<=16*1024*1024);
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

/// Customize one parameter family across a batched view, including its shared
/// dependencies. At least one selected feature must use that family; other
/// families retain defaults. Invalid settings/selection throw before reads.
/// CLAHE retains its dedicated interface. Use FeatureViewParams to configure
/// several families together while sharing the same Engine/cache.
void runFeatureView(P)(ref Engine engine,const Source source,Region2D region,
    scope const Feature[] requested,size_t edge,P parameters,scope Sink sink)
if(isTileFeatureParameter!P)
{
    parameters.validate();
    foreach(feature;requested)if(FeatureConfiguration.accepts!P(feature)) {
        const configuration=FeatureConfiguration.create(feature,parameters);
        engine.runView(source,region,requested,edge,sink,
            configuration.statistics,configuration.paths,configuration.tuning);
        return;
    }
    throw new Exception("No selected feature uses these parameters");
}

/// Configure multiple independent families in the same shared-input view.
/// Local-moment features share parameters.statistics; other families use their
/// own fields. Complete validation precedes any work, including for unused
/// settings. Explicit defaults retain ordinary view identities and outputs.
void runFeatureView(ref Engine engine,const Source source,Region2D region,
    scope const Feature[] requested,size_t edge,FeatureViewParams parameters,scope Sink sink)
{
    parameters.validate();
    Engine.TunableFeatures tuning;
    tuning.ridge=parameters.ridge;tuning.line=parameters.line;tuning.gabor=parameters.gabor;
    tuning.shadowCeiling=parameters.shadowLuminanceCeiling;
    engine.runView(source,region,requested,edge,sink,parameters.statistics,parameters.paths,tuning);
}

/// Configure ridge and path support together, sharing one source read.
@safe unittest
{
    Source source;source.width=source.height=8;source.band="scalar";source.unit="K";
    size_t reads,samples;
    source.read=(Region2D r,scope Sample[] values) {
        ++reads;foreach(ref value;values)value=Sample(273,[0,0,0],true);
    };
    FeatureViewParams parameters;
    parameters.ridge=RidgeParams(2,5);parameters.paths=PathMorphologyParams(5,2);
    Engine engine;
    runFeatureView(engine,source,Region2D(0,0,8,8),[Feature.ridge,Feature.pathOpening],8,parameters,
        (Region2D r,scope const(Value)[] values,Provenance origin){samples+=values.length;});
    assert(reads==1 && samples==128);
}

/// Share configured moments between statistics and normalization.
@safe unittest
{
    Source source;
    source.width=source.height=8;source.band="scalar";source.unit="K";
    source.read=(Region2D r,scope Sample[] values) {
        foreach(i,ref value;values)value=Sample(273+cast(double)(r.x+i%r.width),[0,0,0],true);
    };
    Engine engine;size_t samples;
    runFeatureView(engine,source,Region2D(0,0,8,8),
        [Feature.localStatistics,Feature.localNormalization],8,LocalStatisticsParams(1,5),
        (Region2D r,scope const(Value)[] values,Provenance origin){samples+=values.length;});
    assert(samples==128);
}

// One canonical parameter/halo resolver for direct, batched and queued work.
// The queue stores this bounded value, never an allocating execution closure.
package struct FeatureConfiguration
{
    LocalStatisticsParams statistics;
    PathMorphologyParams paths;
    Engine.TunableFeatures tuning;
    private ubyte kind;

    private static bool localFeature(Feature f) {
        return f==Feature.localStatistics || f==Feature.localNormalization ||
            f==Feature.dynamicRange || f==Feature.relativeDarkness || f==Feature.shadowCandidate;
    }
    private static bool isGabor(Feature f) { return Engine.isGabor(f); }

    static bool accepts(P)(Feature f) if(isTileFeatureParameter!P) {
        static if(is(Unqual!P==LocalStatisticsParams))return localFeature(f);
        else static if(is(Unqual!P==PathMorphologyParams))return f==Feature.pathOpening || f==Feature.pathClosing;
        else static if(is(Unqual!P==RidgeParams))return f==Feature.ridge;
        else static if(is(Unqual!P==LineResponseParams))return f==Feature.lineResponse;
        else static if(is(Unqual!P==GaborParams))return isGabor(f);
        else return f==Feature.shadowCandidate;
    }

    static FeatureConfiguration create(P)(Feature f,P parameters) if(isTileFeatureParameter!P) {
        parameters.validate();
        if(!accepts!P(f))throw new Exception("Feature does not use these parameters");
        FeatureConfiguration result;
        static if(is(Unqual!P==LocalStatisticsParams)) {result.statistics=parameters;result.kind=1;}
        else static if(is(Unqual!P==PathMorphologyParams)) {result.paths=parameters;result.kind=2;}
        else static if(is(Unqual!P==RidgeParams)) {result.tuning.ridge=parameters;result.kind=3;}
        else static if(is(Unqual!P==LineResponseParams)) {result.tuning.line=parameters;result.kind=4;}
        else static if(is(Unqual!P==GaborParams)) {result.tuning.gabor=parameters;result.kind=5;}
        else {result.statistics=parameters.window;result.tuning.shadowCeiling=parameters.luminanceCeiling;result.kind=6;}
        return result;
    }

    size_t halo(Feature f) const {
        if (localFeature(f)) return statistics.radius;
        if (f == Feature.ridge) return tuning.ridge.lastRadius;
        if (f == Feature.lineResponse) return tuning.line.across.lastRadius + tuning.line.alongRadius;
        if (isGabor(f)) {
            import std.math : ceil;
            const index = f == Feature.gabor ? 1 : (f-Feature.gaborFine0)/4;
            return cast(size_t)ceil(tuning.gabor.wavelengths[index]*tuning.gabor.supportRatio);
        }
        if (f==Feature.pathOpening || f==Feature.pathClosing)
            return (paths.length-1)*max(1u,paths.lateralStep);
        return describeTileKernel(f).halo;
    }
    string parameters(Feature f) const {
        import std.conv : to;
        import std.format : format;
        if (localFeature(f) && (statistics!=LocalStatisticsParams.init ||
            (f == Feature.shadowCandidate && tuning.shadowCeiling != 0.15)))
            return "radius="~statistics.radius.to!string~";minimum-valid="~
                statistics.minimumValid.to!string~";variance=population;border=clamp"~
                ";windows=unit-sums-or-centered-welford-v3"~
                (f==Feature.shadowCandidate?format!";luminance-ceiling=%.17g"(tuning.shadowCeiling):"");
        if (f == Feature.ridge && tuning.ridge != RidgeParams.init)
            return format!"radii=%s..%s;angles-deg=0,45,90,135;along=1;across=opposite-radius;aggregate=max-positive;ties=first-radius-angle;border=clamp"(
                tuning.ridge.firstRadius, tuning.ridge.lastRadius);
        if (f == Feature.lineResponse && tuning.line != LineResponseParams.init)
            return format!"radii=%s..%s;angles-deg=0,45,90,135;along=%s;across=opposite-radius;along-reduce=min;aggregate=max-positive;ties=first-radius-angle;border=clamp"(
                tuning.line.across.firstRadius, tuning.line.across.lastRadius, 2*tuning.line.alongRadius+1);
        if (isGabor(f) && tuning.gabor != GaborParams.init)
            return format!"wavelengths=%.17g,%.17g;angles-rad=%.17g,%.17g,%.17g,%.17g;sigma-ratio=%.17g;support-ratio=%.17g;aggregate=max;ties=first-wavelength-angle;border=clamp"(
                tuning.gabor.wavelengths[0], tuning.gabor.wavelengths[1],
                tuning.gabor.angles[0], tuning.gabor.angles[1], tuning.gabor.angles[2], tuning.gabor.angles[3],
                tuning.gabor.sigmaRatio, tuning.gabor.supportRatio);
        if ((f==Feature.pathOpening || f==Feature.pathClosing) && paths!=PathMorphologyParams.init)
            return "element=axis-monotonic-path;length="~paths.length.to!string~
                ";lateral-step="~paths.lateralStep.to!string~";border=clamp";
        return fixedParameters(f);
    }

    TileIdentity identity(const Source source,Region2D region,Feature feature) const {
        auto key=tileIdentity(source,region,feature);
        key.parameters=parameters(feature);key.halo=halo(feature);
        return key;
    }

    void run(ref Engine engine,const Source source,Region2D region,Feature feature,size_t edge,scope Sink sink) const {
        switch(kind) {
            case 0: engine.run(source,region,feature,edge,sink);break;
            case 1: engine.run(source,region,feature,edge,statistics,sink);break;
            case 2: engine.run(source,region,feature,edge,paths,sink);break;
            case 3: engine.run(source,region,feature,edge,tuning.ridge,sink);break;
            case 4: engine.run(source,region,feature,edge,tuning.line,sink);break;
            case 5: engine.run(source,region,feature,edge,tuning.gabor,sink);break;
            case 6: engine.run(source,region,feature,edge,ShadowParams(statistics,tuning.shadowCeiling),sink);break;
            default: assert(0,"Invalid internal feature configuration");
        }
    }
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

/// Borrow completed float32 feature planes only for this callback. Copy samples
/// before retaining a snapshot; the Engine may reuse private cache buffers.
/// Nested slices retain a semantic borrow obligation, not a deep DIP1000 proof.
alias PlanarSink = void delegate(Region2D,scope FeaturePlanes32,Provenance) @safe;

struct MemoryMetrics
{
    size_t scratchAllocations;
    size_t cachePayloadAllocations;
    size_t cacheIndexGrowths;
    size_t liveCacheBytes;
    size_t peakCacheBytes;
    size_t peakTileBytes;
    size_t sourceTileReads;
    /// Successful scalar raster borrows packed/validated in one row-kernel pass.
    size_t borrowedPlaneTiles;
    size_t scalarTilePreparations;
    size_t dependencyTileHits;
    size_t featureEvaluations;
    size_t dependencyEvaluations;
    size_t dependencyCacheHits;
    size_t dependencyCacheMisses;
    size_t peakDependencyBytes;
    /// Optional diagnostic phase clocks. Zero in ordinary builds; enable
    /// version ImageryProfile for same-build phase attribution, not primary timing.
    ulong sourceNanoseconds,preparationNanoseconds,kernelNanoseconds,cacheNanoseconds,sinkNanoseconds;
    /// Reused private cache payloads/scratch setups and fully charged index reservation.
    size_t cachePayloadReuses,scratchReuses,cacheIndexBytes;
}

/// Sequential feature processing with private, exact-region reuse.
struct Engine
{
    @disable this(this);
    private struct Entry
    {
        TileIdentity key;
        Value[] values;
        Value[] backing;
        ulong age;
        bool active,pinned;
    }

    private static size_t entryBytes(const TileIdentity key, size_t count)
    {
        size_t bytes = count * Value.sizeof + key.identity.length + key.revision.length +
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
    private ulong cacheClock;
    private bool busy,planarBusy,planarDispatch,cacheOnlyDependencies;
    private PlanarTileCache planarCache;
    private bool planarReady,planarParametersReady;
    private FeatureConfiguration planarConfiguration;
    private string[featureCount] planarParameterText;
    private string[featureCount] planarValidityText;
    private size_t plannedExecutionEdge;
    /// Reserve a private metadata index and clear cached tiles before work.
    /// maxBytes includes every reserved index slot and cached backing capacity;
    /// it is in 1..16 MiB, with 1..4096 metadata entries. Borrowed tiles must not
    /// be retained across calls. Call only between serial requests. Allocation
    /// failure preserves the old cache. Scratch and source-provider storage are
    /// separately budgeted. Empty entries never conceal retained pixel buffers.
    void reserveCache(size_t maxBytes=16*1024*1024,size_t maxEntries=512)
    {
        if(busy||planarBusy||!maxEntries||maxEntries>4096||!maxBytes||maxBytes>16*1024*1024||
            maxEntries>=maxBytes/Entry.sizeof)throw new Exception("Invalid feature cache reservation");
        auto entries=new Entry[maxEntries];
        cache=entries;cacheLimit=maxBytes;cacheClock=0;cacheOnlyDependencies=false;
        planarCache=PlanarTileCache.init;planarReady=false;
        ++memory.cacheIndexGrowths;memory.cacheIndexBytes=cache.length*Entry.sizeof;
        memory.liveCacheBytes=memory.cacheIndexBytes;
        memory.peakCacheBytes=max(memory.peakCacheBytes,memory.liveCacheBytes);
    }
    private Value[] findCached(const TileIdentity key,bool pin=false)
    {
        if(key.identity.length&&key.revision.length)
            foreach(ref entry;cache)if(entry.active&&entry.key==key) {
                entry.pinned|=pin;return entry.values;
            }
        return null;
    }

    private size_t oldest(size_t except=size_t.max)
    {
        size_t selected=size_t.max;
        foreach(i,ref entry;cache)
            if(i!=except&&entry.active&&!entry.pinned&&
                (selected==size_t.max||entry.age<cache[selected].age))selected=i;
        return selected;
    }
    private void evict(size_t slot)
    {
        memory.liveCacheBytes-=entryBytes(cache[slot].key,cache[slot].backing.length);
        cache[slot]=Entry.init;
    }
    private Value[] storeCached(const TileIdentity key,scope const(Value)[] values,bool retain=false)
    {
        if(!key.identity.length||!key.revision.length)return retain?values.dup:null;
        if(cache is null) {
            // Fixed metadata slots do not repeatedly lose append capacity after
            // eviction. The entire index reservation is charged from setup.
            // Internal setup while a request is active uses the same checked
            // default reservation; public reconfiguration rejects reentry.
            cache=new Entry[512];++memory.cacheIndexGrowths;
            memory.cacheIndexBytes=cache.length*Entry.sizeof;memory.liveCacheBytes=memory.cacheIndexBytes;
            memory.peakCacheBytes=max(memory.peakCacheBytes,memory.liveCacheBytes);
        }
        const fresh=entryBytes(key,values.length);
        if(fresh>cacheLimit-memory.cacheIndexBytes)return retain?values.dup:null;
        size_t slot=size_t.max;
        if(memory.liveCacheBytes<=cacheLimit-fresh)
            foreach(i,ref entry;cache)if(!entry.active){slot=i;break;}
        if(slot==size_t.max)slot=oldest();
        if(slot==size_t.max)return retain?values.dup:null;
        auto previous=cache[slot];
        const oldBytes=previous.active?entryBytes(previous.key,previous.backing.length):0;
        const capacity=max(values.length,previous.backing.length);
        const charge=entryBytes(key,capacity);
        if(charge>cacheLimit-memory.cacheIndexBytes)return retain?values.dup:null;
        while(memory.liveCacheBytes-oldBytes>cacheLimit-charge) {
            const other=oldest(slot);
            if(other==size_t.max)return retain?values.dup:null;
            evict(other);
        }
        auto backing=previous.backing;
        if(backing.length<values.length) {backing=new Value[values.length];++memory.cachePayloadAllocations;}
        else ++memory.cachePayloadReuses;
        auto stored=backing[0..values.length];stored[]=values;
        if(cacheClock==ulong.max){foreach(ref e;cache)e.age=0;cacheClock=0;}
        Entry entry;entry.key=key;entry.values=stored;entry.backing=backing;
        entry.age=++cacheClock;entry.active=true;entry.pinned=retain;cache[slot]=entry;
        memory.liveCacheBytes=memory.liveCacheBytes-oldBytes+charge;
        memory.peakCacheBytes=max(memory.peakCacheBytes,memory.liveCacheBytes);
        return stored;
    }

    private struct ScratchSignature
    {
        FeatureConfiguration configuration;
        size_t edge,halo,rowHalo,bytes;
        int morphologyRadius;
        bool moments,paths,gabor,basic,structural,planar,fullOutput;
    }
    private struct WorkerScratch
    {
        Sample[] input;
        ScalarTile points;
        Point[] morphologyRows,morphologyIntermediate;
        Value[] output;
        float[][3] planes;
        ubyte[] valid,oriented,range;
        double[] rawPath;
        WindowMoments[] moments;
        PathWorkspace paths;
        RowKernelScratch rows;
        GaborMember[] bank;
    }
    private WorkerScratch workerScratch;
    private ScratchSignature workerSignature;
    private bool scratchReady;

    private size_t cacheLimit = 16 * 1024 * 1024;
    size_t hits;
    MemoryMetrics metrics() const { return memory; }

    /// Configure pooled float32 delivery/cache and a separate full-precision
    /// dependency cache. Their combined reservation is bounded by totalBytes
    /// (at most 16 MiB). Defaults assign 6 MiB to full-precision dependencies;
    /// intermediate rounding never changes downstream results. Existing run
    /// remains float64; this selects explicit final float32 publication only.
    /// Setup allocates metadata, pixels on first misses, and serial scratch.
    void reservePlanar(size_t totalBytes=16*1024*1024,size_t dependencyBytes=6*1024*1024,
        size_t maxEntries=256)
    {
        if(busy||planarBusy||!dependencyBytes||dependencyBytes>=totalBytes||totalBytes>16*1024*1024)
            throw new Exception("Invalid planar/dependency cache partition");
        PlanarTileCache candidate;candidate.reserve(totalBytes-dependencyBytes,maxEntries);
        reserveCache(dependencyBytes,maxEntries);
        planarCache=candidate;planarReady=true;cacheOnlyDependencies=true;
    }

    /// Planar cache resource counters; intermediate float64 cache counters are
    /// in metrics. Both current retained byte counts sum to the configured cap.
    PlanarCacheMetrics planarMetrics() const {return planarCache.metrics;}

    /// Stream explicit float32 planes while keeping input preparation and
    /// calculations at float64. Missing math uses validity=0/rangeFailure=0;
    /// finite values lost at float32 publication use rangeFailure=1. Strength
    /// underflow clears orientation validity. Final tiles occupy 15 bytes/pixel
    /// (three channels plus three masks), versus 32-byte Value on x86-64.
    /// Outputs are scoped borrows; .run retains the existing float64 contract.
    /// Source identity and revision must be nonempty and stable for cached data.
    void runPlanar(const Source source,Region2D region,Feature feature,size_t edge,scope PlanarSink sink)
    {
        Feature[1] selected=[feature];runPlanarConfigured(source,region,selected[],edge,FeatureConfiguration.init,sink);
    }

    /// Typed family parameters have the same identity/halo as ordinary run.
    /// Final representation is additionally recorded in provenance/cache keys.
    void runPlanar(P)(const Source source,Region2D region,Feature feature,size_t edge,
        P parameters,scope PlanarSink sink) if(isTileFeatureParameter!P)
    {
        auto config=FeatureConfiguration.create(feature,parameters);config.kind=0;
        Feature[1] selected=[feature];runPlanarConfigured(source,region,selected[],edge,config,sink);
    }

    /// Mixed planar features share full-precision preparation/dependencies.
    /// Repeated requests use compact final tiles without narrowing dependency
    /// values. Dedicated fitted/source-cell/reduction operations keep their APIs.
    void runPlanarView(const Source source,Region2D region,scope const(Feature)[] requested,
        size_t edge,scope PlanarSink sink)
    {runPlanarConfigured(source,region,requested,edge,FeatureConfiguration.init,sink);}

    /// Configure mixed families, including the shared local-statistics window.
    void runPlanarView(const Source source,Region2D region,scope const(Feature)[] requested,
        size_t edge,FeatureViewParams parameters,scope PlanarSink sink)
    {
        parameters.validate();FeatureConfiguration config;
        config.statistics=parameters.statistics;config.paths=parameters.paths;
        config.tuning.ridge=parameters.ridge;config.tuning.line=parameters.line;
        config.tuning.gabor=parameters.gabor;config.tuning.shadowCeiling=parameters.shadowLuminanceCeiling;
        runPlanarConfigured(source,region,requested,edge,config,sink);
    }

    private void runPlanarConfigured(const Source source,Region2D region,scope const(Feature)[] requested,
        size_t edge,FeatureConfiguration configuration,scope PlanarSink sink)
    {
        if(busy||planarBusy||sink is null)throw new Exception("Planar Engine requires a serial callback");
        if(!requested.length)return;
        if(!source.identity.length||!source.revision.length)
            throw new Exception("Planar Engine requires source identity and revision");
        // Reuse the exact normal planner, including maximal mixed halos/budgets,
        // without reading samples or publishing anything in the planning pass.
        runView(source,region,requested,edge,(Region2D t,scope const(Value)[] v,Provenance p){},
            configuration.statistics,configuration.paths,configuration.tuning,true,
            (Region2D t,scope FeaturePlanes32 v,Provenance p){});
        const tileEdge=plannedExecutionEdge;
        if(!planarReady)reservePlanar();
        if(!planarParametersReady||planarConfiguration!=configuration) {
            planarParameterText[]=null;planarConfiguration=configuration;planarParametersReady=true;
        }
        foreach(feature;requested)if(planarParameterText[feature] is null)
            planarParameterText[feature]=configuration.parameters(feature)~";publication=float32;overflow=range-mask;underflow=clear-axis;v=1";
        foreach(feature;requested)if(planarValidityText[feature] is null)
            planarValidityText[feature]=featureValidity(feature)~";float32-overflow=invalid-with-range-mask;axis-requires-nonzero-float32-strength";
        planarBusy=true;scope(exit)planarBusy=false;
        foreachTile(region,tileEdge,(Region2D tile) {
            Feature[featureCount] missing;size_t count;bool[featureCount] seen;
            foreach(feature;requested) {
                if(seen[feature])continue;seen[feature]=true;
                auto key=tileIdentity(source,tile,feature);key.parameters=planarParameterText[feature];
                key.halo=configuration.halo(feature);FeaturePlanes32 planes;
                if(planarCache.find(key,planes)) {
                    ++hits;auto origin=provenance(source,tile,feature);origin.parameters=key.parameters;
                    origin.validity=planarValidityText[feature];
                    version(ImageryProfile) const sinkStarted=MonoTime.currTime;
                    imageryEngineSinkPlanes(sink,tile,planes,origin);
                    version(ImageryProfile) memory.sinkNanoseconds+=(MonoTime.currTime-sinkStarted).total!"nsecs";
                } else missing[count++]=feature;
            }
            if(!count)return;
            planarDispatch=true;scope(exit)planarDispatch=false;
            runView(source,tile,missing[0..count],edge,
                (Region2D actual,scope const(Value)[] values,Provenance origin) {
                    auto key=tileIdentity(source,actual,origin.feature);
                    key.parameters=planarParameterText[origin.feature];key.halo=configuration.halo(origin.feature);
                    version(ImageryProfile) const cacheStarted=MonoTime.currTime;
                    FeaturePlanes32 output;planarCache.store(key,values,output);
                    version(ImageryProfile) memory.cacheNanoseconds+=(MonoTime.currTime-cacheStarted).total!"nsecs";
                    origin.parameters=key.parameters;origin.validity=planarValidityText[origin.feature];
                    version(ImageryProfile) const sinkStarted=MonoTime.currTime;
                    imageryEngineSinkPlanes(sink,actual,output,origin);
                    version(ImageryProfile) memory.sinkNanoseconds+=(MonoTime.currTime-sinkStarted).total!"nsecs";
                },configuration.statistics,configuration.paths,configuration.tuning,false,
                (Region2D actual,scope FeaturePlanes32 values,Provenance origin) {
                    origin.parameters=planarParameterText[origin.feature];origin.validity=planarValidityText[origin.feature];
                    version(ImageryProfile) const sinkStarted=MonoTime.currTime;
                    imageryEngineSinkPlanes(sink,actual,values,origin);
                    version(ImageryProfile) memory.sinkNanoseconds+=(MonoTime.currTime-sinkStarted).total!"nsecs";
                });
        });
    }

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

    /// Tunable ridge scales. All parameters are validated before source reads.
    void run(const Source source, Region2D region, Feature feature, size_t edge,
        RidgeParams parameters, scope Sink sink)
    {
        parameters.validate();
        if (feature != Feature.ridge) throw new Exception("Feature does not use ridge parameters");
        TunableFeatures tuning; tuning.ridge = parameters;
        Feature[1] requested = [feature];
        runView(source, region, requested[], edge, sink, LocalStatisticsParams.init, PathMorphologyParams.init, tuning);
    }

    /// Tunable opposite-side and along-line support; halo is their sum.
    void run(const Source source, Region2D region, Feature feature, size_t edge,
        LineResponseParams parameters, scope Sink sink)
    {
        parameters.validate();
        if (feature != Feature.lineResponse) throw new Exception("Feature does not use line parameters");
        TunableFeatures tuning; tuning.line = parameters;
        Feature[1] requested = [feature];
        runView(source, region, requested[], edge, sink, LocalStatisticsParams.init, PathMorphologyParams.init, tuning);
    }

    /// Tunable two-scale/four-angle Gabor bank or one positional bank member.
    /// Nondefault weights are prepared once per cache-missing request.
    void run(const Source source, Region2D region, Feature feature, size_t edge,
        GaborParams parameters, scope Sink sink)
    {
        parameters.validate();
        if (!isGabor(feature)) throw new Exception("Feature does not use Gabor parameters");
        TunableFeatures tuning; tuning.gabor = parameters;
        Feature[1] requested = [feature];
        runView(source, region, requested[], edge, sink, LocalStatisticsParams.init, PathMorphologyParams.init, tuning);
    }

    /// Tunable shadow window and linear-luminance ceiling. Cacheable moments
    /// share the window identity; the ceiling belongs only to the shadow output.
    void run(const Source source, Region2D region, Feature feature, size_t edge,
        ShadowParams parameters, scope Sink sink)
    {
        parameters.validate();
        if (feature != Feature.shadowCandidate) throw new Exception("Feature does not use shadow parameters");
        TunableFeatures tuning; tuning.shadowCeiling = parameters.luminanceCeiling;
        Feature[1] requested = [feature];
        runView(source, region, requested[], edge, sink, parameters.window, PathMorphologyParams.init, tuning);
    }

    private static bool isGabor(Feature feature)
    {
        return feature == Feature.gabor ||
            (feature >= Feature.gaborFine0 && feature <= Feature.gaborCoarse135);
    }

    private struct TunableFeatures
    {
        RidgeParams ridge;
        LineResponseParams line;
        GaborParams gabor;
        double shadowCeiling = 0.15;
    }

    private void runView(const Source source, Region2D region,
        scope const Feature[] requested, size_t edge, scope Sink sink,
        LocalStatisticsParams statistics = LocalStatisticsParams.init,
        PathMorphologyParams paths = PathMorphologyParams.init,
        TunableFeatures tuning = TunableFeatures.init,bool planOnly=false,scope PlanarSink planarSink=null)
    {
        if (!requested.length)
            return;
        if(busy||(planarBusy&&!planarDispatch))throw new Exception("Feature Engine requires serial non-reentrant use");
        busy=true;scope(exit)busy=false;
        validate(source, region);
        if (edge == 0 || edge > 256 || sink is null)
            throw new Exception("Unsupported feature request");

        const plan = planDependencies(requested);
        const planar=planarSink !is null;
        bool fullOutput=!planar;
        foreach(f;plan.ordered[0..plan.length])fullOutput|=plan.intermediate[f]&&f!=Feature.luminance;
        bool localFeature(Feature f) {
            return f==Feature.localStatistics || f==Feature.localNormalization ||
                f==Feature.dynamicRange || f==Feature.relativeDarkness || f==Feature.shadowCandidate;
        }
        // Keep the existing 8 MiB tile-scratch ceiling for radius-31 windows.
        bool hasMoments,hasMorphology,hasPaths,hasGabor,hasBasic,hasStructuralRows;
        foreach(f;plan.ordered[0..plan.length]) {
            hasMoments|=localFeature(f); hasMorphology|=squareMorphologyRadius(f)!=0;
            hasPaths|=f==Feature.pathOpening || f==Feature.pathClosing;
            hasGabor|=isGabor(f);
            hasBasic|=basicRowFeature(f);
            hasStructuralRows|=structuralRowFeature(f);
        }
        FeatureConfiguration configuration;
        configuration.statistics=statistics;configuration.paths=paths;configuration.tuning=tuning;
        size_t requestedHalo(Feature f) {return configuration.halo(f);}
        string parameterIdentity(Feature f) {return configuration.parameters(f);}
        Provenance originFor(Region2D tile, Feature f) {
            auto result=provenance(source,tile,f);
            result.parameters=parameterIdentity(f);
            return result;
        }
        size_t halo,rowHalo;
        int maxMorphologyRadius;
        bool usesScalar;
        foreach (feature; plan.ordered[0 .. plan.length])
        {
            const descriptor = describeTileKernel(feature);
            if (!source.rgb && descriptor.rgbOnly)
                throw new Exception("Feature view is incompatible with the sample model");
            halo = max(halo, requestedHalo(feature));
            if(basicRowFeature(feature)||structuralRowFeature(feature))rowHalo=max(rowHalo,requestedHalo(feature));
            maxMorphologyRadius = max(maxMorphologyRadius, squareMorphologyRadius(feature));
            usesScalar |= descriptor.usesScalar;
        }

        size_t executionEdge=hasPaths && (hasMoments || hasMorphology) && halo>8 ? min(edge,128UL) :
            halo>8 || (hasMoments && hasMorphology) ? min(edge,192UL) : edge;
        size_t plannedBankBytes;
        if(hasGabor && tuning.gabor!=GaborParams.init) {
            import std.math : ceil;
            plannedBankBytes=8*GaborMember.sizeof;
            foreach(wavelength;tuning.gabor.wavelengths) {
                const side=2*cast(size_t)ceil(wavelength*tuning.gabor.supportRatio)+1;
                plannedBankBytes+=8*side*side*double.sizeof;
            }
        }
        size_t tilePayload(size_t candidate) {
            const area=candidate*candidate,side=candidate+2*halo;
            size_t bytes=plannedBankBytes+side*side*(Sample.sizeof+ScalarTile.sampleBytes)+area*((fullOutput?Value.sizeof:0)+(planar?15:0));
            if(planar&&hasPaths)bytes+=area*double.sizeof;
            if(hasBasic||hasStructuralRows)bytes+=RowKernelScratch.requiredBytes(candidate,candidate,rowHalo,hasStructuralRows?4:0);
            if(hasMoments)bytes+=(candidate+2*statistics.radius)*candidate*WindowMoments.sizeof;
            if(maxMorphologyRadius) {
                const wide=candidate+2*maxMorphologyRadius;
                bytes+=(wide*(candidate+4*maxMorphologyRadius)+wide*wide)*Point.sizeof;
            }
            if(hasPaths && paths.length>1) {
                const pathSide=candidate+2*(paths.length-1)*max(1u,paths.lateralStep);
                bytes+=PathWorkspace.requiredBytes(candidate,candidate,paths,planar&&!fullOutput);
            }
            return bytes;
        }
        enum tileBudget=8*1024*1024;
        if(tilePayload(executionEdge)>tileBudget) {
            // Payload is monotone in the edge. Preserve established partitions
            // whenever they fit; otherwise choose the largest bounded edge.
            if(tilePayload(1)>tileBudget)throw new Exception("Feature support exceeds tile scratch budget");
            size_t low=1,high=executionEdge;
            while(low<high) {
                const middle=low+(high-low+1)/2;
                if(tilePayload(middle)<=tileBudget)low=middle;else high=middle-1;
            }
            executionEdge=low;
        }
        const plannedTileBytes=tilePayload(executionEdge);
        plannedExecutionEdge=executionEdge;if(planOnly)return;
        StructuralOptions shapes;
        shapes.ridge = tuning.ridge;
        shapes.line = tuning.line;
        size_t bankBytes;

        ScratchSignature signature;
        signature.configuration=configuration;signature.edge=executionEdge;signature.halo=halo;
        signature.rowHalo=rowHalo;signature.bytes=plannedTileBytes;signature.morphologyRadius=maxMorphologyRadius;
        signature.moments=hasMoments;signature.paths=hasPaths;signature.gabor=hasGabor;
        signature.basic=hasBasic;signature.structural=hasStructuralRows;signature.planar=planar;signature.fullOutput=fullOutput;
        const reuse=scratchReady&&signature==workerSignature;
        Sample[] input=reuse?workerScratch.input:null;
        ScalarTile points=reuse?workerScratch.points:ScalarTile.init;
        Point[] morphologyRows=reuse?workerScratch.morphologyRows:null;
        Point[] morphologyIntermediate=reuse?workerScratch.morphologyIntermediate:null;
        Value[] output=reuse?workerScratch.output:null;
        float[][3] planes=reuse?workerScratch.planes:typeof(workerScratch.planes).init;
        ubyte[] valid=reuse?workerScratch.valid:null,oriented=reuse?workerScratch.oriented:null,rangeMask=reuse?workerScratch.range:null;
        double[] rawPath=reuse?workerScratch.rawPath:null;
        WindowMoments[] momentRows=reuse?workerScratch.moments:null;
        PathWorkspace pathScratch=reuse?workerScratch.paths:PathWorkspace.init;
        RowKernelScratch rowScratch=reuse?workerScratch.rows:RowKernelScratch.init;
        if(reuse) {
            shapes.gabor=workerScratch.bank;
            bankBytes=shapes.gabor.length*GaborMember.sizeof;
            foreach(ref member;shapes.gabor)bankBytes+=(member.realWeights.length+member.imaginaryWeights.length)*double.sizeof;
        }
        bool usedScratch,scratchComplete=reuse;
        scope(exit)if(usedScratch&&scratchComplete) {
            workerScratch.input=input;workerScratch.points=points;workerScratch.output=output;
            workerScratch.planes=planes;workerScratch.valid=valid;workerScratch.oriented=oriented;workerScratch.range=rangeMask;workerScratch.rawPath=rawPath;
            workerScratch.moments=momentRows;workerScratch.paths=pathScratch;workerScratch.rows=rowScratch;
            workerScratch.morphologyRows=morphologyRows;workerScratch.morphologyIntermediate=morphologyIntermediate;
            workerScratch.bank=shapes.gabor;workerSignature=signature;scratchReady=true;
        }
        foreachTile(region, executionEdge, (Region2D tile) {
            scope(exit)foreach(ref entry;cache)entry.pinned=false;
            const left = min(tile.x, halo);
            const top = min(tile.y, halo);
            const width = left + tile.width + min(halo, source.width - tile.x - tile.width);
            const height = top + tile.height + min(halo, source.height - tile.y - tile.height);
            const window = Region2D(tile.x - left, tile.y - top, width, height);
            const length = width * height;
            bool prepared;
            bool preparedRows;
            bool windowsReady, windowsOptimized;
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
                    cached = findCached(key,dependency||(plan.intermediate[feature]&&feature!=Feature.luminance));
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
                        version(ImageryProfile) const sinkStarted=MonoTime.currTime;
                        if(planar)sink(tile,cached,originFor(tile,feature));
                        else imageryEngineSinkValues(sink,tile,cached,originFor(tile,feature));
                        version(ImageryProfile) if(!planar)memory.sinkNanoseconds+=(MonoTime.currTime-sinkStarted).total!"nsecs";
                    }
                    return;
                }

                const descriptor = describeTileKernel(feature);
                foreach (needed; descriptor.dependencies[0 .. descriptor.dependencyCount])
                    if (needed != Feature.luminance)
                        compute(needed, true);

                if (!prepared)
                {
                    if(!usedScratch&&reuse)++memory.scratchReuses;
                    usedScratch=true;
                    if (input is null)
                    {
                        if (hasGabor && tuning.gabor != GaborParams.init) {
                            shapes.gabor = prepareGabor(tuning.gabor);
                            memory.scratchAllocations += 2;
                            bankBytes = shapes.gabor.length * GaborMember.sizeof;
                            foreach (member; shapes.gabor)
                                bankBytes += (member.realWeights.length + member.imaginaryWeights.length)*double.sizeof;
                        }
                        const side = executionEdge + 2 * halo;
                        input = new Sample[side * side];
                        points.reserve(input.length);
                        const area=executionEdge*executionEdge;
                        if(fullOutput)output=new Value[area];
                        memory.scratchAllocations += 3+fullOutput;
                        if(planar) {
                            foreach(ref plane;planes)plane=new float[area];
                            valid=new ubyte[area];oriented=new ubyte[area];rangeMask=new ubyte[area];
                            memory.scratchAllocations+=6;
                            if(hasPaths){rawPath=new double[area];++memory.scratchAllocations;}
                        }
                        if(hasBasic||hasStructuralRows) {
                            rowScratch.reserve(executionEdge,executionEdge,rowHalo,hasStructuralRows?4:0);
                            memory.scratchAllocations+=hasStructuralRows?2:1;
                        }
                        bool needsMoments;
                        foreach(f;plan.ordered[0..plan.length]) needsMoments|=localFeature(f);
                        if(needsMoments) {
                            momentRows=new WindowMoments[(executionEdge+2*statistics.radius)*executionEdge];
                            ++memory.scratchAllocations;
                        }
                        if (maxMorphologyRadius)
                        {
                            const wide = executionEdge + 2 * maxMorphologyRadius;
                            morphologyRows = new Point[wide * (executionEdge + 4 * maxMorphologyRadius)];
                            morphologyIntermediate = new Point[wide * wide];
                            memory.scratchAllocations += 2;
                        }
                        if(hasPaths && paths.length>1) {
                            const pathHalo=(paths.length-1)*max(1u,paths.lateralStep);
                            const pathSide=executionEdge+2*pathHalo;
                            pathScratch.reserve(executionEdge,executionEdge,paths,planar&&!fullOutput);
                            memory.scratchAllocations+=9;
                        }
                        const allocatedBytes=bankBytes + pathScratch.bytes + input.length * Sample.sizeof + points.length * ScalarTile.sampleBytes +
                            output.length * Value.sizeof + (valid.length+oriented.length+rangeMask.length)+rawPath.length*double.sizeof+
                            (planes[0].length+planes[1].length+planes[2].length)*float.sizeof +
                            momentRows.length*WindowMoments.sizeof +
                            (morphologyRows.length + morphologyIntermediate.length) * Point.sizeof;
                        const allAllocatedBytes=allocatedBytes+rowScratch.bytes;
                        assert(allAllocatedBytes==plannedTileBytes,"Feature scratch estimate must match retained arrays");
                        memory.peakTileBytes = max(memory.peakTileBytes,allAllocatedBytes);
                        scratchComplete=true;
                    }

                    // Basic/structural single-feature requests already own a
                    // packed row carrier. Borrow the provider's raster window
                    // and validate/pack it once, avoiding Sample and Point passes.
                    // Wide, masked and mixed-family requests retain read below.
                    if(!source.rgb&&requested.length==1&&
                        (basicRowFeature(feature)||structuralRowFeature(feature))) {
                        bool borrow(T)(scope bool delegate(Region2D,scope ScalarPlaneConsumer!T) @safe provide) {
                            size_t calls;bool clean,malformed;
                            version(ImageryProfile) const started=MonoTime.currTime;
                            version(ImageryProfile) const oldPreparation=memory.preparationNanoseconds;
                            scope ScalarPlaneConsumer!T consume=(scope ref const RasterPlaneWindow!T plane) @safe nothrow @nogc {
                                if(++calls!=1||plane.width!=window.width||plane.height!=window.height) {malformed=true;return;}
                                version(ImageryProfile) const preparationStarted=MonoTime.currTime;
                                static if(is(T==double))clean=imageryEnginePreparePlane64(rowScratch,plane,tile,window,source.width,source.height,rowHalo);
                                else clean=imageryEnginePreparePlane32(rowScratch,plane,tile,window,source.width,source.height,rowHalo);
                                version(ImageryProfile) memory.preparationNanoseconds+=(MonoTime.currTime-preparationStarted).total!"nsecs";
                            };
                            bool available;
                            static if(is(T==double))available=imageryEngineSourceBorrow64(provide,window,consume);
                            else available=imageryEngineSourceBorrow32(provide,window,consume);
                            version(ImageryProfile) memory.sourceNanoseconds+=(MonoTime.currTime-started).total!"nsecs"-
                                (memory.preparationNanoseconds-oldPreparation);
                            if(malformed||calls!=(available?1:0))throw new Exception("Scalar source plane extent, calls or availability invalid");
                            return available&&clean;
                        }
                        if(source.readPlane !is null)preparedRows=borrow!double(source.readPlane);
                        else if(source.readPlane32 !is null)preparedRows=borrow!float(source.readPlane32);
                    }
                    if(!preparedRows) {
                        version(ImageryProfile) const readStarted=MonoTime.currTime;
                        imageryEngineSourceRead(source,window,input[0..length]);
                        version(ImageryProfile) memory.sourceNanoseconds+=(MonoTime.currTime-readStarted).total!"nsecs";
                    } else ++memory.borrowedPlaneTiles;
                    ++memory.sourceTileReads;
                    version(ImageryProfile) const preparationStarted=MonoTime.currTime;
                    if (usesScalar&&!preparedRows)
                    {
                        ++memory.scalarTilePreparations;
                        imageryEnginePrepareSamples(input[0..length],source.rgb,points);
                    }
                    version(ImageryProfile) memory.preparationNanoseconds+=(MonoTime.currTime-preparationStarted).total!"nsecs";
                    prepared = true;
                }
                const morphologyRadius = squareMorphologyRadius(feature);

                const direct=planar&&!dependency&&(!plan.intermediate[feature]||feature==Feature.luminance);
                auto values=direct?null:output[0..count];
                version(ImageryProfile) const kernelStarted=MonoTime.currTime;
                const derived=descriptor.dependencyCount==2;
                const intermediate=derived?intermediates[descriptor.dependencies[1]]:null;
                void render(Output)(ref Output destination)
                {
                    if (intermediate !is null)
                    {
                        ++memory.dependencyTileHits;
                        foreach (i, prior; intermediate)
                        {
                            destination.invalidate(i);
                            if (!prior.valid)
                                continue;
                            if (feature == Feature.edgeEvidence)
                                destination.setValue(i,Value([clamp(prior.channels[0] / 0.125, 0.0, 1.0), 0, 0], true, false));
                            else
                            {
                                const center = points[(i / tile.width + top) * width + i % tile.width + left];
                                destination.setValue(i,fromLocalMoments(feature, center.value,
                                    prior.channels[0], prior.channels[1], tuning.shadowCeiling));
                            }
                        }
                    }
                    else if(localFeature(feature))
                    {
                        if(!windowsReady) {
                            bool extrema;
                            foreach(f;plan.ordered[0..plan.length])extrema|=f==Feature.dynamicRange;
                            windowsOptimized=evaluateWindows(TileReader(points[0..length],tile.x,tile.y,
                            source.width,source.height,window.x,window.y,width),
                            tile.width,tile.height,statistics.radius,momentRows,extrema);
                            windowsReady=true;
                        }
                        foreach(i,moment;momentRows[0..count]) {
                            destination.invalidate(i);
                            const center=points[(i/tile.width+top)*width+i%tile.width+left];
                            if(!windowsOptimized) {
                                destination.setValue(i,evaluate(feature,source.rgb,
                                    input[(i/tile.width+top)*width+i%tile.width+left],
                                    TileReader(points[0..length],tile.x+i%tile.width,tile.y+i/tile.width,
                                        source.width,source.height,window.x,window.y,width),statistics,paths,shapes,tuning.shadowCeiling));
                                continue;
                            }
                            if(!center.valid || moment.count<statistics.minimumValid ||
                                !isFinite(moment.mean) || !isFinite(moment.m2)) continue;
                            const deviation=sqrt(max(0.0,moment.m2/moment.count));
                            if(usesLocalMoments(feature))
                                destination.setValue(i,fromLocalMoments(feature,center.value,moment.mean,deviation,tuning.shadowCeiling));
                            else if(feature==Feature.dynamicRange) {
                                const range=moment.high-moment.low;
                                destination.setValue(i,Value([range,0,0],isFinite(range),false));
                            }
                            else destination.setValue(i,Value([moment.mean,deviation,0],true,false));
                        }
                    }
                    else if(feature==Feature.pathOpening || feature==Feature.pathClosing) {
                        const read=TileReader(points[0..length],tile.x,tile.y,
                            source.width,source.height,window.x,window.y,width);
                        if(!evaluatePathsInto(feature==Feature.pathClosing,tile.width,tile.height,
                            read,paths,pathScratch,destination))
                            foreach(y;0..tile.height)foreach(x;0..tile.width)
                                destination.setValue(y*tile.width+x,evaluate(feature,source.rgb,
                                    input[(y+top)*width+x+left],
                                    TileReader(points[0..length],tile.x+x,tile.y+y,
                                        source.width,source.height,window.x,window.y,width),statistics,paths,shapes,tuning.shadowCeiling));
                    }
                    else if (morphologyRadius)
                        evaluateSquareMorphologyInto(feature, cast(int)tile.width, cast(int)tile.height,
                            (int x, int y) {
                                const sx = offset(tile.x, x, source.width) - window.x;
                                const sy = offset(tile.y, y, source.height) - window.y;
                                return points[sy * width + sx];
                            }, morphologyRows, morphologyIntermediate, destination);
                    else if(preparedRows&&basicRowFeature(feature)&&rowScratch.basicLoaded(feature,tile.width,tile.height,destination)) {}
                    else if(preparedRows&&structuralRowFeature(feature)&&rowScratch.structuralLoaded(feature,tile.width,tile.height,rowHalo,shapes,destination)) {}
                    else if(basicRowFeature(feature) && rowScratch.basic(feature,tile.width,tile.height,
                        TileReader(points[0..length],tile.x,tile.y,source.width,source.height,window.x,window.y,width),
                        destination)) {}
                    else if(structuralRowFeature(feature) && rowScratch.structural(feature,tile.width,tile.height,
                        TileReader(points[0..length],tile.x,tile.y,source.width,source.height,window.x,window.y,width),
                        shapes,destination)) {}
                    else
                        foreach (y; 0 .. tile.height)
                            foreach (x; 0 .. tile.width)
                            {
                                const center = input[(y + top) * width + x + left];
                                destination.setValue(y * tile.width + x,evaluate(feature, source.rgb, center,
                                    TileReader(points[0 .. length], tile.x+x, tile.y+y,
                                        source.width, source.height, window.x, window.y, width), statistics, paths, shapes, tuning.shadowCeiling));
                            }

                }
                if(direct) {
                    auto destination=Float32TileOutput(planes,valid,oriented,rangeMask,
                        feature==Feature.pathOpening||feature==Feature.pathClosing?rawPath:null);
                    render(destination);
                } else {
                    auto destination=ValueTileOutput(values);render(destination);
                }

                version(ImageryProfile) memory.kernelNanoseconds+=(MonoTime.currTime-kernelStarted).total!"nsecs";
                if (dependency)
                    ++memory.dependencyEvaluations;
                else
                    ++memory.featureEvaluations;

                if(direct) {
                    auto finalKey=tileIdentity(source,tile,feature);
                    finalKey.parameters=planarParameterText[feature];finalKey.halo=configuration.halo(feature);
                    version(ImageryProfile) const cacheStarted=MonoTime.currTime;
                    FeaturePlanes32 result;imageryEngineCacheExchange(planarCache,finalKey,planes,valid,oriented,rangeMask,result);
                    version(ImageryProfile) memory.cacheNanoseconds+=(MonoTime.currTime-cacheStarted).total!"nsecs";
                    planarSink(tile,result,originFor(tile,feature));return;
                }
                version(ImageryProfile) const cacheStarted=MonoTime.currTime;
                const keep=dependency||(plan.intermediate[feature]&&feature!=Feature.luminance);
                auto retained=cacheOnlyDependencies&&!keep?null:imageryEngineCacheValues(this,key,values,keep);
                version(ImageryProfile) memory.cacheNanoseconds+=(MonoTime.currTime-cacheStarted).total!"nsecs";
                if (dependency || (plan.intermediate[feature] && feature != Feature.luminance))
                {
                    intermediates[feature] = retained;
                    dependencyBytes += count * Value.sizeof;
                    memory.peakDependencyBytes = max(memory.peakDependencyBytes, dependencyBytes);
                }
                if (!dependency)
                {
                    version(ImageryProfile) const sinkStarted=MonoTime.currTime;
                    if(planar)sink(tile,values,originFor(tile,feature));
                    else imageryEngineSinkValues(sink,tile,values,originFor(tile,feature));
                    version(ImageryProfile) if(!planar)memory.sinkNanoseconds+=(MonoTime.currTime-sinkStarted).total!"nsecs";
                }
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

// Differential public-API transport law, including signed raster strides,
// edge halos, finite-domain fallbacks and final Float32 publication. Only
// fixture allocation/adoption needs @system; the providers/Engine stay @safe.
@system unittest
{
    import raster : RasterLease,OwnedByteResource,PlaneByteLayout,tryAdoptMallocResource,tryImportOwnedRaster,withPlane;
    import core.stdc.stdlib : malloc;
    import std.meta : AliasSeq;
    import std.math : signbit;
    enum w=19,h=13;
    static foreach(T;AliasSeq!(float,double)) {
        foreach(reverse;[false,true])foreach(step;[1UL,T.sizeof])foreach(scenario;0..6) {
            auto data=new T[w*h];
            foreach(i,ref v;data)v=cast(T)(cast(float)((i*37+i/w*17)%256)/255);
            if(scenario==1)data[17]=T.nan;
            if(scenario==2)data[17]=T.infinity;
            if(scenario==3)data[17]=cast(T)-0.0;
            if(scenario==4)foreach(ref v;data)v=cast(T)(1e12+v);
            auto bytes=cast(T*)malloc(w*h*step*T.sizeof);assert(bytes !is null);
            foreach(y;0..h)foreach(x;0..w)bytes[((reverse?h-1-y:y)*w+x)*step]=data[y*w+x];
            OwnedByteResource resource;assert(tryAdoptMallocResource(bytes,w*h*step*T.sizeof,resource));
            const rowStride=cast(ptrdiff_t)(w*step*T.sizeof)*(reverse?-1:1);
            PlaneByteLayout[1] layouts=[PlaneByteLayout(reverse?(h-1)*w*step*T.sizeof:0,rowStride,step*T.sizeof)];
            RasterLease!T owner;assert(tryImportOwnedRaster!T(resource,layouts[],Region2D(0,0,w,h),owner).ok);
            auto source=Source("plane-law","1","grid","intensity","1",0,w,h,false);
            size_t offered,reads;int broken;
            source.read=(Region2D r,scope Sample[] values) @safe {
                ++reads;foreach(i,ref v;values) {const index=(r.y+i/r.width)*w+r.x+i%r.width;
                    v=Sample(data[index],[0,0,0],scenario!=5||index%7!=0);}
            };
            bool provide(Region2D r,scope ScalarPlaneConsumer!T consume) @safe {
                ++offered;if(scenario==5)return false;auto parent=owner.view();bool ok;
                scope auto child=parent.tryRoi(r,ok);assert(ok);
                if(broken==1)return true; // claimed availability without a call
                if(broken==4) {child=parent.tryRoi(Region2D(r.x,r.y,r.width-1,r.height),ok);assert(ok);}
                const available=withPlane(child,0,(scope ref const RasterPlaneWindow!T plane) @safe nothrow @nogc {
                    consume(plane);if(broken==2)consume(plane);
                });
                return broken==3?false:available;
            }
            foreach(feature;[Feature.gaussian,Feature.gradient,Feature.median,Feature.ridge,Feature.gabor]) {
                foreach(edge;[5UL,19UL]) {
                    auto expected=new Value[w*h],actual=new Value[w*h];Engine baseline,candidate;
                    source.readPlane=null;source.readPlane32=null;
                    baseline.run(source,Region2D(0,0,w,h),feature,edge,
                        (Region2D r,scope const(Value)[] values,Provenance p) @safe {
                            foreach(i,v;values)expected[(r.y+i/r.width)*w+r.x+i%r.width]=v;
                        });
                    static if(is(T==double))source.readPlane=&provide;else source.readPlane32=&provide;
                    const priorReads=reads;
                    candidate.run(source,Region2D(0,0,w,h),feature,edge,
                        (Region2D r,scope const(Value)[] values,Provenance p) @safe {
                            assert(p.identity==source.identity&&p.revision==source.revision);
                            foreach(i,v;values)actual[(r.y+i/r.width)*w+r.x+i%r.width]=v;
                        });
                    assert(offered>0);
                    if(scenario==0) {
                        assert(candidate.metrics.borrowedPlaneTiles>0,T.stringof~" clean plane must use the borrow path");
                        assert(reads==priorReads,"Clean borrow must not call Sample transport");
                        if(edge==19)foreach(failure;1..5) {
                            broken=failure;source.revision="broken";
                            bool rejected;size_t delivered;
                            try {candidate.run(source,Region2D(0,0,w,h),feature,edge,
                                (Region2D r,scope const(Value)[] values,Provenance p) @safe {++delivered;});}
                            catch(Exception){rejected=true;}
                            assert(rejected&&delivered==0,"Malformed borrow must publish no tile");
                            source.revision="1";broken=0;
                            const retained=candidate.findCached(tileIdentity(source,Region2D(0,0,w,h),feature));
                            assert(retained !is null&&retained==actual,"Failed revision must preserve committed cache");
                        }
                    }
                    if(scenario>=1&&scenario<=4&&edge==19)
                        assert(reads>priorReads&&candidate.metrics.borrowedPlaneTiles==0,
                            "Nonfinite, negative-zero and wide planes must use Sample fallback");
                    foreach(i,a;actual) {
                        const b=expected[i];assert(a.valid==b.valid&&a.orientationValid==b.orientationValid);
                        foreach(c;0..3)assert(a.channels[c]==b.channels[c]&&
                            (a.channels[c]!=0||signbit(a.channels[c])==signbit(b.channels[c])));
                    }
                }
            }
        }
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
    scope Sample[] scratch, ref ClaheMap map, ClaheParams parameters)
{
    map = ClaheMap.init;
    map.initialized = true;
    const left = x * parameters.cellEdge;
    const top = y * parameters.cellEdge;
    const width = min(parameters.cellEdge, source.width - left);
    const height = min(parameters.cellEdge, source.height - top);
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

    import std.math : ceil;
    const limit = max(1u, cast(uint)ceil(parameters.clipFactor * count / 256));
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

private CellAxis cellAxis(size_t pixel, size_t length, size_t cellEdge)
{
    const last = (length - 1) / cellEdge;
    if (pixel < cellEdge / 2 || last == 0)
        return CellAxis(0, 0, 0);
    const shifted = pixel - cellEdge / 2;
    const first = min(last, shifted / cellEdge);
    return CellAxis(first, min(last, first + 1), (shifted % cellEdge + 0.5) / cellEdge);
}

/// Fixed-grid CLAHE on RGB8 linear luminance. Cell centers are anchored
/// to the source, with bilinear interpolation across nonempty neighboring cells.
void equalizeLuminanceLocally(ref Engine engine, const Source source, Region2D region,
    size_t edge, scope Sink sink)
{
    equalizeLuminanceLocally(engine, source, region, edge, ClaheParams.init, sink);
}

/// CLAHE with explicit source-anchored cell geometry and histogram clip factor.
/// Parameters, source, region and tile edge are validated before any reads or
/// allocations. Throws Exception on invalid input. Reuses underlying luminance
/// tiles; CLAHE maps/output are not cached. Provenance records all settings.
void equalizeLuminanceLocally(ref Engine engine, const Source source, Region2D region,
    size_t edge, ClaheParams parameters, scope Sink sink)
{
    parameters.validate();
    validate(source, region);
    if (!source.rgb || sink is null)
        throw new Exception("CLAHE requires RGB8 and an output sink");
    if (!edge || edge > 256) throw new Exception("Unsupported CLAHE tile edge");

    // Small cells need more maps; cap processing tiles to preserve 8 MiB.
    const executionEdge = parameters.cellEdge < 16 ? min(edge, 192UL) : edge;
    const maxMapsPerAxis = (executionEdge + parameters.cellEdge - 1)/parameters.cellEdge + 2;
    Sample[] cellScratch;
    ClaheMap[] maps;
    Value[] scratch;
    import std.format : format;
    const identity = parameters == ClaheParams.init ? fixedParameters(Feature.clahe) :
        format!"cells=%sx%s;bins=256;clip-factor=%.17g;grid=source-anchored;interpolation=bilinear;empty=renormalize;constant=identity"(
            parameters.cellEdge, parameters.cellEdge, parameters.clipFactor);
    engine.run(source, region, Feature.luminance, executionEdge,
        (Region2D tile, scope const(Value)[] input, Provenance origin) {
            if (scratch is null) {
                scratch = new Value[executionEdge * executionEdge];
                cellScratch = new Sample[parameters.cellEdge * parameters.cellEdge];
                maps = new ClaheMap[maxMapsPerAxis * maxMapsPerAxis];
                engine.memory.scratchAllocations += 3;
                engine.memory.peakTileBytes = max(engine.memory.peakTileBytes,
                    executionEdge*executionEdge*(Sample.sizeof+Point.sizeof+2*Value.sizeof) +
                    cellScratch.length*Sample.sizeof + maps.length*ClaheMap.sizeof);
            }
            auto output = scratch[0 .. input.length];
            const firstCellX = cellAxis(tile.x, source.width, parameters.cellEdge).first;
            const firstCellY = cellAxis(tile.y, source.height, parameters.cellEdge).first;
            foreach (ref map; maps)
                map.initialized = false;
            foreach (i, value; input)
            {
                output[i] = Value.init;
                if (!value.valid)
                    continue;
                const x = cellAxis(tile.x + i % tile.width, source.width, parameters.cellEdge);
                const y = cellAxis(tile.y + i / tile.width, source.height, parameters.cellEdge);
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
                            fitCell(source, cx, cy, cellScratch[], *map, parameters);
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
            origin.parameters = identity;
            origin.validity = featureValidity(origin.feature);
            sink(tile, output, origin);
        });
}
