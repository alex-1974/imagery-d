module m3_2_channel_metadata.contract;

import m1_5_image_view.contract : ImageView;
import raster : WritableRasterView;

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
        }
    }

    foreach (y; 0 .. image.height)
    {
        foreach (x; 0 .. image.width)
        {
            bool valid = true;
            if (image.hasValidity)
            {
                ubyte flag;
                if (!image.tryValidity(0, x, y, flag))
                {
                    return SemanticMapError.sampleAccessFailure;
                }
                valid = flag != 0;
            }

            foreach (component; 0 .. 3)
            {
                float output = 0.0f;
                if (valid)
                {
                    if (!image.trySample(selected[component], x, y, output))
                    {
                        return SemanticMapError.sampleAccessFailure;
                    }
                    if (values == ValueInterpretation.physical)
                    {
                        const ref meaning = intrinsic[selected[component]];
                        output = output * meaning.scale + meaning.offset;
                    }
                }
                if (!destination.trySetSample(component, x, y, output))
                {
                    return SemanticMapError.sampleAccessFailure;
                }
            }
        }
    }

    return SemanticMapError.none;
}
