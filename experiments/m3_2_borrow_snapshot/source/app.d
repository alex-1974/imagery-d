module app;

import core.stdc.stdlib : exit, malloc;
import std.datetime.stopwatch : StopWatch;
import std.stdio : stderr, writeln;

import m1_5_image_view.contract :
    ChannelDescriptor, ImageView, ImageViewValidationError, tryMakeImageView;
import m3_2_channel_metadata.contract :
    IntrinsicChannel, ColourBinding, DeclaredColour,
    ValueInterpretation, SemanticMapError;
import m3_2_retained_metadata.contract :
    BorrowedSemanticImage, MetadataBorrowError, tryBorrowSemanticImage;
import m3_2_dynamic_metadata.contract :
    RetainedDynamicImage, SnapshotError;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease,
    RasterView, Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

private enum LayoutKind : ubyte { planar, interleaved }

private void require(bool condition, string message)
{
    if (!condition)
    {
        stderr.writeln("M3.2.5 FAIL: ", message);
        exit(1);
    }
}

private float sampleValue(size_t channel, size_t x, size_t y)
@safe pure nothrow @nogc
{
    return cast(float)(channel * 100 + y * 10 + x);
}

private RasterLease!float makeRaster(
    size_t channels,
    LayoutKind layout,
    bool initialize
)
{
    enum size_t width = 7;
    enum size_t height = 5;
    const totalBytes = channels * width * height * float.sizeof;
    auto raw = cast(float*) malloc(totalBytes);
    require(raw !is null, "allocate float payload");

    OwnedByteResource resource;
    require(tryAdoptMallocResource(raw, totalBytes, resource),
        "adopt float payload");

    auto planes = new PlaneByteLayout[](channels);
    foreach (channel; 0 .. channels)
    {
        if (layout == LayoutKind.planar)
        {
            planes[channel] = PlaneByteLayout(
                channel * width * height * float.sizeof,
                cast(ptrdiff_t)(width * float.sizeof),
                cast(ptrdiff_t)float.sizeof
            );
        }
        else
        {
            planes[channel] = PlaneByteLayout(
                channel * float.sizeof,
                cast(ptrdiff_t)(width * channels * float.sizeof),
                cast(ptrdiff_t)(channels * float.sizeof)
            );
        }
    }

    RasterLease!float lease;
    const imported = tryImportOwnedRaster!float(
        resource, planes[], Region2D(0, 0, width, height), lease
    );
    require(imported.ok, "import float payload");

    if (initialize)
    {
        bool ok;
        scope auto writable = lease.tryWritableView(ok);
        require(ok, "source writable");
        foreach (channel; 0 .. channels)
        {
            foreach (y; 0 .. height)
            {
                foreach (x; 0 .. width)
                {
                    require(writable.trySetSample(channel, x, y,
                        sampleValue(channel, x, y)), "initialize source");
                }
            }
        }
    }
    return lease;
}

private RasterLease!ubyte makeValidity()
{
    enum size_t width = 7;
    enum size_t height = 5;

    auto raw = cast(ubyte*) malloc(width * height);
    require(raw !is null, "allocate validity");
    foreach (i; 0 .. width * height) raw[i] = 255;
    raw[width * height - 1] = 0;

    OwnedByteResource resource;
    require(tryAdoptMallocResource(raw, width * height, resource),
        "adopt validity");
    const PlaneByteLayout[1] descriptor =
        [PlaneByteLayout(0, cast(ptrdiff_t)width, 1)];
    RasterLease!ubyte lease;
    const imported = tryImportOwnedRaster!ubyte(
        resource, descriptor[],
        Region2D(0, 0, width, height), lease);
    require(imported.ok, "import validity");
    return lease;
}

private void validateOutput(
    scope RasterView!float output,
    size_t inputChannels,
    bool masked
)
{
    foreach (component; 0 .. 3)
    {
        const index = inputChannels - 1 - component;
        foreach (y; 0 .. output.height)
        {
            foreach (x; 0 .. output.width)
            {
                float value;
                require(output.trySample(component, x, y, value),
                    "read mapped output");
                const expected = masked
                    && x == output.width - 1
                    && y == output.height - 1
                    ? 0.0f
                    : sampleValue(index, x, y) * 0.5f - 10.0f;
                require(value == expected, "independent output oracle");
            }
        }
    }
}

private void compareOutput(
    scope RasterView!float lhs,
    scope RasterView!float rhs
)
{
    require(lhs.width == rhs.width && lhs.height == rhs.height
        && lhs.planeCount == rhs.planeCount, "output dimensions equal");
    foreach (channel; 0 .. lhs.planeCount)
    {
        foreach (y; 0 .. lhs.height)
        {
            foreach (x; 0 .. lhs.width)
            {
                float a, b;
                require(lhs.trySample(channel, x, y, a), "read first");
                require(rhs.trySample(channel, x, y, b), "read second");
                require(a == b, "borrow-only and snapshot outputs equal");
            }
        }
    }
}

