module app;

import core.stdc.stdlib : exit, malloc;
import std.stdio : stderr, writeln;

import m1_5_image_view.contract :
    ChannelDescriptor,
    ImageView,
    ImageViewValidationError,
    tryMakeImageView;

import m3_2_channel_metadata.contract :
    ColourBinding,
    DeclaredColour,
    IntrinsicChannel,
    SemanticMapError,
    ValueInterpretation,
    mapComponentsInto;

import raster :
    OwnedByteResource,
    PlaneByteLayout,
    RasterLease,
    RasterView,
    Region2D,
    WritableRasterView,
    tryAdoptMallocResource,
    tryImportOwnedRaster;

private enum LayoutKind : ubyte
{
    planar,
    interleaved
}

private enum DisplayError : ubyte
{
    none,
    invalidBinding,
    incompatibleDestination,
    unsupportedValidity,
    sampleAccessFailure
}

private struct DisplaySelection
{
    size_t red;
    size_t green;
    size_t blue;
}

private void require(bool condition, string message)
{
    if (condition)
    {
        return;
    }

    stderr.writeln("M3.2 FAIL: ", message);
    exit(1);
}

private float sampleValue(size_t channel, size_t x, size_t y)
@safe pure nothrow @nogc
{
    return cast(float)(channel * 100 + y * 10 + x);
}

private RasterLease!float makeRaster(
    size_t width,
    size_t height,
    size_t channelCount,
    LayoutKind layout
)
{
    const sampleCount = width * height * channelCount;
    const byteLength = sampleCount * float.sizeof;
    auto memory = cast(float*) malloc(byteLength);
    require(memory !is null, "malloc primary/destination");

    OwnedByteResource resource;
    require(
        tryAdoptMallocResource(memory, byteLength, resource),
        "adopt primary/destination"
    );

    // Four source channels or three destination channels. No layout hint
    // escapes as an image-semantic property.
    PlaneByteLayout[4] physical;
    foreach (channel; 0 .. channelCount)
    {
        if (layout == LayoutKind.planar)
        {
            physical[channel] = PlaneByteLayout(
                channel * width * height * float.sizeof,
                cast(ptrdiff_t)(width * float.sizeof),
                cast(ptrdiff_t)float.sizeof
            );
        }
        else
        {
            physical[channel] = PlaneByteLayout(
                channel * float.sizeof,
                cast(ptrdiff_t)(width * channelCount * float.sizeof),
                cast(ptrdiff_t)(channelCount * float.sizeof)
            );
        }
    }

    RasterLease!float lease;
    const imported = tryImportOwnedRaster!float(
        resource,
        physical[0 .. channelCount],
        Region2D(0, 0, width, height),
        lease
    );
    require(imported.ok, "import primary/destination");
    return lease;
}

private RasterLease!ubyte makeValidity(size_t width, size_t height)
{
    const byteLength = width * height;
    auto memory = cast(ubyte*) malloc(byteLength);
    require(memory !is null, "malloc validity");

    foreach (index; 0 .. byteLength)
    {
        memory[index] = 255;
    }
    memory[byteLength - 1] = 0;

    OwnedByteResource resource;
    require(tryAdoptMallocResource(memory, byteLength, resource),
        "adopt validity");

    const PlaneByteLayout[1] physical =
        [PlaneByteLayout(0, cast(ptrdiff_t)width, 1)];
    RasterLease!ubyte lease;
    const imported = tryImportOwnedRaster!ubyte(
        resource,
        physical[],
        Region2D(0, 0, width, height),
        lease
    );
    require(imported.ok, "import validity");
    return lease;
}

private void initializeSamples(ref RasterLease!float lease)
{
    bool ok;
    scope auto writable = lease.tryWritableView(ok);
    require(ok, "source writable view");

    foreach (channel; 0 .. writable.planeCount)
    {
        foreach (y; 0 .. writable.height)
        {
            foreach (x; 0 .. writable.width)
            {
                require(
                    writable.trySetSample(channel, x, y,
                        sampleValue(channel, x, y)),
                    "fill source"
                );
            }
        }
    }
}

/*
 * One explicit, validity-aware selection of three display components.
 * Not sRGB. Never infer meaning from plane names/count or physical layout.
 * Invalid-to-zero is a caller-visible choice for this probe, not a universal
 * NoData or alpha policy.
 */
