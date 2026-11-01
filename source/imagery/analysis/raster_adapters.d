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

enum RasterAdapterError : ubyte {
    none, invalidSource, invalidRegion, invalidPlane, sampleFailure, bufferTooSmall
}

private bool contains(Region2D r, size_t w, size_t h) @safe pure nothrow @nogc {
    return r.width != 0 && r.height != 0 && r.x <= w && r.y <= h &&
        r.width <= w-r.x && r.height <= h-r.y;
}

/// Copies one raster plane ROI into a dense row-major buffer. The view owns
/// all physical layout and lifetime; the caller owns the destination buffer.
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

/// Reads a validity plane and converts raster-d's nonzero convention into a
/// compact boolean-like byte mask. This keeps NoData policy explicit.
RasterAdapterError tryReadValidity(scope RasterView!ubyte source, Region2D roi,
    ref ubyte[] destination) @safe {
    if (source.planeCount != 1) return RasterAdapterError.invalidPlane;
    auto status = tryReadPlane!ubyte(source, 0, roi, destination);
    if (status != RasterAdapterError.none) return status;
    foreach (ref v; destination[0 .. roi.width * roi.height]) v = v == 0 ? 0 : 1;
    return RasterAdapterError.none;
}

