module m1_5_image_view.contract;

import raster :
    RasterLease,
    RasterView,
    Region2D;


/++
    Minimal semantic channel descriptor for the M1.5 lifetime experiment.

    This deliberately does not attempt to model the final imagery-d channel
    API. Its only job is to give ImageView borrowed immutable metadata whose
    lifetime DIP1000 can track.
+/
struct ChannelDescriptor
{
    uint semanticId;
}


/++
    Validation outcomes required by this spike.

    The final imagery-d API may use a different result/error model.
+/
enum ImageViewValidationError : ubyte
{
    none,
    channelCountMismatch,
    validityExtentMismatch
}


/++
    Experimental common-grid image view.

    Responsibilities deliberately kept narrow:

    - borrow one primary RasterView!T;
    - borrow immutable channel semantics;
    - optionally borrow one same-grid UInt8 validity RasterView;
    - preserve all three borrow relationships through ROI.

    This type owns no pixel storage and no semantic metadata.
+/
struct ImageView(T)
{
private:
    RasterView!T primary_;
    const(ChannelDescriptor)[] channels_;

    RasterView!ubyte validity_;
    bool hasValidity_;


public:
    @property
    size_t channelCount() const
    @safe
    pure
    nothrow
    @nogc
    {
        return channels_.length;
    }


    @property
    bool hasValidity() const
    @safe
    pure
    nothrow
    @nogc
    {
        return hasValidity_;
    }


    @property
    size_t width() const
    @safe
    pure
    nothrow
    @nogc
    {
        return primary_.width;
    }


    @property
    size_t height() const
    @safe
    pure
    nothrow
    @nogc
    {
        return primary_.height;
    }


    @property
    RasterView!T primary() const
    return scope
    @safe
    pure
    nothrow
    @nogc
    {
        return primary_;
    }


    @property
    const(ChannelDescriptor)[] channels() const
    return scope
    @safe
    pure
    nothrow
    @nogc
    {
        return channels_;
    }


    @property
    RasterView!ubyte validity() const
    return scope
    @safe
    pure
    nothrow
    @nogc
    {
        return validity_;
    }


    bool trySample(
        size_t channel,
        size_t x,
        size_t y,
        out T value
    ) const
    @safe
    nothrow
    @nogc
    {
        return primary_.trySample(
            channel,
            x,
            y,
            value
        );
    }


    /++
        Reads one validity value.

        Zero means invalid.
        Non-zero means valid.

        The validity raster may contain one shared mask plane or several mask
        planes. This experiment does not yet model the final binding from
        primary channels to mask planes.
    +/
    bool tryValidity(
        size_t maskPlane,
        size_t x,
        size_t y,
        out ubyte value
    ) const
    @safe
    nothrow
    @nogc
    {
        value = 0;

        if (!hasValidity_)
        {
            return false;
        }

        return validity_.trySample(
            maskPlane,
            x,
            y,
            value
        );
    }


    /++
        Creates a child common-grid image view.

        Primary and validity views receive the same relative ROI.
        Immutable semantic metadata is shared without copying.
    +/
    ImageView!T tryRoi(
        Region2D relative,
        out bool success
    ) const
    return scope
    @safe
    pure
    nothrow
    @nogc
    {
        success = false;

        bool primaryOk;

        auto childPrimary =
            primary_.tryRoi(
                relative,
                primaryOk
            );

        if (!primaryOk)
        {
            return ImageView!T.init;
        }


        RasterView!ubyte childValidity;

        if (hasValidity_)
        {
            bool validityOk;

            childValidity =
                validity_.tryRoi(
                    relative,
                    validityOk
                );

            /*
             * A validated parent ImageView has equal primary/validity local
             * extents, so equal relative ROI should succeed for both.
             */
            if (!validityOk)
            {
                return ImageView!T.init;
            }
        }


        ImageViewValidationError error;

        auto child =
            tryMakeImageView!T(
                childPrimary,
                channels_,
                childValidity,
                hasValidity_,
                error
            );

        if (
            error
            != ImageViewValidationError.none
        )
        {
            return ImageView!T.init;
        }

        success = true;

        return child;
    }


package(m1_5_image_view):

