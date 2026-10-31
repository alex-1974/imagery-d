/** Execution contracts for tiled/strided image kernels.
 *
 * This deliberately does not duplicate raster-d ownership. It describes a
 * borrowed scalar plane and provides safe coordinate mapping plus validity
 * policy that adapters can use when invoking analysis primitives.
 */
module imagery.analysis.execution;

import raster.parallel_rows : ParallelRowsResult, parallelRows;

struct PlaneWindow {
    const(float)* data;
    size_t width;
    size_t height;
    ptrdiff_t rowStride;
    ptrdiff_t sampleStride;
    size_t originX;
    size_t originY;
}

struct Roi { size_t x; size_t y; size_t width; size_t height; }
struct Halo { size_t left; size_t right; size_t top; size_t bottom; }
struct Tile { Roi core; Roi halo; }

Roi expand(Roi roi, Halo halo, size_t width, size_t height) @safe pure nothrow @nogc {
    auto left = halo.left > roi.x ? roi.x : halo.left;
    auto top = halo.top > roi.y ? roi.y : halo.top;
    auto right = halo.right > width - roi.x - roi.width ? width - roi.x - roi.width : halo.right;
    auto bottom = halo.bottom > height - roi.y - roi.height ? height - roi.y - roi.height : halo.bottom;
    return Roi(roi.x-left, roi.y-top, roi.width+left+right, roi.height+top+bottom);
}

Halo neighbourhoodHalo(size_t radius) @safe pure nothrow @nogc { return Halo(radius, radius, radius, radius); }

/// Enumerates a deterministic row-major partition. `core` is the portion to
/// publish; `halo` is the read window required by neighbourhood kernels.
void foreachTile(scope void delegate(Tile) @safe nothrow emit,
    size_t width, size_t height, size_t tileWidth, size_t tileHeight,
    Halo halo) @safe nothrow {
    if (width == 0 || height == 0 || tileWidth == 0 || tileHeight == 0) return;
    for (size_t y = 0; y < height; y += tileHeight)
        for (size_t x = 0; x < width; x += tileWidth) {
            auto core = Roi(x, y, x + tileWidth > width ? width-x : tileWidth,
                y + tileHeight > height ? height-y : tileHeight);
            emit(Tile(core, expand(core, halo, width, height)));
        }
}

/// Bounded parallel tile traversal. Tiles in each row band are processed by
/// the caller callback; completion is a full barrier before return.
ParallelRowsResult parallelTiles(scope bool delegate(Tile) @safe nothrow emit,
    size_t width, size_t height, size_t tileWidth, size_t tileHeight,
    Halo halo, size_t workerLimit = 0, size_t minimumRowChunk = 1) @trusted {
    if (emit is null || width == 0 || height == 0 || tileWidth == 0 || tileHeight == 0)
        return emit is null ? ParallelRowsResult.callbackFailed : ParallelRowsResult.completed;
    auto rows = (height + tileHeight - 1) / tileHeight;
    return parallelRows(rows, workerLimit, minimumRowChunk,
        (size_t first, size_t last) @safe nothrow {
            foreach (row; first .. last) {
                auto y = row * tileHeight;
                foreach (x; 0 .. (width + tileWidth - 1) / tileWidth) {
                    auto xx = x * tileWidth;
                    auto core = Roi(xx, y, xx + tileWidth > width ? width-xx : tileWidth,
                        y + tileHeight > height ? height-y : tileHeight);
                    if (!emit(Tile(core, expand(core, halo, width, height)))) return false;
                }
            }
            return true;
        });
}

enum SampleValidity : ubyte { valid = 0, nodata = 1, transparent = 2 }

bool contains(Roi roi, size_t width, size_t height) @safe pure nothrow @nogc {
    return roi.width != 0 && roi.height != 0 && roi.x <= width && roi.y <= height &&
        roi.width <= width - roi.x && roi.height <= height - roi.y;
}

bool validWindow(PlaneWindow p) @safe pure nothrow @nogc {
    return p.data !is null && p.width != 0 && p.height != 0 &&
        p.rowStride != 0 && p.sampleStride != 0;
}

/// Returns the byte/element offset for a local coordinate, after bounds check.
bool tryOffset(PlaneWindow p, size_t x, size_t y, out ptrdiff_t offset) @safe pure nothrow @nogc {
    if (!validWindow(p) || x >= p.width || y >= p.height) { offset = 0; return false; }
    offset = cast(ptrdiff_t)y * p.rowStride + cast(ptrdiff_t)x * p.sampleStride;
    return true;
}

/// Combines an optional validity plane and alpha plane. Alpha is normalized
/// to [0,1]; NoData always wins over alpha.
bool isUsable(scope const(ubyte)[] validity, scope const(ubyte)[] alpha,
    size_t index, float minimumAlpha = 0.0f) @safe pure nothrow @nogc {
    if (validity.length != 0 && (index >= validity.length || validity[index] == 0)) return false;
    if (alpha.length != 0 && (index >= alpha.length || cast(float)alpha[index] / 255.0f <= minimumAlpha)) return false;
    return true;
}

/// Copies a strided ROI into a dense plane. The caller supplies element size
/// through `T`; no allocation or ownership is hidden by the contract.
bool copyRoi(T)(PlaneWindow p, Roi roi, ref T[] destination) @safe {
    if (!validWindow(p) || !contains(roi, p.width, p.height) || destination.length < roi.width * roi.height) return false;
    foreach (y; 0 .. roi.height) foreach (x; 0 .. roi.width) {
        ptrdiff_t off;
        if (!tryOffset(p, roi.x + x, roi.y + y, off)) return false;
        destination[y * roi.width + x] = (cast(const(T)*)p.data)[off / T.sizeof];
    }
    return true;
}

