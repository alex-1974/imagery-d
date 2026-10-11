module m3_2_retained_metadata.contract;

import m1_5_image_view.contract :
    ChannelDescriptor,
    ImageView,
    ImageViewValidationError,
    tryMakeImageView;
import m3_2_channel_metadata.contract :
    IntrinsicChannel,
    ColourBinding,
    SemanticMapError,
    ValueInterpretation,
    mapComponentsInto;
import raster :
    RasterLease,
    RasterView,
    Region2D,
    WritableRasterView;

enum MetadataBorrowError : ubyte
{
    none,
    countMismatch,
    identityMismatch,
    imageConstructionFailure
}

/++
    Experimental carrier borrowing both M1.5 ImageView and M3.2.2 intrinsic
    metadata. It owns neither raster resources nor channel metadata.

    This is a typed, scope-bound composition probe, *not* a proposed public
    ImageLease or universal metadata representation.
+/
struct BorrowedSemanticImage
{
private:
    ImageView!float image_;
    const(IntrinsicChannel)[] intrinsic_;

public:
    @property size_t width() const
    @safe pure nothrow @nogc
    {
        return image_.width;
    }

    @property size_t height() const
    @safe pure nothrow @nogc
    {
        return image_.height;
    }

    @property size_t channelCount() const
    @safe pure nothrow @nogc
    {
        return image_.channelCount;
    }

    @property const(IntrinsicChannel)[] intrinsic()
    return scope @safe pure nothrow @nogc
    {
        return intrinsic_;
    }

    SemanticMapError mapInto(
        ColourBinding binding,
        ValueInterpretation values,
        scope WritableRasterView!float destination
    )
    @safe nothrow @nogc
    {
        return mapComponentsInto(
            image_, intrinsic_, binding, values, destination
        );
    }

    BorrowedSemanticImage tryRoi(
        Region2D region,
        out bool success
    )
    return scope @safe pure nothrow @nogc
    {
        success = false;
        bool imageOk;
        auto subimage = image_.tryRoi(region, imageOk);
        if (!imageOk)
        {
            return BorrowedSemanticImage.init;
        }

        MetadataBorrowError error;
        auto result = tryBorrowSemanticImage(subimage, intrinsic_, error);
        if (error != MetadataBorrowError.none)
        {
            return BorrowedSemanticImage.init;
        }
        success = true;
        return result;
    }

package(m3_2_retained_metadata):
    void setValidated(
        return scope ImageView!float image,
        return scope const(IntrinsicChannel)[] intrinsic
    )
    @safe pure nothrow @nogc
    {
        image_ = image;
        intrinsic_ = intrinsic;
    }
}

/++
    Bind existing M1.5 image semantics and M3.2.2 intrinsic metadata.

    Borrowed content and its transitive ROIs may not outlive either source.
    Explicit cardinality and semantic IDs are checked at binding time.
+/
BorrowedSemanticImage tryBorrowSemanticImage(
    return scope ImageView!float image,
    return scope const(IntrinsicChannel)[] intrinsic,
    out MetadataBorrowError error
)
@safe pure nothrow @nogc
{
    error = MetadataBorrowError.none;
    if (image.channelCount != intrinsic.length)
    {
        error = MetadataBorrowError.countMismatch;
        return BorrowedSemanticImage.init;
    }

    auto channels = image.channels;
    foreach (i; 0 .. intrinsic.length)
    {
        if (channels[i].semanticId != intrinsic[i].semanticId)
        {
            error = MetadataBorrowError.identityMismatch;
            return BorrowedSemanticImage.init;
        }
    }

    BorrowedSemanticImage result;
    result.setValidated(image, intrinsic);
    return result;
}

/++
    Research-only example of an owning fixture: reuse raster-d's leases,
    with immutable metadata stored *inside* one caller-controlled aggregate.

    Fixed cardinality is *only* a bounded probe fixture; the M1 contract
    supports arbitrary channel count. Do not freeze this owner or inline
    metadata representation as the production API.
