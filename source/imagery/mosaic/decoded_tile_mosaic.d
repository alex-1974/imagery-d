/++ Public regular decoded RGBA8 tile-grid mosaic operation. +/
module imagery.mosaic.decoded_tile_mosaic;

import core.stdc.stdlib : free, malloc;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

/++
 Borrow one decoded four-plane RGBA8 tile at an explicit canvas origin. `.init` has an empty raster; keep its owner alive through mapping.
+/
struct DecodedRgbaTile
{
    /++
     Borrowed four-plane RGBA8 raster with common tile dimensions.
    +/
    RasterView!ubyte pixels;
    /++
     Tile origin column in the regular canvas grid.
    +/
    size_t originX;
    /++
     Tile origin row in the regular canvas grid.
    +/
    size_t originY;
}

/// Scale a decoded RGBA tile without changing its bytes or association.
@system unittest
{
    import core.stdc.stdlib : malloc;
    import raster : OwnedByteResource,PlaneByteLayout,RasterLease,Region2D,
        tryAdoptMallocResource,tryImportOwnedRaster;
    auto memory=cast(ubyte*)malloc(4);
    assert(memory !is null);
    memory[0]=64; memory[1]=128; memory[2]=192; memory[3]=255;
    OwnedByteResource owner;
    assert(tryAdoptMallocResource(memory,4,owner));
    PlaneByteLayout[4] layouts;
    foreach(c;0..4) layouts[c]=PlaneByteLayout(c,4,4);
    RasterLease!ubyte input;
    assert(tryImportOwnedRaster!ubyte(owner,layouts[],Region2D(0,0,1,1),input).ok);
    DecodedRgbaTile[1] tiles=[DecodedRgbaTile(input.view,0,0)];
    RasterLease!ubyte result;
    assert(tryMapNearestRgbaTilesOwned(tiles[],1,1,RgbaAlphaAssociation.straight,
        Region2D(0,0,1,1),2,1,16,result)==TileMosaicError.none);
    ubyte red;
    assert(result.view.width==2 && result.view.height==2 && result.view.trySample(0,1,1,red) && red==64);
}


/++
 Declare the association of decoded RGBA bytes. `.init` is unspecified and is rejected; accepted policies preserve the bytes.
+/
enum RgbaAlphaAssociation : ubyte {
    /++ No explicit policy was supplied. +/
    unspecified,
    /++ RGB is not multiplied by alpha; bytes are preserved. +/
    straight,
    /++ RGB is already multiplied by alpha; bytes are preserved. +/
    premultiplied,
    /++ Association is explicitly unknown; preserve bytes without converting association. +/
    unknown }
/++
 Report regular-grid RGBA mapping status. `.init` is notAttempted and never denotes success.
+/
enum TileMosaicError : ubyte
{
    /++ No operation has completed; this is the default sentinel. +/
    notAttempted,
    /++ The operation completed successfully. +/
    none,
    /++ Tile origins or dimensions do not form the required regular grid. +/
    invalidGrid,
    /++ The alpha-association declaration is unsupported. +/
    invalidAssociation,
    /++ The requested pixel rectangle is empty or outside the source extent. +/
    invalidRegion,
    /++ The rational scale is zero, overflows or yields unsupported output dimensions. +/
    invalidScale,
    /++ Required retained output storage exceeds the caller’s budget. +/
    resultExceedsBudget,
    /++ Storage allocation or owned-raster construction failed. +/
    allocationFailure,
    /++ A raster sample could not be read or written. +/
    sampleFailure
}

private bool allocate(size_t bytes, out OwnedByteResource owner) @trusted
{
    auto memory = malloc(bytes);
    if (memory is null || !tryAdoptMallocResource(memory, bytes, owner))
    {
        if (memory !is null) free(memory);
        return false;
    }
    return true;
}

