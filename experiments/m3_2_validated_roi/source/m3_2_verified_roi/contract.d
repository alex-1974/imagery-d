module m3_2_verified_roi.contract;

import m1_5_image_view.contract :
    ChannelDescriptor, ImageView, ImageViewValidationError,
    tryMakeImageView;
import m3_2_channel_metadata.contract :
    IntrinsicChannel, ColourBinding, ValueInterpretation,
    SemanticMapError, mapComponentsInto;
import raster :
    RasterView, WritableRasterView, Region2D;

/// Experimental construction failures; not a public imagery-d result enum.
enum VerifiedRoiError : ubyte
{
    none,
    descriptorCountMismatch,
    identityMismatch,
    imageViewFailure
}

/++
    A narrowly qualified, source-independent and **non-owning** view.

    Its factory requires truly immutable M1 and M3 channel descriptor
    arrays. Unlike const(T)[] from mutable backing, their semantic IDs
    cannot change through a second mutable alias in @safe code.

    Factory: O(channelCount) identity validation exactly once.
    Child ROI: O(1) descriptor work (M1 image ROI still validates extent
    and plane count), without redoing the intrinsic identity loop.

    This is a research-only proof, not a new approved ImageView API.
+/
struct ValidatedImmutableImage
{
private:
    ImageView!float image_;
    immutable(IntrinsicChannel)[] intrinsic_;
    bool verified_;

public:
    @property size_t channelCount() const
    @safe pure nothrow @nogc
    {
        return image_.channelCount;
    }

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

    @property immutable(IntrinsicChannel)[] intrinsic() const
    return scope @safe pure nothrow @nogc
    {
        return intrinsic_;
    }

    @property bool isVerified() const
    @safe pure nothrow @nogc
    {
        return verified_;
    }

    /++
        Preserve metadata identity through an ROI after one factory
        validation. Only the raster and validity coordinate windows change.

        No manual pointer arithmetic and no new lifetime bypass: M1's
        ImageView.tryRoi propagates the original raster/validity borrows.
    +/
    ValidatedImmutableImage tryRoi(
        Region2D relative,
        out bool success
    )
    return scope @safe pure nothrow @nogc
    {
        success = false;
        if (!verified_)
        {
            return ValidatedImmutableImage.init;
        }

        bool imageOk;
        auto child = image_.tryRoi(relative, imageOk);
        if (!imageOk)
        {
            return ValidatedImmutableImage.init;
        }

        success = true;
        // Verified identity is invariant: true immutable metadata backing,
        // unchanged M1 descriptors, and a validated relative image ROI.
        return ValidatedImmutableImage(child, intrinsic_, true);
    }

    /++
        Reuse the previous M3.2.2 semantic mapping consumer.

        That *operation* independently performs its existing preflight,
        including channel identity comparisons. The optimization evaluated
        here is strictly ROI construction, not arithmetic mapping.
    +/
    SemanticMapError mapInto(
        ColourBinding binding,
        ValueInterpretation values,
        scope WritableRasterView!float destination
    )
    @safe nothrow @nogc
    {
        if (!verified_)
        {
            return SemanticMapError.metadataCountMismatch;
        }
        return mapComponentsInto(
            image_, intrinsic_, binding, values, destination
        );
    }
}

/++
    Construct a verified-once image with immutable channel metadata.

    Mutable const(T)[] is intentionally not accepted; a caller needing
    this optimization must already possess immutable metadata or perform
    an explicit snapshot as qualified in M3.2.4. No implicit copy is made.

    Raster backing remains retained outside by raster-d RasterLease.
