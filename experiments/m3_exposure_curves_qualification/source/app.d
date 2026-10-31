module app;
import core.stdc.stdlib : malloc;
import imagery : CurvePoint, Exposure, tryCurvesOwned, tryExposureOwned, ExposureCurvesError;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import std.stdio : writeln;

RasterLease!ubyte make(size_t w, size_t h, bool interleaved, bool reverse)
{
    auto memory = cast(ubyte*)malloc(w * h * 3); assert(memory !is null);
    foreach (i; 0 .. w * h * 3) memory[i] = cast(ubyte)((i * 19 + 5) & 255);
    OwnedByteResource owner; assert(tryAdoptMallocResource(memory, w * h * 3, owner));
    PlaneByteLayout[3] layouts;
    foreach (c; 0 .. 3) layouts[c] = interleaved
        ? PlaneByteLayout((reverse ? (h - 1) * w * 3 : 0) + c, reverse ? -cast(ptrdiff_t)(w * 3) : cast(ptrdiff_t)(w * 3), 3)
        : PlaneByteLayout(c * w * h + (reverse ? (h - 1) * w : 0), reverse ? -cast(ptrdiff_t)w : cast(ptrdiff_t)w, 1);
    RasterLease!ubyte result; assert(tryImportOwnedRaster!ubyte(owner, layouts[], Region2D(0, 0, w, h), result).ok); return result;
}

void main()
{
    enum w = 20, h = 12; bool[3] channels = [true, true, true]; auto points = [CurvePoint(0, 0), CurvePoint(0.5, 0.75), CurvePoint(1, 1)]; size_t checks;
    foreach (interleaved; [false, true]) foreach (reverse; [false, true])
    {
        auto input = make(w, h, interleaved, reverse); RasterLease!float exposure, curves;
        assert(tryExposureOwned(input.view(), Region2D(0, 0, w, h), channels[], Exposure(1), w * h * 3 * float.sizeof, exposure) == ExposureCurvesError.none);
        assert(tryCurvesOwned(input.view(), Region2D(0, 0, w, h), channels[], points[], w * h * 3 * float.sizeof, curves) == ExposureCurvesError.none);
        auto ev = exposure.view(); auto cv = curves.view(); foreach (y; 0 .. h) foreach (x; 0 .. w) foreach (c; 0 .. 3) { float a, b; assert(ev.trySample(c, x, y, a)); assert(cv.trySample(c, x, y, b)); assert(a >= 0 && a <= 1 && b >= 0 && b <= 1); checks += 2; }
    }
    writeln("M3_EXPOSURE_CURVES_QUALIFICATION=PASS;checks:", checks, ";layouts:4");
}
