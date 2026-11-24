/**
 * Run an image operation on regions and tiles.
 *
 * Use `parallelTiles` when an operation needs neighboring pixels. The callback
 * receives a tile to read and the smaller core region to publish.
 *
 * Example:
 * ---
 * parallelTiles((tile) @safe nothrow {
 *     // process tile.halo, publish tile.core
 *     return true;
 * }, 1920, 1080, 512, 512, neighbourhoodHalo(1), 4);
 * ---
 */
module imagery.analysis.execution;

import raster.data_plane : RasterPlaneWindow;
import raster.parallel_rows : ParallelRowsResult, parallelRows;

/++
 Describe a borrowed float32 plane with explicit byte strides.

 The pointer denotes the local top-left sample; originX/originY locate it in
 an external grid. Keep the backing alive while using the window. `.init`
 has no data and is rejected by validWindow. Strides are byte offsets for
 numeric offset inspection. This descriptor does not validate allocation
 bounds and cannot authorize pixel access; use RasterPlaneWindow for copying.
+/
struct PlaneWindow {
    /++
     Borrowed pointer to the local top-left float sample.
    +/
    const(float)* data;
    /++
     Window width in pixels.
    +/
    size_t width;
    /++
     Window height in pixels.
    +/
    size_t height;
    /++
     Signed distance between rows in bytes.
    +/
    ptrdiff_t rowStride;
    /++
     Signed distance between adjacent columns in bytes.
    +/
    ptrdiff_t sampleStride;
    /++
     Global column coordinate of the local top-left sample.
    +/
    size_t originX;
    /++
     Global row coordinate of the local top-left sample.
    +/
    size_t originY;
}

/++
 Describe a half-open pixel rectangle with origin x/y and dimensions width/height. `.init` is empty.
+/
struct Roi {
    /++
 Left column coordinate.
+/
size_t x;
    /++
 Top row coordinate.
+/
size_t y;
    /++
 Number of columns.
+/
size_t width;
    /++
 Number of rows.
+/
size_t height; }
/++
 Describe nonnegative input margins in pixels on each side of a region. `.init` requests no margin.
+/
struct Halo {
    /++
 Extra input columns on the left.
+/
size_t left;
    /++
 Extra input columns on the right.
+/
size_t right;
    /++
 Extra input rows above.
+/
size_t top;
    /++
 Extra input rows below.
+/
size_t bottom; }
/++
 Pair a writable output core with its input region including halo. `.init` contains two empty regions.
+/
struct Tile {
    /++
 Output rectangle to publish.
+/
Roi core;
    /++
 Input rectangle covering core and clipped neighborhood support.
+/
Roi halo; }

/++
 Expand a contained region by a halo, clipped to the image boundary.

 Params:
  roi = Region already contained in the width-by-height image.
  halo = Requested nonnegative input margins in pixels.
  width = Full image width in pixels.
  height = Full image height in pixels.

 Returns:
 The expanded half-open rectangle. Call contains first for untrusted regions.
+/
Roi expand(Roi roi, Halo halo, size_t width, size_t height) @safe pure nothrow @nogc {
    auto left = halo.left > roi.x ? roi.x : halo.left;
    auto top = halo.top > roi.y ? roi.y : halo.top;
    auto right = halo.right > width - roi.x - roi.width ? width - roi.x - roi.width : halo.right;
    auto bottom = halo.bottom > height - roi.y - roi.height ? height - roi.y - roi.height : halo.bottom;
    return Roi(roi.x-left, roi.y-top, roi.width+left+right, roi.height+top+bottom);
}

/// Clip a neighborhood read window while keeping its output core unchanged.
@safe unittest
{
    auto core=Roi(1,1,2,2);
    auto input=expand(core,neighbourhoodHalo(2),5,4);
    assert(input==Roi(0,0,5,4));
    assert(contains(core,5,4));
}


/++
 Request the same neighborhood radius on all four sides.

 Params:
  radius = Support radius in pixels.

 Returns:
 A symmetric halo.
+/
Halo neighbourhoodHalo(size_t radius) @safe pure nothrow @nogc { return Halo(radius, radius, radius, radius); }

