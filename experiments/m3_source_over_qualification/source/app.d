module app;

import core.stdc.stdlib : malloc;
import imagery : AlphaAssociation, SourceOverError, tryRgbaSourceOverOwned;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import std.stdio : writeln;

RasterLease!ubyte image(size_t w, size_t h, bool interleaved, bool reverse,
    ubyte seed)
{
    auto memory = cast(ubyte*)malloc(w * h * 4);
    assert(memory !is null);
    foreach (i; 0 .. w * h * 4) memory[i] = cast(ubyte)(seed + i * 7);
    OwnedByteResource owner;
    assert(tryAdoptMallocResource(memory, w * h * 4, owner));
    PlaneByteLayout[4] layouts;
    foreach (c; 0 .. 4)
        layouts[c] = interleaved
            ? PlaneByteLayout((reverse ? (h - 1) * w * 4 : 0) + c,
                reverse ? -cast(ptrdiff_t)(w * 4) : cast(ptrdiff_t)(w * 4), 4)
            : PlaneByteLayout(c * w * h + (reverse ? (h - 1) * w : 0),
                reverse ? -cast(ptrdiff_t)w : cast(ptrdiff_t)w, 1);
    RasterLease!ubyte result;
    assert(tryImportOwnedRaster!ubyte(owner, layouts[], Region2D(0, 0, w, h), result).ok);
    return result;
}

void main()
{
    enum w = 24, h = 16;
    size_t checks;
    foreach (interleaved; [false, true])
    foreach (reverse; [false, true])
    foreach (association; [AlphaAssociation.straight, AlphaAssociation.premultiplied])
    {
        auto source = image(w, h, interleaved, reverse, 11);
        auto destination = image(w, h, interleaved, reverse, 43);
        RasterLease!ubyte whole;
        assert(tryRgbaSourceOverOwned(source.view(), destination.view(),
            Region2D(0, 0, w, h), association, w * h * 4, whole) == SourceOverError.none);
        auto wholeView = whole.view();
        foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        foreach (c; 0 .. 4) { ubyte value; assert(wholeView.trySample(c, x, y, value)); ++checks; }
        RasterLease!ubyte top, bottom;
        assert(tryRgbaSourceOverOwned(source.view(), destination.view(),
            Region2D(0, 0, w, h / 2), association, w * h * 4, top) == SourceOverError.none);
        assert(tryRgbaSourceOverOwned(source.view(), destination.view(),
            Region2D(0, h / 2, w, h - h / 2), association, w * h * 4, bottom) == SourceOverError.none);
        auto topView = top.view(); auto bottomView = bottom.view();
        foreach (y; 0 .. h / 2)
        foreach (x; 0 .. w)
        foreach (c; 0 .. 4)
        { ubyte a, b; assert(wholeView.trySample(c, x, y, a)); assert(topView.trySample(c, x, y, b)); assert(a == b);
          assert(wholeView.trySample(c, x, y + h / 2, a)); assert(bottomView.trySample(c, x, y, b)); assert(a == b); checks += 2; }
    }
    writeln("M3_SOURCE_OVER_QUALIFICATION=PASS;checks:", checks,
        ";layouts:4;associations:2;partition_oracle:PASS");
}