private void exercise(
    size_t channelCount,
    LayoutKind layout,
    bool masked
)
{
    auto identities = new ChannelDescriptor[](channelCount);
    auto intrinsic = new IntrinsicChannel[](channelCount);
    foreach (channel; 0 .. channelCount)
    {
        const id = cast(uint)(4000 + channel);
        identities[channel] = ChannelDescriptor(id);
        intrinsic[channel] = IntrinsicChannel(
            id, channel % 2 ? "R" : "custom", "arbitrary",
            true, 0.5f, -10.0f
        );
    }

    auto pixels = makeRaster(channelCount, layout, true);
    RasterLease!ubyte validity;
    if (masked) validity = makeValidity();

    // Path A: zero metadata snapshots; caller must keep arrays and
    // raster leases alive and refrain from changing metadata while used.
    auto rasterView = pixels.view();
    auto validityView = masked ? validity.view() : RasterView!ubyte.init;
    ImageViewValidationError imageError;
    auto base = tryMakeImageView!float(
        rasterView, identities[], validityView, masked, imageError);
    require(imageError == ImageViewValidationError.none,
        "borrow-only image construction");

    MetadataBorrowError borrowError;
    auto borrowed = tryBorrowSemanticImage(base, intrinsic[], borrowError);
    require(borrowError == MetadataBorrowError.none,
        "borrow-only semantic construction");
    require(borrowed.intrinsic.ptr is intrinsic.ptr,
        "borrow-only metadata pointer remains caller-owned");

    // Path B: two explicit .idup snapshots, still using the same
    // raster-d physical backing through independent retained leases.
    SnapshotError snapshotError;
    auto snapshot = RetainedDynamicImage.create(
        identities, intrinsic, snapshotError);
    require(snapshotError == SnapshotError.none,
        "snapshot construction");
    snapshot.primary = pixels;
    if (masked)
    {
        snapshot.validity = validity;
        snapshot.hasValidity = true;
    }

    require(snapshot.identities.ptr !is identities.ptr,
        "identity snapshot is independent");
    require(snapshot.intrinsic.ptr !is intrinsic.ptr,
        "intrinsic snapshot is independent");

    auto retainedBorrow = snapshot.borrow(borrowError);
    require(borrowError == MetadataBorrowError.none,
        "snapshot semantic borrow");
    require(retainedBorrow.channelCount == channelCount
        && borrowed.channelCount == channelCount, "channel cardinality");

    bool roiOk;
    auto roiA = borrowed.tryRoi(Region2D(1, 1, 3, 2), roiOk);
    require(roiOk, "borrow-only ROI");
    auto roiB = retainedBorrow.tryRoi(Region2D(1, 1, 3, 2), roiOk);
    require(roiOk, "snapshot ROI");
    require(roiA.intrinsic.ptr is intrinsic.ptr,
        "borrow-only ROI does not copy metadata");
    require(roiB.intrinsic.ptr is snapshot.intrinsic.ptr,
        "snapshot ROI does not copy metadata");

    if (channelCount >= 3)
    {
        const binding = ColourBinding(
            channelCount - 1,
            channelCount - 2,
            channelCount - 3,
            DeclaredColour.unspecified
        );
        auto destinationA = makeRaster(3, layout, false);
        auto destinationB = makeRaster(3, layout, false);
        {
            bool ok;
            scope auto writable = destinationA.tryWritableView(ok);
            require(ok, "borrow destination writable");
            require(borrowed.mapInto(
                binding, ValueInterpretation.physical, writable)
                == SemanticMapError.none, "borrow-only physical map");
        }
        {
            bool ok;
            scope auto writable = destinationB.tryWritableView(ok);
            require(ok, "snapshot destination writable");
            require(retainedBorrow.mapInto(
                binding, ValueInterpretation.physical, writable)
                == SemanticMapError.none, "snapshot physical map");
        }
        auto a = destinationA.view();
        auto b = destinationB.view();
        compareOutput(a, b);
        validateOutput(a, channelCount, masked);
    }

    // const is a read-only capability, not an immutable-value snapshot.
    // The borrowed slice observes caller updates, the snapshot does not.
    const before = snapshot.intrinsic[0].scale;
    intrinsic[0].scale = 7.0f;
    require(borrowed.intrinsic[0].scale == 7.0f,
        "caller mutation remains visible to a const borrow");
    require(snapshot.intrinsic[0].scale == before,
        "snapshot isolated from input mutation");

    identities[0].semanticId = 999_999;
    require(snapshot.identities[0].semanticId == 4000,
        "identity snapshot isolated from input mutation");
    // Do not run image operations via the caller borrow once its
    // identity mapping has been mutated.
}

