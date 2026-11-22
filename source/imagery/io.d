/**
 * Image I/O handoff for the default imagery configuration.
 *
 * This module exposes imageio's neutral decoded-region contract and, when
 * imageio I/O is enabled, its typed TIFF/PNG/JPEG writer facade. The semantic
 * interpretation and raster ownership remain in imagery-d and raster-d;
 * imageio owns file-format encoding, metadata policy and atomic publication.
 */
module imagery.io;

version (imageio_io)
{
import core.stdc.stdlib : malloc, free;
import imageio : ImageFormat, ImageRegion, ImageRegionInfo, ImagePlane,
    PlaneGeometryStatus, ComponentRole, SourceModel, MetadataState,
    ColorMatrix, ColorRange, TransferFunction, ColorPrimaries, SampleSignedness,
    ImagePlaneInfo, Rational,
    TiffDecodeError,
    PixelLayout, SampleFormat, TiffRegionPlan, decodeRegion, detectFormat,
    decodeRegionAtBestLevel, inspectLevels, planRegion, planRegionAtLevel,
    selectLevel;
public import imageio.io : ImageWriteError, ImageWriteFormat, ImageWriteOptions,
    ImageWriteRequest, ImageWriteResult, MetadataDisposition, MetadataPolicy,
    writeAtomically;
public import imageio.tiff_write : TiffWriteInfo, TiffWriteMetadata,
    TiffWriteRequirements, tiffWriteRequirements, writeClassicTiff,
    writeClassicTiffFile, writeImage, writeImageFile;
public import imageio.png_write : PngWriteInfo, writePng;
public import imageio.jpeg_io : JpegWriteInfo, JpegWriteMetadata,
    writeJpeg;
import std.string : startsWith;
import transport : ByteSource, FileSource;
import transport.http_curl : CurlHttpSource;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease,
    tryAdoptMallocResource, tryImportOwnedRaster, Region2D;
import color : SRgb, SRgbd, YCbCr, YCbCrMatrix, YCbCrRange,
    Bt601Full, Bt601Video, Bt709Full, Bt709Video,
    Bt2020Full, Bt2020Video;
import color.ycbcr : toSRgb;
import color : SRgb8, tryToSRgb8;
import std.algorithm : min, max;
import imagery.materialization : isImageModel, isGeometryPolicy, isOutputPolicy;

/** A decoded region accepted by imagery-side materialization code. */
struct DecodedImageRegion
{
    ImageRegionInfo description;
    ImageRegion region;
}

/** An explicit policy for turning imageio's neutral region into an image
 * representation. No policy is selected implicitly. */
enum ImageMaterialization : ubyte
{
    nativePlanes,
    upsampledComponents,
    upsampledComponentsBilinear,
    rgb
}

/// Materialization status. Result fields initialize to notAttempted, preserving
/// the historical enum numbers. none is reported only by a completed operation.
enum ImageMaterializationError : ubyte
{
    none,
    unsupportedMode,
    missingColorModel,
    missingPlanes,
    invalidPlane,
    allocationFailure,
    missingGeometry,
    unsupportedGeometry,
    conflictingGeometry,
    notAttempted, invalidGeometry, invalidRegion, componentCountMismatch,
    missingComponentRole, invalidComponentRole, conflictingMetadata,
    unsupportedColorModel, missingMatrix, unsupportedMatrix, missingRange,
    unsupportedRange, missingTransfer, unsupportedTransfer, missingPrimaries,
    unsupportedPrimaries, missingBitDepth, unsupportedBitDepth,
    unsupportedSampleFormat, policyMismatch, invalidOutputPolicy,
    resultExceedsBudget, invalidConsumer, consumerRejected
}

/** Owned native component planes. Plane geometry and sampling metadata are
 * preserved exactly; no chroma or colour interpretation is performed. */
struct NativePlanesMaterialization
{
    ImagePlane[] planes;
    /// Original source/color description and region origin, without pixel copies.
    ImageRegionInfo source;
    /// Reference-grid origin of the original region.
    size_t originX, originY;

    @property bool ok() const @safe pure nothrow @nogc
    { return planes.length != 0; }
}

/// Visit validated native u8 planes without copying or interpreting their source
/// metadata. Unavailable/conflicting geometry and color remain inspectable.
/// The source owner controls byte lifetime; do not retain borrowed plane data
/// beyond that lifetime. DIP1000 does not enforce deep aggregate-slice retention.
/// Source storage must remain unchanged. imagery-d retains neither bytes nor callback.
ImageMaterializationError visitNativePlanes(scope ImageRegion image,
    scope bool delegate(scope const ImageRegion source) @safe consumer) @safe
{
    if(consumer is null)return ImageMaterializationError.invalidConsumer;
    const status=validateComponents(image,false);
    if(status!=ImageMaterializationError.none)return status;
    return consumer(image)?ImageMaterializationError.none:ImageMaterializationError.consumerRejected;
}

/// Owned native/component result; .init has notAttempted status and no planes.
struct ImageMaterializationResult
{
    ImageMaterializationError error = ImageMaterializationError.notAttempted;
    NativePlanesMaterialization native;

    @property bool ok() const @safe pure nothrow @nogc
    { return error == ImageMaterializationError.none; }
}

/// Owned GC array result; .init is notAttempted. Only .ok results contain pixels.
struct RgbMaterializationResult(T)
{
    static if (is(T == ubyte))
        struct Pixel { ubyte r; ubyte g; ubyte b; }
    else
        alias Pixel = SRgb!T;
    ImageMaterializationError error = ImageMaterializationError.notAttempted;
    size_t width;
    size_t height;
    Pixel[] pixels;

    @property bool ok() const @safe pure nothrow @nogc
    { return error == ImageMaterializationError.none; }
}

private ImageMaterializationError validateComponents(scope const ImageRegion image,
    bool requireGeometry) @safe pure nothrow @nogc
{
    alias E=ImageMaterializationError;
    if (image.info.sampleFormat!=SampleFormat.u8) return E.unsupportedSampleFormat;
    if (!image.info.width || !image.info.height ||
        image.originX>size_t.max-image.info.width || image.originY>size_t.max-image.info.height)
        return E.invalidRegion;
    if (!image.planes.length) return E.missingPlanes;
    if (image.info.componentCount!=image.planes.length) return E.componentCountMismatch;
    foreach (ref plane;image.planes)
    {
        if (!plane.width || !plane.height || plane.rowStrideBytes<plane.width ||
            plane.height-1>(size_t.max-plane.width)/plane.rowStrideBytes ||
            plane.data.length<(plane.height-1)*plane.rowStrideBytes+plane.width ||
            plane.originX>size_t.max-plane.width || plane.originY>size_t.max-plane.height)
            return E.invalidPlane;
        if (!requireGeometry) continue;
        const g=plane.info.geometry;
        switch (g.status)
        {
            case PlaneGeometryStatus.known: break;
            case PlaneGeometryStatus.unavailable: return E.missingGeometry;
            case PlaneGeometryStatus.unsupported: return E.unsupportedGeometry;
            case PlaneGeometryStatus.conflicting: return E.conflictingGeometry;
            default: return E.invalidGeometry;
        }
        if (!g.horizontalFactor || !g.verticalFactor || !g.centerOffsetX.valid || !g.centerOffsetY.valid ||
            !plane.referenceOffsetX.valid || !plane.referenceOffsetY.valid) return E.invalidGeometry;
        // This adapter admits sub-cell phases, not arbitrary translations hidden
        // in rational phase fields. The bound prevents catastrophic cancellation
        // after float64 conversion; integer storage origins carry translations.
        foreach(i,rational;[g.centerOffsetX,g.centerOffsetY,plane.referenceOffsetX,plane.referenceOffsetY])
        {
            const spacing=i%2?g.verticalFactor:g.horizontalFactor;
            const magnitude=rational.numerator<0?0UL-cast(ulong)rational.numerator:cast(ulong)rational.numerator;
            const whole=magnitude/rational.denominator;
            if(whole>spacing || (whole==spacing && magnitude%rational.denominator))return E.unsupportedGeometry;
        }
    }
    return E.none;
}

private ImageMaterializationError validateRgb(alias Spec)(scope const ImageRegion image)
    @safe pure nothrow @nogc
{
    alias E=ImageMaterializationError;
    const validation=validateComponents(image,true);
    if (validation!=E.none) return validation;
    if (image.info.componentCount!=Spec.model.componentCount) return E.componentCountMismatch;
    enum y=Spec.model.yPlane, cb=Spec.model.cbPlane, cr=Spec.model.crPlane;
    if (y>=image.planes.length || cb>=image.planes.length || cr>=image.planes.length ||
        y==cb || y==cr || cb==cr) return E.invalidComponentRole;
    bool haveY,haveCb,haveCr;
    foreach (ref plane;image.planes)
    {
        switch(plane.info.role)
        {
            case ComponentRole.luma: if(haveY)return E.invalidComponentRole; haveY=true; break;
            case ComponentRole.chromaBlue: if(haveCb)return E.invalidComponentRole; haveCb=true; break;
            case ComponentRole.chromaRed: if(haveCr)return E.invalidComponentRole; haveCr=true; break;
            default: break;
        }
    }
    if(!haveY || !haveCb || !haveCr) return E.missingComponentRole;
    if(image.planes[y].info.role!=ComponentRole.luma || image.planes[cb].info.role!=ComponentRole.chromaBlue ||
        image.planes[cr].info.role!=ComponentRole.chromaRed) return E.invalidComponentRole;
    const m=image.info.colorMetadata;
    foreach(state;[m.state,m.modelState,m.matrixState,m.rangeState,m.transferState,m.primariesState,m.bitDepthState])
        if(state==MetadataState.conflicting || state>MetadataState.conflicting) return E.conflictingMetadata;
    if(m.state==MetadataState.unsupported)return E.unsupportedColorModel;
    if(m.state!=MetadataState.known)return E.missingColorModel;
    if(m.modelState==MetadataState.absent || m.model==SourceModel.unknown || image.info.sourceModel==SourceModel.unknown)
        return E.missingColorModel;
    if(m.modelState!=MetadataState.known) return E.unsupportedColorModel;
    if(m.model!=image.info.sourceModel) return E.conflictingMetadata;
    if(m.model!=SourceModel.yCbCr) return E.unsupportedColorModel;
    if(m.matrixState==MetadataState.absent) return E.missingMatrix;
    if(m.matrixState!=MetadataState.known || (m.matrix!=ColorMatrix.bt601 && m.matrix!=ColorMatrix.bt709)) return E.unsupportedMatrix;
    if(m.rangeState==MetadataState.absent) return E.missingRange;
    if(m.rangeState!=MetadataState.known || (m.range!=ColorRange.full && m.range!=ColorRange.video)) return E.unsupportedRange;
    if(m.transferState==MetadataState.absent) return E.missingTransfer;
    if(m.transferState!=MetadataState.known || m.transfer!=TransferFunction.sRGB) return E.unsupportedTransfer;
    if(m.primariesState==MetadataState.absent) return E.missingPrimaries;
    if(m.primariesState!=MetadataState.known || m.primaries!=ColorPrimaries.bt709) return E.unsupportedPrimaries;
    if(m.bitDepthState==MetadataState.absent) return E.missingBitDepth;
    if(m.bitDepthState!=MetadataState.known || m.bitDepth!=8 || Spec.model.colorPolicy.bitDepth!=8) return E.unsupportedBitDepth;
    if(m.signedness!=SampleSignedness.unsigned) return E.unsupportedSampleFormat;
    const expectedMatrix=Spec.model.colorPolicy.matrix==YCbCrMatrix.bt601?ColorMatrix.bt601:
        Spec.model.colorPolicy.matrix==YCbCrMatrix.bt709?ColorMatrix.bt709:ColorMatrix.unknown;
    const expectedRange=Spec.model.colorPolicy.range==YCbCrRange.full?ColorRange.full:ColorRange.video;
    if(m.matrix!=expectedMatrix || m.range!=expectedRange) return E.policyMismatch;
    static if(is(Spec.output.Sample==ubyte)) {if(!Spec.output.clip)return E.invalidOutputPolicy;}
    else {if(Spec.output.clip)return E.invalidOutputPolicy;}
    static if(Spec.geometry.kind=="native")
    {
        foreach(index;[y,cb,cr])
        {
            const p=image.planes[index], g=p.info.geometry;
            if(p.width!=image.info.width || p.height!=image.info.height ||
                p.originX!=image.originX || p.originY!=image.originY ||
                g.horizontalFactor!=1 || g.verticalFactor!=1 || g.centerOffsetX.numerator ||
                g.centerOffsetY.numerator || p.referenceOffsetX.numerator || p.referenceOffsetY.numerator)
                return E.invalidGeometry;
        }
    }
    else static if(Spec.geometry.kind!="nearest" && Spec.geometry.kind!="bilinear") return E.unsupportedMode;
    return E.none;
}

// Invert imageio.sampleCenter(origin,index,spacing,cropOffset), then add the
// separately declared geometry center offset. Divide BEFORE converting the
// large unsigned origins to double, preserving small differences near size_t.max.
private double componentCoordinate(size_t target,size_t origin,uint spacing,
    long centerNumerator,ulong centerDenominator,long cropNumerator,ulong cropDenominator)
    @safe pure nothrow @nogc
{
    const whole=target/spacing;
    const difference=whole>=origin?cast(double)(whole-origin):-cast(double)(origin-whole);
    return difference+(cast(double)(target%spacing)-cast(double)centerNumerator/centerDenominator-
        cast(double)cropNumerator/cropDenominator)/spacing;
}

private double componentSample(scope ref const ImagePlane plane,size_t x,size_t y,bool bilinear)
    @safe pure nothrow @nogc
{
    const g=plane.info.geometry;
    const px=min(cast(double)(plane.width-1),max(0.0,componentCoordinate(x,plane.originX,g.horizontalFactor,
        g.centerOffsetX.numerator,g.centerOffsetX.denominator,plane.referenceOffsetX.numerator,plane.referenceOffsetX.denominator)));
    const py=min(cast(double)(plane.height-1),max(0.0,componentCoordinate(y,plane.originY,g.verticalFactor,
        g.centerOffsetY.numerator,g.centerOffsetY.denominator,plane.referenceOffsetY.numerator,plane.referenceOffsetY.denominator)));
    if(!bilinear)
        return plane.data[min(plane.height-1,cast(size_t)(py+.5))*plane.rowStrideBytes+
            min(plane.width-1,cast(size_t)(px+.5))];
    const x0=cast(size_t)px,y0=cast(size_t)py,x1=min(x0+1,plane.width-1),y1=min(y0+1,plane.height-1);
    const fx=px-x0,fy=py-y0;
    const a=plane.data[y0*plane.rowStrideBytes+x0]*(1-fx)+plane.data[y0*plane.rowStrideBytes+x1]*fx;
    const b=plane.data[y1*plane.rowStrideBytes+x0]*(1-fx)+plane.data[y1*plane.rowStrideBytes+x1]*fx;
    return a*(1-fy)+b*fy;
}

private SRgbd rgbSample(alias Spec)(scope const ImageRegion image,size_t x,size_t y)
    @safe pure nothrow @nogc
{
    enum bilinear=Spec.geometry.kind=="bilinear";
    return toSRgb(YCbCr!(double,Spec.model.colorPolicy)(
        componentSample(image.planes[Spec.model.yPlane],image.originX+x,image.originY+y,bilinear)/255,
        componentSample(image.planes[Spec.model.cbPlane],image.originX+x,image.originY+y,bilinear)/255,
        componentSample(image.planes[Spec.model.crPlane],image.originX+x,image.originY+y,bilinear)/255));
}

private SRgb8 clippedRgb(SRgbd input) @safe pure nothrow @nogc
{
    SRgb8 output;
    const valid=tryToSRgb8(SRgbd(min(1.0,max(0.0,input.r)),min(1.0,max(0.0,input.g)),
        min(1.0,max(0.0,input.b))),output);
    assert(valid); // finite u8 samples and prevalidated 8-bit policies
    return output;
}

/** Convert one normalized YCbCr sample using an explicit color-d policy.
 * Plane geometry and chroma upsampling remain separate materialization steps. */
SRgbd convertYCbCr(double y, double cb, double cr,
    YCbCrMatrix matrix, YCbCrRange range)
@safe pure nothrow @nogc
{
    final switch (matrix)
    {
    case YCbCrMatrix.bt601:
        if (range == YCbCrRange.full)
            return toSRgb(YCbCr!(double, Bt601Full)(y, cb, cr));
        return toSRgb(YCbCr!(double, Bt601Video)(y, cb, cr));
    case YCbCrMatrix.bt709:
        if (range == YCbCrRange.full)
            return toSRgb(YCbCr!(double, Bt709Full)(y, cb, cr));
        return toSRgb(YCbCr!(double, Bt709Video)(y, cb, cr));
    case YCbCrMatrix.bt2020:
        if (range == YCbCrRange.full)
            return toSRgb(YCbCr!(double, Bt2020Full)(y, cb, cr));
        return toSRgb(YCbCr!(double, Bt2020Video)(y, cb, cr));
    }
}


/** Copy native u8 component planes or explicitly resample them to the reference
 * grid. Source origins, geometry, roles and crop offsets survive native copying.
 * Component output is u8; interpolation is rounded once to the nearest byte.
 * Floating RGB conversion samples the source directly and does not use this
 * byte-quantized component representation. No source bytes are retained.
 * maxResultBytes bounds plane payload, excluding O(component count) descriptors.
 */
ImageMaterializationResult materialize(ImageRegion image,
    ImageMaterialization mode = ImageMaterialization.nativePlanes,
    size_t maxResultBytes = size_t.max) @safe
{
    alias E=ImageMaterializationError;
    if(mode==ImageMaterialization.rgb)return ImageMaterializationResult(E.missingColorModel);
    if(mode>ImageMaterialization.rgb)return ImageMaterializationResult(E.unsupportedMode);
    const resample=mode!=ImageMaterialization.nativePlanes;
    const status=validateComponents(image,resample);
    if(status!=E.none)return ImageMaterializationResult(status);
    size_t bytes;
    if(resample)
    {
        if(image.info.width>cast(size_t)ptrdiff_t.max/image.info.height/image.planes.length)
            return ImageMaterializationResult(E.resultExceedsBudget);
        bytes=image.info.width*image.info.height*image.planes.length;
    }
    else foreach(ref plane;image.planes)
    {
        const span=(plane.height-1)*plane.rowStrideBytes+plane.width;
        if(span>cast(size_t)ptrdiff_t.max-bytes)return ImageMaterializationResult(E.resultExceedsBudget);
        bytes+=span;
    }
    if(bytes>maxResultBytes)return ImageMaterializationResult(E.resultExceedsBudget);
    auto owned=new ImagePlane[image.planes.length];
    foreach(index,ref source;image.planes)
    {
        owned[index]=source; // preserve every source fact, including crop phase
        if(!resample)
        {
            const span=(source.height-1)*source.rowStrideBytes+source.width;
            owned[index].data=source.data[0..span].dup;
            continue;
        }
        auto data=new ubyte[image.info.width*image.info.height];
        foreach(y;0..image.info.height)foreach(x;0..image.info.width)
            data[y*image.info.width+x]=cast(ubyte)(componentSample(source,image.originX+x,image.originY+y,
                mode==ImageMaterialization.upsampledComponentsBilinear)+.5);
        auto info=source.info;
        info.horizontalSampling=info.verticalSampling=1;
        info.geometry=typeof(info.geometry)(1,1,typeof(info.geometry.centerOffsetX).init,
            typeof(info.geometry.centerOffsetY).init,PlaneGeometryStatus.known);
        owned[index]=ImagePlane(info,image.info.width,image.info.height,image.originX,image.originY,
            image.info.width,data);
    }
    return ImageMaterializationResult(E.none,NativePlanesMaterialization(owned,image.info,image.originX,image.originY));
}

/** Typed component geometry; this legacy component result remains u8.
 * Spec.output selects the sample representation of materializeRgb, not the
 * ImagePlane byte storage contract. Component count is checked before copying.
 */
ImageMaterializationResult materialize(alias Spec)(ImageRegion image,
    size_t maxResultBytes=size_t.max) @safe
if (isImageModel!(Spec.model) && isGeometryPolicy!(Spec.geometry) && isOutputPolicy!(Spec.output))
{
    if(image.info.componentCount!=Spec.model.componentCount)
        return ImageMaterializationResult(ImageMaterializationError.componentCountMismatch);
    static if(Spec.geometry.kind=="native")enum mode=ImageMaterialization.nativePlanes;
    else static if(Spec.geometry.kind=="nearest")enum mode=ImageMaterialization.upsampledComponents;
    else static if(Spec.geometry.kind=="bilinear")enum mode=ImageMaterialization.upsampledComponentsBilinear;
    else return ImageMaterializationResult(ImageMaterializationError.unsupportedMode);
    static if(__traits(compiles,mode))return materialize(image,mode,maxResultBytes);
}

/** Convert explicitly mapped u8 YCbCr planes to encoded-sRGB samples.
 * Matrix/range must match the supplied color-d policy. Known sRGB transfer,
 * BT.709/sRGB primaries, unsigned 8-bit samples, roles and usable geometry are
 * required. Missing/unsupported/conflicting facts produce distinct errors.
 * Float output preserves extended values; byte output clips then uses color-d
 * nearest-byte quantization. Bilinear components stay float64 until conversion.
 * Coordinates invert imageio.sampleCenter plus the declared geometry offset;
 * there is no additional half-pixel convention. .init results are not success.
 */
RgbMaterializationResult!(Spec.output.Sample) materializeRgb(alias Spec)(ImageRegion image,
    size_t maxResultBytes=size_t.max) @safe
if (isImageModel!(Spec.model) && isGeometryPolicy!(Spec.geometry) && isOutputPolicy!(Spec.output))
{
    alias Result=RgbMaterializationResult!(Spec.output.Sample);
    static if(!__traits(compiles,Spec.model.colorPolicy.matrix,Spec.model.colorPolicy.range,
        Spec.model.colorPolicy.bitDepth,Spec.model.yPlane,Spec.model.cbPlane,Spec.model.crPlane))
        return Result(ImageMaterializationError.missingColorModel);
    else
    {
        const status=validateRgb!Spec(image);
        if(status!=ImageMaterializationError.none)return Result(status);
        if(image.info.width>cast(size_t)ptrdiff_t.max/image.info.height/Result.Pixel.sizeof ||
            image.info.width*image.info.height>maxResultBytes/Result.Pixel.sizeof)
            return Result(ImageMaterializationError.resultExceedsBudget);
        auto pixels=new Result.Pixel[image.info.width*image.info.height];
        foreach(y;0..image.info.height)foreach(x;0..image.info.width)
        {
            const rgb=rgbSample!Spec(image,x,y);
            static if(is(Spec.output.Sample==ubyte))
            {
                const b=clippedRgb(rgb);
                pixels[y*image.info.width+x]=Result.Pixel(b.r,b.g,b.b);
            }
            else pixels[y*image.info.width+x]=SRgb!(Spec.output.Sample)(
                cast(Spec.output.Sample)rgb.r,cast(Spec.output.Sample)rgb.g,cast(Spec.output.Sample)rgb.b);
        }
        return Result(ImageMaterializationError.none,image.info.width,image.info.height,pixels);
    }
}

/// Compatibility float-raster result; .init is notAttempted and owns no pixels.
/// Use OwnedRgbMaterialization when source geometry/provenance is needed.
struct RgbFloatRasterResult
{
    ImageMaterializationError error = ImageMaterializationError.notAttempted;
    RasterLease!float raster;

    @property bool ok() const @safe pure nothrow @nogc
    { return error == ImageMaterializationError.none; }
}

/// Source-plane geometry only; no source sample arrays or decoder owners.
struct MaterializedComponentOrigin
{
    /// Decoder component identity/role, source sampling factors and center offsets.
    ImagePlaneInfo info;
    /// Storage origin in source-plane coordinates.
    size_t originX, originY;
    /// Crop alignment reported by imageio, separate from sample siting.
    Rational referenceOffsetX, referenceOffsetY;
    /// Caller-verified plane index in the original decoder result.
    size_t index;
}

/// Owned encoded-sRGB result. `.init` is empty; only explicit success publishes.
/// Lease copies retain storage; use serially because raster-d counts are non-atomic.
struct OwnedRgbMaterialization(T)
if(is(T==float) || is(T==double) || is(T==ubyte))
{
    /// Three interleaved RGB planes, with ROI-local coordinates starting at zero.
    RasterLease!T raster;
    /// Original technical source description, including color facts.
    ImageRegionInfo source;
    /// Source region origin in the reference grid.
    size_t originX, originY;
    /// Original Y/Cb/Cr mapping and coordinate facts, in that order.
    MaterializedComponentOrigin[3] components;
    /// Explicit geometry policy and versioned coordinate recipe.
    string sampling, recipe;
}

/// Empty owners are inert; copying a completed value retains raster storage.
@safe unittest
{
    OwnedRgbMaterialization!float frame;
    assert(frame.raster.view().planeCount==0 && frame.recipe.length==0);
    auto retained=frame;
    assert(retained.raster.view().planeCount==0);
}

// The caller proves width*height*3*sizeof(T) <= ptrdiff_t.max before entry.
// raster-d validates layouts and retains the adopted malloc release obligation.
// No raw sample writes occur inside or outside this allocation boundary.
private bool allocateRgb(T)(size_t width,size_t height,ref RasterLease!T result) @trusted
{
    const bytes=width*height*3*T.sizeof;
    auto memory=malloc(bytes);
    if(memory is null)return false;
    OwnedByteResource resource;
    if(!tryAdoptMallocResource(memory,bytes,resource)){free(memory);return false;}
    PlaneByteLayout[3] layouts;
    foreach(c;0..3)layouts[c]=PlaneByteLayout(c*T.sizeof,
        cast(ptrdiff_t)(width*3*T.sizeof),3*T.sizeof);
    return tryImportOwnedRaster!T(resource,layouts[],Region2D(0,0,width,height),result).ok;
}

/++ Materialize directly into one raster-d-owned RGB buffer after complete
 preflight. No intermediate component/RGB image, source lease or sample array
 is retained. maxResultBytes bounds the exact 3*width*height*sizeof(Sample)
 payload; metadata, allocator overhead and decoder input have separate lifetimes.
 Float/double preserve finite extended encoded-sRGB; ubyte clips to [0,1] and
 rounds with color-d. All returned failures and thrown exceptions preserve
 published and its aliases. Metadata is copied before publishing the candidate.
 The caller keeps source descriptors/bytes unchanged throughout this synchronous
 call. O(width*height) time, O(1) working storage beyond the owned output.
+/
ImageMaterializationError tryMaterializeRgbOwned(alias Spec)(scope ImageRegion image,
    size_t maxResultBytes,ref OwnedRgbMaterialization!(Spec.output.Sample) published) @safe
if(is(Spec.output.Sample==float) || is(Spec.output.Sample==double) || is(Spec.output.Sample==ubyte))
{
    alias E=ImageMaterializationError;
    static if(!__traits(compiles,Spec.model.colorPolicy.matrix,Spec.model.colorPolicy.range,
        Spec.model.colorPolicy.bitDepth,Spec.model.yPlane,Spec.model.cbPlane,Spec.model.crPlane))
        return E.missingColorModel;
    else
    {
        const status=validateRgb!Spec(image);
        if(status!=E.none)return status;
        alias T=Spec.output.Sample;
        if(image.info.width>cast(size_t)ptrdiff_t.max/image.info.height/(3*T.sizeof) ||
            image.info.width*image.info.height>maxResultBytes/(3*T.sizeof))return E.resultExceedsBudget;
        OwnedRgbMaterialization!T candidate;
        if(!allocateRgb!T(image.info.width,image.info.height,candidate.raster))return E.allocationFailure;
        candidate.source=image.info; candidate.originX=image.originX; candidate.originY=image.originY;
        candidate.sampling=Spec.geometry.kind; candidate.recipe="imageio-sampleCenter-plus-geometry-v1";
        foreach(i,index;[Spec.model.yPlane,Spec.model.cbPlane,Spec.model.crPlane])
        {
            const p=image.planes[index];
            candidate.components[i]=MaterializedComponentOrigin(p.info,p.originX,p.originY,
                p.referenceOffsetX,p.referenceOffsetY,index);
        }
        bool writable;
        scope auto output=candidate.raster.tryWritableView(writable);
        if(!writable)return E.allocationFailure;
        foreach(y;0..image.info.height)foreach(x;0..image.info.width)
        {
            const rgb=rgbSample!Spec(image,x,y);
            T[3] values;
            static if(is(T==ubyte)){const bytes=clippedRgb(rgb);values=[bytes.r,bytes.g,bytes.b];}
            else values=[cast(T)rgb.r,cast(T)rgb.g,cast(T)rgb.b];
            foreach(c;0..3)if(!output.trySetSample(c,x,y,values[c]))return E.invalidPlane;
        }
        published=candidate;
        return E.none;
    }
}

/// A source must declare geometry and color; no JPEG defaults are inferred.
@safe unittest
{
    import imageio : zeroPhaseSampling;
    import imagery.materialization : YCbCrModel, ValidatedMaterializationSpec,
        NearestUpsampling, LinearFloatOutput;
    alias Spec=ValidatedMaterializationSpec!(YCbCrModel!(Bt601Video,0,1,2),
        NearestUpsampling,LinearFloatOutput!float);
    auto info=ImageRegionInfo(1,1,3,SampleFormat.u8,PixelLayout.planar,0,0,0,SourceModel.yCbCr);
    auto color=info.colorMetadata;
    color.state=color.modelState=color.matrixState=color.rangeState=color.transferState=
        color.primariesState=color.bitDepthState=MetadataState.known;
    color.model=SourceModel.yCbCr; color.matrix=ColorMatrix.bt601; color.range=ColorRange.video;
    color.transfer=TransferFunction.sRGB; color.primaries=ColorPrimaries.bt709;
    color.bitDepth=8; color.signedness=SampleSignedness.unsigned; info.colorMetadata=color;
    ImagePlane[] planes;
    foreach(i,role;[ComponentRole.luma,ComponentRole.chromaBlue,ComponentRole.chromaRed])
        planes~=ImagePlane(ImagePlaneInfo(cast(uint)i,1,1,zeroPhaseSampling(1,1),role),
            1,1,0,0,1,[cast(ubyte)(i?128:16)]);
    OwnedRgbMaterialization!float published;
    assert(tryMaterializeRgbOwned!Spec(ImageRegion(info,0,0,null,planes),12,published)==ImageMaterializationError.none);
    float red=1;
    assert(published.raster.view().trySample(0,0,0,red) && red==0);
    assert(published.components[1].index==1);
}

/** Compatibility result wrapper around the safe, single-allocation owned path. */
RgbFloatRasterResult materializeRgbFloatRaster(alias Spec)(ImageRegion image,
    size_t maxResultBytes=size_t.max) @safe
if(is(Spec.output.Sample==float))
{
    OwnedRgbMaterialization!float output;
    const status=tryMaterializeRgbOwned!Spec(image,maxResultBytes,output);
    return RgbFloatRasterResult(status,output.raster);
}

/** Compatibility byte wrapper. sourceError preserves structured materialization
 * errors that the historical RasterMaterializationError cannot represent.
 */
RasterMaterializationResult materializeRgbUbyteRaster(alias Spec)(ImageRegion image,
    size_t maxResultBytes=size_t.max) @safe
if(is(Spec.output.Sample==ubyte))
{
    OwnedRgbMaterialization!ubyte output;
    const status=tryMaterializeRgbOwned!Spec(image,maxResultBytes,output);
    auto result=RasterMaterializationResult(status==ImageMaterializationError.none?
        RasterMaterializationError.none:RasterMaterializationError.importFailure,output.raster);
    result.sourceError=status;
    return result;
}

/// Compact raw-copy/legacy raster status. Result fields start at notAttempted;
/// historical enum values are preserved. invalidLayout never means allocation failure.
enum RasterMaterializationError : ubyte
{
    none,
    unsupportedFormat,
    invalidLayout,
    allocationFailure,
    importFailure,
    notAttempted,
    resultExceedsBudget
}

/// Owned u8 copy or legacy RGB wrapper. .init is notAttempted and empty.
/// Typed RGB failures retain their detailed sourceError alongside the old status.
struct RasterMaterializationResult
{
    RasterMaterializationError error = RasterMaterializationError.notAttempted;
    RasterLease!ubyte raster;
    /// Detailed typed-RGB conversion status; notAttempted for raw-copy adapters.
    ImageMaterializationError sourceError = ImageMaterializationError.notAttempted;

    @property bool ok() const @safe pure nothrow @nogc
    { return error == RasterMaterializationError.none; }
}

// T is unsigned byte/word, so every imported bit pattern is valid. The safe
// caller checks sizes before this boundary; raster-d validates all layouts.
// Only this helper touches malloc memory, and adoption owns exactly one free.
private bool copyFlatBytes(T)(scope const(ubyte)[] bytes,
    scope const PlaneByteLayout[] layouts,size_t width,size_t height,ref RasterLease!T result) @trusted
if(is(T==ubyte) || is(T==ushort))
{
    auto memory=cast(ubyte*)malloc(bytes.length);
    if(memory is null)return false;
    memory[0..bytes.length]=bytes;
    OwnedByteResource owner;
    if(!tryAdoptMallocResource(memory,bytes.length,owner)){free(memory);return false;}
    return tryImportOwnedRaster!T(owner,layouts,Region2D(0,0,width,height),result).ok;
}

private RasterMaterializationError copyFlatRegion(T)(ImageRegion region,size_t maxResultBytes,
    ref RasterLease!T result) @safe
{
    alias E=RasterMaterializationError;
    static if(is(T==ubyte))enum format=SampleFormat.u8;else enum format=SampleFormat.u16;
    if(region.info.sampleFormat!=format || !region.info.componentCount)return E.unsupportedFormat;
    const w=region.info.width,h=region.info.height,c=region.info.componentCount;
    if(!w || !h || region.info.layout>PixelLayout.planar)return E.invalidLayout;
    if(w>cast(size_t)ptrdiff_t.max/h/c/T.sizeof)return E.allocationFailure;
    const count=w*h,bytes=count*c*T.sizeof;
    if(bytes>maxResultBytes)return E.resultExceedsBudget;
    if(bytes!=region.data.length)return E.invalidLayout;
    const planar=region.info.layout==PixelLayout.planar;
    const row=planar?w*T.sizeof:w*c*T.sizeof;
    const sample=planar?T.sizeof:c*T.sizeof;
    const plane=planar?count*T.sizeof:0;
    if((region.info.rowStrideBytes && region.info.rowStrideBytes!=row) ||
        (region.info.sampleStrideBytes && region.info.sampleStrideBytes!=sample) ||
        (region.info.planeStrideBytes && region.info.planeStrideBytes!=plane))return E.invalidLayout;
    auto layouts=new PlaneByteLayout[c];
    foreach(index;0..c)layouts[index]=PlaneByteLayout(planar?index*plane:index*T.sizeof,
        cast(ptrdiff_t)row,cast(ptrdiff_t)sample);
    return copyFlatBytes!T(region.data,layouts,w,h,result)?E.none:E.importFailure;
}

/** Copy tightly packed planar/interleaved u8 samples without interpretation.
 * Explicit stride metadata must match that compact layout; malformed dimensions
 * and multiplication are checked before allocation. .init results are inert.
 */
RasterMaterializationResult materializeUbyte(ImageRegion region,
    size_t maxResultBytes=size_t.max) @safe
{
    RasterMaterializationResult result;
    result.error=copyFlatRegion!ubyte(region,maxResultBytes,result.raster);
    return result;
}

/// Owned native-host-order u16 copy. Source byte order is not converted.
struct UshortRasterMaterializationResult
{
    RasterMaterializationError error=RasterMaterializationError.notAttempted;
    RasterLease!ushort raster;
    @property bool ok() const @safe pure nothrow @nogc
    {return error==RasterMaterializationError.none;}
}

/** Copy tightly packed native-host-order u16 bytes without numeric conversion.
 * The caller supplies decoded bytes in host order; this does not reinterpret
 * arbitrary encoded TIFF/JPEG bytes. Overflow/layout checks precede allocation.
 */
UshortRasterMaterializationResult materializeUshort(ImageRegion region,
    size_t maxResultBytes=size_t.max) @safe
{
    UshortRasterMaterializationResult result;
    result.error=copyFlatRegion!ushort(region,maxResultBytes,result.raster);
    return result;
}

/** Wrap a neutral imageio region without copying its samples. */
DecodedImageRegion acceptDecodedRegion(ImageRegion region)
@safe pure nothrow @nogc
{
    return DecodedImageRegion(region.info, region);
}

/** Decode a TIFF ROI through imageio and expose it to imagery consumers.
 * .init contains no region and ok is false, regardless of the upstream enum default.
 */
struct ImageOpenResult
{
    TiffDecodeError error;
    DecodedImageRegion image;
    TiffRegionPlan plan;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == TiffDecodeError.none && image.region.info.width!=0 && image.region.info.height!=0;
    }
}

