module m3_2_channel_metadata.contract;

import m1_5_image_view.contract :
    ImageView, ChannelDescriptor, ImageViewValidationError, tryMakeImageView;
import raster : RasterView, WritableRasterView, Region2D;

/++
    Research-only intrinsic description of one logical image channel.

    The source label and quantity label are opaque. They do not imply
    red/green/blue roles, scaling, physical units, or a colour space.
    Fields remain provisional and are not a proposed public API.
+/
struct IntrinsicChannel
{
    uint semanticId;
    string sourceLabel;
    string quantityLabel;
    bool hasCalibration;
    float scale;
    float offset;
}

/++
    Colour interpretation is independent of channel identity and of stored
    versus physical arithmetic. The operation below never performs colour
    conversion, regardless of this declared interpretation.
+/
enum DeclaredColour : ubyte
{
    unspecified,
    encodedSRgb,
    linearSRgb
}

struct ColourBinding
{
    size_t redChannel;
    size_t greenChannel;
    size_t blueChannel;
    DeclaredColour declaredColour;
}

enum ValueInterpretation : ubyte
{
    stored,
    physical
}

enum SemanticMapError : ubyte
{
    none,
    metadataCountMismatch,
    metadataIdentityMismatch,
    invalidBinding,
    missingCalibration,
    invalidCalibration,
    unsupportedValidity,
    destinationMismatch,
    sampleAccessFailure
}

private bool finite(float value)
@safe pure nothrow @nogc
{
    return value == value
        && value != float.infinity
        && value != -float.infinity;
}

/++
    Materialize one explicitly bound triple of image channels.

    - Metadata is caller-owned, immutable and borrowed for this operation.
    - Stored mode forwards exact stored samples.
    - Physical mode explicitly evaluates stored * scale + offset.
    - No channel name or plane count implies RGB.
    - A validity mask, when present, is kept distinct from calibration.
    - Invalid-to-zero is an explicit test policy only, not an alpha/NoData rule.
    - The destination is caller-owned; no storage is allocated here.

    All metadata preflight checks precede any destination write.
    This experiment does not promise transactionality if a sample write fails
    after a successful preflight.
+/
/++
    M3.2.11: the only checked pixel/validity/write loop, now module private.

    Only full M3.2.2 one-shot preflight and the unforgeable prepared
    executor method in this module can call this implementation.
    No caller can pass arbitrary selected indices or scales directly.
+/
pragma(inline, false)
private SemanticMapError researchExecuteCheckedPixels(
    scope ImageView!float image,
    size_t[3] selected,
    float[3] scales,
    float[3] offsets,
    ValueInterpretation values,
    scope WritableRasterView!float destination
)
@safe nothrow @nogc
{
    foreach (y; 0 .. image.height)
    {
        foreach (x; 0 .. image.width)
        {
            bool valid = true;
            if (image.hasValidity)
            {
                ubyte flag;
                if (!image.tryValidity(0, x, y, flag))
                    return SemanticMapError.sampleAccessFailure;
                valid = flag != 0;
            }

            foreach (component; 0 .. 3)
            {
                float output = 0.0f;
                if (valid)
                {
                    if (!image.trySample(selected[component], x, y, output))
                        return SemanticMapError.sampleAccessFailure;

                    if (values == ValueInterpretation.physical)
                        output = output * scales[component]
                            + offsets[component];
                }
                if (!destination.trySetSample(component, x, y, output))
                    return SemanticMapError.sampleAccessFailure;
            }
        }
    }
    return SemanticMapError.none;
}

/++
    M3.2.11 research-only, nonowning **validated execution capability**.

    The explicit private constructor suppresses D's public positional
    struct literal. '.init' is inert. The source image is reconstructed
    exclusively with *truly immutable* channel semantics by the
    validating factory below. 'const' over mutable descriptor backing
    does not qualify. No allocation and no unchecked pointer operations.

    Unlike the raw kernel, a caller cannot create an apparently valid
    executor from arbitrary indices, calibration or raster metadata.
+/
struct ResearchCheckedExecution
{
private:
    ImageView!float image_;
    size_t[3] selected_;
    float[3] scales_;
    float[3] offsets_;
    ValueInterpretation values_;
    bool validated_;

    private this(
        return scope ImageView!float image,
        size_t[3] selected,
        float[3] scales,
        float[3] offsets,
        ValueInterpretation values
    )
    @safe pure nothrow @nogc
    {
        image_ = image;
        selected_ = selected;
        scales_ = scales;
        offsets_ = offsets;
        values_ = values;
        validated_ = true;
    }

public:
    @property bool isValidated() const
    scope @safe pure nothrow @nogc
    {
        return validated_;
    }

