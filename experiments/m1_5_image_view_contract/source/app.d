module app;

import core.stdc.stdlib :
    malloc;

import m1_5_image_view.contract :
    ChannelDescriptor,
    ImageViewValidationError,
    exerciseRoiNoGc,
    tryMakeImageView;

import raster :
    OwnedByteResource,
    PlaneByteLayout,
    RasterLease,
    RasterView,
    Region2D,
    tryAdoptMallocResource,
    tryImportOwnedRaster;


/++
    Creates one retained float raster with a single logical plane.
+/
private
RasterLease!float makePrimary(
    size_t width,
    size_t height
)
{
    const sampleCount =
        width * height;

    const byteLength =
        sampleCount * float.sizeof;

    auto memory =
        cast(float*) malloc(byteLength);

    assert(memory !is null);

    foreach (index; 0 .. sampleCount)
    {
        memory[index] =
            cast(float) index
            + 0.5f;
    }

    OwnedByteResource resource;

    assert(
        tryAdoptMallocResource(
            memory,
            byteLength,
            resource
        )
    );

    RasterLease!float lease;

    PlaneByteLayout[1] planes =
    [
        PlaneByteLayout(
            0,
            width * float.sizeof,
            float.sizeof
        )
    ];

    const result =
        tryImportOwnedRaster!float(
            resource,
            planes[],
            Region2D(
                0,
                0,
                width,
                height
            ),
            lease
        );

    assert(result.ok);

    return lease;
}


/++
    Creates a retained UInt8 validity raster.

    One value is deliberately zero to verify semantic validity access.
+/
private
RasterLease!ubyte makeValidity(
    size_t width,
    size_t height
)
{
    const byteLength =
        width * height;

    auto memory =
        cast(ubyte*) malloc(byteLength);

    assert(memory !is null);

    foreach (index; 0 .. byteLength)
    {
        memory[index] = 255;
    }

    if (byteLength > 0)
    {
        memory[byteLength - 1] = 0;
    }

    OwnedByteResource resource;

    assert(
        tryAdoptMallocResource(
            memory,
            byteLength,
            resource
        )
    );

    RasterLease!ubyte lease;

    PlaneByteLayout[1] planes =
    [
        PlaneByteLayout(
            0,
            width,
            1
        )
    ];

    const result =
        tryImportOwnedRaster!ubyte(
            resource,
            planes[],
            Region2D(
                0,
                0,
                width,
                height
            ),
            lease
        );

    assert(result.ok);

    return lease;
}


void main()
{
    enum size_t width = 4;
    enum size_t height = 3;

    auto primaryLease =
        makePrimary(
            width,
            height
        );

    auto validityLease =
        makeValidity(
            width,
            height
        );

    auto primary =
        primaryLease.view();

    auto validity =
        validityLease.view();


    static immutable ChannelDescriptor[1] semantics =
    [
        ChannelDescriptor(1001)
    ];


    ImageViewValidationError error;

    auto image =
        tryMakeImageView!float(
            primary,
            semantics[],
            validity,
            true,
            error
        );

    assert(
        error
        == ImageViewValidationError.none
    );

    assert(image.channelCount == 1);
    assert(image.hasValidity);
    assert(image.width == width);
    assert(image.height == height);


    /*
     * Primary sample access.
     */
    float sample;

    assert(
        image.trySample(
            0,
            3,
            2,
            sample
        )
    );

    assert(sample == 11.5f);


    /*
     * Explicit validity is independent from the float primary sample type.
     */
    ubyte valid;

    assert(
        image.tryValidity(
            0,
            0,
            0,
            valid
        )
    );

    assert(valid == 255);

    assert(
        image.tryValidity(
            0,
            3,
            2,
            valid
        )
    );

    assert(valid == 0);


    /*
     * ROI applies the same relative geometry to both raster views and borrows
     * the exact same immutable semantic metadata.
     */
    bool roiOk;

    auto roi =
        image.tryRoi(
            Region2D(
                2,
                1,
                2,
                2
            ),
            roiOk
        );

    assert(roiOk);
    assert(roi.width == 2);
    assert(roi.height == 2);
    assert(roi.channelCount == 1);

    assert(
        roi.channels.ptr
        is image.channels.ptr
    );

    assert(
        roi.channels.length
        == image.channels.length
    );


    /*
     * Parent coordinate (3,2) becomes ROI-local coordinate (1,1).
     */
    assert(
        roi.trySample(
            0,
            1,
            1,
            sample
        )
    );

    assert(sample == 11.5f);

    assert(
        roi.tryValidity(
            0,
            1,
            1,
            valid
        )
    );

    assert(valid == 0);


    /*
     * The ROI implementation itself is @nogc.
     */
    exerciseRoiNoGc(image);


    /*
     * Channel-descriptor count must match primary raster plane count.
     */
    static immutable ChannelDescriptor[2] wrongCount =
    [
        ChannelDescriptor(1),
        ChannelDescriptor(2)
    ];

    auto rejectedCount =
        tryMakeImageView!float(
            primary,
            wrongCount[],
            validity,
            true,
            error
        );

    assert(
        error
        == ImageViewValidationError
            .channelCountMismatch
    );

    assert(rejectedCount.channelCount == 0);


    /*
     * Same-grid validity means matching local extents.
     *
     * A smaller validity ROI is not accepted as attachment to the full
     * primary view. No implicit offset correction or resampling occurs.
     */
    bool smallMaskOk;

    auto smallMask =
        validity.tryRoi(
            Region2D(
                0,
                0,
                2,
                2
            ),
            smallMaskOk
        );

    assert(smallMaskOk);

    auto rejectedValidity =
        tryMakeImageView!float(
            primary,
            semantics[],
            smallMask,
            true,
            error
        );

    assert(
        error
        == ImageViewValidationError
            .validityExtentMismatch
    );

    assert(rejectedValidity.channelCount == 0);


    /*
     * Mask-free images carry no validity raster cost in the semantic view.
     */
    auto maskFree =
        tryMakeImageView!float(
            primary,
            semantics[],
            RasterView!ubyte.init,
            false,
            error
        );

    assert(
        error
        == ImageViewValidationError.none
    );

    assert(!maskFree.hasValidity);

    assert(
        !maskFree.tryValidity(
            0,
            0,
            0,
            valid
        )
    );
}