ImageOpenResult openTiffRegion(ByteSource source, size_t x, size_t y,
    size_t width, size_t height)
@safe
{
    auto planned = planRegion(source, x, y, width, height);
    if (!planned.ok)
        return ImageOpenResult(planned.error);
    auto decoded = decodeRegion(source, x, y, width, height);
    if (!decoded.ok)
        return ImageOpenResult(decoded.error);
    return ImageOpenResult(TiffDecodeError.none,
        acceptDecodedRegion(decoded.region), planned.plan);
}

/** Open a region using the best available overview for the target size. */
ImageOpenResult openTiffBestRegion(ByteSource source, size_t x, size_t y,
    size_t width, size_t height, size_t targetWidth, size_t targetHeight)
@safe
{
    auto levels = inspectLevels(source);
    if (!levels.ok)
        return ImageOpenResult(TiffDecodeError.sourceFailure);
    auto selected = selectLevel(levels.levels, targetWidth, targetHeight);
    if (!selected.ok)
        return ImageOpenResult(selected.error);
    auto decoded = decodeRegionAtBestLevel(source, x, y, width, height,
        targetWidth, targetHeight);
    if (!decoded.ok)
        return ImageOpenResult(decoded.error);
    auto plan = planRegionAtLevel(source, selected.selection.levelIndex,
        cast(size_t)((cast(ulong) x * selected.selection.level.width) / levels.levels[0].width),
        cast(size_t)((cast(ulong) y * selected.selection.level.height) / levels.levels[0].height),
        decoded.region.info.width, decoded.region.info.height);
    if (!plan.ok)
        return ImageOpenResult(plan.error);
    return ImageOpenResult(TiffDecodeError.none,
        acceptDecodedRegion(decoded.region), plan.plan);
}

