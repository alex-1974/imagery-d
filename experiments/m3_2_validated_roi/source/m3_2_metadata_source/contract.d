module m3_2_metadata_source.contract;

import m1_5_image_view.contract : ChannelDescriptor;
import m3_2_channel_metadata.contract :
    IntrinsicChannel, ColourBinding, DeclaredColour,
    ValueInterpretation, SemanticMapError;
import m3_2_metadata_owner.contract : ResearchMetadataState;
import m3_2_verified_roi.contract :
    VerifiedRoiError, tryMakeValidatedImmutableImage,
    tryPrepareSemanticMap;
import raster : RasterView, WritableRasterView, Region2D;

/++
    Experimental long-lived immutable metadata *source adapter*.

    Pixels and validity remain borrowed raster data with their own owners.
    Metadata references are retained through GC-managed immutable arrays.
    A new snapshot is explicitly required for new caller-mutable semantics.
    No mutable-to-immutable cast or mutable alias is ever retained.

    This intentionally does not claim to own RasterLease resources,
    provide a public ImageLease, or cache a Prepared token beyond the
    source/primary/validity borrow scopes.
+/
struct ResearchLongLivedMetadataSource
{
private:
    ResearchMetadataState state_;

public:
    static ResearchLongLivedMetadataSource fromImmutable(
        immutable(ChannelDescriptor)[] ids,
        immutable(IntrinsicChannel)[] intrinsic
    ) @safe pure nothrow @nogc
    {
        ResearchLongLivedMetadataSource result;
        result.state_ = ResearchMetadataState.fromImmutable(ids, intrinsic);
        return result;
    }

    static ResearchLongLivedMetadataSource snapshot(
        scope const(ChannelDescriptor)[] ids,
        scope const(IntrinsicChannel)[] intrinsic
    ) @safe
    {
        ResearchLongLivedMetadataSource result;
        result.state_ = ResearchMetadataState.snapshot(ids, intrinsic);
        return result;
    }

    @property size_t channelCount() const @safe pure nothrow @nogc
    {
        return state_.channelCount;
    }

    @property immutable(ChannelDescriptor)[] identities() const
        return scope @safe pure nothrow @nogc
    {
        return state_.identities;
    }

    @property immutable(IntrinsicChannel)[] metadata() const
        return scope @safe pure nothrow @nogc
    {
        return state_.metadata;
    }

    /++
        Verify immutable semantics once per ordered ROI batch; prepare
        binding once; map each ROI into the *caller's* reused output and
        return first/last pixels of each of three mapped components
        in exact order through caller-provided buffers.

        No per-ROI allocation. No returned Prepared or escaped raster
        borrow. Errors are fail-closed; output is not transactional
        after mapping begins. The consumer must allocate sample buffers.
    +/
    SourceRoiError tryMapOrderedInto(
        scope RasterView!float primary,
        scope RasterView!ubyte validity,
        bool hasValidity,
        ColourBinding binding,
        ValueInterpretation values,
        scope const(Region2D)[] windows,
        scope WritableRasterView!float destination,
        scope float[] firstSamples,
        scope float[] lastSamples
    ) const scope @safe nothrow @nogc
    {
        if (windows.length == 0 || windows.length > size_t.max / 3
            || firstSamples.length != windows.length * 3
            || lastSamples.length != windows.length * 3)
            return SourceRoiError.sampleBuffer;

        VerifiedRoiError verifyError;
        auto verified = tryMakeValidatedImmutableImage(
            primary, state_.identities, state_.metadata,
            validity, hasValidity, verifyError);
        if (verifyError != VerifiedRoiError.none)
            return SourceRoiError.invalidImage;

        SemanticMapError prepareError;
        auto prepared = tryPrepareSemanticMap(
            verified, binding, values, prepareError);
        if (prepareError != SemanticMapError.none)
            return SourceRoiError.invalidBinding;

        foreach (index, region; windows)
        {
            if (region.width != destination.width
                || region.height != destination.height
                || region.width == 0 || region.height == 0)
                return SourceRoiError.invalidRegion;
            bool validRoi;
            auto child = prepared.tryRoi(region, validRoi);
            if (!validRoi)
                return SourceRoiError.invalidRegion;
            if (child.mapInto(destination) != SemanticMapError.none)
                return SourceRoiError.mappingFailure;
            foreach (component; 0 .. 3)
            {
                float first, last;
                if (!destination.trySample(component, 0, 0, first)
                    || !destination.trySample(
                        component, destination.width - 1,
                        destination.height - 1, last))
                    return SourceRoiError.sampleFailure;
                firstSamples[index * 3 + component] = first;
                lastSamples[index * 3 + component] = last;
            }
        }
        return SourceRoiError.none;
    }
}

enum SourceRoiError : ubyte
{
    none,
    sampleBuffer,
    invalidImage,
    invalidBinding,
    invalidRegion,
    mappingFailure,
    sampleFailure
}


/++
    Whole-source DIP1000 negative probes bound to the M3.2.18 metadata
    source. Metadata may be held independently, but a Prepared value
    cannot borrow a RasterLease which dies in this function.
    Both configurations MUST be compiler-rejected in @safe code.
+/
version (M3219_NEGATIVE_SOURCE_PRIMARY_ESCAPE)
{
    import raster : RasterLease;
    import m3_2_verified_roi.contract : PreparedSemanticMap;

    @safe PreparedSemanticMap m3219IllegalPrimaryEscape(
        return scope ResearchLongLivedMetadataSource metadata
    )
    {
        RasterLease!float localPrimary;
        VerifiedRoiError verifyError;
        auto checked = tryMakeValidatedImmutableImage(
            localPrimary.view(), metadata.identities, metadata.metadata,
            RasterView!ubyte.init, false, verifyError);
        SemanticMapError mapError;
        return tryPrepareSemanticMap(
            checked,
            ColourBinding(0, 1, 2, DeclaredColour.unspecified),
            ValueInterpretation.stored, mapError);
    }
}

version (M3219_NEGATIVE_SOURCE_VALIDITY_ESCAPE)
{
    import raster : RasterLease;
    import m3_2_verified_roi.contract : PreparedSemanticMap;

    @safe PreparedSemanticMap m3219IllegalValidityEscape(
        return scope ResearchLongLivedMetadataSource metadata,
        return scope RasterView!float primary
    )
    {
        RasterLease!ubyte localValidity;
        VerifiedRoiError verifyError;
        auto checked = tryMakeValidatedImmutableImage(
            primary, metadata.identities, metadata.metadata,
            localValidity.view(), true, verifyError);
        SemanticMapError mapError;
        return tryPrepareSemanticMap(
            checked,
            ColourBinding(0, 1, 2, DeclaredColour.unspecified),
            ValueInterpretation.stored, mapError);
    }
}
