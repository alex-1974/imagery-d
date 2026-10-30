module app;

import core.stdc.stdlib : malloc;
import imagery : BrightnessContrast, BrightnessContrastError,
    tryBrightnessContrastOwned;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import std.stdio : writeln;

RasterLease!ubyte source(size_t w, size_t h, bool interleaved, bool reverse)
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
            ? PlaneByteLayout((reverse ? (h - 1) * w * 3 : 0) + c,
                reverse ? -cast(ptrdiff_t)(w * 3) : cast(ptrdiff_t)(w * 3), 3)
            : PlaneByteLayout(c * w * h + (reverse ? (h - 1) * w : 0),
                reverse ? -cast(ptrdiff_t)w : cast(ptrdiff_t)w, 1);
    RasterLease!ubyte result;
    assert(tryImportOwnedRaster!ubyte(owner, layouts[],
        Region2D(0, 0, w, h), result).ok);
    return result;
}

RasterLease!ubyte mask(size_t w, size_t h, ubyte value)
{
    auto memory = cast(ubyte*) malloc(w * h);
    assert(memory !is null);
    foreach (i; 0 .. w * h) memory[i] = value;
    OwnedByteResource owner;
    assert(tryAdoptMallocResource(memory, w * h, owner));
    PlaneByteLayout[1] layout = [PlaneByteLayout(0, cast(ptrdiff_t)w, 1)];
    RasterLease!ubyte result;
    assert(tryImportOwnedRaster!ubyte(owner, layout[], Region2D(0, 0, w, h), result).ok);
    return result;
}

void main()
{
    enum w = 32, h = 24;
    bool[3] channels = [true, true, true];
    size_t checks;
    foreach (interleaved; [false, true])
    foreach (reverse; [false, true])
    {
        auto input = source(w, h, interleaved, reverse);
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

        foreach (weight; [ubyte(0), ubyte(128), ubyte(255)])
        {
            auto selected = mask(w, h, weight);
            RasterLease!float masked;
            assert(tryBrightnessContrastOwned(input.view(), Region2D(0, 0, w, h),
                channels[], BrightnessContrast(0.1, 0.4), selected.view(),
                w * h * 3 * float.sizeof, masked) == BrightnessContrastError.none);
            auto maskedView = masked.view();
            float value;
            assert(maskedView.trySample(0, 0, 0, value));
            const original = cast(double)((7.0) / 255.0);
            const mapped = (original - 0.5) * 1.4 + 0.6;
            const expected = weight == 0 ? original : weight == 255 ? mapped :
                original + (128.0 / 255.0) * (mapped - original);
            assert(value >= expected - 0.00001f && value <= expected + 0.00001f);
            checks += 3;
        }

        // Whole-vs-partition oracle: two disjoint horizontal ROI packets
        // must equal the corresponding rows of the complete result.
        auto topInput = source(w, h, interleaved, reverse);
        auto bottomInput = source(w, h, interleaved, reverse);
        RasterLease!float top, bottom;
        assert(tryBrightnessContrastOwned(topInput.view(),
            Region2D(0, 0, w, h / 2), channels[],
            BrightnessContrast(0.1, 0.4), w * h * 3 * float.sizeof, top) ==
            BrightnessContrastError.none);
        assert(tryBrightnessContrastOwned(bottomInput.view(),
            Region2D(0, h / 2, w, h - h / 2), channels[],
            BrightnessContrast(0.1, 0.4), w * h * 3 * float.sizeof, bottom) ==
            BrightnessContrastError.none);
        auto topView = top.view();
        auto bottomView = bottom.view();
        foreach (y; 0 .. h / 2)
        foreach (x; 0 .. w)
        foreach (c; 0 .. 3)
        {
            float a, b;
            assert(view.trySample(c, x, y, a));
            assert(topView.trySample(c, x, y, b));
            assert(a == b);
            assert(view.trySample(c, x, y + h / 2, a));
            assert(bottomView.trySample(c, x, y, b));
            assert(a == b);
            checks += 2;
        }
    }
    writeln("M3_BRIGHTNESS_CONTRAST_QUALIFICATION=PASS;component_checks:", checks,
        ";layouts:planar,interleaved;partition_oracle:PASS");
}