/** Open a TIFF ROI from a local file through the standard source stack. */
ImageOpenResult openTiffFile(string path, size_t x, size_t y,
    size_t width, size_t height)
@safe
{
    return openTiffRegion(new FileSource(path), x, y, width, height);
}

/** Open a TIFF ROI from an HTTP URL through the standard range source. */
ImageOpenResult openTiffUrl(string url, size_t x, size_t y,
    size_t width, size_t height)
@safe
{
    return openTiffRegion(new CurlHttpSource(url), x, y, width, height);
}

/** Open an image location and select the reader from its content signature. */
ImageOpenResult openImage(string location, size_t x, size_t y,
    size_t width, size_t height)
@safe
{
    ByteSource source;
    if (location.startsWith("http://") || location.startsWith("https://"))
        source = new CurlHttpSource(location);
    else
        source = new FileSource(location);
    auto format = detectFormat(source);
    if (!format.ok || format.format != ImageFormat.tiff)
        return ImageOpenResult(TiffDecodeError.unsupportedFormat);
    return openTiffRegion(source, x, y, width, height);
}

/** Open a file or URL and select an overview for the requested output size. */
ImageOpenResult openImageBest(string location, size_t x, size_t y,
    size_t width, size_t height, size_t targetWidth, size_t targetHeight)