@safe unittest {
    auto e = expand(Roi(2, 2, 4, 4), neighbourhoodHalo(2), 8, 8);
    assert(e.x == 0 && e.y == 0 && e.width == 8 && e.height == 8);
    size_t count;
    foreachTile((Tile t) @safe nothrow { ++count; assert(t.core.width != 0); }, 9, 5, 4, 4, neighbourhoodHalo(1));
    assert(count == 6);
}

/++
 Enumerates a deterministic row-major partition. `core` is the portion to
  publish; `halo` is the read window required by neighbourhood kernels.

 Params:
  emit = Synchronous tile callback; parallel variants may invoke it concurrently on disjoint cores.
  width = Image or grid width in pixels.
  height = Image or grid height in pixels.
  tileWidth = Positive output core width in pixels.
  tileHeight = Positive output core height in pixels.
  halo = Input margins in pixels around an output core.
+/
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

/++
 Bounded parallel tile traversal. Tiles in each row band are processed by
   the caller callback; completion is a full barrier before return.

 Params:
  emit = Synchronous tile callback; parallel variants may invoke it concurrently on disjoint cores.
  width = Image or grid width in pixels.
  height = Image or grid height in pixels.
  tileWidth = Positive output core width in pixels.
  tileHeight = Positive output core height in pixels.
  halo = Input margins in pixels around an output core.
  workerLimit = Upper limit on row workers; zero delegates the choice to raster-d.
  minimumRowChunk = Minimum row-band chunk per worker, at least one.

 Returns:
 raster-d row-execution status; completed means all callbacks finished, and callbackFailed includes a rejected callback.
+/
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

@safe unittest {
    size_t seen;
    auto result = parallelTiles((Tile t) @safe nothrow { ++seen; return true; }, 33, 17, 8, 8, neighbourhoodHalo(1), 1, 1);
    assert(result == ParallelRowsResult.completed && seen == 15);
}

/++
 Distinguish usable data, NoData and transparency. `.init` is valid; this enum alone does not prove a numeric sample exists.
+/
enum SampleValidity : ubyte {
    /++ The validity layer marks this sample usable. +/
    valid = 0,
    /++ The sample is missing, regardless of alpha. +/
    nodata = 1,
    /++ The sample has no visible contribution. +/
    transparent = 2 }

/++
 Check whether a rectangle fits inside a pixel extent without overflow.

 Params:
  roi = Half-open rectangle; empty rectangles can be contained.
  width = Image width in pixels.
  height = Image height in pixels.

 Returns:
 True if the rectangle lies inside the extent.
+/
bool contains(Roi roi, size_t width, size_t height) @safe pure nothrow @nogc {
    return roi.width != 0 && roi.height != 0 && roi.x <= width && roi.y <= height &&
        roi.width <= width - roi.x && roi.height <= height - roi.y;
}

/++
 Check the pointer, dimensions and nonzero strides of a plane descriptor.

   This does not establish allocation bounds, lifetime or absence of aliasing.

 Params:
  p = Borrowed float32 window to inspect.

 Returns:
 True for a nonnull pointer, nonempty extent and nonzero strides.
+/
bool validWindow(PlaneWindow p) @safe pure nothrow @nogc {
    return p.data !is null && p.width != 0 && p.height != 0 &&
        p.rowStride != 0 && p.sampleStride != 0;
}

/++
 Returns the byte offset for a local coordinate, after bounds check.

 Params:
  p = Borrowed float32 window with byte strides.
  x = Column coordinate in the specified grid/window.
  y = Row coordinate in the specified grid/window.
  offset = Receives the byte offset; reset to zero on entry and on failure.

 Returns:
 True with a computed byte offset, or false with offset zero for an invalid window/coordinate.
+/
bool tryOffset(PlaneWindow p, size_t x, size_t y, out ptrdiff_t offset) @safe pure nothrow @nogc {
    if (!validWindow(p) || x >= p.width || y >= p.height) { offset = 0; return false; }
    offset = cast(ptrdiff_t)y * p.rowStride + cast(ptrdiff_t)x * p.sampleStride;
    return true;
}

