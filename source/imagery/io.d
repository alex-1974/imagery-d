/**
 * Image I/O handoff for the default imagery configuration.
 *
 * This module intentionally exposes only imageio's neutral decoded-region
 * contract. The semantic interpretation and raster ownership remain in
 * imagery-d and raster-d respectively.
 */
module imagery.io;

version (imageio_io)
{
import core.stdc.stdlib : malloc, free;
import imageio : ImageFormat, ImageRegion, ImageRegionInfo, ImagePlane,
    PlaneGeometryStatus, ComponentRole, SourceModel, MetadataState,
    ColorMatrix, ColorRange,
    TiffDecodeError,
    PixelLayout, SampleFormat, TiffRegionPlan, decodeRegion, detectFormat,
    decodeRegionAtBestLevel, inspectLevels, planRegion, planRegionAtLevel,
    selectLevel;
import std.string : startsWith;
import transport : ByteSource, FileSource;
import transport.http_curl : CurlHttpSource;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease,
    tryAdoptMallocResource, tryImportOwnedRaster, Region2D;
import color : SRgb, SRgbd, YCbCr, YCbCrMatrix, YCbCrRange,
    Bt601Full, Bt601Video, Bt709Full, Bt709Video;
import color.ycbcr : toSRgb;
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
    conflictingGeometry
}

/** Owned native component planes. Plane geometry and sampling metadata are
 * preserved exactly; no chroma or colour interpretation is performed. */
struct NativePlanesMaterialization
{
    ImagePlane[] planes;

    @property bool ok() const @safe pure nothrow @nogc
    { return planes.length != 0; }
}

struct ImageMaterializationResult
{
    ImageMaterializationError error;
    NativePlanesMaterialization native;

    @property bool ok() const @safe pure nothrow @nogc
    { return error == ImageMaterializationError.none; }
}

struct RgbMaterializationResult(T)
{
    static if (is(T == ubyte))
        struct Pixel { ubyte r; ubyte g; ubyte b; }
    else
        alias Pixel = SRgb!T;
    ImageMaterializationError error;
    size_t width;
    size_t height;
    Pixel[] pixels;

    @property bool ok() const @safe pure nothrow @nogc
    { return error == ImageMaterializationError.none; }
}

private ubyte encodeRgb8(double value)
@safe pure nothrow @nogc
{
    if (value != value || value <= 0)
        return 0;
    if (value >= 1)
        return 255;
    return cast(ubyte)(value * 255.0 + 0.5);
}

private double planeIndexAt(ImagePlane plane, size_t target,
    size_t origin, uint spacing, long offsetNumerator,
    ulong offsetDenominator, long phaseNumerator,
    ulong phaseDenominator)
@safe pure nothrow @nogc
{
    if (spacing == 0 || offsetDenominator == 0)
        return double.nan;
    const auto offset = cast(double) offsetNumerator
        / cast(double) offsetDenominator;
    const auto phase = cast(double) phaseNumerator
        / cast(double) phaseDenominator;
    return (cast(double) target - cast(double) origin - offset - phase)
        / cast(double) spacing;
}

private bool hasRgbRoles(ImageRegion image, size_t y, size_t cb, size_t cr)
@safe pure nothrow @nogc
{
    if (y >= image.planes.length || cb >= image.planes.length
        || cr >= image.planes.length || y == cb || y == cr || cb == cr)
        return false;
    return image.planes[y].info.role == ComponentRole.luma
        && image.planes[cb].info.role == ComponentRole.chromaBlue
        && image.planes[cr].info.role == ComponentRole.chromaRed;
}

private bool hasRgbMetadata(ImageRegion image)
@safe pure nothrow @nogc
{
    const auto metadata = image.info.colorMetadata;
    return image.info.sourceModel == SourceModel.yCbCr
        && metadata.modelState == MetadataState.known
        && metadata.matrixState == MetadataState.known
        && metadata.rangeState == MetadataState.known
        && (metadata.matrix == ColorMatrix.bt601
            || metadata.matrix == ColorMatrix.bt709)
        && (metadata.range == ColorRange.full
            || metadata.range == ColorRange.video);
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
    }
}