    ResearchCheckedExecution tryRoi(
        Region2D region,
        out bool success
    )
    return scope @safe pure nothrow @nogc
    {
        success = false;
        if (!validated_)
            return ResearchCheckedExecution.init;
        bool ok;
        auto child = image_.tryRoi(region, ok);
        if (!ok)
            return ResearchCheckedExecution.init;

        success = true;
        return ResearchCheckedExecution(
            child, selected_, scales_, offsets_, values_
        );
    }

    SemanticMapError mapInto(
        scope WritableRasterView!float destination
    )
    scope @safe nothrow @nogc
    {
        if (!validated_)
            return SemanticMapError.metadataCountMismatch;
        if (destination.planeCount != 3
            || destination.width != image_.width
            || destination.height != image_.height)
            return SemanticMapError.destinationMismatch;

        // The *same* private noninline implementation as one-shot.
        return researchExecuteCheckedPixels(
            image_, selected_, scales_, offsets_, values_, destination
        );
    }
}

/++
    M3.2.12 research-only initial immutable semantic verification.

    One complete channel identity scan per source image. Its private
    constructor cannot be invoked from other D modules, including the
    M3.2.6 compatibility wrapper. No owner, snapshot, or GC allocation.
+/
enum ResearchVerifiedImageError : ubyte
{
    none,
    descriptorCountMismatch,
    identityMismatch,
    imageViewFailure
}

struct ResearchVerifiedSemanticImage
{
private:
    ImageView!float image_;
    immutable(ChannelDescriptor)[] identities_;
    immutable(IntrinsicChannel)[] intrinsic_;
    bool verified_;

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
    @property bool isVerified() const
    scope @safe pure nothrow @nogc
    {
        return verified_;
    }

    @property size_t channelCount() const
    scope @safe pure nothrow @nogc
    {
        return image_.channelCount;
    }

    @property size_t width() const
    scope @safe pure nothrow @nogc
    {
        return image_.width;
    }

    @property size_t height() const
    scope @safe pure nothrow @nogc
    {
        return image_.height;
    }

    @property immutable(IntrinsicChannel)[] intrinsic() const
    return scope @safe pure nothrow @nogc
    {
        return intrinsic_;
    }

    ResearchVerifiedSemanticImage tryRoi(
        Region2D relative,
        out bool success
    )
    return scope @safe pure nothrow @nogc
    {
        success = false;
        if (!verified_)
            return ResearchVerifiedSemanticImage.init;

        bool roiOk;
        auto child = image_.tryRoi(relative, roiOk);
        if (!roiOk)
            return ResearchVerifiedSemanticImage.init;

        success = true;
        return ResearchVerifiedSemanticImage(
            child, identities_, intrinsic_
        );
    }

    SemanticMapError mapInto(
        ColourBinding binding,
        ValueInterpretation values,
        scope WritableRasterView!float destination
    )
    scope @safe nothrow @nogc
    {
        if (!verified_)
            return SemanticMapError.metadataCountMismatch;
        // Preserve the original M3.2.2 per-call semantic preflight.
        return mapComponentsInto(
            image_, intrinsic_, binding, values, destination
        );
    }

    /++
        M3.2.12: bind three channels after the one complete identity
        check in the private-construction image factory. This method
        has no whole-image semantic ID pass (O(1) scalar preparation).
        It cannot be called on a forgeable caller-supplied ImageView.
    +/
    ResearchCheckedExecution tryPrepare(
        ColourBinding binding,
        ValueInterpretation values,
        out SemanticMapError error
    )
    return scope @safe pure nothrow @nogc
    {
        error = SemanticMapError.none;
        if (!verified_)
        {
            error = SemanticMapError.metadataCountMismatch;
            return ResearchCheckedExecution.init;
        }

        const size_t[3] selected =
            [binding.redChannel, binding.greenChannel, binding.blueChannel];
        foreach (component; 0 .. 3)
        {
            if (selected[component] >= image_.channelCount)
            {
                error = SemanticMapError.invalidBinding;
                return ResearchCheckedExecution.init;
            }
        }
        if (selected[0] == selected[1]
            || selected[0] == selected[2]
            || selected[1] == selected[2])
        {
            error = SemanticMapError.invalidBinding;
            return ResearchCheckedExecution.init;
        }

        if (image_.hasValidity && image_.validity.planeCount != 1)
        {
            error = SemanticMapError.unsupportedValidity;
            return ResearchCheckedExecution.init;
        }

        float[3] scales = [1.0f, 1.0f, 1.0f];
        float[3] offsets = [0.0f, 0.0f, 0.0f];
        if (values == ValueInterpretation.physical)
        {
            foreach (component; 0 .. 3)
            {
                const ref meaning = intrinsic_[selected[component]];
                if (!meaning.hasCalibration)
                {
                    error = SemanticMapError.missingCalibration;
                    return ResearchCheckedExecution.init;
                }
                if (!finite(meaning.scale) || !finite(meaning.offset))
                {
                    error = SemanticMapError.invalidCalibration;
                    return ResearchCheckedExecution.init;
                }
                scales[component] = meaning.scale;
                offsets[component] = meaning.offset;
            }
        }

        return ResearchCheckedExecution(
            image_, selected, scales, offsets, values
        );
    }
}