private DisplayError mapDisplayInto(
    scope ImageView!float image,
    scope WritableRasterView!float destination,
    DisplaySelection selection
)
@safe nothrow @nogc
{
    if (selection.red >= image.channelCount ||
        selection.green >= image.channelCount ||
        selection.blue >= image.channelCount ||
        selection.red == selection.green ||
        selection.red == selection.blue ||
        selection.green == selection.blue)
    {
        return DisplayError.invalidBinding;
    }

    if (destination.planeCount != 3 ||
        destination.width != image.width ||
        destination.height != image.height)
    {
        return DisplayError.incompatibleDestination;
    }

    if (image.hasValidity && image.validity.planeCount != 1)
    {
        return DisplayError.unsupportedValidity;
    }

    const size_t[3] channels = [
        selection.red, selection.green, selection.blue
    ];

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
                    return DisplayError.sampleAccessFailure;
                }
                valid = flag != 0;
            }

            foreach (component; 0 .. 3)
            {
                float value = 0.0f;
                if (valid && !image.trySample(channels[component], x, y, value))
                {
                    return DisplayError.sampleAccessFailure;
                }
                if (!destination.trySetSample(component, x, y, value))
                {
                    return DisplayError.sampleAccessFailure;
                }
            }
        }
    }

    return DisplayError.none;
}

private void validateResult(
    scope RasterView!float result,
    bool withValidity,
    size_t width,
    size_t height
)
{
    const size_t[3] channels = [3, 2, 1];
    foreach (y; 0 .. height)
    {
        foreach (x; 0 .. width)
        {
            foreach (component; 0 .. 3)
            {
                float observed;
                require(result.trySample(component, x, y, observed),
                    "read output");
                const expected = withValidity &&
                    x == width - 1 && y == height - 1
                    ? 0.0f
                    : sampleValue(channels[component], x, y);
                require(observed == expected, "semantic output mismatch");
            }
        }
    }
}

private void compareResults(
    scope RasterView!float a,
    scope RasterView!float b
)
{
    require(a.planeCount == b.planeCount &&
        a.width == b.width && a.height == b.height,
        "output shape equivalence");

    foreach (channel; 0 .. a.planeCount)
    {
        foreach (y; 0 .. a.height)
        {
            foreach (x; 0 .. a.width)
            {
                float lhs;
                float rhs;
                require(a.trySample(channel, x, y, lhs), "compare lhs");
                require(b.trySample(channel, x, y, rhs), "compare rhs");
                require(lhs == rhs, "whole/ROI or planar/interleaved mismatch");
            }
        }
    }
}


/*
 * M3.2.2 consumer of the existing ImageView borrow.
 *
 * Intrinsic channel names/quantities are deliberately incompatible with
 * the explicitly requested display ordering. A physical value is produced
 * only through the explicit ValueInterpretation.physical path.
 */