/** Materialize only the native component-plane representation.
 *
 * The result owns copied plane buffers. Different plane dimensions and
 * sampling factors remain intact. Upsampling and RGB conversion are
 * deliberately rejected unless the caller selects a compatible policy.
 */
ImageMaterializationResult materialize(ImageRegion image,
    ImageMaterialization mode = ImageMaterialization.nativePlanes)
@safe
{
    if (mode == ImageMaterialization.rgb)
        return ImageMaterializationResult(ImageMaterializationError.missingColorModel);
    if (image.info.sampleFormat != SampleFormat.u8 || image.planes.length == 0)
        return ImageMaterializationResult(ImageMaterializationError.missingPlanes);

    auto owned = new ImagePlane[](image.planes.length);
    foreach (index, source; image.planes)
    {
        if (source.width == 0 || source.height == 0
            || source.rowStrideBytes < source.width
            || source.height > size_t.max / source.rowStrideBytes
            || source.data.length < source.rowStrideBytes * source.height)
            return ImageMaterializationResult(ImageMaterializationError.invalidPlane);
        auto bytes = source.rowStrideBytes * source.height;
        auto data = new ubyte[](bytes);
        data[] = source.data[0 .. bytes];
        owned[index] = ImagePlane(source.info, source.width, source.height,
            source.originX, source.originY, source.rowStrideBytes, data);
    }

    if (mode == ImageMaterialization.upsampledComponents
        || mode == ImageMaterialization.upsampledComponentsBilinear)
    {
        if (image.info.width == 0 || image.info.height == 0)
            return ImageMaterializationResult(ImageMaterializationError.invalidPlane);
        foreach (index, source; owned)
        {
            if (source.width == image.info.width && source.height == image.info.height)
                continue;
            final switch (source.info.geometry.status)
            {
            case PlaneGeometryStatus.known:
                break;
            case PlaneGeometryStatus.unavailable:
                return ImageMaterializationResult(
                    ImageMaterializationError.missingGeometry);
            case PlaneGeometryStatus.unsupported:
                return ImageMaterializationResult(
                    ImageMaterializationError.unsupportedGeometry);
            case PlaneGeometryStatus.conflicting:
            case PlaneGeometryStatus.invalid:
                return ImageMaterializationResult(
                    ImageMaterializationError.conflictingGeometry);
            }
            if (image.info.width > size_t.max / image.info.height)
                return ImageMaterializationResult(ImageMaterializationError.allocationFailure);
            auto data = new ubyte[](image.info.width * image.info.height);
            const auto spacingX = source.info.geometry.horizontalFactor;
            const auto spacingY = source.info.geometry.verticalFactor;
            const auto geometryX = cast(double)
                source.info.geometry.centerOffsetX.numerator
                / cast(double) source.info.geometry.centerOffsetX.denominator;
            const auto geometryY = cast(double)
                source.info.geometry.centerOffsetY.numerator
                / cast(double) source.info.geometry.centerOffsetY.denominator;
            const auto cropX = cast(double) source.referenceOffsetX.numerator
                / cast(double) source.referenceOffsetX.denominator;
            const auto cropY = cast(double) source.referenceOffsetY.numerator
                / cast(double) source.referenceOffsetY.denominator;
            foreach (y; 0 .. image.info.height)
            {
                double sourceY = (cast(double)(image.originY + y)
                    + 0.5 - cast(double)source.originY - geometryY - cropY)
                    / spacingY - 0.5;
                if (sourceY < 0) sourceY = 0;
                if (sourceY > source.height - 1) sourceY = source.height - 1;
                auto sy = cast(size_t)sourceY;
                auto fy = sourceY - sy;
                if (mode == ImageMaterialization.upsampledComponents)
                {
                    sy = cast(size_t)(sourceY + 0.5);
                    if (sy >= source.height) sy = source.height - 1;
                }
                foreach (x; 0 .. image.info.width)
                {
                    double sourceX = (cast(double)(image.originX + x)
                        + 0.5 - cast(double)source.originX - geometryX - cropX)
                        / spacingX - 0.5;
                    if (sourceX < 0) sourceX = 0;
                    if (sourceX > source.width - 1) sourceX = source.width - 1;
                    auto sx = cast(size_t)sourceX;
                    auto fx = sourceX - sx;
                    if (mode == ImageMaterialization.upsampledComponents)
                    {
                        sx = cast(size_t)(sourceX + 0.5);
                        if (sx >= source.width) sx = source.width - 1;
                    }
                    if (mode == ImageMaterialization.upsampledComponentsBilinear)
                    {
                        auto sx1 = sx + 1 < source.width ? sx + 1 : sx;
                        auto sy1 = sy + 1 < source.height ? sy + 1 : sy;
                        auto a = source.data[sy * source.rowStrideBytes + sx];
                        auto b = source.data[sy * source.rowStrideBytes + sx1];
                        auto c = source.data[sy1 * source.rowStrideBytes + sx];
                        auto d = source.data[sy1 * source.rowStrideBytes + sx1];
                        auto top = a * (1.0 - fx) + b * fx;
                        auto bottom = c * (1.0 - fx) + d * fx;
                        data[y * image.info.width + x] = cast(ubyte)
                            (top * (1.0 - fy) + bottom * fy + 0.5);
                    }
                    else
                        data[y * image.info.width + x] =
                            source.data[sy * source.rowStrideBytes + sx];
                }
            }
            auto info = source.info;
            info.horizontalSampling = 1;
            info.verticalSampling = 1;
            owned[index] = ImagePlane(info, image.info.width, image.info.height,
                image.originX, image.originY, image.info.width, data);
        }
    }
    return ImageMaterializationResult(ImageMaterializationError.none,
        NativePlanesMaterialization(owned));
}