/++
    The one and only O(channelCount) immutable identity validator
    creates the unforgeable verified image token. The M3.2.6 wrapper
    delegates here; prepared bindings derive solely from this token.
    Error ordering matches the legacy M3.2.6 factory exactly.
+/
ResearchVerifiedSemanticImage tryResearchVerifySemanticImage(
    return scope RasterView!float primary,
    return scope immutable(ChannelDescriptor)[] identities,
    return scope immutable(IntrinsicChannel)[] intrinsic,
    return scope RasterView!ubyte validity,
    bool hasValidity,
    out ResearchVerifiedImageError error
)
@safe pure nothrow @nogc
{
    error = ResearchVerifiedImageError.none;
    if (identities.length != intrinsic.length)
    {
        error = ResearchVerifiedImageError.descriptorCountMismatch;
        return ResearchVerifiedSemanticImage.init;
    }

    foreach (index; 0 .. intrinsic.length)
    {
        if (identities[index].semanticId != intrinsic[index].semanticId)
        {
            error = ResearchVerifiedImageError.identityMismatch;
            return ResearchVerifiedSemanticImage.init;
        }
    }

    ImageViewValidationError imageError;
    auto image = tryMakeImageView!float(
        primary, identities, validity, hasValidity, imageError
    );
    if (imageError != ImageViewValidationError.none)
    {
        error = ResearchVerifiedImageError.imageViewFailure;
        return ResearchVerifiedSemanticImage.init;
    }
    return ResearchVerifiedSemanticImage(image, identities, intrinsic);
}


SemanticMapError mapComponentsInto(
    scope ImageView!float image,
    scope const(IntrinsicChannel)[] intrinsic,
    ColourBinding binding,
    ValueInterpretation values,
    scope WritableRasterView!float destination
)
@safe nothrow @nogc
{
    if (intrinsic.length != image.channelCount)
    {
        return SemanticMapError.metadataCountMismatch;
    }

    const auto channels = image.channels;
    foreach (index; 0 .. intrinsic.length)
    {
        if (channels[index].semanticId != intrinsic[index].semanticId)
        {
            return SemanticMapError.metadataIdentityMismatch;
        }
    }

    const size_t[3] selected =
        [binding.redChannel, binding.greenChannel, binding.blueChannel];

    foreach (index; 0 .. 3)
    {
        if (selected[index] >= image.channelCount)
        {
            return SemanticMapError.invalidBinding;
        }
    }
    if (selected[0] == selected[1]
        || selected[0] == selected[2]
        || selected[1] == selected[2])
    {
        return SemanticMapError.invalidBinding;
    }

    if (destination.planeCount != 3
        || destination.width != image.width
        || destination.height != image.height)
    {
        return SemanticMapError.destinationMismatch;
    }

    if (image.hasValidity && image.validity.planeCount != 1)
    {
        return SemanticMapError.unsupportedValidity;
    }

    float[3] scales = [1.0f, 1.0f, 1.0f];
    float[3] offsets = [0.0f, 0.0f, 0.0f];
    if (values == ValueInterpretation.physical)
    {
        foreach (index; 0 .. 3)
        {
            const ref meaning = intrinsic[selected[index]];
            if (!meaning.hasCalibration)
            {
                return SemanticMapError.missingCalibration;
            }
            if (!finite(meaning.scale) || !finite(meaning.offset))
            {
                return SemanticMapError.invalidCalibration;
            }
            scales[index] = meaning.scale;
            offsets[index] = meaning.offset;
        }
    }

    return researchExecuteCheckedPixels(
        image, selected, scales, offsets, values, destination
    );
}