@safe
{
    ByteSource source;
    if (location.startsWith("http://") || location.startsWith("https://"))
        source = new CurlHttpSource(location);
    else
        source = new FileSource(location);
    auto format = detectFormat(source);
    if (!format.ok || format.format != ImageFormat.tiff)
        return ImageOpenResult(TiffDecodeError.unsupportedFormat);
    return openTiffBestRegion(source, x, y, width, height,
        targetWidth, targetHeight);
}

unittest
{
    import imageio : ImagePlane, ImagePlaneInfo, ImageRegion, ImageRegionInfo,
        PixelLayout, SampleFormat, zeroPhaseSampling, ComponentRole,
        SourceModel, MetadataState, ColorMatrix, ColorRange;
    import imagery.materialization : ComponentModel,
        BilinearUpsampling, LinearFloatOutput, NativePlanesGeometry,
        NearestUpsampling,
        ValidatedMaterializationSpec;

    auto white = convertYCbCr(1.0, 0.5, 0.5,
        YCbCrMatrix.bt601, YCbCrRange.full);
    assert(white == SRgbd(1.0, 1.0, 1.0));

    auto luma = ImagePlane(ImagePlaneInfo(1, 1, 1,zeroPhaseSampling(1,1)), 4, 2, 0, 0, 4,
        [ubyte(1), 2, 3, 4, 5, 6, 7, 8]);
    auto chroma = ImagePlane(ImagePlaneInfo(2, 2, 2,
        zeroPhaseSampling(2, 2)), 2, 1, 0, 0, 2,
        [ubyte(10), 20]);
    auto region = ImageRegion(
        ImageRegionInfo(4, 2, 2, SampleFormat.u8, PixelLayout.planar),
        0, 0, null, [luma, chroma]);

    auto result = materialize(region);
    assert(result.ok);
    assert(result.native.planes.length == 2);
    assert(result.native.planes[0].width == 4);
    assert(result.native.planes[1].width == 2);
    assert(result.native.planes[1].info.horizontalSampling == 2);
    assert(result.native.planes[1].data[0] == 10);
    assert(result.native.planes[1].data.ptr != chroma.data.ptr);
    assert(materialize(region, ImageMaterialization.rgb).error
        == ImageMaterializationError.missingColorModel);
    auto expanded = materialize(region, ImageMaterialization.upsampledComponents);
    assert(expanded.ok);
    assert(expanded.native.planes[1].width == 4
        && expanded.native.planes[1].height == 2);
    assert(expanded.native.planes[1].info.horizontalSampling == 1);
    assert(expanded.native.planes[1].data == [ubyte(10), 20, 20, 20,
        10, 20, 20, 20]);

    auto unknownChroma = ImagePlane(ImagePlaneInfo(2, 2, 2), 2, 1, 0, 0, 2,
        [ubyte(10), 20]);
    auto unknownRegion = ImageRegion(
        ImageRegionInfo(4, 2, 2, SampleFormat.u8, PixelLayout.planar),
        0, 0, null, [luma, unknownChroma]);
    assert(materialize(unknownRegion,
        ImageMaterialization.upsampledComponents).error
        == ImageMaterializationError.missingGeometry);

    alias Spec = ValidatedMaterializationSpec!(
        ComponentModel!2, NearestUpsampling, LinearFloatOutput!double);
    auto planned = materialize!Spec(region);
    assert(planned.ok);
    alias NativeSpec = ValidatedMaterializationSpec!(
        ComponentModel!2, NativePlanesGeometry, LinearFloatOutput!double);
    auto nativePlanned = materialize!NativeSpec(region);
    assert(nativePlanned.native.planes[1].width == 2);
    alias BilinearSpec = ValidatedMaterializationSpec!(
        ComponentModel!2, BilinearUpsampling, LinearFloatOutput!double);
    auto bilinear = materialize!BilinearSpec(region);
    assert(bilinear.ok);
}

