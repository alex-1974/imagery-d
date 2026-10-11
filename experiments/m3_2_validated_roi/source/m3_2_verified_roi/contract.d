module m3_2_verified_roi.contract;

import m1_5_image_view.contract :
    ChannelDescriptor, ImageView, ImageViewValidationError,
    tryMakeImageView;
import m3_2_channel_metadata.contract :
    IntrinsicChannel, ColourBinding, DeclaredColour, ValueInterpretation,
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

    // Explicit constructor suppresses public struct-literal initialization.
    // Only this module may assert the verified-once invariant.
    private this(
        return scope ImageView!float image,
        return scope immutable(IntrinsicChannel)[] intrinsic
    )
    @safe pure nothrow @nogc
    {
        image_ = image;
        intrinsic_ = intrinsic;
        verified_ = true;
    }

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
        return ValidatedImmutableImage(child, intrinsic_);
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
    scope @safe nothrow @nogc
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

    return ValidatedImmutableImage(base, intrinsic);
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


/++
    M3.2.9 research-only prepared mapping over a truly immutable,
    previously validated semantic image. No allocation or ownership.

    The constructor is private, not a forgeable public struct literal.
    The retained image capability is borrowed transitively via DIP1000.
    Calibration and selected indices are copied as *values* once;
    immutable metadata cannot be changed via a second @safe alias.

    Preparation: O(channelCount) image validation already performed by
    ValidatedImmutableImage factory; O(1) selected-three checks here.
    Per-ROI: O(1) metadata operations; per-map: O(width*height) pixels.
+/
struct PreparedSemanticMap
{
private:
    ValidatedImmutableImage image_;
    size_t[3] selected_;
    float[3] scales_;
    float[3] offsets_;
    ValueInterpretation values_;
    bool prepared_;

    private this(
        return scope ValidatedImmutableImage image,
        size_t[3] selected,
        float[3] scales,
        float[3] offsets,
        ValueInterpretation values
    )
    @safe nothrow @nogc
    {
        image_ = image;
        selected_ = selected;
        scales_ = scales;
        offsets_ = offsets;
        values_ = values;
        prepared_ = true;
    }

public:
    @property bool isPrepared() const
    @safe pure nothrow @nogc
    {
        return prepared_;
    }

    PreparedSemanticMap tryRoi(
        Region2D region,
        out bool success
    )
    return scope @safe pure nothrow @nogc
    {
        success = false;
        if (!prepared_)
            return PreparedSemanticMap.init;

        bool childOk;
        auto child = image_.tryRoi(region, childOk);
        if (!childOk)
            return PreparedSemanticMap.init;
        success = true;
        return PreparedSemanticMap(
            child, selected_, scales_, offsets_, values_
        );
    }

    /++
        Perform only destination-dependent validation before any write.
        The source grid/mask/identity, selected indices, and calibration
        have been validated in the source and preparation factories.

        Sample read/write failure is still an explicit error. Like the
        original one-shot operation this is not transactionally rolled
        back if a sample write fails after successful preflight.
        Invalid data maps to zero per *test-only* validity policy.
    +/
    SemanticMapError mapInto(
        scope WritableRasterView!float destination
    )
    scope @safe nothrow @nogc
    {
        if (!prepared_)
            return SemanticMapError.metadataCountMismatch;

        if (destination.planeCount != 3
            || destination.width != image_.image_.width
            || destination.height != image_.image_.height)
            return SemanticMapError.destinationMismatch;

        foreach (y; 0 .. image_.image_.height)
        {
            foreach (x; 0 .. image_.image_.width)
            {
                bool valid = true;
                if (image_.image_.hasValidity)
                {
                    ubyte flag;
                    if (!image_.image_.tryValidity(0, x, y, flag))
                        return SemanticMapError.sampleAccessFailure;
                    valid = flag != 0;
                }

                foreach (component; 0 .. 3)
                {
                    float output = 0.0f;
                    if (valid)
                    {
                        if (!image_.image_.trySample(
                            selected_[component], x, y, output
                        ))
                            return SemanticMapError.sampleAccessFailure;
                        if (values_ == ValueInterpretation.physical)
                            output = output * scales_[component]
                                + offsets_[component];
                    }
                    if (!destination.trySetSample(
                        component, x, y, output
                    ))
                        return SemanticMapError.sampleAccessFailure;
                }
            }
        }
        return SemanticMapError.none;
    }
}

/++
    Prepare the explicit channel-to-output semantic mapping exactly once.
    Precondition: verified immutable source established by the M3.2.6
    factory. Unlike .mapInto, this intentionally does not inspect a
    destination; destination validation remains per operation.

    No implicit GC allocation, pixel copy, or channel inference.
+/
PreparedSemanticMap tryPrepareSemanticMap(
    return scope ValidatedImmutableImage image,
    ColourBinding binding,
    ValueInterpretation values,
    out SemanticMapError error
)
@safe nothrow @nogc
{
    error = SemanticMapError.none;
    if (!image.isVerified)
    {
        error = SemanticMapError.metadataCountMismatch;
        return PreparedSemanticMap.init;
    }

    const size_t[3] indices = [
        binding.redChannel, binding.greenChannel, binding.blueChannel
    ];
    foreach (index; 0 .. 3)
    {
        if (indices[index] >= image.image_.channelCount)
        {
            error = SemanticMapError.invalidBinding;
            return PreparedSemanticMap.init;
        }
    }
    if (indices[0] == indices[1]
        || indices[0] == indices[2]
        || indices[1] == indices[2])
    {
        error = SemanticMapError.invalidBinding;
        return PreparedSemanticMap.init;
    }

    if (image.image_.hasValidity
        && image.image_.validity.planeCount != 1)
    {
        error = SemanticMapError.unsupportedValidity;
        return PreparedSemanticMap.init;
    }

    float[3] scales = [1.0f, 1.0f, 1.0f];
    float[3] offsets = [0.0f, 0.0f, 0.0f];
    if (values == ValueInterpretation.physical)
    {
        foreach (component; 0 .. 3)
        {
            const meaning = image.intrinsic[indices[component]];
            if (!meaning.hasCalibration)
            {
                error = SemanticMapError.missingCalibration;
                return PreparedSemanticMap.init;
            }
            if (!(meaning.scale == meaning.scale)
                || meaning.scale == float.infinity
                || meaning.scale == -float.infinity
                || !(meaning.offset == meaning.offset)
                || meaning.offset == float.infinity
                || meaning.offset == -float.infinity)
            {
                error = SemanticMapError.invalidCalibration;
                return PreparedSemanticMap.init;
            }
            scales[component] = meaning.scale;
            offsets[component] = meaning.offset;
        }
    }
    return PreparedSemanticMap(
        image, indices, scales, offsets, values
    );
}

// Negative whole-source DIP1000 proof: an image borrowed from a local
// raster owner may not escape embedded in a prepared mapping.
version (M329_NEGATIVE_OWNER_ESCAPE)
{
    import raster : RasterLease;

    @safe PreparedSemanticMap escapeLocalPrepared(
        return scope immutable(ChannelDescriptor)[] ids,
        return scope immutable(IntrinsicChannel)[] meanings
    )
    {
        RasterLease!float local;
        VerifiedRoiError viewErr;
        auto view = tryMakeValidatedImmutableImage(
            local.view(), ids, meanings, RasterView!ubyte.init,
            false, viewErr
        );
        SemanticMapError mapErr;
        return tryPrepareSemanticMap(
            view, ColourBinding(0, 1, 2, DeclaredColour.unspecified),
            ValueInterpretation.stored, mapErr
        );
    }
}
