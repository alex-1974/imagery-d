module app;

import core.stdc.stdlib : malloc;
import std.stdio : writeln;

import m3_2_retained_metadata.contract :
    RetainedFourChannelFixture,
    BorrowedSemanticImage,
    MetadataBorrowError,
    tryBorrowSemanticImage;
import m3_2_channel_metadata.contract :
    ColourBinding,
    DeclaredColour,
    IntrinsicChannel,
    ValueInterpretation,
    SemanticMapError;
import raster :
    OwnedByteResource,
    PlaneByteLayout,
    RasterLease,
    RasterView,
    Region2D,
    tryAdoptMallocResource,
    tryImportOwnedRaster;

private enum PhysicalLayout : ubyte { planar, interleaved }

private void require(bool valid, string message)
{
    if (!valid)
    {
        import std.stdio : stderr;
        stderr.writeln("M3.2.3 FAIL: ", message);
        import core.stdc.stdlib : exit;
        exit(1);
    }
}

private float sampleValue(size_t channel, size_t x, size_t y)
@safe pure nothrow @nogc
{
    return cast(float)(channel * 100 + y * 10 + x);
}

private RasterLease!float makeFloatRaster(
    size_t width,
    size_t height,
    size_t planeCount,
    PhysicalLayout layout
)
{
    const byteCount = width * height * planeCount * float.sizeof;
    auto memory = cast(float*)malloc(byteCount);
    require(memory !is null, "malloc float");

    OwnedByteResource resource;
    require(tryAdoptMallocResource(memory, byteCount, resource),
        "adopt float");

    PlaneByteLayout[4] descriptors;
    foreach (plane; 0 .. planeCount)
    {
        if (layout == PhysicalLayout.planar)
        {
            descriptors[plane] = PlaneByteLayout(
                plane * width * height * float.sizeof,
                cast(ptrdiff_t)(width * float.sizeof),
                cast(ptrdiff_t)float.sizeof
            );
        }
        else
        {
            descriptors[plane] = PlaneByteLayout(
                plane * float.sizeof,
                cast(ptrdiff_t)(width * planeCount * float.sizeof),
                cast(ptrdiff_t)(planeCount * float.sizeof)
            );
        }
    }

    RasterLease!float lease;
    auto imported = tryImportOwnedRaster!float(
        resource, descriptors[0 .. planeCount],
        Region2D(0, 0, width, height), lease);
    require(imported.ok, "import float");
    return lease;
}

private RasterLease!ubyte makeMask(size_t width, size_t height)
{
    const byteCount = width * height;
    auto memory = cast(ubyte*)malloc(byteCount);
    require(memory !is null, "malloc mask");

    foreach (index; 0 .. byteCount)
    {
        memory[index] = 255;
    }
    memory[byteCount - 1] = 0;

    OwnedByteResource resource;
    require(tryAdoptMallocResource(memory, byteCount, resource), "adopt mask");

    const PlaneByteLayout[1] plane =
        [PlaneByteLayout(0, cast(ptrdiff_t)width, 1)];
    RasterLease!ubyte lease;
    auto imported = tryImportOwnedRaster!ubyte(
        resource, plane[], Region2D(0, 0, width, height), lease);
    require(imported.ok, "import mask");
    return lease;
}

private void populate(ref RasterLease!float lease)
{
    bool ok;
    scope auto writable = lease.tryWritableView(ok);
    require(ok, "source writable");
    foreach (channel; 0 .. writable.planeCount)
    {
        foreach (y; 0 .. writable.height)
        {
            foreach (x; 0 .. writable.width)
            {
                require(writable.trySetSample(channel, x, y,
                    sampleValue(channel, x, y)), "write input");
            }
        }
    }
}

private void compare(scope RasterView!float first, scope RasterView!float second)
{
    require(first.planeCount == second.planeCount
        && first.width == second.width
        && first.height == second.height, "same dimensions");
    foreach (channel; 0 .. first.planeCount)
    {
        foreach (y; 0 .. first.height)
        {
            foreach (x; 0 .. first.width)
            {
                float a, b;
                require(first.trySample(channel, x, y, a), "read first");
                require(second.trySample(channel, x, y, b), "read second");
                require(a == b, "same stored/physical output");
            }
        }
    }
}