unittest
{
    import imageio : ImagePlane, ImagePlaneInfo, ImageRegion, ImageRegionInfo,
        PixelLayout, SampleFormat, zeroPhaseSampling;
    import imagery.materialization : BilinearUpsampling, LinearFloatOutput,
        ClippedUbyteOutput, ValidatedMaterializationSpec, YCbCrModel;
    import color : Bt601Video;

    ImagePlane[] planes = [
        ImagePlane(ImagePlaneInfo(0, 1, 1, zeroPhaseSampling(1, 1),
            ComponentRole.luma), 1, 1, 0, 0, 1, [ubyte(16)]),
        ImagePlane(ImagePlaneInfo(1, 1, 1, zeroPhaseSampling(1, 1),
            ComponentRole.chromaBlue), 1, 1, 0, 0, 1, [ubyte(128)]),
        ImagePlane(ImagePlaneInfo(2, 1, 1, zeroPhaseSampling(1, 1),
            ComponentRole.chromaRed), 1, 1, 0, 0, 1, [ubyte(128)])
    ];
    auto regionInfo = ImageRegionInfo(1, 1, 3, SampleFormat.u8,
        PixelLayout.planar, 0, 0, 0, SourceModel.yCbCr);
    regionInfo.colorMetadata.model = SourceModel.yCbCr;
    regionInfo.colorMetadata.state = MetadataState.known;
    regionInfo.colorMetadata.modelState = MetadataState.known;
    regionInfo.colorMetadata.matrix = ColorMatrix.bt601;
    regionInfo.colorMetadata.matrixState = MetadataState.known;
    regionInfo.colorMetadata.range = ColorRange.video;
    regionInfo.colorMetadata.rangeState = MetadataState.known;
    regionInfo.colorMetadata.transfer=TransferFunction.sRGB;
    regionInfo.colorMetadata.transferState=MetadataState.known;
    regionInfo.colorMetadata.primaries=ColorPrimaries.bt709;
    regionInfo.colorMetadata.primariesState=MetadataState.known;
    regionInfo.colorMetadata.bitDepth=8;
    regionInfo.colorMetadata.bitDepthState=MetadataState.known;
    regionInfo.colorMetadata.signedness=SampleSignedness.unsigned;
    auto region = ImageRegion(regionInfo, 0, 0, null, planes);
    alias Model = YCbCrModel!(Bt601Video, 0, 1, 2);
    alias Spec = ValidatedMaterializationSpec!(
        Model, BilinearUpsampling, LinearFloatOutput!double);
    auto result = materializeRgb!Spec(region);
    assert(result.ok && result.width == 1 && result.height == 1);
    assert(result.pixels[0] == SRgbd(0.0, 0.0, 0.0));
    alias UbyteSpec = ValidatedMaterializationSpec!(
        Model, BilinearUpsampling, ClippedUbyteOutput);
    auto bytes = materializeRgb!UbyteSpec(region);
    assert(bytes.ok && bytes.pixels[0].r == 0
        && bytes.pixels[0].g == 0 && bytes.pixels[0].b == 0);
    auto raster = materializeRgbUbyteRaster!UbyteSpec(region);
    assert(raster.ok);
    scope auto rasterView = raster.raster.view();
    ubyte sample;
    assert(rasterView.trySample(0, 0, 0, sample) && sample == 0);
}

