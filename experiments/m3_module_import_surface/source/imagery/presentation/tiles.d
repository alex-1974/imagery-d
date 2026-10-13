module imagery.presentation.tiles;

import raster : RasterView, WritableRasterView, Region2D;

/++
    Research-only description of a previously decoded four-channel tile.

    The image raster is borrowed and must remain alive for the complete
    mapping call. The (x,y) origin denotes logical mosaic pixel placement,
    NOT RasterView.region, CRS coordinates, a provider tile ID, or a URL.
    Component order 0..3 is EXPLICITLY R,G,B,A for this experiment.
    No colour transfer function is inferred from the four components.
+/
struct DecodedRgbaTile
{
    RasterView!ubyte pixels;
    size_t originX;
    size_t originY;
}

/++
    Explicit alpha association of already decoded channels.

    Alpha is a fourth image component, NOT validity, NoData or opacity
    of an editor layer. Mapping copies all four bytes unchanged;
    it does NOT premultiply/unpremultiply or composite any layers.
+/
enum RgbaAlphaAssociation : ubyte
{
    unspecified,
    straight,
    premultiplied,
    unknown
}

enum RgbaTileError : ubyte
{
    none,
    invalidGrid,
    invalidAssociation,
    invalidRegion,
    invalidScale,
    destinationMismatch,
    sampleFailure
}

/++
    Research-only zero-allocation, @safe checked virtual tile mosaic.

    Tile positions are explicit and ordered row-major on an exactly
    regular already-decoded resident grid. All tiles MUST have identical
    dimensions, four channels and exact logical placement. Their
    RasterLease owners remain with the caller. The target is borrowed
    caller-owned four-component output.

    Source ROI is in logical mosaic pixel coordinates. Mapping uses
    *explicit pixel-origin aligned nearest-neighbour* sampling:
      sx = roi.x + floor(destX * scaleDenominator / scaleNumerator)
    with similarly mapped sy. The output extent is exactly
      roi.width * scaleNumerator / scaleDenominator
    and must be integral, nonzero and equal to the caller output.
    No implicit interpolation, colour conversion, clipping,
    alpha compositing, reprojection, cache request or allocation.

    ALL geometry/alpha/shape checks precede the first output write.
    Unexpected pixel access failure after preflight is not promised
    transactional rollback; failures in that path may partially write.
    This cannot be exposed as a production API without a consumer/ADR.
+/
RgbaTileError tryMapNearestRgbaTiles(
    scope const(DecodedRgbaTile)[] tiles,
    size_t columns,
    size_t rows,
    RgbaAlphaAssociation association,
    Region2D sourceRoi,
    size_t scaleNumerator,
    size_t scaleDenominator,
    scope WritableRasterView!ubyte destination
) @safe nothrow @nogc
{
    if (columns == 0 || rows == 0 || columns > size_t.max / rows
        || tiles.length != columns * rows)
        return RgbaTileError.invalidGrid;

    const tileWidth = tiles[0].pixels.width;
    const tileHeight = tiles[0].pixels.height;
    if (tileWidth == 0 || tileHeight == 0
        || columns > size_t.max / tileWidth
        || rows > size_t.max / tileHeight)
        return RgbaTileError.invalidGrid;

    foreach (index, tile; tiles)
    {
        const column = index % columns;
        const row = index / columns;
        if (tile.pixels.planeCount != 4
            || tile.pixels.width != tileWidth
            || tile.pixels.height != tileHeight
            || tile.originX != column * tileWidth
            || tile.originY != row * tileHeight)
            return RgbaTileError.invalidGrid;
    }

    if (association == RgbaAlphaAssociation.unspecified)
        return RgbaTileError.invalidAssociation;

    const canvasWidth = columns * tileWidth;
    const canvasHeight = rows * tileHeight;
    if (sourceRoi.width == 0 || sourceRoi.height == 0
        || sourceRoi.x > canvasWidth || sourceRoi.y > canvasHeight
        || sourceRoi.width > canvasWidth - sourceRoi.x
        || sourceRoi.height > canvasHeight - sourceRoi.y)
        return RgbaTileError.invalidRegion;

    if (scaleNumerator == 0 || scaleDenominator == 0
        || sourceRoi.width > size_t.max / scaleNumerator
        || sourceRoi.height > size_t.max / scaleNumerator)
        return RgbaTileError.invalidScale;

    const scaledWidth = sourceRoi.width * scaleNumerator;
    const scaledHeight = sourceRoi.height * scaleNumerator;
    if (scaledWidth % scaleDenominator != 0
        || scaledHeight % scaleDenominator != 0)
        return RgbaTileError.invalidScale;

    const outputWidth = scaledWidth / scaleDenominator;
    const outputHeight = scaledHeight / scaleDenominator;
    if (outputWidth == 0 || outputHeight == 0
        || outputWidth - 1 > size_t.max / scaleDenominator
        || outputHeight - 1 > size_t.max / scaleDenominator)
        return RgbaTileError.invalidScale;
    if (destination.planeCount != 4
        || destination.width != outputWidth
        || destination.height != outputHeight)
        return RgbaTileError.destinationMismatch;

    foreach (y; 0 .. outputHeight)
    {
        const sy = sourceRoi.y
            + y * scaleDenominator / scaleNumerator;
        const tileRow = sy / tileHeight;
        foreach (x; 0 .. outputWidth)
        {
            const sx = sourceRoi.x
                + x * scaleDenominator / scaleNumerator;
            const tileColumn = sx / tileWidth;
            const tile = tiles[tileRow * columns + tileColumn];
            foreach (component; 0 .. 4)
            {
                ubyte sample;
                if (!tile.pixels.trySample(
                    component, sx % tileWidth, sy % tileHeight, sample))
                    return RgbaTileError.sampleFailure;
                if (!destination.trySetSample(component, x, y, sample))
                    return RgbaTileError.sampleFailure;
            }
        }
    }
    return RgbaTileError.none;
}