private void failures()
{
    ChannelDescriptor[2] ids = [
        ChannelDescriptor(3), ChannelDescriptor(4)
    ];
    IntrinsicChannel[2] meanings = [
        IntrinsicChannel(3, "", "", false, 0, 0),
        IntrinsicChannel(5, "", "", false, 0, 0)
    ];
    SnapshotError e;
    auto failed = RetainedDynamicImage.create(ids[], meanings[], e);
    require(e == SnapshotError.semanticIdentityMismatch
        && failed.channelCount == 0, "reject wrong identity");
    auto mismatched = RetainedDynamicImage.create(
        ids[], meanings[0 .. 1], e);
    require(e == SnapshotError.channelCountMismatch
        && mismatched.channelCount == 0, "reject wrong length");
}

private void benchmark()
{
    // Advisory CPU-time observation on the CI VM; not a release decision.
    // Preflight correctness above always runs before this section.
    writeln("metric,channels,iterations,elapsed_us,checksum");
    foreach (n; [cast(size_t)3, 64, 256])
    {
        const size_t iterations = n >= 256 ? 1200 :
            n >= 64 ? 3000 : 12000;
        auto ids = new ChannelDescriptor[](n);
        auto meanings = new IntrinsicChannel[](n);
        foreach (i; 0 .. n)
        {
            ids[i] = ChannelDescriptor(cast(uint)(4000 + i));
            meanings[i] = IntrinsicChannel(
                cast(uint)(4000 + i), "channel", "unit",
                true, 0.5f, -10.0f);
        }

        auto pixels = makeRaster(n, LayoutKind.planar, false);
        auto view = pixels.view();
        ImageViewValidationError imgError;
        auto image = tryMakeImageView!float(
            view, ids[], RasterView!ubyte.init, false, imgError);
        require(imgError == ImageViewValidationError.none,
            "benchmark image preflight");

        SnapshotError snapError;
        auto snapshot = RetainedDynamicImage.create(ids, meanings, snapError);
        require(snapError == SnapshotError.none,
            "benchmark snapshot preflight");
        snapshot.primary = pixels;
        MetadataBorrowError borrowError;
        auto baseBorrow = tryBorrowSemanticImage(image, meanings, borrowError);
        require(borrowError == MetadataBorrowError.none,
            "benchmark borrowed preflight");
        auto held = snapshot.borrow(borrowError);
        require(borrowError == MetadataBorrowError.none,
            "benchmark snapshot borrow preflight");

        size_t checksum;
        StopWatch watch;
        watch.start();
        foreach (_; 0 .. iterations)
        {
            auto b = tryBorrowSemanticImage(image, meanings, borrowError);
            require(borrowError == MetadataBorrowError.none,
                "benchmark borrow");
            checksum += b.channelCount;
        }
        watch.stop();
        writeln("borrow_bind,", n, ",", iterations, ",",
            watch.peek.total!"usecs", ",", checksum);

        checksum = 0;
        watch.reset();
        watch.start();
        foreach (_; 0 .. iterations)
        {
            auto snap = RetainedDynamicImage.create(ids, meanings, snapError);
            require(snapError == SnapshotError.none,
                "benchmark snapshot create");
            checksum += snap.channelCount;
        }
        watch.stop();
        writeln("snapshot_create,", n, ",", iterations, ",",
            watch.peek.total!"usecs", ",", checksum);

        checksum = 0;
        watch.reset();
        watch.start();
        foreach (_; 0 .. iterations)
        {
            bool ok;
            auto region = baseBorrow.tryRoi(Region2D(1, 1, 3, 2), ok);
            require(ok, "benchmark borrowed ROI");
            checksum += region.channelCount;
        }
        watch.stop();
        writeln("borrow_roi,", n, ",", iterations, ",",
            watch.peek.total!"usecs", ",", checksum);

        checksum = 0;
        watch.reset();
        watch.start();
        foreach (_; 0 .. iterations)
        {
            bool ok;
            auto region = held.tryRoi(Region2D(1, 1, 3, 2), ok);
            require(ok, "benchmark snapshot ROI");
            checksum += region.channelCount;
        }
        watch.stop();
        writeln("snapshot_roi,", n, ",", iterations, ",",
            watch.peek.total!"usecs", ",", checksum);
    }
}

version (M325_NEGATIVE_CALLER_METADATA_ESCAPE)
{
    @safe BorrowedSemanticImage escapeCallerMetadata(
        return scope ImageView!float callerImage
    )
    {
        IntrinsicChannel[3] local;
        MetadataBorrowError error;
        return tryBorrowSemanticImage(callerImage, local[], error);
    }
}

void main(string[] args)
{
    failures();
    foreach (n; [cast(size_t)1, 3, 4, 17, 64, 256])
    {
        exercise(n, LayoutKind.planar, true);
        exercise(n, LayoutKind.interleaved, false);
    }
    writeln("M3.2.5 PASS: borrow versus immutable snapshot semantics");

    if (args.length > 1 && args[1] == "--benchmark")
        benchmark();
}