/** Compile-time policy entry point for explicit plane materialization. */
ImageMaterializationResult materialize(alias Spec)(ImageRegion image)
if (isImageModel!(Spec.model) && isGeometryPolicy!(Spec.geometry)
    && isOutputPolicy!(Spec.output))
{
    static if (Spec.geometry.kind == "native")
        return materialize(image, ImageMaterialization.nativePlanes);
    else static if (Spec.geometry.kind == "nearest")
        return materialize(image, ImageMaterialization.upsampledComponents);
    else static if (Spec.geometry.kind == "bilinear")
        return materialize(image,
            ImageMaterialization.upsampledComponentsBilinear);
    else
        return ImageMaterializationResult(
            ImageMaterializationError.unsupportedMode);
}

/** Materialize a typed YCbCr policy into owned encoded-sRGB samples.
 *
 * The result deliberately retains color-d's floating-point values. No
 * clipping, quantization or transfer-function substitution occurs here.
 */
RgbMaterializationResult!(Spec.output.Sample) materializeRgb(alias Spec)(ImageRegion image)
if (isImageModel!(Spec.model) && isGeometryPolicy!(Spec.geometry)
    && isOutputPolicy!(Spec.output))
{
    static if (!__traits(compiles, Spec.model.colorPolicy)
        || !__traits(compiles, Spec.model.yPlane)
        || !__traits(compiles, Spec.model.cbPlane)
        || !__traits(compiles, Spec.model.crPlane))
    {
        return RgbMaterializationResult!(Spec.output.Sample)(
            ImageMaterializationError.missingColorModel);
    }
    else static if (!is(Spec.output.Sample == float)
        && !is(Spec.output.Sample == double)
        && !is(Spec.output.Sample == ubyte))
    {
        return RgbMaterializationResult!(Spec.output.Sample)(
            ImageMaterializationError.unsupportedMode);
    }
    else
    {
        auto components = materialize!Spec(image);
        if (!components.ok
            || image.info.componentCount != Spec.model.componentCount
            || components.native.planes.length <= Spec.model.crPlane)
            return RgbMaterializationResult!(Spec.output.Sample)(
                components.error == ImageMaterializationError.none
                    ? ImageMaterializationError.missingPlanes
                    : components.error);
        if (!hasRgbRoles(image, Spec.model.yPlane, Spec.model.cbPlane,
            Spec.model.crPlane))
            return RgbMaterializationResult!(Spec.output.Sample)(
                ImageMaterializationError.missingColorModel);
        if (!hasRgbMetadata(image))
            return RgbMaterializationResult!(Spec.output.Sample)(
                ImageMaterializationError.missingColorModel);
        auto yPlane = components.native.planes[Spec.model.yPlane];
        auto cbPlane = components.native.planes[Spec.model.cbPlane];
        auto crPlane = components.native.planes[Spec.model.crPlane];
        if (yPlane.width != cbPlane.width || yPlane.width != crPlane.width
            || yPlane.height != cbPlane.height || yPlane.height != crPlane.height)
            return RgbMaterializationResult!(Spec.output.Sample)(
                ImageMaterializationError.invalidPlane);
        if (yPlane.width > size_t.max / yPlane.height)
            return RgbMaterializationResult!(Spec.output.Sample)(
                ImageMaterializationError.allocationFailure);
        auto pixels = new RgbMaterializationResult!(Spec.output.Sample).Pixel[](
            yPlane.width * yPlane.height);
        foreach (y; 0 .. yPlane.height)
        foreach (x; 0 .. yPlane.width)
        {
            auto offset = y * yPlane.rowStrideBytes + x;
            auto rgb = convertYCbCr(
                yPlane.data[offset] / 255.0,
                cbPlane.data[y * cbPlane.rowStrideBytes + x] / 255.0,
                crPlane.data[y * crPlane.rowStrideBytes + x] / 255.0,
                Spec.model.colorPolicy.matrix, Spec.model.colorPolicy.range);
            static if (is(Spec.output.Sample == ubyte))
            {
                pixels[y * yPlane.width + x] =
                    RgbMaterializationResult!ubyte.Pixel(
                        encodeRgb8(rgb.r), encodeRgb8(rgb.g), encodeRgb8(rgb.b));
            }
            else
                pixels[y * yPlane.width + x] =
                    SRgb!(Spec.output.Sample)(cast(Spec.output.Sample) rgb.r,
                        cast(Spec.output.Sample) rgb.g,
                        cast(Spec.output.Sample) rgb.b);
        }
        return RgbMaterializationResult!(Spec.output.Sample)(
            ImageMaterializationError.none,
            yPlane.width, yPlane.height, pixels);
    }
}

