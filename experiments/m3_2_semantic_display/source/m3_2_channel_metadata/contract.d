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
/++
    M3.2.10 **RESEARCH-ONLY INTERNAL ADAPTER** — NOT a public imagery API.

    Both the conservative one-shot mapper and the prepared mapper call
    this exact non-inlined symbol to isolate semantic-preflight overhead
    from pixel-codegen differences. Its callers establish source
    identity/binding/calibration and destination shape; this adapter does
    NOT establish these capabilities and must NOT be promoted or exposed
    in a production package. A production version requires a private
    capability-safe boundary (no caller-forgeable "validated" bool).

    Contains the one and only pixel/validity/write loop for both paths.
    Every sample and destination write remains checked. No allocation.
+/
pragma(inline, false)
SemanticMapError researchExecuteCheckedPixels(
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
