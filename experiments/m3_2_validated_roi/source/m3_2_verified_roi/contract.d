module m3_2_verified_roi.contract;

import m1_5_image_view.contract :
    ChannelDescriptor, ImageView, ImageViewValidationError,
    tryMakeImageView;
import m3_2_channel_metadata.contract :
    IntrinsicChannel, ColourBinding, DeclaredColour, ValueInterpretation,
    SemanticMapError, ResearchCheckedExecution,
    ResearchVerifiedSemanticImage, ResearchVerifiedImageError,
    tryResearchVerifySemanticImage;
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
    // This unforgeable, scoped token was validated in the same D module
    // that owns the private checked pixel executor. The M3.2.6 wrapper
    // intentionally adds no second semantic ID check or copied owner.
    ResearchVerifiedSemanticImage verified_;

    private this(
        return scope ResearchVerifiedSemanticImage verified
    )
    @safe pure nothrow @nogc
    {
        verified_ = verified;
    }

public:
    @property size_t channelCount() const
    scope @safe pure nothrow @nogc
    {
        return verified_.channelCount;
    }

    @property size_t width() const
    scope @safe pure nothrow @nogc
    {
        return verified_.width;
    }

    @property size_t height() const
    scope @safe pure nothrow @nogc
    {
        return verified_.height;
    }

    @property immutable(IntrinsicChannel)[] intrinsic() const
    return scope @safe pure nothrow @nogc
    {
        return verified_.intrinsic;
    }

    @property bool isVerified() const
    scope @safe pure nothrow @nogc
    {
        return verified_.isVerified;
    }

    ValidatedImmutableImage tryRoi(
        Region2D relative,
        out bool success
    )
    return scope @safe pure nothrow @nogc
    {
        success = false;
        if (!verified_.isVerified)
            return ValidatedImmutableImage.init;

        bool childOk;
        auto child = verified_.tryRoi(relative, childOk);
        if (!childOk)
            return ValidatedImmutableImage.init;
        success = true;
        return ValidatedImmutableImage(child);
    }

    // Keep the existing M3.2.6 one-shot consumer and its repeated
    // full semantic-ID preflight: it is the honest control baseline.
    SemanticMapError mapInto(
        ColourBinding binding,
        ValueInterpretation values,
        scope WritableRasterView!float destination
    )
    scope @safe nothrow @nogc
    {
        return verified_.mapInto(binding, values, destination);
    }
}

/++
    Construct once from genuinely immutable identities and intrinsic
    metadata. M3.2.12 delegates its *single* O(channelCount) check
    and grid validation to the module holding the private executor.

    Preserve the exact M3.2.6 error classes and precedence.
    No allocation, snapshot, ownership or public marker bypass.
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
    ResearchVerifiedImageError verifyError;
    auto verified = tryResearchVerifySemanticImage(
        primary, identities, intrinsic, validity, hasValidity, verifyError
    );
    if (verifyError != ResearchVerifiedImageError.none)
    {
        if (verifyError == ResearchVerifiedImageError.descriptorCountMismatch)
            error = VerifiedRoiError.descriptorCountMismatch;
        else if (verifyError == ResearchVerifiedImageError.identityMismatch)
            error = VerifiedRoiError.identityMismatch;
        else
            error = VerifiedRoiError.imageViewFailure;
        return ValidatedImmutableImage.init;
    }
    return ValidatedImmutableImage(verified);
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

    Preparation: the only O(channelCount) identity scan occurs inside
    the verified token factory; selected-three binding is O(1).
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
    M3.2.12: prepare from the co-located verified semantic token.

    Exactly one O(channelCount) semantic ID scan occurs at initial
    immutable image construction; binding/calibration setup is O(1).
    Private token constructors preserve the same security boundary.
    Subsequent ROIs and mapping operations never rescan identities.
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
    // The token's single full identity scan occurred at the M3.2.6
    // factory, inside the defining checked-execution D module.
    // This call only checks the selected three bands and calibration.
    auto checked = image.verified_.tryPrepare(binding, values, error);
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