struct RgbFloatRasterResult
{
    ImageMaterializationError error;
    RasterLease!float raster;

    @property bool ok() const @safe pure nothrow @nogc
    { return error == ImageMaterializationError.none; }
}

/** Materialize a float RGB result into raster-d-owned interleaved storage. */
RgbFloatRasterResult materializeRgbFloatRaster(alias Spec)(ImageRegion image)
if (is(Spec.output.Sample == float))
{
    auto source = materializeRgb!Spec(image);
    if (!source.ok)
        return RgbFloatRasterResult(source.error);
    auto count = source.width * source.height;
    if (count > size_t.max / (3 * float.sizeof))
        return RgbFloatRasterResult(ImageMaterializationError.allocationFailure);
    auto bytes = count * 3 * float.sizeof;
    auto memory = cast(float*) malloc(bytes);
    if (memory is null)
        return RgbFloatRasterResult(ImageMaterializationError.allocationFailure);
    foreach (index, pixel; source.pixels)
    {
        memory[index * 3 .. index * 3 + 3] = [pixel.r, pixel.g, pixel.b];
    }
    OwnedByteResource owned;
    if (!tryAdoptMallocResource(cast(ubyte*)memory, bytes, owned))
    {
        free(memory);
        return RgbFloatRasterResult(ImageMaterializationError.allocationFailure);
    }
    const PlaneByteLayout[3] layouts = [
        PlaneByteLayout(0, source.width * 3 * float.sizeof, 3 * float.sizeof),
        PlaneByteLayout(float.sizeof, source.width * 3 * float.sizeof, 3 * float.sizeof),
        PlaneByteLayout(2 * float.sizeof, source.width * 3 * float.sizeof, 3 * float.sizeof)
    ];
    RasterLease!float lease;
    auto imported = tryImportOwnedRaster!float(owned, layouts[],
        Region2D(0, 0, source.width, source.height), lease);
    if (!imported.ok)
        return RgbFloatRasterResult(ImageMaterializationError.allocationFailure);
    return RgbFloatRasterResult(ImageMaterializationError.none, lease);
}

