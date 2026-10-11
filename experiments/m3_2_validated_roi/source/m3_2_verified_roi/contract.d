module m3_2_verified_roi.contract;

import m1_5_image_view.contract :
    ChannelDescriptor, ImageView, ImageViewValidationError,
    tryMakeImageView;
import m3_2_channel_metadata.contract :
    IntrinsicChannel, ColourBinding, DeclaredColour, ValueInterpretation,
    SemanticMapError, mapComponentsInto, ResearchCheckedExecution,
    tryResearchPrepareCheckedExecution;
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
    immutable(ChannelDescriptor)[] identities_;
    immutable(IntrinsicChannel)[] intrinsic_;
    bool verified_;

    // Explicit constructor suppresses public struct-literal initialization.
    // Only this module may assert the verified-once invariant.
    private this(
        return scope ImageView!float image,
        return scope immutable(ChannelDescriptor)[] identities,
        return scope immutable(IntrinsicChannel)[] intrinsic
    )
    @safe pure nothrow @nogc
    {
        image_ = image;
        identities_ = identities;
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
        return ValidatedImmutableImage(child, identities_, intrinsic_);
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

    return ValidatedImmutableImage(base, identities, intrinsic);
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
    ResearchCheckedExecution checked_;
    bool prepared_;

    // Explicit private construction: the only successful path receives
    // a fully checked, truly immutable execution value from its factory.
    private this(
        return scope ResearchCheckedExecution checked
    )
    @safe pure nothrow @nogc
    {
        checked_ = checked;
        prepared_ = checked.isValidated;
    }

public:
    @property bool isPrepared() const
    @safe pure nothrow @nogc
    {
        return prepared_ && checked_.isValidated;
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
        auto child = checked_.tryRoi(region, childOk);
        if (!childOk)
            return PreparedSemanticMap.init;
        success = true;
        return PreparedSemanticMap(child);
    }

    SemanticMapError mapInto(
        scope WritableRasterView!float destination
    )
    scope @safe nothrow @nogc
    {
        if (!prepared_)
            return SemanticMapError.metadataCountMismatch;
        return checked_.mapInto(destination);
    }
}

/++
    M3.2.11: prepare from an actually verified immutable image.

    A second O(channelCount) identity check occurs **once** when creating
    the sealed executor, because its separate defining D module may not
    accept a public caller-provided "already validated" boolean. All
    subsequent ROIs and pixel mappings reuse the immutable checked
    executable without repeating the identity validation.

    This duplicate one-time preparation scan is deliberately retained
    in the research experiment rather than reintroducing a bypass.
    Elimination needs a single private factory/module in production.
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
    if (!image.verified_)
    {
        error = SemanticMapError.metadataCountMismatch;
        return PreparedSemanticMap.init;
    }

    auto checked = tryResearchPrepareCheckedExecution(
        image.image_.primary,
        image.identities_,
        image.intrinsic_,
        image.image_.validity,
        image.image_.hasValidity,
        binding, values, error
    );
    if (error != SemanticMapError.none)
        return PreparedSemanticMap.init;

    return PreparedSemanticMap(checked);
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

version (M329_NEGATIVE_METADATA_ESCAPE)
{
    @safe PreparedSemanticMap escapeLocalPreparedMetadata(
        return scope RasterView!float primary
    )
    {
        immutable(ChannelDescriptor)[3] ids = [
            ChannelDescriptor(1), ChannelDescriptor(2), ChannelDescriptor(3)
        ];
        immutable(IntrinsicChannel)[3] meanings = [
            IntrinsicChannel(1, "", "", true, 1.0f, 0.0f),
            IntrinsicChannel(2, "", "", true, 1.0f, 0.0f),
            IntrinsicChannel(3, "", "", true, 1.0f, 0.0f)
        ];
        VerifiedRoiError viewError;
        auto view = tryMakeValidatedImmutableImage(
            primary, ids[], meanings[], RasterView!ubyte.init,
            false, viewError
        );
        SemanticMapError mapError;
        return tryPrepareSemanticMap(
            view, ColourBinding(0, 1, 2, DeclaredColour.unspecified),
            ValueInterpretation.physical, mapError
        );
    }
}