/++
 Combines an optional validity plane and alpha plane. Alpha is normalized
   to [0,1]; NoData always wins over alpha.

 Params:
  validity = Explicit validity data/callback; nonzero is valid and is independent of alpha.
  alpha = Optional byte alpha plane; zero has no contribution.
  index = Linear sample index into optional mask planes.
  minimumAlpha = Normalized alpha cutoff in [0,1].

 Returns:
 True when optional validity and alpha data admit the sample at the requested index.
+/
bool isUsable(scope const(ubyte)[] validity, scope const(ubyte)[] alpha,
    size_t index, float minimumAlpha = 0.0f) @safe pure nothrow @nogc {
    if (validity.length != 0 && (index >= validity.length || validity[index] == 0)) return false;
    if (alpha.length != 0 && (index >= alpha.length || cast(float)alpha[index] / 255.0f <= minimumAlpha)) return false;
    return true;
}

/++
 Copy a validated scalar-plane region into dense caller-owned samples.

 Call inside raster.withPlane. Coordinates are local to its borrowed window,
 including when the parent RasterView is cropped. Raster-d interprets signed
 strides and sample alignment; this adapter does not reinterpret byte offsets.
 The source and destination must be disjoint and remain unchanged by other
 writers during the call. No window or sample reference is retained.

 T is ubyte, ushort, float or double. Samples retain their numeric values,
 including nonfinite values and signed zero; no image validity policy is inferred.

 Params:
  p = Read-only validated plane, borrowed for the enclosing withPlane callback.
  roi = Nonempty half-open pixel region inside p, in window-local coordinates.
  destination = Dense output of at least roi.width*roi.height samples; extra elements are untouched.
 Returns:
 True after copying. False before any writes for empty/out-of-bounds regions,
 overflowing sample counts or short output. An empty default window is rejected.
+/
bool copyRoi(T)(scope ref const RasterPlaneWindow!T p, Roi roi,
    scope T[] destination) @safe nothrow @nogc
if (is(T == ubyte) || is(T == ushort) || is(T == float) || is(T == double))
{
    if (!roi.width || !roi.height || !contains(roi, p.width, p.height) ||
        roi.width > size_t.max / roi.height ||
        destination.length < roi.width * roi.height) return false;
    foreach (y; 0 .. roi.height) foreach (x; 0 .. roi.width) {
        destination[y * roi.width + x] = p.load(roi.x + x, roi.y + y);
    }
    return true;
}

/// Copy inside a validated plane borrow; extra output samples remain unchanged.
@system unittest
{
    import core.stdc.stdlib : malloc;
    import raster : OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
        tryAdoptMallocResource, tryImportOwnedRaster, withPlane;
    auto memory = cast(float*)malloc(6 * float.sizeof);
    assert(memory !is null);
    foreach (i; 0 .. 6) memory[i] = cast(float)(i + 1);
    OwnedByteResource owner;
    assert(tryAdoptMallocResource(memory, 6 * float.sizeof, owner));
    PlaneByteLayout[1] layouts = [PlaneByteLayout(0, 3 * float.sizeof, float.sizeof)];
    RasterLease!float image;
    assert(tryImportOwnedRaster!float(owner, layouts[], Region2D(0, 0, 3, 2), image).ok);
    float[3] output = -1;
    bool copied;
    scope auto view = image.view;
    assert(withPlane(view, 0,
        (scope ref const RasterPlaneWindow!float window) @safe nothrow @nogc {
            copied = copyRoi(window, Roi(1, 0, 2, 1), output[]);
        }));
    assert(copied && output == [2, 3, -1]);
}

/++
 Identify the disabled pointer-only copy spelling for source migration.

 PlaneWindow carries no validated storage extent or typed backing provenance.
 This overload was never instantiable under its declared @safe contract.
 It is now explicitly deprecated and disabled. Use the RasterPlaneWindow
 overload inside raster.withPlane; no unchecked pointer access is admitted.

 Params:
  p = Pointer-only descriptor without validated backing extent.
  roi = Previously intended source-pixel rectangle.
  destination = Previously intended dense output; the overload cannot be called.

 Returns:
 No result is available; calls to this deprecated overload are rejected.
+/
deprecated("Use copyRoi with a validated raster.RasterPlaneWindow inside raster.withPlane")
@disable bool copyRoi(T)(PlaneWindow p, Roi roi, ref T[] destination) @safe;