private void exerciseChannelSemantics(
    scope ImageView!float image,
    LayoutKind layout,
    bool withValidity
)
{
    enum size_t width = 7;
    enum size_t height = 4;

    static immutable IntrinsicChannel[4] intrinsic = [
        IntrinsicChannel(100, "R", "unspecified", false, 0.0f, 0.0f),
        IntrinsicChannel(101, "NIR", "reflectance", true, -1.0f, 5.0f),
        IntrinsicChannel(102, "B08", "reflectance", true, 2.0f, -400.0f),
        IntrinsicChannel(103, "G", "radiance", true, 0.25f, 120.0f)
    ];

    // Intentionally not the order or identity implied by source labels.
    auto binding = ColourBinding(3, 2, 1, DeclaredColour.unspecified);

    auto physicalLease = makeRaster(width, height, 3, layout);
    auto roiLease = makeRaster(width, height, 3, layout);
    auto storedLease = makeRaster(width, height, 3, layout);

    {
        bool ok;
        scope auto destination = physicalLease.tryWritableView(ok);
        require(ok, "physical writable");
        require(
            mapComponentsInto(
                image, intrinsic[], binding,
                ValueInterpretation.physical, destination)
                == SemanticMapError.none,
            "physical mapping"
        );
    }

    {
        bool ok;
        scope auto destination = storedLease.tryWritableView(ok);
        require(ok, "stored writable");
        require(
            mapComponentsInto(
                image, intrinsic[], binding,
                ValueInterpretation.stored, destination)
                == SemanticMapError.none,
            "stored mapping"
        );
    }

    {
        bool ok;
        scope auto destination = roiLease.tryWritableView(ok);
        require(ok, "physical ROI writable");

        const Region2D[4] regions = [
            Region2D(0, 0, 2, 2),
            Region2D(2, 0, 5, 2),
            Region2D(0, 2, 4, 2),
            Region2D(4, 2, 3, 2)
        ];
        foreach (region; regions)
        {
            bool imageOk;
            auto imageRoi = image.tryRoi(region, imageOk);
            require(imageOk, "physical ROI source");
            require(imageRoi.channels.ptr is image.channels.ptr,
                "unchanged channel identity through ROI");

            bool destinationOk;
            auto destRoi = destination.tryRoi(region, destinationOk);
            require(destinationOk, "physical ROI destination");
            require(
                mapComponentsInto(
                    imageRoi, intrinsic[], binding,
                    ValueInterpretation.physical, destRoi)
                    == SemanticMapError.none,
                "physical ROI mapping"
            );
        }
    }

    auto physical = physicalLease.view();
    auto partitioned = roiLease.view();
    auto stored = storedLease.view();
    compareResults(physical, partitioned);

    const size_t[3] selected = [3, 2, 1];
    foreach (y; 0 .. height)
    {
        foreach (x; 0 .. width)
        {
            const invalid = withValidity &&
                x == width - 1 && y == height - 1;
            foreach (component; 0 .. 3)
            {
                const index = selected[component];
                const raw = invalid ? 0.0f : sampleValue(index, x, y);
                const expectedPhysical = invalid
                    ? 0.0f
                    : raw * intrinsic[index].scale + intrinsic[index].offset;

                float gotStored;
                float gotPhysical;
                require(stored.trySample(component, x, y, gotStored),
                    "stored sample access");
                require(physical.trySample(component, x, y, gotPhysical),
                    "physical sample access");
                require(gotStored == raw, "no implicit calibration");
                require(gotPhysical == expectedPhysical,
                    "explicit physical oracle");
            }
        }
    }

    // Unknown/custom channel 0 is not interpreted as red despite its name,
    // and it remains uncalibrated without blocking the selected channels.
    require(!intrinsic[0].hasCalibration, "unknown raw channel retained");
    require(intrinsic[0].sourceLabel == "R", "opaque name retained");

    // A colour-space declaration on the binding is not a request to run
    // color-d; this operation only performs explicit radiometric mapping.
    binding.declaredColour = DeclaredColour.encodedSRgb;

    bool ok;
    scope auto destination = storedLease.tryWritableView(ok);
    require(ok, "semantic negative writable");

    require(mapComponentsInto(image, intrinsic[0 .. 3], binding,
        ValueInterpretation.stored, destination)
        == SemanticMapError.metadataCountMismatch,
        "metadata cardinality rejection");

    IntrinsicChannel[4] changed;
    foreach (i; 0 .. 4)
    {
        changed[i] = IntrinsicChannel(
            intrinsic[i].semanticId, intrinsic[i].sourceLabel,
            intrinsic[i].quantityLabel, intrinsic[i].hasCalibration,
            intrinsic[i].scale, intrinsic[i].offset
        );
    }

    changed[0].semanticId = 999;
    require(mapComponentsInto(image, changed[], binding,
        ValueInterpretation.stored, destination)
        == SemanticMapError.metadataIdentityMismatch,
        "semantic identity rejection");
    changed[0].semanticId = 100;

    require(mapComponentsInto(image, changed[], ColourBinding(
        3, 3, 1, DeclaredColour.unspecified),
        ValueInterpretation.stored, destination)
        == SemanticMapError.invalidBinding,
        "duplicate display component rejection");

    require(mapComponentsInto(image, changed[], ColourBinding(
        3, 2, 999, DeclaredColour.unspecified),
        ValueInterpretation.physical, destination)
        == SemanticMapError.invalidBinding,
        "out-of-range display component rejection");

    changed[3].hasCalibration = false;
    require(mapComponentsInto(image, changed[], binding,
        ValueInterpretation.physical, destination)
        == SemanticMapError.missingCalibration,
        "calibration required for physical interpretation");
    // Raw access must remain possible even if a channel lacks calibration.
    require(mapComponentsInto(image, changed[], binding,
        ValueInterpretation.stored, destination)
        == SemanticMapError.none,
        "stored samples survive missing calibration");

    changed[3].hasCalibration = true;
    changed[3].scale = float.nan;
    require(mapComponentsInto(image, changed[], binding,
        ValueInterpretation.physical, destination)
        == SemanticMapError.invalidCalibration,
        "nonfinite physical calibration rejected");
}

