module app;

import candidate :
    DecodedRgbaTile, RgbaAlphaAssociation, TileMosaicError,
    tryMapNearestRgbaTilesOwned;
import core.stdc.stdlib : free, malloc;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;

enum tileWidth = 4;
enum tileHeight = 4;
enum columns = 3;
enum rows = 2;

private void need(bool condition, string message)
{
    if (!condition)
        throw new Exception("M5 decoded tile mosaic: " ~ message);
}

private RasterLease!ubyte allocateRgba(
    size_t width, size_t height, bool planar,
    bool reverseRows = false, bool reverseSamples = false)
@trusted
{
    const bytes = width * height * 4;
    auto memory = malloc(bytes);
    need(memory !is null, "allocate fixture");
    OwnedByteResource resource;
    if (!tryAdoptMallocResource(memory, bytes, resource))
    {
        free(memory);
        need(false, "adopt fixture");
    }
    PlaneByteLayout[4] layouts;
    if (planar)
    {
        const rowBytes = width;
        foreach (component; 0 .. 4)
            layouts[component] = PlaneByteLayout(
                component * width * height +
                    (reverseRows ? (height - 1) * rowBytes : 0) +
                    (reverseSamples ? width - 1 : 0),
                reverseRows ? -cast(ptrdiff_t)rowBytes :
                    cast(ptrdiff_t)rowBytes,
                reverseSamples ? -1 : 1);
    }
    else
    {
        const rowBytes = width * 4;
        foreach (component; 0 .. 4)
            layouts[component] = PlaneByteLayout(
                component +
                    (reverseRows ? (height - 1) * rowBytes : 0) +
                    (reverseSamples ? (width - 1) * 4 : 0),
                reverseRows ? -cast(ptrdiff_t)rowBytes :
                    cast(ptrdiff_t)rowBytes,
                reverseSamples ? -4 : 4);
    }
    RasterLease!ubyte owner;
    need(tryImportOwnedRaster!ubyte(resource, layouts[],
        Region2D(0, 0, width, height), owner).ok, "import fixture");
    return owner;
}

private ubyte alphaAt(size_t x, size_t y)
{
    final switch ((x + 2 * y) % 3)
    {
        case 0: return 0;
        case 1: return 128;
        case 2: return 255;
    }
}

private ubyte straightComponent(size_t component, size_t x, size_t y)
{
    return cast(ubyte)((x * 29 + y * 47 + component * 61 + 13) & 255);
}

private ubyte expectedComponent(
    RgbaAlphaAssociation association,
    size_t component, size_t x, size_t y)
{
    const alpha = alphaAt(x, y);
    if (component == 3)
        return alpha;
    const straight = straightComponent(component, x, y);
    if (association == RgbaAlphaAssociation.premultiplied)
        return cast(ubyte)((cast(uint)straight * alpha + 127) / 255);
    return straight;
}

private void initializeTile(
    ref RasterLease!ubyte owner,
    size_t originX,
    size_t originY,
    RgbaAlphaAssociation association)
{
    bool writable;
    scope auto output = owner.tryWritableView(writable);
    need(writable, "tile writable");
    foreach (y; 0 .. tileHeight)
    foreach (x; 0 .. tileWidth)
    foreach (component; 0 .. 4)
        need(output.trySetSample(component, x, y,
            expectedComponent(association, component,
                originX + x, originY + y)), "initialize tile sample");
}

private struct ViewCase
{
    Region2D roi;
    size_t numerator;
    size_t denominator;
}

private immutable ViewCase[6] cases = [
    ViewCase(Region2D(0, 0, 12, 8), 1, 1),
    ViewCase(Region2D(0, 0, 12, 8), 2, 1),
    ViewCase(Region2D(0, 0, 12, 8), 1, 2),
    ViewCase(Region2D(3, 2, 6, 4), 1, 1),
    ViewCase(Region2D(3, 2, 6, 4), 2, 1),
    ViewCase(Region2D(2, 0, 8, 6), 3, 2)
];

private size_t verifySuccessMatrix()
{
    size_t checkedComponents;
    foreach (planar; [false, true])
    foreach (reverseRows; [false, true])
    foreach (reverseSamples; [false, true])
    foreach (association; [
        RgbaAlphaAssociation.straight,
        RgbaAlphaAssociation.premultiplied,
        RgbaAlphaAssociation.unknown])
    {
        RasterLease!ubyte[columns * rows] owners;
        DecodedRgbaTile[columns * rows] tiles;
        foreach (index; 0 .. tiles.length)
        {
            const column = index % columns;
            const row = index / columns;
            owners[index] = allocateRgba(tileWidth, tileHeight,
                planar, reverseRows, reverseSamples);
            initializeTile(owners[index], column * tileWidth,
                row * tileHeight, association);
            tiles[index] = DecodedRgbaTile(owners[index].view(),
                column * tileWidth, row * tileHeight);
        }

        foreach (viewCase; cases)
        {
            const outputWidth =
                viewCase.roi.width * viewCase.numerator /
                viewCase.denominator;
            const outputHeight =
                viewCase.roi.height * viewCase.numerator /
                viewCase.denominator;
            const budget = outputWidth * outputHeight * 4;
            RasterLease!ubyte output;
            need(tryMapNearestRgbaTilesOwned(tiles[], columns, rows,
                association, viewCase.roi, viewCase.numerator,
                viewCase.denominator, budget, output) ==
                TileMosaicError.none, "map valid viewport");
            scope auto result = output.view();
            need(result.width == outputWidth &&
                result.height == outputHeight && result.planeCount == 4,
                "owned result shape");
            foreach (y; 0 .. outputHeight)
            foreach (x; 0 .. outputWidth)
            {
                const sourceX = viewCase.roi.x +
                    x * viewCase.denominator / viewCase.numerator;
                const sourceY = viewCase.roi.y +
                    y * viewCase.denominator / viewCase.numerator;
                foreach (component; 0 .. 4)
                {
                    ubyte actual;
                    need(result.trySample(component, x, y, actual) &&
                        actual == expectedComponent(association, component,
                            sourceX, sourceY), "independent pixel oracle");
                    ++checkedComponents;
                }
            }
        }
    }
    return checkedComponents;
}

