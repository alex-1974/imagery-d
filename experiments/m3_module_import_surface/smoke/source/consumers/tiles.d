module consumers.tiles;

// A second independent DUB consumer: synthetic *decoded* RGBA tiles
// from raster-d and explicit image-domain tile presentation.
// No M1/M3 private implementation imports, no editor, decoder or URLs.
import core.stdc.stdlib : malloc;
import core.memory : GC;
import imagery.presentation.tiles :
    DecodedRgbaTile, RgbaAlphaAssociation, RgbaTileError,
    tryMapNearestRgbaTiles;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

private enum Layout : ubyte { planar, interleaved }
private enum size_t columns = 3, rows = 2;
private enum size_t tileWidth = 4, tileHeight = 4;
private enum size_t canvasWidth = columns * tileWidth;
private enum size_t canvasHeight = rows * tileHeight;

private void require(bool value, string description)
{
    if (!value)
        throw new Exception("M3 decoded RGBA consumer: " ~ description);
}

// Independent *already decoded* source pixels. In straight-alpha mode,
// invisible RGB is deliberately retained and MUST NOT be zeroed by tiling.
// In premultiplied mode the *fixture* prepares associated RGB values;
// the imagery tile mapper itself never invokes colour conversion maths.
private ubyte reference(
    size_t component, size_t x, size_t y,
    RgbaAlphaAssociation association
) @safe pure nothrow @nogc
{
    const ubyte alpha = (x + y) % 4 == 0 ? 0
        : ((x + 2 * y) % 3 == 0 ? 128 : 255);
    if (component == 3)
        return alpha;
    uint sample;
    switch (component)
    {
        case 0: sample = cast(uint)(23 * x + 7 * y); break;
        case 1: sample = cast(uint)(11 * x + 29 * y); break;
        case 2: sample = cast(uint)(13 * x + 19 * y); break;
        default: sample = 0; break;
    }
    sample %= 256;
    if (association == RgbaAlphaAssociation.premultiplied)
        sample = (sample * alpha) / 255;
    return cast(ubyte)sample;
}

private RasterLease!ubyte createRgba(
    size_t width, size_t height, Layout layout,
    size_t originX, size_t originY,
    RgbaAlphaAssociation association, bool fill
)
{
    const bytes = width * height * 4;
    auto memory = cast(ubyte*)malloc(bytes);
    require(memory !is null, "allocate tile/target backing");
    OwnedByteResource owned;
    require(tryAdoptMallocResource(memory, bytes, owned),
        "adopt tile/target storage");

    PlaneByteLayout[4] planes;
    foreach (channel; 0 .. 4)
    {
        planes[channel] = layout == Layout.planar
            ? PlaneByteLayout(channel * width * height,
                cast(ptrdiff_t)width, 1)
            : PlaneByteLayout(channel,
                cast(ptrdiff_t)(width * 4), 4);
    }
    RasterLease!ubyte result;
    auto imported = tryImportOwnedRaster!ubyte(
        owned, planes[], Region2D(0, 0, width, height), result);
    require(imported.ok, "import owned decoded tile/target");

    if (fill)
    {
        bool ok;
        scope auto writable = result.tryWritableView(ok);
        require(ok, "tile writer");
        foreach (channel; 0 .. 4)
        foreach (y; 0 .. height)
        foreach (x; 0 .. width)
            require(writable.trySetSample(channel, x, y,
                reference(channel, originX + x, originY + y,
                    association)), "populate decoded sample");
    }
    return result;
}

// The viewport is deliberately specified in logical mosaic coordinates,
// distinct from each tile's own resident 0,0-origin RasterView.
private struct Scene
{
    Region2D region;
    size_t numerator;
    size_t denominator;
}

