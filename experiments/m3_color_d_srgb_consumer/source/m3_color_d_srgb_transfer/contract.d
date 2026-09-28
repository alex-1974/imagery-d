module m3_color_d_srgb_transfer.contract;

import color :
    LinearSRgb,
    SRgb,
    toLinear,
    toSRgb;

import raster :
    RasterView,
    WritableRasterView;


/++
    Colour interpretation attached to one explicit RGB component binding.

    This experiment deliberately models only the distinction required by the
    M3 consumer slice. It does not attempt to define the eventual imagery-d
    public metadata model.
+/
enum RgbEncoding : ubyte
{
    encodedSRgb,
    linearSRgb
}


/++
    Explicit ordered mapping from image colour components to raster planes.

    Plane count, names, or physical interleaving are never used to infer RGB.
+/
struct RgbBinding
{
    size_t redPlane;
    size_t greenPlane;
    size_t bluePlane;
    RgbEncoding encoding;
}


/++
    Failure categories for the focused pointwise transfer experiment.
+/
enum RgbTransferError : ubyte
{
    none,
    invalidSourceEncoding,
    invalidDestinationEncoding,
    invalidSourceBinding,
    invalidDestinationBinding,
    extentMismatch,
    readFailure,
    writeFailure
}


/++
    Result of one bounded region transfer.

    The natural init state is deliberately a failure state, not success.
+/
struct RgbTransferResult
{
    RgbTransferError error =
        RgbTransferError.readFailure;

    size_t x = size_t.max;
    size_t y = size_t.max;

    @property
    bool ok() const
    @safe
    pure
    nothrow
    @nogc
    {
        return error == RgbTransferError.none;
    }
}


private bool validBinding(
    size_t planeCount,
    RgbBinding binding
)
@safe
pure
nothrow
@nogc
{
    if (
        binding.redPlane >= planeCount
        || binding.greenPlane >= planeCount
        || binding.bluePlane >= planeCount
    )
    {
        return false;
    }

    return
        binding.redPlane != binding.greenPlane
        && binding.redPlane != binding.bluePlane
        && binding.greenPlane != binding.bluePlane;
}


private RgbTransferResult failure(
    RgbTransferError error,
    size_t x = size_t.max,
    size_t y = size_t.max
)
@safe
pure
nothrow
@nogc
{
    return RgbTransferResult(
        error,
        x,
        y
    );
}


private RgbTransferResult success()
@safe
pure
nothrow
@nogc
{
    return RgbTransferResult(
        RgbTransferError.none,
        size_t.max,
        size_t.max
    );
}


private RgbTransferResult validateTransfer(
    size_t sourcePlaneCount,
    size_t sourceWidth,
    size_t sourceHeight,
    RgbBinding sourceBinding,
    size_t destinationPlaneCount,
    size_t destinationWidth,
    size_t destinationHeight,
    RgbBinding destinationBinding,
    RgbEncoding requiredSourceEncoding,
    RgbEncoding requiredDestinationEncoding
)
@safe
pure
nothrow
@nogc
{
    if (sourceBinding.encoding != requiredSourceEncoding)
    {
        return failure(
            RgbTransferError.invalidSourceEncoding
        );
    }

    if (destinationBinding.encoding != requiredDestinationEncoding)
    {
        return failure(
            RgbTransferError.invalidDestinationEncoding
        );
    }

    if (!validBinding(sourcePlaneCount, sourceBinding))
    {
        return failure(
            RgbTransferError.invalidSourceBinding
        );
    }

    if (!validBinding(destinationPlaneCount, destinationBinding))
    {
        return failure(
            RgbTransferError.invalidDestinationBinding
        );
    }

    if (
        sourceWidth != destinationWidth
        || sourceHeight != destinationHeight
    )
    {
        return failure(
            RgbTransferError.extentMismatch
        );
    }

    return success();
}


/++
    Decodes one already-materialized encoded-sRGB image region into
    linear-light sRGB.

    Image-domain responsibilities stay with the caller:

    - the RGB component binding is explicit;
    - region/layout/lifetime come from raster-d;
    - validity, NoData and alpha are not inferred or transformed;
    - destination storage is caller-owned and already allocated.

    color-d owns only the scalar colour-value transfer.

    No clipping, gamut mapping, whole-image temporary or allocation occurs.