unittest
{
    import imageio : ImagePlane, ImagePlaneInfo, ImageRegion, ImageRegionInfo,
        PixelLayout, SampleFormat, zeroPhaseSampling;
    import imagery.materialization : BilinearUpsampling, ComponentModel,
        LinearFloatOutput, ValidatedMaterializationSpec;

    auto plane = ImagePlane(ImagePlaneInfo(0, 2, 2, zeroPhaseSampling(2, 2)),
        2, 2, 0, 0, 2,
        [ubyte(0), 100, 200, 255]);
    auto region = ImageRegion(
        ImageRegionInfo(4, 4, 1, SampleFormat.u8, PixelLayout.planar),
        0, 0, null, [plane]);
    alias Spec = ValidatedMaterializationSpec!(
        ComponentModel!1, BilinearUpsampling, LinearFloatOutput!float);
    auto expanded = materialize!Spec(region);
    assert(expanded.ok);
    // Corner preservation and a genuinely weighted interior sample.
    assert(expanded.native.planes[0].data[0] == 0);
    assert(expanded.native.planes[0].data[$ - 1] == 255);
    assert(expanded.native.planes[0].data[1 * 4 + 1] == 139);
}

unittest
{
    import imageio : ImageRegion, ImageRegionInfo, PixelLayout, SampleFormat;
    import raster : RasterView;

    ubyte[] planar = [1, 2, 3, 4, 10, 20, 30, 40];
    auto region = ImageRegion(
        ImageRegionInfo(2, 2, 2, SampleFormat.u8, PixelLayout.planar),
        0, 0, planar);
    auto materialized = materializeUbyte(region);
    assert(materialized.ok);
    scope auto view = materialized.raster.view();
    ubyte sample;
    assert(view.trySample(0, 1, 1, sample) && sample == 4);
    assert(view.trySample(1, 1, 1, sample) && sample == 40);
}