private void validatePhysical(
    scope RasterView!float result,
    bool hasMask
)
{
    const size_t[3] selected = [3, 2, 1];
    const float[3] scale = [0.25f, 2.0f, -1.0f];
    const float[3] offset = [120.0f, -400.0f, 5.0f];
    foreach (y; 0 .. result.height)
    {
        foreach (x; 0 .. result.width)
        {
            bool invalid = hasMask &&
                x == result.width - 1 &&
                y == result.height - 1;
            foreach (component; 0 .. 3)
            {
                float got;
                require(result.trySample(component, x, y, got),
                    "physical output sample");
                const expected = invalid
                    ? 0.0f
                    : sampleValue(selected[component], x, y)
                        * scale[component] + offset[component];
                require(got == expected, "physical oracle");
            }
        }
    }
}

private void exercise(PhysicalLayout layout, bool hasMask)
{
    enum width = 5;
    enum height = 3;

    RetainedFourChannelFixture owner;
    owner.primary = makeFloatRaster(width, height, 4, layout);
    populate(owner.primary);
    if (hasMask)
    {
        owner.validity = makeMask(width, height);
        owner.hasValidity = true;
    }

    MetadataBorrowError error;
    auto borrowed = owner.borrow(error);
    require(error == MetadataBorrowError.none,
        "borrow metadata and raster as one lifetime");
    require(borrowed.width == width && borrowed.height == height
        && borrowed.channelCount == 4, "semantic image shape");
    require(borrowed.intrinsic.length == 4, "retained metadata count");
    require(borrowed.intrinsic.ptr is owner.intrinsicMeaning.ptr,
        "metadata must be borrowed, not cloned");

    const binding = ColourBinding(3, 2, 1, DeclaredColour.unspecified);
    auto wholeLease = makeFloatRaster(width, height, 3, layout);
    auto splitLease = makeFloatRaster(width, height, 3, layout);

    {
        bool writableOk;
        scope auto writable = wholeLease.tryWritableView(writableOk);
        require(writableOk, "whole destination");
        require(borrowed.mapInto(binding, ValueInterpretation.physical,
            writable) == SemanticMapError.none, "whole semantic operation");
    }

    {
        bool writableOk;
        scope auto writable = splitLease.tryWritableView(writableOk);
        require(writableOk, "split destination");
        const Region2D[4] partitions = [
            Region2D(0, 0, 2, 1),
            Region2D(2, 0, 3, 1),
            Region2D(0, 1, 2, 2),
            Region2D(2, 1, 3, 2)
        ];

        foreach (part; partitions)
        {
            bool sourceOk;
            auto roi = borrowed.tryRoi(part, sourceOk);
            require(sourceOk, "borrowed semantic ROI");
            require(roi.intrinsic.ptr is borrowed.intrinsic.ptr,
                "ROI shares same intrinsic metadata");

            bool destOk;
            auto outputRoi = writable.tryRoi(part, destOk);
            require(destOk, "writable ROI");
            require(roi.mapInto(binding, ValueInterpretation.physical,
                outputRoi) == SemanticMapError.none, "ROI semantic mapping");
        }
    }
    compare(wholeLease.view(), splitLease.view());
    validatePhysical(wholeLease.view(), hasMask);

    {
        // Bad intrinsic identity and cardinality are rejected before a view
        // borrowing the new metadata can be published.
        auto baseView = owner.primary.view();
        auto validityView = hasMask ? owner.validity.view()
            : RasterView!ubyte.init;
        import m1_5_image_view.contract :
            tryMakeImageView, ImageViewValidationError;
        ImageViewValidationError imageError;
        auto image = tryMakeImageView!float(
            baseView, owner.descriptorIdentity[],
            validityView, hasMask, imageError);
        require(imageError == ImageViewValidationError.none,
            "base ImageView contract");

        IntrinsicChannel[4] wrong;
        foreach (i; 0 .. 4)
        {
            wrong[i] = owner.intrinsicMeaning[i];
        }
        wrong[0].semanticId = 999;
        auto rejected = tryBorrowSemanticImage(image, wrong[], error);
        require(error == MetadataBorrowError.identityMismatch
            && rejected.channelCount == 0, "metadata identity mismatch");

        auto rejectedCount = tryBorrowSemanticImage(
            image, wrong[0 .. 3], error);
        require(error == MetadataBorrowError.countMismatch
            && rejectedCount.channelCount == 0,
            "metadata count mismatch");
    }

    bool invalidRoiOk;
    auto invalidRoi = borrowed.tryRoi(
        Region2D(width, height, 1, 1), invalidRoiOk);
    require(!invalidRoiOk && invalidRoi.channelCount == 0,
        "out-of-bounds ROI rejected");
}

void main()
{
    exercise(PhysicalLayout.planar, true);
    exercise(PhysicalLayout.interleaved, true);
    exercise(PhysicalLayout.planar, false);
    exercise(PhysicalLayout.interleaved, false);
    writeln("M3.2.3 PASS: retained raster + metadata ROI/lifetime consumer");
}