private void verifyFailures()
{
    RasterLease!ubyte[columns * rows] owners;
    DecodedRgbaTile[columns * rows] tiles;
    foreach (index; 0 .. tiles.length)
    {
        const column = index % columns;
        const row = index / columns;
        owners[index] = allocateRgba(tileWidth, tileHeight, index % 2 == 0,
            index % 3 == 0, index % 2 == 1);
        initializeTile(owners[index], column * tileWidth,
            row * tileHeight, RgbaAlphaAssociation.straight);
        tiles[index] = DecodedRgbaTile(owners[index].view(),
            column * tileWidth, row * tileHeight);
    }
    auto prior = allocateRgba(1, 1, false);
    {
        bool writable;
        scope auto output = prior.tryWritableView(writable);
        need(writable && output.trySetSample(0, 0, 0, 211),
            "prior sentinel");
    }

    void retained(TileMosaicError observed, TileMosaicError expected,
        string label)
    {
        ubyte sentinel;
        scope auto result = prior.view();
        need(observed == expected && result.width == 1 &&
            result.trySample(0, 0, 0, sentinel) && sentinel == 211,
            label ~ " preserves prior publication");
    }

    const full = Region2D(0, 0, 12, 8);
    retained(tryMapNearestRgbaTilesOwned(tiles[0 .. 5], columns, rows,
        RgbaAlphaAssociation.straight, full, 1, 1, 384, prior),
        TileMosaicError.invalidGrid, "missing tile");
    auto misplaced = tiles;
    misplaced[1].originX = 5;
    retained(tryMapNearestRgbaTilesOwned(misplaced[], columns, rows,
        RgbaAlphaAssociation.straight, full, 1, 1, 384, prior),
        TileMosaicError.invalidGrid, "misplaced tile");
    retained(tryMapNearestRgbaTilesOwned(tiles[], columns, rows,
        RgbaAlphaAssociation.unspecified, full, 1, 1, 384, prior),
        TileMosaicError.invalidAssociation, "unspecified alpha");
    retained(tryMapNearestRgbaTilesOwned(tiles[], columns, rows,
        cast(RgbaAlphaAssociation)255, full, 1, 1, 384, prior),
        TileMosaicError.invalidAssociation, "unknown alpha enum value");
    auto wrongShapeOwner = allocateRgba(3, tileHeight, true);
    auto wrongShape = tiles;
    wrongShape[0].pixels = wrongShapeOwner.view();
    retained(tryMapNearestRgbaTilesOwned(wrongShape[], columns, rows,
        RgbaAlphaAssociation.straight, full, 1, 1, 384, prior),
        TileMosaicError.invalidGrid, "wrong tile shape");
    retained(tryMapNearestRgbaTilesOwned(tiles[], columns, rows,
        RgbaAlphaAssociation.straight, Region2D(11, 0, 2, 1),
        1, 1, 8, prior), TileMosaicError.invalidRegion,
        "outside ROI");
    retained(tryMapNearestRgbaTilesOwned(tiles[], columns, rows,
        RgbaAlphaAssociation.straight, full, 0, 1, 384, prior),
        TileMosaicError.invalidScale, "zero scale");
    retained(tryMapNearestRgbaTilesOwned(tiles[], columns, rows,
        RgbaAlphaAssociation.straight, full, size_t.max, 1,
        size_t.max, prior), TileMosaicError.invalidScale,
        "overflowing scale");
    retained(tryMapNearestRgbaTilesOwned(tiles[], columns, rows,
        RgbaAlphaAssociation.straight, Region2D(0, 0, 11, 8),
        1, 2, 384, prior), TileMosaicError.invalidScale,
        "fractional output shape");
    retained(tryMapNearestRgbaTilesOwned(tiles[], columns, rows,
        RgbaAlphaAssociation.straight, full, 1, 1, 383, prior),
        TileMosaicError.resultExceedsBudget, "short budget");
}

void main()
{
    const checked = verifySuccessMatrix();
    verifyFailures();
    need(checked == 70_272, "expected complete oracle count");
    writeln("M5_DECODED_TILE_MOSAIC=PASS; layouts:8,alpha:3,views:6," ~
        "outputs:144,component_checks:70272,seams:horizontal+vertical," ~
        "owned_result:1,short_budget_rollback:1");
}
