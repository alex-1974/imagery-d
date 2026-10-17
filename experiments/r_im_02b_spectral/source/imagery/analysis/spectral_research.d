/++
 R-IM-02b experiment: normalized band difference after EXPLICIT grid
 alignment. This is NOT a public imagery-d source/API or a sensor adapter.

 Real pixels, output storage and masks are owned by raster-d. Band IDs
 and numeric values are supplied explicitly, not inferred from band index.
 There is NO reprojection, resampling, or native grid resolution selection.
+/
module imagery.analysis.spectral_research;

import raster : RasterView, WritableRasterView, Region2D;

/// This is a caller-declared grid identity, NOT a CRS transform or proof
/// that independently measured scenes are truly registered.
struct ResearchGrid
{
    ulong frameId; // 0 means unbound, not a claimed coordinate frame.
    double originX;
    double originY;
    double stepX;
    double stepY;
}

enum ResearchUnit : ubyte
{
    unspecified,
    reflectance,
    radiance,
    otherConsistentUnit
}

struct ResearchNoData(T)
{
    bool enabled;
    T sentinel;
}

struct ResearchSpectralBand(T)
{
    RasterView!T pixels;
    size_t plane;
    uint bandId; // caller-declared identity, independent from raster plane
    ResearchGrid grid;
    ResearchUnit unit;
    bool calibrated; // if false, no physical value is declared
    double scale;
    double offset;
    ResearchNoData!T noData;
}

enum ResearchSpectralError : ubyte
{
    none,
    invalidBand,
    mismatchedGrid,
    invalidCalibration,
    invalidMask,
    invalidRegion,
    invalidOutput,
    sampleFailure,
    invalidMetadata,
    invalidIdentity,
    invalidNoData
}

private bool finite(double x)
{
    return x >= -double.max && x <= double.max;
}

private bool validGrid(ResearchGrid grid)
{
    return grid.frameId != 0 &&
        finite(grid.originX) && finite(grid.originY) &&
        finite(grid.stepX) && finite(grid.stepY) &&
        grid.stepX != 0.0 && grid.stepY != 0.0;
}

private bool sameGrid(ResearchGrid a, ResearchGrid b)
{
    return a.frameId == b.frameId &&
        a.originX == b.originX && a.originY == b.originY &&
        a.stepX == b.stepX && a.stepY == b.stepY;
}

private bool contains(Region2D region, size_t width, size_t height)
{
    return region.width != 0 && region.height != 0 &&
        region.x <= width && region.y <= height &&
        region.width <= width - region.x &&
        region.height <= height - region.y;
}

/++
 Compute normalized difference (A - B) / (A + B) from two explicitly
 calibrated bands describing the EXACT SAME source grid.

 This is an image-semantic experiment. It does not claim that declared
 grid metadata is independently verified or that equally sized inputs
 must be physically aligned. Resolution, origin and frame must match.
 A and B can be any selected physical bands with the SAME declared unit.
 Unspecified units and missing/nonfinite calibration are rejected.

 maskA/maskB each refer to the entire associated source grid; zero means
 invalid. A masked, non-finite, zero-denominator or non-finite-result pixel
 writes result=0.0f and validity=0 (no hidden epsilon and no clamping).
 Valid pixels write result as float and validity=255. A negative result or
 a value outside [-1,1] is not automatically invalid.

 The caller's separately owned destinations have one plane and ROI size.
 A deterministic preflight failure performs ZERO output writes. Once the
 pixel pass starts, unexpected raster access/write failures may leave a
 PARTIAL caller-owned destination: there is no rollback or physical
 source/destination alias enforcement via the public raster view API.
 The research consumer supplies independent, disjoint owners; this is
 explicitly NOT a safe general public caller-owned API.

 Inputs and both masks are borrowed synchronously; source owners must
 outlive the call and cannot be concurrently mutated without external
 synchronization. D's @safe annotation, if later established, would not
 in itself prove image-semantic nonalias.