+/
struct RetainedFourChannelFixture
{
    RasterLease!float primary;
    RasterLease!ubyte validity;
    bool hasValidity;

    immutable(ChannelDescriptor)[4] descriptorIdentity =
        [ChannelDescriptor(100), ChannelDescriptor(101),
         ChannelDescriptor(102), ChannelDescriptor(103)];

    immutable(IntrinsicChannel)[4] intrinsicMeaning =
        [IntrinsicChannel(100, "custom-R", "raw", false, 0.0f, 0.0f),
         IntrinsicChannel(101, "NIR", "reflectance", true, -1.0f, 5.0f),
         IntrinsicChannel(102, "B08", "reflectance", true, 2.0f, -400.0f),
         IntrinsicChannel(103, "custom-G", "radiance", true, 0.25f, 120.0f)];

    BorrowedSemanticImage borrow(out MetadataBorrowError error)
    return @safe nothrow @nogc
    {
        auto primaryView = primary.view();
        auto validityView = hasValidity
            ? validity.view()
            : RasterView!ubyte.init;
        ImageViewValidationError imageError;
        auto view = tryMakeImageView!float(
            primaryView, descriptorIdentity[], validityView,
            hasValidity, imageError
        );
        if (imageError != ImageViewValidationError.none)
        {
            error = MetadataBorrowError.imageConstructionFailure;
            return BorrowedSemanticImage.init;
        }

        return tryBorrowSemanticImage(
            view, intrinsicMeaning[], error
        );
    }

    @disable this(this);
}


version (M32_NEGATIVE_INTRINSIC_ESCAPE)
{
    @safe BorrowedSemanticImage escapeLocalIntrinsic(
        return scope ImageView!float callerImage
    )
    {
        IntrinsicChannel[4] localMetadata;
        MetadataBorrowError error;
        return tryBorrowSemanticImage(
            callerImage, localMetadata[], error
        );
    }
}

version (M32_NEGATIVE_PRIMARY_ESCAPE)
{
    @safe BorrowedSemanticImage escapeLocalPrimary(
        return scope const(IntrinsicChannel)[] callerMetadata
    )
    {
        RasterLease!float localPrimary;
        static immutable ChannelDescriptor[4] ids = [
            ChannelDescriptor(100), ChannelDescriptor(101),
            ChannelDescriptor(102), ChannelDescriptor(103)
        ];
        ImageViewValidationError imageError;
        auto image = tryMakeImageView!float(
            localPrimary.view(), ids[], RasterView!ubyte.init,
            false, imageError
        );
        MetadataBorrowError error;
        return tryBorrowSemanticImage(image, callerMetadata, error);
    }
}

version (M32_NEGATIVE_VALIDITY_ESCAPE)
{
    @safe BorrowedSemanticImage escapeLocalValidity(
        return scope RasterView!float callerPrimary,
        return scope const(IntrinsicChannel)[] callerMetadata
    )
    {
        RasterLease!ubyte localValidity;
        static immutable ChannelDescriptor[4] ids = [
            ChannelDescriptor(100), ChannelDescriptor(101),
            ChannelDescriptor(102), ChannelDescriptor(103)
        ];
        ImageViewValidationError imageError;
        auto image = tryMakeImageView!float(
            callerPrimary, ids[], localValidity.view(),
            true, imageError
        );
        MetadataBorrowError error;
        return tryBorrowSemanticImage(image, callerMetadata, error);
    }
}

version (M32_NEGATIVE_OWNER_ESCAPE)
{
    @safe BorrowedSemanticImage escapeLocalRetainedFixture()
    {
        RetainedFourChannelFixture local;
        MetadataBorrowError error;
        return local.borrow(error);
    }
}

version (M32_NEGATIVE_ROI_ESCAPE)
{
    @safe BorrowedSemanticImage escapeLocalRoi()
    {
        RetainedFourChannelFixture local;
        MetadataBorrowError error;
        auto image = local.borrow(error);
        bool ok;
        return image.tryRoi(Region2D(0, 0, 0, 0), ok);
    }
}