/++
 Map a regular decoded RGBA8 tile grid into an owned nearest-neighbour view.

    The tile origins must form a complete row-major regular grid. The alpha
    association is validated and preserved byte-for-byte; it is not converted.

 Params:
  tiles = Borrowed row-major regular tile descriptors with equal nonzero dimensions.
  columns = Number of tile columns in the complete row-major grid.
  rows = Number of tile rows in the complete row-major grid.
  association = Explicit straight or premultiplied alpha association; no automatic conversion.
  sourceRoi = Nonempty contained rectangle in the regular tile canvas.
  scaleNumerator = Positive numerator of the output/source dimension ratio.
  scaleDenominator = Positive denominator; scaled dimensions must divide exactly.
  maxResultBytes = Maximum requested retained output pixel/payload bytes, excluding allocator overhead unless stated above.
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
TileMosaicError tryMapNearestRgbaTilesOwned(
    scope const DecodedRgbaTile[] tiles, size_t columns, size_t rows,
    RgbaAlphaAssociation association, Region2D sourceRoi,
    size_t scaleNumerator, size_t scaleDenominator, size_t maxResultBytes,
    ref RasterLease!ubyte published)
@safe
{
    if (columns == 0 || rows == 0 || columns > size_t.max / rows ||
        tiles.length != columns * rows)
        return TileMosaicError.invalidGrid;
    if (association < RgbaAlphaAssociation.straight ||
        association > RgbaAlphaAssociation.unknown)
        return TileMosaicError.invalidAssociation;

    const tileWidth = tiles[0].pixels.width;
    const tileHeight = tiles[0].pixels.height;
    if (tileWidth == 0 || tileHeight == 0 ||
        columns > size_t.max / tileWidth || rows > size_t.max / tileHeight)
        return TileMosaicError.invalidGrid;
    foreach (index, tile; tiles)
    {
        const column = index % columns;
        const row = index / columns;
        if (tile.pixels.planeCount != 4 || tile.pixels.width != tileWidth ||
            tile.pixels.height != tileHeight ||
            tile.originX != column * tileWidth ||
            tile.originY != row * tileHeight)
            return TileMosaicError.invalidGrid;
    }

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
    if (scaledWidth % scaleDenominator || scaledHeight % scaleDenominator)
        return TileMosaicError.invalidScale;
    const outputWidth = scaledWidth / scaleDenominator;
    const outputHeight = scaledHeight / scaleDenominator;
    if (outputWidth == 0 || outputHeight == 0 ||
        outputWidth > size_t.max / outputHeight)
        return TileMosaicError.invalidScale;
    const pixels = outputWidth * outputHeight;
    if (pixels > size_t.max / 4)
        return TileMosaicError.allocationFailure;
    const bytes = pixels * 4;
    if (bytes > maxResultBytes || bytes > cast(size_t)ptrdiff_t.max)
        return TileMosaicError.resultExceedsBudget;
    if (outputWidth > cast(size_t)ptrdiff_t.max / 4)
        return TileMosaicError.allocationFailure;

    OwnedByteResource resource;
    if (!allocate(bytes, resource)) return TileMosaicError.allocationFailure;
    PlaneByteLayout[4] layouts;
    foreach (component; 0 .. 4)
        layouts[component] = PlaneByteLayout(component,
            cast(ptrdiff_t)(outputWidth * 4), 4);
    RasterLease!ubyte temporary;
    if (!tryImportOwnedRaster!ubyte(resource, layouts[],
        Region2D(0, 0, outputWidth, outputHeight), temporary).ok)
        return TileMosaicError.allocationFailure;
    bool writable;
    scope auto output = temporary.tryWritableView(writable);
    if (!writable) return TileMosaicError.allocationFailure;
    foreach (y; 0 .. outputHeight)
    foreach (x; 0 .. outputWidth)
    {
        const sourceX = sourceRoi.x + x * scaleDenominator / scaleNumerator;
        const sourceY = sourceRoi.y + y * scaleDenominator / scaleNumerator;
        const tile = tiles[(sourceY / tileHeight) * columns +
            sourceX / tileWidth];
        foreach (component; 0 .. 4)
        {
            ubyte sample;
            if (!tile.pixels.trySample(component, sourceX % tileWidth,
                    sourceY % tileHeight, sample) ||
                !output.trySetSample(component, x, y, sample))
                return TileMosaicError.sampleFailure;
        }
    }
    published = temporary;
    return TileMosaicError.none;
}