+/
ResearchSpectralError tryNormalizedDifferenceIntoResearch(A, B)(
    scope ResearchSpectralBand!A a,
    scope ResearchSpectralBand!B b,
    Region2D region,
    scope RasterView!ubyte maskA,
    bool hasMaskA,
    scope RasterView!ubyte maskB,
    bool hasMaskB,
    scope WritableRasterView!float values,
    scope WritableRasterView!ubyte validity)
if ((is(A == ushort) || is(A == float)) &&
    (is(B == ushort) || is(B == float)))
{
    if (a.pixels.planeCount == 0 || b.pixels.planeCount == 0 ||
        a.plane >= a.pixels.planeCount ||
        b.plane >= b.pixels.planeCount ||
        a.bandId == 0 || b.bandId == 0)
        return ResearchSpectralError.invalidBand;

    if (!validGrid(a.grid) || !validGrid(b.grid) ||
        !sameGrid(a.grid, b.grid) ||
        a.pixels.width != b.pixels.width ||
        a.pixels.height != b.pixels.height)
        return ResearchSpectralError.mismatchedGrid;

    if (!a.calibrated || !b.calibrated ||
        a.unit == ResearchUnit.unspecified ||
        b.unit == ResearchUnit.unspecified || a.unit != b.unit ||
        !finite(a.scale) || !finite(a.offset) ||
        !finite(b.scale) || !finite(b.offset))
        return ResearchSpectralError.invalidCalibration;

    static if (is(A == float))
        if (a.noData.enabled && a.noData.sentinel != a.noData.sentinel)
            return ResearchSpectralError.invalidNoData;
    static if (is(B == float))
        if (b.noData.enabled && b.noData.sentinel != b.noData.sentinel)
            return ResearchSpectralError.invalidNoData;

    if (!contains(region, a.pixels.width, a.pixels.height))
        return ResearchSpectralError.invalidRegion;

    if ((hasMaskA && (maskA.planeCount != 1 ||
                      maskA.width != a.pixels.width ||
                      maskA.height != a.pixels.height)) ||
        (hasMaskB && (maskB.planeCount != 1 ||
                      maskB.width != b.pixels.width ||
                      maskB.height != b.pixels.height)))
        return ResearchSpectralError.invalidMask;

    if (values.planeCount != 1 || validity.planeCount != 1 ||
        values.width != region.width || values.height != region.height ||
        validity.width != region.width || validity.height != region.height)
        return ResearchSpectralError.invalidOutput;

    foreach (y; region.y .. region.y + region.height)
    foreach (x; region.x .. region.x + region.width)
    {
        bool valid = true;
        if (hasMaskA)
        {
            ubyte m;
            if (!maskA.trySample(0, x, y, m))
                return ResearchSpectralError.sampleFailure;
            valid = valid && m != 0;
        }
        if (hasMaskB)
        {
            ubyte m;
            if (!maskB.trySample(0, x, y, m))
                return ResearchSpectralError.sampleFailure;
            valid = valid && m != 0;
        }

        double index = 0.0;
        if (valid)
        {
            A rawA;
            B rawB;
            if (!a.pixels.trySample(a.plane, x, y, rawA) ||
                !b.pixels.trySample(b.plane, x, y, rawB))
                return ResearchSpectralError.sampleFailure;

            if ((a.noData.enabled && rawA == a.noData.sentinel) ||
                (b.noData.enabled && rawB == b.noData.sentinel))
                valid = false;

            const physicalA = cast(double)rawA * a.scale + a.offset;
            const physicalB = cast(double)rawB * b.scale + b.offset;
            const denominator = physicalA + physicalB;
            if (!valid || !finite(physicalA) || !finite(physicalB) ||
                !finite(denominator) || denominator == 0.0)
                valid = false;
            else
            {
                index = (physicalA - physicalB) / denominator;
                if (!finite(index) ||
                    index > cast(double)float.max ||
                    index < -cast(double)float.max)
                    valid = false;
            }
        }

        const localX = x - region.x;
        const localY = y - region.y;
        if (!values.trySetSample(0, localX, localY,
                valid ? cast(float)index : 0.0f) ||
            !validity.trySetSample(0, localX, localY,
                valid ? cast(ubyte)255 : cast(ubyte)0))
            return ResearchSpectralError.sampleFailure;
    }
    return ResearchSpectralError.none;
}