    void setValidated(
        return scope RasterView!T primary,
        return scope const(ChannelDescriptor)[] channels,
        return scope RasterView!ubyte validity,
        bool hasValidity
    )
    @safe
    pure
    nothrow
    @nogc
    {
        primary_ = primary;
        channels_ = channels;
        validity_ = validity;
        hasValidity_ = hasValidity;
    }
}


/++
    Validates and constructs a borrowed common-grid ImageView.

    All alias-bearing inputs are `return scope` because the result may contain
    borrows derived from each of them.
+/
ImageView!T tryMakeImageView(T)(
    return scope RasterView!T primary,
    return scope const(ChannelDescriptor)[] channels,
    return scope RasterView!ubyte validity,
    bool hasValidity,
    out ImageViewValidationError error
)
@safe
pure
nothrow
@nogc
{
    error =
        ImageViewValidationError.none;

    if (
        primary.planeCount
        != channels.length
    )
    {
        error =
            ImageViewValidationError
                .channelCountMismatch;

        return ImageView!T.init;
    }


    if (
        hasValidity
        && (
            primary.width
                != validity.width
            || primary.height
                != validity.height
        )
    )
    {
        error =
            ImageViewValidationError
                .validityExtentMismatch;

        return ImageView!T.init;
    }


    ImageView!T result;

    result.setValidated(
        primary,
        channels,
        validity,
        hasValidity
    );

    return result;
}


/++
    Explicit @nogc ROI consumer.

    Merely compiling this function proves that the semantic ROI path itself
    requires no GC allocation.
+/
void exerciseRoiNoGc(T)(
    scope ImageView!T image
)
@safe
nothrow
@nogc
{
    bool success;

    auto roi =
        image.tryRoi(
            Region2D(
                0,
                0,
                image.width,
                image.height
            ),
            success
        );

    if (success)
    {
        /*
         * Prevent the local from being optimized into a completely unused
         * expression without imposing an allocation or I/O dependency.
         */
        assert(
            roi.channelCount
            == image.channelCount
        );
    }
}


/*
 * Compile-negative lifetime probes.
 *
 * Each configuration is expected to fail compilation. The run script treats a
 * successful build of any one of these configurations as a research failure.
 */

version (M1_NEGATIVE_PRIMARY_ESCAPE)
{
    @safe
    ImageView!ubyte negativeEscapePrimary()
    {
        RasterLease!ubyte localLease;

        auto localPrimary =
            localLease.view();

        static immutable ChannelDescriptor[1] semantics =
        [
            ChannelDescriptor(1)
        ];

        ImageViewValidationError error;

        return tryMakeImageView!ubyte(
            localPrimary,
            semantics[],
            RasterView!ubyte.init,
            false,
            error
        );
    }
}


version (M1_NEGATIVE_METADATA_ESCAPE)
{
    @safe
    ImageView!ubyte negativeEscapeMetadata(
        return scope RasterView!ubyte callerPrimary
    )
    {
        ChannelDescriptor[1] localSemantics =
        [
            ChannelDescriptor(1)
        ];

        ImageViewValidationError error;

        return tryMakeImageView!ubyte(
            callerPrimary,
            localSemantics[],
            RasterView!ubyte.init,
            false,
            error
        );
    }
}


version (M1_NEGATIVE_VALIDITY_ESCAPE)
{
    @safe
    ImageView!ubyte negativeEscapeValidity(
        return scope RasterView!ubyte callerPrimary,
        return scope const(ChannelDescriptor)[] callerSemantics
    )
    {
        RasterLease!ubyte localValidityLease;

        auto localValidity =
            localValidityLease.view();

        ImageViewValidationError error;

        return tryMakeImageView!ubyte(
            callerPrimary,
            callerSemantics,
            localValidity,
            true,
            error
        );
    }
}


version (M1_NEGATIVE_ROI_ESCAPE)
{
    @safe
    ImageView!ubyte negativeEscapeRoi()
    {
        RasterLease!ubyte localLease;

        auto localPrimary =
            localLease.view();

        static immutable ChannelDescriptor[1] semantics =
        [
            ChannelDescriptor(1)
        ];

        ImageViewValidationError error;

        auto localImage =
            tryMakeImageView!ubyte(
                localPrimary,
                semantics[],
                RasterView!ubyte.init,
                false,
                error
            );

        bool success;

        auto localRoi =
            localImage.tryRoi(
                Region2D(
                    0,
                    0,
                    0,
                    0
                ),
                success
            );

        return localRoi;
    }
}
