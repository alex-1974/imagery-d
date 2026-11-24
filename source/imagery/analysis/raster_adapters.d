/**
 * Read image regions from a raster-d view.
 *
 * Use these helpers when an image operation expects a dense plane but the
 * source is a raster view.
 *
 * Example:
 * ---
 * float[] tile = new float[](256 * 256);
 * auto status = tryReadPlane(source, 0, Region2D(0, 0, 256, 256), tile);
 * ---
 */
module imagery.analysis.raster_adapters;

import raster : RasterView, Region2D;

/++
 Report scalar-plane adapter status. `.init` is none; only the returned status establishes success.
+/
enum RasterAdapterError : ubyte {
    /++ The operation completed successfully. +/
    none,
    /++ Source shape, identity or sample descriptor is invalid. +/
    invalidSource,
    /++ The requested pixel rectangle is empty or outside the source extent. +/
    invalidRegion,
    /++ A requested plane is absent or has an invalid layout. +/
    invalidPlane,
    /++ A raster sample could not be read or written. +/
    sampleFailure,
    /++ The caller-provided destination has insufficient capacity. +/
    bufferTooSmall
}

private bool contains(Region2D r, size_t w, size_t h) @safe pure nothrow @nogc {
    return r.width != 0 && r.height != 0 && r.x <= w && r.y <= h &&
        r.width <= w-r.x && r.height <= h-r.y;
}

/++
 Copies one raster plane ROI into a dense row-major buffer. The view owns
   all physical layout and lifetime; the caller owns the destination buffer.

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  plane = Zero-based input plane index.
  roi = Nonempty half-open source-pixel rectangle, fully contained in the input.
  destination = Caller-owned output storage, or the destination pixel/raster for compositing.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
RasterAdapterError tryReadPlane(T)(scope RasterView!T source, size_t plane,
    Region2D roi, ref T[] destination) @safe
if (is(T == ubyte) || is(T == ushort) || is(T == float) || is(T == double)) {
    if (source.planeCount == 0 || source.width == 0 || source.height == 0)
        return RasterAdapterError.invalidSource;
    if (plane >= source.planeCount) return RasterAdapterError.invalidPlane;
    if (!contains(roi, source.width, source.height)) return RasterAdapterError.invalidRegion;
    if (destination.length < roi.width * roi.height) return RasterAdapterError.bufferTooSmall;
    foreach (y; 0 .. roi.height) foreach (x; 0 .. roi.width) {
        T value;
        if (!source.trySample(plane, roi.x + x, roi.y + y, value))
            return RasterAdapterError.sampleFailure;
        destination[y * roi.width + x] = value;
    }
    return RasterAdapterError.none;
}

/// Read a public raster view into a dense caller-owned plane.
@system unittest
{
    import core.stdc.stdlib : malloc;
    import raster : OwnedByteResource,PlaneByteLayout,RasterLease,Region2D,
        tryAdoptMallocResource,tryImportOwnedRaster;
    auto memory=cast(ubyte*)malloc(2);
    assert(memory !is null);
    memory[0]=7; memory[1]=9;
    OwnedByteResource owner;
    assert(tryAdoptMallocResource(memory,2,owner));
    PlaneByteLayout[1] layouts;
    foreach(c;0..1) layouts[c]=PlaneByteLayout(c,2,1);
    RasterLease!ubyte input;
    assert(tryImportOwnedRaster!ubyte(owner,layouts[],Region2D(0,0,2,1),input).ok);
    ubyte[] dense=new ubyte[2];
    assert(tryReadPlane!ubyte(input.view,0,Region2D(0,0,2,1),dense)==RasterAdapterError.none);
    assert(dense==[7,9]);
}


/++
 Reads a validity plane and converts raster-d's nonzero convention into a
   compact boolean-like byte mask. This keeps NoData policy explicit.

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  roi = Nonempty half-open source-pixel rectangle, fully contained in the input.
  destination = Caller-owned output storage, or the destination pixel/raster for compositing.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
RasterAdapterError tryReadValidity(scope RasterView!ubyte source, Region2D roi,
    ref ubyte[] destination) @safe {
    if (source.planeCount != 1) return RasterAdapterError.invalidPlane;
    auto status = tryReadPlane!ubyte(source, 0, roi, destination);
    if (status != RasterAdapterError.none) return status;
    foreach (ref v; destination[0 .. roi.width * roi.height]) v = v == 0 ? 0 : 1;
    return RasterAdapterError.none;
}