private RasterLease!float exercise(
    LayoutKind layout,
    bool withValidity
)
{
    enum size_t width = 7;
    enum size_t height = 4;
    auto sourceLease = makeRaster(width, height, 4, layout);
    initializeSamples(sourceLease);

    // A mask-free view must not require allocation of a validity raster.
    RasterLease!ubyte validityLease;
    RasterView!ubyte validity;
    if (withValidity)
    {
        validityLease = makeValidity(width, height);
        validity = validityLease.view();
    }
    auto source = sourceLease.view();

    // Opaque semantics are not RGB channels or colour-space declarations.
    static immutable ChannelDescriptor[4] semantics = [
        ChannelDescriptor(100), ChannelDescriptor(101),
        ChannelDescriptor(102), ChannelDescriptor(103)
    ];

    ImageViewValidationError error;
    auto image = tryMakeImageView!float(
        source, semantics[], validity, withValidity, error
    );
    require(error == ImageViewValidationError.none,
        "construct semantic image");
    require(image.channelCount == 4, "semantic channel count");

    auto wholeLease = makeRaster(width, height, 3, layout);
    auto partitionLease = makeRaster(width, height, 3, layout);
    const selected = DisplaySelection(3, 2, 1);

    exerciseChannelSemantics(image, layout, withValidity);

    {
        bool ok;
        scope auto destination = wholeLease.tryWritableView(ok);
        require(ok, "whole writable view");
        require(mapDisplayInto(image, destination, selected)
            == DisplayError.none, "whole mapping");
    }

    {
        bool ok;
        scope auto destination = partitionLease.tryWritableView(ok);
        require(ok, "partitioned writable view");

        const Region2D[4] regions = [
            Region2D(0, 0, 2, 2),
            Region2D(2, 0, 5, 2),
            Region2D(0, 2, 4, 2),
            Region2D(4, 2, 3, 2)
        ];

        foreach (region; regions)
        {
            bool imageOk;
            auto imageRoi = image.tryRoi(region, imageOk);
            require(imageOk, "image ROI");
            require(imageRoi.channels.ptr is image.channels.ptr,
                "metadata shared for ROI");

            bool destinationOk;
            auto outputRoi = destination.tryRoi(region, destinationOk);
            require(destinationOk, "destination ROI");
            require(mapDisplayInto(imageRoi, outputRoi, selected)
                == DisplayError.none, "ROI mapping");
        }
    }

    auto whole = wholeLease.view();
    auto partitioned = partitionLease.view();
    compareResults(whole, partitioned);
    validateResult(whole, withValidity, width, height);

    bool outputOk;
    scope auto output = wholeLease.tryWritableView(outputOk);
    require(outputOk, "negative output view");
    require(mapDisplayInto(image, output, DisplaySelection(3, 3, 1))
        == DisplayError.invalidBinding, "duplicate channel rejection");
    require(mapDisplayInto(image, output, DisplaySelection(50, 2, 1))
        == DisplayError.invalidBinding, "unknown channel rejection");

    static immutable ChannelDescriptor[3] insufficient = [
        ChannelDescriptor(100), ChannelDescriptor(101), ChannelDescriptor(102)
    ];
    auto rejected = tryMakeImageView!float(
        source, insufficient[], validity, withValidity, error
    );
    require(error == ImageViewValidationError.channelCountMismatch &&
        rejected.channelCount == 0, "channel count rejection");

    if (withValidity)
    {
        bool smallOk;
        auto smaller = validity.tryRoi(Region2D(0, 0, 3, 2), smallOk);
        require(smallOk, "smaller mask setup");
        rejected = tryMakeImageView!float(
            source, semantics[], smaller, true, error
        );
        require(error == ImageViewValidationError.validityExtentMismatch &&
            rejected.channelCount == 0, "validity grid rejection");
    }

    return wholeLease;
}

void main()
{
    // These model distinct upstream origins without linking any decoder.
    auto planarA = exercise(LayoutKind.planar, true);
    auto planarB = exercise(LayoutKind.planar, true);
    auto interleaved = exercise(LayoutKind.interleaved, true);
    auto noMask = exercise(LayoutKind.interleaved, false);
    compareResults(planarA.view(), planarB.view());
    compareResults(planarA.view(), interleaved.view());
    require(noMask.view().planeCount == 3, "mask-free operation");
    writeln("M3.2 PASS: synthetic layout/ROI/validity and binding checks");
}