/** Materialize clipped UInt8 RGB samples through the existing raster adapter. */
RasterMaterializationResult materializeRgbUbyteRaster(alias Spec)(ImageRegion image)
if (is(Spec.output.Sample == ubyte))
{
    auto source = materializeRgb!Spec(image);
    if (!source.ok)
        return RasterMaterializationResult(RasterMaterializationError.importFailure);
    if (source.width > size_t.max / source.height
        || source.width * source.height > size_t.max / 3)
        return RasterMaterializationResult(RasterMaterializationError.allocationFailure);
    auto bytes = new ubyte[](source.width * source.height * 3);
    foreach (index, pixel; source.pixels)
    {
        bytes[index * 3 .. index * 3 + 3] = [pixel.r, pixel.g, pixel.b];
    }
    auto region = ImageRegion(
        ImageRegionInfo(source.width, source.height, 3,
            SampleFormat.u8, PixelLayout.interleaved,
            source.width * 3, 3, 0), 0, 0, bytes);
    return materializeUbyte(region);
}

enum RasterMaterializationError : ubyte
{
    none,
    unsupportedFormat,
    invalidLayout,
    allocationFailure,
    importFailure
}

struct RasterMaterializationResult
{
    RasterMaterializationError error;
    RasterLease!ubyte raster;

    @property bool ok() const @safe pure nothrow @nogc
    { return error == RasterMaterializationError.none; }
}

/** Materialize an interleaved UInt8 region into raster-d ownership. */
RasterMaterializationResult materializeUbyte(ImageRegion region)
@system
{
    if (region.info.sampleFormat != SampleFormat.u8
        || region.info.componentCount == 0)
        return RasterMaterializationResult(RasterMaterializationError.unsupportedFormat);
    auto components = region.info.componentCount;
    auto planeBytes = region.info.width * region.info.height;
    auto bytes = planeBytes * components;
    if (bytes != region.data.length)
        return RasterMaterializationResult(RasterMaterializationError.invalidLayout);
    auto expectedRow = region.info.layout == PixelLayout.planar
        ? region.info.width : region.info.width * components;
    auto expectedSample = region.info.layout == PixelLayout.planar
        ? 1 : components;
    auto expectedPlane = region.info.layout == PixelLayout.planar
        ? planeBytes : 0;
    if ((region.info.rowStrideBytes != 0 && region.info.rowStrideBytes != expectedRow)
        || (region.info.sampleStrideBytes != 0
            && region.info.sampleStrideBytes != expectedSample)
        || (region.info.planeStrideBytes != 0
            && region.info.planeStrideBytes != expectedPlane))
        return RasterMaterializationResult(RasterMaterializationError.allocationFailure);
    auto memory = cast(ubyte*) malloc(bytes);
    if (memory is null)
        return RasterMaterializationResult(RasterMaterializationError.importFailure);
    memory[0 .. bytes] = region.data[];
    OwnedByteResource owned;
    if (!tryAdoptMallocResource(memory, bytes, owned))
    {
        free(memory);
        return RasterMaterializationResult(RasterMaterializationError.importFailure);
    }
    auto layouts = new PlaneByteLayout[](components);
    foreach (component; 0 .. components)
    {
        auto offset = region.info.layout == PixelLayout.planar
            ? component * planeBytes : component;
        auto rowStride = region.info.layout == PixelLayout.planar
            ? region.info.width : region.info.width * components;
        auto sampleStride = region.info.layout == PixelLayout.planar ? 1 : components;
        layouts[component] = PlaneByteLayout(offset, rowStride, sampleStride);
    }
    RasterLease!ubyte lease;
    if (!tryImportOwnedRaster!ubyte(owned, layouts[],
        Region2D(0, 0, region.info.width, region.info.height), lease).ok)
        return RasterMaterializationResult(RasterMaterializationError.importFailure);
    return RasterMaterializationResult(RasterMaterializationError.none, lease);
}

struct UshortRasterMaterializationResult
{
    RasterMaterializationError error;
    RasterLease!ushort raster;

    @property bool ok() const @safe pure nothrow @nogc
    { return error == RasterMaterializationError.none; }
}