unittest
{
    import imageio : ImageRegion, ImageRegionInfo, PixelLayout, SampleFormat;

    // Two planar UInt16 samples, little-endian byte order.
    ubyte[] planar = [1, 0, 2, 0, 3, 0, 4, 0,
                      10, 0, 20, 0, 30, 0, 40, 0];
    auto region = ImageRegion(
        ImageRegionInfo(2, 2, 2, SampleFormat.u16, PixelLayout.planar),
        0, 0, planar);
    auto materialized = materializeUshort(region);
    assert(materialized.ok);
    scope auto view = materialized.raster.view();
    ushort sample;
    assert(view.trySample(0, 1, 1, sample) && sample == 4);
    assert(view.trySample(1, 1, 1, sample) && sample == 40);
}

version (unittest) private ImageRegion materializationRegression()
@safe
{
    import imageio : ImagePlaneInfo, zeroPhaseSampling, TransferFunction,
        ColorPrimaries, SampleSignedness;
    auto info = ImageRegionInfo(3, 1, 3, SampleFormat.u8, PixelLayout.planar,
        0, 0, 0, SourceModel.yCbCr);
    auto m = info.colorMetadata;
    m.state=m.modelState=m.matrixState=m.rangeState=m.transferState=
        m.primariesState=m.bitDepthState=MetadataState.known;
    m.model=SourceModel.yCbCr; m.matrix=ColorMatrix.bt601; m.range=ColorRange.video;
    m.transfer=TransferFunction.sRGB; m.primaries=ColorPrimaries.bt709;
    m.bitDepth=8; m.signedness=SampleSignedness.unsigned;
    info.colorMetadata=m;
    return ImageRegion(info,0,0,null,[
        ImagePlane(ImagePlaneInfo(1,1,1,zeroPhaseSampling(1,1),ComponentRole.luma),
            3,1,0,0,3,[ubyte(16),80,160]),
        ImagePlane(ImagePlaneInfo(2,1,1,zeroPhaseSampling(2,1),ComponentRole.chromaBlue),
            2,1,0,0,2,[ubyte(120),137]),
        ImagePlane(ImagePlaneInfo(3,1,1,zeroPhaseSampling(2,1),ComponentRole.chromaRed),
            2,1,0,0,2,[ubyte(129),140])]);
}