+/
ValidatedImmutableImage tryMakeValidatedImmutableImage(
    return scope RasterView!float primary,
    return scope immutable(ChannelDescriptor)[] identities,
    return scope immutable(IntrinsicChannel)[] intrinsic,
    return scope RasterView!ubyte validity,
    bool hasValidity,
    out VerifiedRoiError error
)
@safe pure nothrow @nogc
{
    error = VerifiedRoiError.none;

    if (identities.length != intrinsic.length)
    {
        error = VerifiedRoiError.descriptorCountMismatch;
        return ValidatedImmutableImage.init;
    }

    foreach (index; 0 .. intrinsic.length)
    {
        if (identities[index].semanticId != intrinsic[index].semanticId)
        {
            error = VerifiedRoiError.identityMismatch;
            return ValidatedImmutableImage.init;
        }
    }

    ImageViewValidationError viewError;
    auto base = tryMakeImageView!float(
        primary, identities, validity, hasValidity, viewError
    );
    if (viewError != ImageViewValidationError.none)
    {
        error = VerifiedRoiError.imageViewFailure;
        return ValidatedImmutableImage.init;
    }

    return ValidatedImmutableImage(base, intrinsic, true);
}

// Whole-source negative probes: all are expected to fail due to scope
// borrow escape in DMD/LDC. They are tested under -preview=dip1000.

version (M326_NEGATIVE_PRIMARY_ESCAPE)
{
    import raster : RasterLease;
    @safe ValidatedImmutableImage negativePrimaryEscape(
        return scope immutable(ChannelDescriptor)[] ids,
        return scope immutable(IntrinsicChannel)[] meanings
    )
    {
        RasterLease!float local;
        VerifiedRoiError error;
        return tryMakeValidatedImmutableImage(
            local.view(), ids, meanings, RasterView!ubyte.init,
            false, error
        );
    }
}

version (M326_NEGATIVE_VALIDITY_ESCAPE)
{
    import raster : RasterLease;
    @safe ValidatedImmutableImage negativeValidityEscape(
        return scope RasterView!float primary,
        return scope immutable(ChannelDescriptor)[] ids,
        return scope immutable(IntrinsicChannel)[] meanings
    )
    {
        RasterLease!ubyte local;
        VerifiedRoiError error;
        return tryMakeValidatedImmutableImage(
            primary, ids, meanings, local.view(), true, error
        );
    }
}

version (M326_NEGATIVE_METADATA_ESCAPE)
{
    @safe ValidatedImmutableImage negativeMetadataEscape(
        return scope RasterView!float primary
    )
    {
        immutable(ChannelDescriptor)[3] localIds = [
            ChannelDescriptor(1), ChannelDescriptor(2),
            ChannelDescriptor(3)
        ];
        immutable(IntrinsicChannel)[3] localMeaning = [
            IntrinsicChannel(1, "x", "unknown", false, 0.0f, 0.0f),
            IntrinsicChannel(2, "y", "unknown", false, 0.0f, 0.0f),
            IntrinsicChannel(3, "z", "unknown", false, 0.0f, 0.0f)
        ];
        VerifiedRoiError error;
        return tryMakeValidatedImmutableImage(
            primary, localIds[], localMeaning[],
            RasterView!ubyte.init, false, error
        );
    }
}

version (M326_NEGATIVE_ROI_ESCAPE)
{
    import raster : RasterLease;
    @safe ValidatedImmutableImage negativeRoiEscape(
        return scope immutable(ChannelDescriptor)[] ids,
        return scope immutable(IntrinsicChannel)[] meanings
    )
    {
        RasterLease!float local;
        VerifiedRoiError error;
        auto image = tryMakeValidatedImmutableImage(
            local.view(), ids, meanings,
            RasterView!ubyte.init, false, error
        );
        bool success;
        return image.tryRoi(Region2D(0, 0, 0, 0), success);
    }
}

version (M326_NEGATIVE_MUTABLE_METADATA)
{
    @safe ValidatedImmutableImage negativeMutableMetadata(
        return scope RasterView!float primary,
        return scope const(ChannelDescriptor)[] ids,
        return scope const(IntrinsicChannel)[] meanings
    )
    {
        VerifiedRoiError error;
        return tryMakeValidatedImmutableImage(
            primary, ids, meanings, RasterView!ubyte.init,
            false, error
        );
    }
}