/** Materialize an interleaved UInt16 region without numeric conversion. */
UshortRasterMaterializationResult materializeUshort(ImageRegion region)
@system
{
    if (region.info.sampleFormat != SampleFormat.u16
        || region.info.componentCount == 0)
        return UshortRasterMaterializationResult(RasterMaterializationError.unsupportedFormat);
    auto components = region.info.componentCount;
    auto planeSamples = region.info.width * region.info.height;
    auto samples = planeSamples * components;
    if (samples > size_t.max / ushort.sizeof
        || samples * ushort.sizeof != region.data.length)
        return UshortRasterMaterializationResult(RasterMaterializationError.invalidLayout);
    auto expectedRow = region.info.layout == PixelLayout.planar
        ? region.info.width * ushort.sizeof
        : region.info.width * components * ushort.sizeof;
    auto expectedSample = region.info.layout == PixelLayout.planar
        ? ushort.sizeof : components * ushort.sizeof;
    auto expectedPlane = region.info.layout == PixelLayout.planar
        ? planeSamples * ushort.sizeof : 0;
    if ((region.info.rowStrideBytes != 0 && region.info.rowStrideBytes != expectedRow)
        || (region.info.sampleStrideBytes != 0
            && region.info.sampleStrideBytes != expectedSample)
        || (region.info.planeStrideBytes != 0
            && region.info.planeStrideBytes != expectedPlane))
        return UshortRasterMaterializationResult(RasterMaterializationError.allocationFailure);
    auto bytes = samples * ushort.sizeof;
    auto memory = cast(ubyte*) malloc(bytes);
    if (memory is null)
        return UshortRasterMaterializationResult(RasterMaterializationError.importFailure);
    memory[0 .. bytes] = region.data[];
    OwnedByteResource owned;
    if (!tryAdoptMallocResource(memory, bytes, owned))
    {
        free(memory);
        return UshortRasterMaterializationResult(RasterMaterializationError.importFailure);
    }
    auto layouts = new PlaneByteLayout[](components);
    foreach (component; 0 .. components)
    {
        auto offset = region.info.layout == PixelLayout.planar
            ? component * planeSamples * ushort.sizeof
            : component * ushort.sizeof;
        auto rowStride = region.info.layout == PixelLayout.planar
            ? region.info.width * ushort.sizeof
            : region.info.width * components * ushort.sizeof;
        auto sampleStride = region.info.layout == PixelLayout.planar
            ? ushort.sizeof : components * ushort.sizeof;
        layouts[component] = PlaneByteLayout(offset, rowStride, sampleStride);
    }
    RasterLease!ushort lease;
    if (!tryImportOwnedRaster!ushort(owned, layouts[],
        Region2D(0, 0, region.info.width, region.info.height), lease).ok)
        return UshortRasterMaterializationResult(RasterMaterializationError.importFailure);
    return UshortRasterMaterializationResult(RasterMaterializationError.none, lease);
}

/** Wrap a neutral imageio region without copying its samples. */
DecodedImageRegion acceptDecodedRegion(ImageRegion region)
@safe pure nothrow @nogc
{
    return DecodedImageRegion(region.info, region);
}

/** Decode a TIFF ROI through imageio and expose it to imagery consumers. */
struct ImageOpenResult
{
    TiffDecodeError error;
    DecodedImageRegion image;
    TiffRegionPlan plan;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == TiffDecodeError.none;
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

    auto luma = ImagePlane(ImagePlaneInfo(1, 1, 1), 4, 2, 7, 9, 4,
        [ubyte(1), 2, 3, 4, 5, 6, 7, 8]);
    auto chroma = ImagePlane(ImagePlaneInfo(2, 2, 2,
        zeroPhaseSampling(2, 2)), 2, 1, 7, 9, 2,
        [ubyte(10), 20]);
    auto region = ImageRegion(
        ImageRegionInfo(4, 2, 2, SampleFormat.u8, PixelLayout.planar),
        7, 9, null, [luma, chroma]);

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
    assert(expanded.native.planes[1].data == [ubyte(10), 10, 20, 20,
        10, 10, 20, 20]);

    auto unknownChroma = ImagePlane(ImagePlaneInfo(2, 2, 2), 2, 1, 7, 9, 2,
        [ubyte(10), 20]);
    auto unknownRegion = ImageRegion(
        ImageRegionInfo(4, 2, 2, SampleFormat.u8, PixelLayout.planar),
        7, 9, null, [luma, unknownChroma]);
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
    assert(expanded.native.planes[0].data[1 * 4 + 1] == 72);
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
}
