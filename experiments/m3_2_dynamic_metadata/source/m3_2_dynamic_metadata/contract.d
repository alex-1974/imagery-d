module m3_2_dynamic_metadata.contract;

import std.algorithm.mutation : move;

import m1_5_image_view.contract :
    ChannelDescriptor,
    ImageViewValidationError,
    tryMakeImageView;
import m3_2_channel_metadata.contract : IntrinsicChannel;
import m3_2_retained_metadata.contract :
    BorrowedSemanticImage,
    MetadataBorrowError,
    tryBorrowSemanticImage;
import raster :
    RasterLease,
    RasterView;

enum SnapshotError : ubyte
{
    none,
    channelCountMismatch,
    semanticIdentityMismatch
}

/++
    Research-only owner of a variable number of immutable channel snapshots.

    Copies the two metadata arrays once at construction via .idup (GC).
    The raster leases still own pixel and mask resources through raster-d.
    No copy or heap allocation occurs when making ROI/image borrows.

    GC-backed allocation is a deliberate *candidate* to measure, not a
    production allocation policy. No final public API is implied.
+/
struct RetainedDynamicImage
{
    RasterLease!float primary;
    RasterLease!ubyte validity;
    bool hasValidity;

private:
    immutable(ChannelDescriptor)[] identities_;
    immutable(IntrinsicChannel)[] intrinsic_;

public:
    @disable this(this);

    static RetainedDynamicImage create(
        scope const(ChannelDescriptor)[] identities,
        scope const(IntrinsicChannel)[] intrinsic,
        out SnapshotError error
    )
    @safe
    {
        error = SnapshotError.none;

        if (identities.length != intrinsic.length)
        {
            error = SnapshotError.channelCountMismatch;
            return RetainedDynamicImage.init;
        }

        foreach (i; 0 .. identities.length)
        {
            if (identities[i].semanticId != intrinsic[i].semanticId)
            {
                error = SnapshotError.semanticIdentityMismatch;
                return RetainedDynamicImage.init;
            }
        }

        // Both arrays are copied before either is published by the owner.
        // Callers remain free to mutate their source descriptors afterwards.
        auto ownedIds = identities.idup;
        auto ownedMeaning = intrinsic.idup;

        RetainedDynamicImage result;
        result.identities_ = ownedIds;
        result.intrinsic_ = ownedMeaning;
        return move(result);
    }

    @property size_t channelCount() const
    @safe pure nothrow @nogc
    {
        return identities_.length;
    }

    @property const(IntrinsicChannel)[] intrinsic()
    return scope @safe pure nothrow @nogc
    {
        return intrinsic_;
    }

    @property const(ChannelDescriptor)[] identities()
    return scope @safe pure nothrow @nogc
    {
        return identities_;
    }

    BorrowedSemanticImage borrow(out MetadataBorrowError error)
    return @safe nothrow @nogc
    {
        auto source = primary.view();
        auto mask = hasValidity ? validity.view() : RasterView!ubyte.init;

        ImageViewValidationError viewError;
        auto image = tryMakeImageView!float(
            source, identities_, mask, hasValidity, viewError
        );
        if (viewError != ImageViewValidationError.none)
        {
            error = MetadataBorrowError.imageConstructionFailure;
            return BorrowedSemanticImage.init;
        }

        return tryBorrowSemanticImage(image, intrinsic_, error);
    }
}

version (M324_NEGATIVE_OWNER_ESCAPE)
{
    @safe BorrowedSemanticImage negativeEscapeDynamicOwner()
    {
        RetainedDynamicImage local;
        MetadataBorrowError error;
        return local.borrow(error);
    }
}

version (M324_NEGATIVE_ROI_ESCAPE)
{
    @safe BorrowedSemanticImage negativeEscapeDynamicRoi()
    {
        import raster : Region2D;
        RetainedDynamicImage local;
        MetadataBorrowError error;
        auto image = local.borrow(error);
        bool ok;
        return image.tryRoi(Region2D(0, 0, 0, 0), ok);
    }
}

// GC snapshot slices may safely survive their owner (and extend GC residency).
// This is intentional current behavior, not a strictly owner-scoped contract.
version (M324_GC_METADATA_ACCESS_ESCAPE)
{
    @safe const(IntrinsicChannel)[] negativeEscapeMetadataAccess()
    {
        RetainedDynamicImage local;
        return local.intrinsic;
    }
}
