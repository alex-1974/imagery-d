/++ Research-only M5 candidate. Not a public imagery-d module. +/
module candidate;

import core.stdc.stdlib : free, malloc;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;

struct DecodedRgbaTile
{
    RasterView!ubyte pixels;
    size_t originX;
    size_t originY;
}

enum RgbaAlphaAssociation : ubyte
{
    unspecified,
    straight,
    premultiplied,
    unknown
}

enum TileMosaicError : ubyte
{
    notAttempted,
    none,
    invalidGrid,
    invalidAssociation,
    invalidRegion,
    invalidScale,
    resultExceedsBudget,
    allocationFailure,
    sampleFailure
}

private bool tryCreateOwnedMallocBytes(
    size_t bytes, out OwnedByteResource owner) @trusted
{
    owner = OwnedByteResource.init;
    void* memory = malloc(bytes);
    if (memory is null)
        return false;
    if (!tryAdoptMallocResource(memory, bytes, owner))
    {
        free(memory);
        return false;
    }
    return true;
}

/++
 Research candidate for a complete owned viewport from a regular decoded
 RGBA8 tile grid. It copies nearest pixel-origin samples and preserves all
 four stored bytes; association is declared but never converted.
+/
TileMosaicError tryMapNearestRgbaTilesOwned(
    scope const DecodedRgbaTile[] tiles,
    size_t columns,
    size_t rows,
    RgbaAlphaAssociation association,
    Region2D sourceRoi,
    size_t scaleNumerator,
    size_t scaleDenominator,
    size_t maxResultBytes,
    ref RasterLease!ubyte published)
@safe
{
    if (columns == 0 || rows == 0 || columns > size_t.max / rows ||
        tiles.length != columns * rows)
        return TileMosaicError.invalidGrid;

    const tileWidth = tiles[0].pixels.width;
    const tileHeight = tiles[0].pixels.height;
    if (tileWidth == 0 || tileHeight == 0 ||
        columns > size_t.max / tileWidth ||
        rows > size_t.max / tileHeight)
        return TileMosaicError.invalidGrid;

    foreach (index, tile; tiles)
    {
        const column = index % columns;
        const row = index / columns;
        if (tile.pixels.planeCount != 4 ||
            tile.pixels.width != tileWidth ||
            tile.pixels.height != tileHeight ||
            tile.originX != column * tileWidth ||
            tile.originY != row * tileHeight)
            return TileMosaicError.invalidGrid;
    }
    if (association < RgbaAlphaAssociation.straight ||
        association > RgbaAlphaAssociation.unknown)
        return TileMosaicError.invalidAssociation;

    const canvasWidth = columns * tileWidth;
    const canvasHeight = rows * tileHeight;
    if (sourceRoi.width == 0 || sourceRoi.height == 0 ||
        sourceRoi.x > canvasWidth || sourceRoi.y > canvasHeight ||
        sourceRoi.width > canvasWidth - sourceRoi.x ||
        sourceRoi.height > canvasHeight - sourceRoi.y)
        return TileMosaicError.invalidRegion;

    if (scaleNumerator == 0 || scaleDenominator == 0 ||
        sourceRoi.width > size_t.max / scaleNumerator ||
        sourceRoi.height > size_t.max / scaleNumerator)
        return TileMosaicError.invalidScale;
    const scaledWidth = sourceRoi.width * scaleNumerator;
    const scaledHeight = sourceRoi.height * scaleNumerator;
    if (scaledWidth % scaleDenominator != 0 ||
        scaledHeight % scaleDenominator != 0)
        return TileMosaicError.invalidScale;
    const outputWidth = scaledWidth / scaleDenominator;
    const outputHeight = scaledHeight / scaleDenominator;
    if (outputWidth == 0 || outputHeight == 0 ||
        outputWidth - 1 > size_t.max / scaleDenominator ||
        outputHeight - 1 > size_t.max / scaleDenominator)
        return TileMosaicError.invalidScale;

    if (outputWidth > size_t.max / outputHeight)
        return TileMosaicError.allocationFailure;
    const pixels = outputWidth * outputHeight;
    if (pixels > size_t.max / 4)
        return TileMosaicError.allocationFailure;
    const bytes = pixels * 4;
    if (bytes > cast(size_t)ptrdiff_t.max ||
        outputWidth > cast(size_t)ptrdiff_t.max / 4)
        return TileMosaicError.allocationFailure;
    if (bytes > maxResultBytes)
        return TileMosaicError.resultExceedsBudget;

    OwnedByteResource resource;
    if (!tryCreateOwnedMallocBytes(bytes, resource))
        return TileMosaicError.allocationFailure;
    PlaneByteLayout[4] layouts;
    foreach (component; 0 .. 4)
        layouts[component] = PlaneByteLayout(
            component, cast(ptrdiff_t)(outputWidth * 4), 4);
    RasterLease!ubyte temporary;
    if (!tryImportOwnedRaster!ubyte(resource, layouts[],
        Region2D(0, 0, outputWidth, outputHeight), temporary).ok)
        return TileMosaicError.allocationFailure;
    bool writable;
    scope auto output = temporary.tryWritableView(writable);
    if (!writable)
        return TileMosaicError.allocationFailure;

    foreach (y; 0 .. outputHeight)
    {
        const sourceY = sourceRoi.y +
            y * scaleDenominator / scaleNumerator;
        const tileRow = sourceY / tileHeight;
        foreach (x; 0 .. outputWidth)
        {
            const sourceX = sourceRoi.x +
                x * scaleDenominator / scaleNumerator;
            const tileColumn = sourceX / tileWidth;
            const tile = tiles[tileRow * columns + tileColumn];
            foreach (component; 0 .. 4)
            {
                ubyte sample;
                if (!tile.pixels.trySample(component,
                    sourceX % tileWidth, sourceY % tileHeight, sample) ||
                    !output.trySetSample(component, x, y, sample))
                    return TileMosaicError.sampleFailure;
            }
        }
    }
    published = temporary;
    return TileMosaicError.none;
}

static assert(TileMosaicError.init == TileMosaicError.notAttempted);
static assert(TileMosaicError.init != TileMosaicError.none);