+/
RgbTransferResult decodeSrgbRegion(T)(
    scope RasterView!T source,
    RgbBinding sourceBinding,
    scope WritableRasterView!T destination,
    RgbBinding destinationBinding
)
@safe
nothrow
@nogc
{
    static assert(
        is(T == float) || is(T == double),
        "sRGB transfer experiment supports float or double samples"
    );

    const validation =
        validateTransfer(
            source.planeCount,
            source.width,
            source.height,
            sourceBinding,
            destination.planeCount,
            destination.width,
            destination.height,
            destinationBinding,
            RgbEncoding.encodedSRgb,
            RgbEncoding.linearSRgb
        );

    if (!validation.ok)
    {
        return validation;
    }

    foreach (y; 0 .. source.height)
    {
        foreach (x; 0 .. source.width)
        {
            T red;
            T green;
            T blue;

            if (
                !source.trySample(
                    sourceBinding.redPlane,
                    x,
                    y,
                    red
                )
                || !source.trySample(
                    sourceBinding.greenPlane,
                    x,
                    y,
                    green
                )
                || !source.trySample(
                    sourceBinding.bluePlane,
                    x,
                    y,
                    blue
                )
            )
            {
                return failure(
                    RgbTransferError.readFailure,
                    x,
                    y
                );
            }

            const linear =
                SRgb!T(
                    red,
                    green,
                    blue
                ).toLinear;

            if (
                !destination.trySetSample(
                    destinationBinding.redPlane,
                    x,
                    y,
                    linear.r
                )
                || !destination.trySetSample(
                    destinationBinding.greenPlane,
                    x,
                    y,
                    linear.g
                )
                || !destination.trySetSample(
                    destinationBinding.bluePlane,
                    x,
                    y,
                    linear.b
                )
            )
            {
                return failure(
                    RgbTransferError.writeFailure,
                    x,
                    y
                );
            }
        }
    }

    return success();
}


/++
    Encodes one already-materialized linear-light sRGB image region back into
    encoded sRGB.

    This is the explicit reverse of decodeSrgbRegion.
+/
RgbTransferResult encodeSrgbRegion(T)(
    scope RasterView!T source,
    RgbBinding sourceBinding,
    scope WritableRasterView!T destination,
    RgbBinding destinationBinding
)
@safe
nothrow
@nogc
{
    static assert(
        is(T == float) || is(T == double),
        "sRGB transfer experiment supports float or double samples"
    );

    const validation =
        validateTransfer(
            source.planeCount,
            source.width,
            source.height,
            sourceBinding,
            destination.planeCount,
            destination.width,
            destination.height,
            destinationBinding,
            RgbEncoding.linearSRgb,
            RgbEncoding.encodedSRgb
        );

    if (!validation.ok)
    {
        return validation;
    }

    foreach (y; 0 .. source.height)
    {
        foreach (x; 0 .. source.width)
        {
            T red;
            T green;
            T blue;

            if (
                !source.trySample(
                    sourceBinding.redPlane,
                    x,
                    y,
                    red
                )
                || !source.trySample(
                    sourceBinding.greenPlane,
                    x,
                    y,
                    green
                )
                || !source.trySample(
                    sourceBinding.bluePlane,
                    x,
                    y,
                    blue
                )
            )
            {
                return failure(
                    RgbTransferError.readFailure,
                    x,
                    y
                );
            }

            const encoded =
                LinearSRgb!T(
                    red,
                    green,
                    blue
                ).toSRgb;

            if (
                !destination.trySetSample(
                    destinationBinding.redPlane,
                    x,
                    y,
                    encoded.r
                )
                || !destination.trySetSample(
                    destinationBinding.greenPlane,
                    x,
                    y,
                    encoded.g
                )
                || !destination.trySetSample(
                    destinationBinding.bluePlane,
                    x,
                    y,
                    encoded.b
                )
            )
            {
                return failure(
                    RgbTransferError.writeFailure,
                    x,
                    y
                );
            }
        }
    }

    return success();
}
