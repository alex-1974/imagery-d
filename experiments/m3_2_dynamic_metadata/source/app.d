module app;

import core.stdc.stdlib : exit, malloc;
import std.stdio : stderr, writeln;
import std.algorithm.mutation : move;

import m1_5_image_view.contract : ChannelDescriptor;
import m3_2_channel_metadata.contract :
    IntrinsicChannel,
    ColourBinding,
    DeclaredColour,
    ValueInterpretation,
    SemanticMapError;
import m3_2_retained_metadata.contract :
    BorrowedSemanticImage,
    MetadataBorrowError;
import m3_2_dynamic_metadata.contract :
    RetainedDynamicImage,
    SnapshotError;

import raster :
    OwnedByteResource,
    PlaneByteLayout,
    RasterLease,
    Region2D,
    tryAdoptMallocResource,
    tryImportOwnedRaster;

private enum LayoutKind : ubyte { planar, interleaved }

private void require(bool condition, string what)
{
    if (!condition)
    {
        stderr.writeln("M3.2.4 FAIL: ", what);
        exit(1);
    }
}

private RasterLease!float createRaster(
    size_t channelCount,
    LayoutKind layout
)
{
    enum size_t width = 5;
    enum size_t height = 3;

    const byteLength = channelCount * width * height * float.sizeof;
    auto data = cast(float*) malloc(byteLength);
    require(data !is null, "allocate raster");

    OwnedByteResource resource;
    require(tryAdoptMallocResource(data, byteLength, resource),
        "adopt raster bytes");

    auto planes = new PlaneByteLayout[](channelCount);
    foreach (i; 0 .. channelCount)
    {
        if (layout == LayoutKind.planar)
        {
            planes[i] = PlaneByteLayout(
                i * width * height * float.sizeof,
                cast(ptrdiff_t)(width * float.sizeof),
                cast(ptrdiff_t)float.sizeof
            );
        }
        else
        {
            planes[i] = PlaneByteLayout(
                i * float.sizeof,
                cast(ptrdiff_t)(width * channelCount * float.sizeof),
                cast(ptrdiff_t)(channelCount * float.sizeof)
            );
        }
    }

    RasterLease!float lease;
    auto outcome = tryImportOwnedRaster!float(
        resource, planes[], Region2D(0, 0, width, height), lease
    );
    require(outcome.ok, "import raster");

    bool writableOk;
    scope auto writable = lease.tryWritableView(writableOk);
    require(writableOk, "source writable");
    foreach (c; 0 .. channelCount)
    {
        foreach (y; 0 .. height)
        {
            foreach (x; 0 .. width)
            {
                const value = cast(float)(c * 100 + y * 10 + x);
                require(writable.trySetSample(c, x, y, value),
                    "source fill");
            }
        }
    }
    return lease;
}

private RasterLease!ubyte createMask()
{
    enum size_t width = 5;
    enum size_t height = 3;
    auto data = cast(ubyte*) malloc(width * height);
    require(data !is null, "allocate mask");
    foreach (i; 0 .. width * height) data[i] = 255;
    data[width * height - 1] = 0;

    OwnedByteResource resource;
    require(tryAdoptMallocResource(data, width * height, resource),
        "adopt mask");

    const PlaneByteLayout[1] layout =
        [PlaneByteLayout(0, cast(ptrdiff_t)width, 1)];

    RasterLease!ubyte lease;
    auto outcome = tryImportOwnedRaster!ubyte(
        resource, layout[], Region2D(0, 0, width, height), lease
    );
    require(outcome.ok, "import mask");
    return lease;
}