@safe unittest
{
    import imagery.materialization : YCbCrModel, ValidatedMaterializationSpec,
        BilinearUpsampling, LinearFloatOutput;
    import std.math : abs;
    alias Spec=ValidatedMaterializationSpec!(YCbCrModel!(Bt601Video,0,1,2),
        BilinearUpsampling,LinearFloatOutput!double);
    auto source=materializationRegression();
    auto result=materializeRgb!Spec(source);
    assert(result.ok);
    auto expected=convertYCbCr(80.0/255,128.5/255,134.5/255,
        YCbCrMatrix.bt601,YCbCrRange.video);
    assert(abs(result.pixels[1].r-expected.r)<1e-14 &&
        abs(result.pixels[1].g-expected.g)<1e-14 &&
        abs(result.pixels[1].b-expected.b)<1e-14,
        "Bilinear float RGB must preserve fractional component samples and source centers");
    source.info.colorMetadata.matrix=ColorMatrix.bt709;
    assert(!materializeRgb!Spec(source).ok,"Source/policy matrix mismatch must fail");
}

@safe unittest
{
    assert(!ImageMaterializationResult.init.ok && !RgbMaterializationResult!double.init.ok,
        "Default materialization results are not successful");
    assert(!ImageOpenResult.init.ok && !RasterMaterializationResult.init.ok && !UshortRasterMaterializationResult.init.ok);
    auto empty=ImageRegion(ImageRegionInfo(0,1,1,SampleFormat.u8,PixelLayout.interleaved));
    assert(materializeUbyte(empty).error==RasterMaterializationError.invalidLayout);
    empty.info.width=size_t.max;empty.info.height=2;
    assert(materializeUbyte(empty).error==RasterMaterializationError.allocationFailure);
    empty.info.width=empty.info.height=1;empty.data=[ubyte(7)];
    assert(materializeUbyte(empty,0).error==RasterMaterializationError.resultExceedsBudget);
    empty.info.rowStrideBytes=2;
    assert(materializeUbyte(empty).error==RasterMaterializationError.invalidLayout);
}
}