private void execute(
    Layout sourceLayout,
    Layout outputLayout,
    RgbaAlphaAssociation association
)
{
    RasterLease!ubyte[columns * rows] leases;
    DecodedRgbaTile[columns * rows] tiles;
    foreach (index; 0 .. tiles.length)
    {
        const x = (index % columns) * tileWidth;
        const y = (index / columns) * tileHeight;
        leases[index] = createRgba(
            tileWidth, tileHeight, sourceLayout, x, y,
            association, true);
        tiles[index] = DecodedRgbaTile(leases[index].view(), x, y);
    }

    const Scene[6] cases = [
        Scene(Region2D(0, 0, canvasWidth, canvasHeight), 1, 1),
        Scene(Region2D(0, 0, canvasWidth, canvasHeight), 2, 1),
        Scene(Region2D(0, 0, canvasWidth, canvasHeight), 1, 2),
        Scene(Region2D(3, 2, 6, 4), 1, 1),
        Scene(Region2D(3, 2, 6, 4), 2, 1),
        Scene(Region2D(2, 0, 8, 6), 3, 2)
    ];
    foreach (scene; cases)
    {
        const width = scene.region.width
            * scene.numerator / scene.denominator;
        const height = scene.region.height
            * scene.numerator / scene.denominator;
        auto destinationLease = createRgba(
            width, height, outputLayout, 0, 0, association, false);
        bool ok;
        scope auto output = destinationLease.tryWritableView(ok);
        require(ok, "target writer");
        auto readback = destinationLease.view();

        const before = GC.stats().allocatedInCurrentThread;
        const error = tryMapNearestRgbaTiles(
            tiles[], columns, rows, association, scene.region,
            scene.numerator, scene.denominator, output);
        const after = GC.stats().allocatedInCurrentThread;
        require(error == RgbaTileError.none,
            "map real neighbouring tile samples");
        require(after == before,
            "mapping must allocate zero GC bytes");

        // Independent global-coordinate oracle for ALL resulting
        // output components, transparent/partial/opaque alpha included.
        // Consequently any 4px/8px horizontal or 4px vertical seam is
        // checked at the same strength as interior mapped pixels.
        foreach (y; 0 .. height)
        foreach (x; 0 .. width)
        {
            const sourceX = scene.region.x
                + x * scene.denominator / scene.numerator;
            const sourceY = scene.region.y
                + y * scene.denominator / scene.numerator;
            foreach (channel; 0 .. 4)
            {
                ubyte observed;
                require(readback.trySample(channel, x, y, observed),
                    "read independent output component");
                require(observed == reference(
                    channel, sourceX, sourceY, association),
                    "pixel oracle: tile seam, scaling or RGBA preservation");
            }
        }

        // Reject ALL malformed contracts before touching a byte of the
        // reused output. This includes invalid tile ordering/placement,
        // missing tiles, explicit alpha policy and viewport constraints.
        enum ubyte sentinel = 197;
        foreach (channel; 0 .. 4)
        foreach (y; 0 .. height)
        foreach (x; 0 .. width)
            require(output.trySetSample(channel, x, y, sentinel),
                "write failure sentinel");

        auto reordered = tiles;
        reordered[0].originX = 1;
        auto checkRejected = (RgbaTileError expected,
            scope const(DecodedRgbaTile)[] candidates,
            RgbaAlphaAssociation alpha, Region2D region,
            size_t numerator, size_t denominator)
        {
            const got = tryMapNearestRgbaTiles(
                candidates, columns, rows, alpha, region,
                numerator, denominator, output);
            require(got == expected, "classified malformed request");
            foreach (channel; 0 .. 4)
            foreach (y; 0 .. height)
            foreach (x; 0 .. width)
            {
                ubyte value;
                require(readback.trySample(channel, x, y, value)
                    && value == sentinel,
                    "preflight failure changed caller-owned output");
            }
        };

        checkRejected(RgbaTileError.invalidGrid, reordered[],
            association, scene.region,
            scene.numerator, scene.denominator);
        checkRejected(RgbaTileError.invalidGrid, tiles[0 .. $ - 1],
            association, scene.region,
            scene.numerator, scene.denominator);
        auto missingView = tiles;
        missingView[1].pixels = RasterView!ubyte.init;
        checkRejected(RgbaTileError.invalidGrid, missingView[],
            association, scene.region,
            scene.numerator, scene.denominator);
        checkRejected(RgbaTileError.invalidAssociation, tiles[],
            RgbaAlphaAssociation.unspecified, scene.region,
            scene.numerator, scene.denominator);
        checkRejected(RgbaTileError.invalidRegion, tiles[],
            association, Region2D(canvasWidth, canvasHeight, 2, 2),
            scene.numerator, scene.denominator);
        checkRejected(RgbaTileError.invalidScale, tiles[],
            association, scene.region, 0, scene.denominator);
        checkRejected(RgbaTileError.invalidScale, tiles[],
            association, scene.region, 1, 5);
        checkRejected(RgbaTileError.destinationMismatch, tiles[],
            association, scene.region,
            scene.numerator * 2, scene.denominator);
    }
}

void runTileBackgroundConsumer()
{
    foreach (input; [Layout.planar, Layout.interleaved])
    foreach (output; [Layout.planar, Layout.interleaved])
    foreach (alpha;
        [RgbaAlphaAssociation.straight,
         RgbaAlphaAssociation.premultiplied])
        execute(input, output, alpha);

    import std.stdio : writeln;
    writeln("M3 tile consumer PASS: 48 real scenes, 6 decoded tiles, ",
        "RGB+alpha independent oracle, cross-tile seams, pan/zoom, ",
        "no mapped GC, preflight preserved output");
}