private void runDynamicFixture(
    size_t channelCount,
    LayoutKind layout,
    bool withValidity
)
{
    auto ids = new ChannelDescriptor[](channelCount);
    auto meanings = new IntrinsicChannel[](channelCount);
    foreach (i; 0 .. channelCount)
    {
        ids[i] = ChannelDescriptor(cast(uint)(1000 + i));
        meanings[i] = IntrinsicChannel(
            cast(uint)(1000 + i),
            i % 2 == 0 ? "R" : "B08",
            "arbitrary quantity",
            true,
            0.25f,
            -10.0f
        );
    }

    SnapshotError snapshotError;
    auto owner = RetainedDynamicImage.create(
        ids, meanings, snapshotError
    );
    require(snapshotError == SnapshotError.none,
        "snapshot accepted");
    require(owner.channelCount == channelCount, "snapshot cardinality");

    if (channelCount > 0)
    {
        // Mutating the caller's original arrays must not modify the
        // immutable owner snapshot.
        ids[0].semanticId = 777777;
        meanings[0].semanticId = 777777;
        meanings[0].scale = 65535.0f;
        require(owner.identities[0].semanticId == 1000,
            "identity snapshot isolation");
        require(owner.intrinsic[0].semanticId == 1000
            && owner.intrinsic[0].scale == 0.25f,
            "intrinsic snapshot isolation");
    }

    if (channelCount == 0)
    {
        require(owner.channelCount == 0, "empty snapshot accepted");
        return;
    }

    owner.primary = createRaster(channelCount, layout);
    if (withValidity)
    {
        owner.validity = createMask();
        owner.hasValidity = true;
    }

    // Transfer the complete owner *before* creating any borrow.
    // Whether the final public carrier is movable remains undecided.
    auto transferred = move(owner);
    require(owner.channelCount == 0, "moved-from metadata empty");
    require(transferred.channelCount == channelCount,
        "metadata survives transfer");

    MetadataBorrowError borrowError;
    auto image = transferred.borrow(borrowError);
    require(borrowError == MetadataBorrowError.none,
        "combined ImageView + metadata borrow");
    require(image.channelCount == channelCount,
        "borrowed channel count");
    require(image.intrinsic.ptr is transferred.intrinsic.ptr,
        "borrow aliases owner metadata exactly");

    bool roiOk;
    auto roi = image.tryRoi(Region2D(1, 0, 3, 3), roiOk);
    require(roiOk, "dynamic ROI");
    require(roi.intrinsic.ptr is image.intrinsic.ptr,
        "ROI shares metadata backing");
    require(roi.channelCount == channelCount
        && roi.width == 3 && roi.height == 3,
        "ROI size/channel invariants");

    if (channelCount < 3) return;

    const binding = ColourBinding(
        channelCount - 1,
        channelCount - 2,
        channelCount - 3,
        DeclaredColour.unspecified
    );

    auto full = createRaster(3, layout);
    auto partitioned = createRaster(3, layout);

    {
        bool ok;
        scope auto destination = full.tryWritableView(ok);
        require(ok, "full destination writable");
        require(image.mapInto(
            binding, ValueInterpretation.physical, destination
        ) == SemanticMapError.none, "full physical map");
    }

    {
        bool ok;
        scope auto destination = partitioned.tryWritableView(ok);
        require(ok, "partition destination writable");
        const Region2D[4] parts = [
            Region2D(0, 0, 2, 1), Region2D(2, 0, 3, 1),
            Region2D(0, 1, 2, 2), Region2D(2, 1, 3, 2)
        ];
        foreach (part; parts)
        {
            bool srcOk;
            auto sub = image.tryRoi(part, srcOk);
            require(srcOk, "part source");
            bool dstOk;
            auto dst = destination.tryRoi(part, dstOk);
            require(dstOk, "part destination");
            require(sub.mapInto(
                binding, ValueInterpretation.physical, dst
            ) == SemanticMapError.none, "part physical map");
        }
    }

    auto lhs = full.view();
    auto rhs = partitioned.view();
    foreach (component; 0 .. 3)
    {
        foreach (y; 0 .. lhs.height)
        {
            foreach (x; 0 .. lhs.width)
            {
                float whole;
                float split;
                require(lhs.trySample(component, x, y, whole),
                    "whole sample");
                require(rhs.trySample(component, x, y, split),
                    "part sample");
                require(whole == split, "whole/ROI exact equivalence");

                const index = channelCount - 1 - component;
                const invalid = withValidity &&
                    x == lhs.width - 1 && y == lhs.height - 1;
                const expected = invalid ? 0.0f :
                    cast(float)(index * 100 + y * 10 + x) * 0.25f
                    - 10.0f;
                require(whole == expected, "physical oracle");
            }
        }
    }
}

private void testFailureWithoutPublication()
{
    ChannelDescriptor[2] descriptors = [
        ChannelDescriptor(7), ChannelDescriptor(8)
    ];
    IntrinsicChannel[2] meanings = [
        IntrinsicChannel(7, "n", "", false, 0, 0),
        IntrinsicChannel(9, "n", "", false, 0, 0)
    ];

    SnapshotError e;
    auto bad = RetainedDynamicImage.create(
        descriptors[], meanings[], e
    );
    require(e == SnapshotError.semanticIdentityMismatch
        && bad.channelCount == 0, "identity mismatch rejected");

    bad = RetainedDynamicImage.create(
        descriptors[], meanings[0 .. 1], e
    );
    require(e == SnapshotError.channelCountMismatch
        && bad.channelCount == 0, "cardinality mismatch rejected");
}

void main()
{
    testFailureWithoutPublication();

    foreach (n; [cast(size_t)0, 1, 3, 4, 17, 64])
    {
        if (n == 0)
        {
            runDynamicFixture(n, LayoutKind.planar, false);
        }
        else
        {
            runDynamicFixture(n, LayoutKind.planar, true);
            runDynamicFixture(n, LayoutKind.interleaved, false);
        }
    }

    writeln("M3.2.4 PASS: dynamic immutable metadata snapshots and ROI");
}
