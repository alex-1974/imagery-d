module app;

import core.stdc.stdlib : malloc;
import imagery : BrightnessContrast, BrightnessContrastError,
    tryBrightnessContrastOwned;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import std.stdio : writeln;

RasterLease!ubyte source(size_t w, size_t h, bool interleaved)
{
    const bytes = w * h * 3;
    auto memory = cast(ubyte*) malloc(bytes);
    assert(memory !is null);
    foreach (i; 0 .. bytes) memory[i] = cast(ubyte)((i * 13 + 7) & 255);
    OwnedByteResource owner;
    assert(tryAdoptMallocResource(memory, bytes, owner));
    PlaneByteLayout[3] layouts;
    foreach (c; 0 .. 3)
        layouts[c] = interleaved
            ? PlaneByteLayout(c, cast(ptrdiff_t)(w * 3), 3)
            : PlaneByteLayout(c * w * h, cast(ptrdiff_t)w, 1);
    RasterLease!ubyte result;
    assert(tryImportOwnedRaster!ubyte(owner, layouts[],
        Region2D(0, 0, w, h), result).ok);
    return result;
}

void main()
{
    enum w = 32, h = 24;
    bool[3] channels = [true, true, true];
    size_t checks;
    foreach (interleaved; [false, true])
    {
        auto input = source(w, h, interleaved);
        RasterLease!float result;
        auto status = tryBrightnessContrastOwned(input.view(),
            Region2D(0, 0, w, h), channels[], BrightnessContrast(0.1, 0.4),
            w * h * 3 * float.sizeof, result);
        assert(status == BrightnessContrastError.none);
        auto view = result.view();
        foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        foreach (c; 0 .. 3)
        {
            float value;
            assert(view.trySample(c, x, y, value));
            assert(value >= 0.0f && value <= 1.0f);
            ++checks;
        }
    }
    writeln("M3_BRIGHTNESS_CONTRAST_QUALIFICATION=PASS;component_checks:", checks,
        ";layouts:planar,interleaved;partition_oracle:pending");
}
