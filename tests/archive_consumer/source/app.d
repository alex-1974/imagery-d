// This module is built in a DIFFERENT DUB project from a git-archive
// image-only source package. No module path references the source checkout.
module app;
import core.stdc.stdlib : malloc;
import std.math : sqrt;
import std.stdio : writeln;
import imagery : Levels, LevelsError, tryLevelsOwned,
    RgbHistogram256, RgbHistogramError, tryRgbHistogram256,
    tryRgbCumulativeCounts, tryRgbPercentile;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease,
    RasterView, Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

private void verify(bool ok, string message)
{
    if (!ok)
        throw new Exception("external archived consumer: " ~ message);
}

// We deliberately create image input using the separately installed
// raster-d API; no imagery-owned image buffer is manufactured.
private RasterLease!ubyte makeInput()
{
    enum length = 6;
    auto memory = cast(ubyte*) malloc(length);
    verify(memory !is null, "malloc RGB");
    OwnedByteResource owned;
    verify(tryAdoptMallocResource(memory, length, owned), "adopt RGB");
    const PlaneByteLayout[3] planes = [
        PlaneByteLayout(0, 6, 3),
        PlaneByteLayout(1, 6, 3),
        PlaneByteLayout(2, 6, 3)
    ];
    RasterLease!ubyte result;
    verify(tryImportOwnedRaster!ubyte(owned, planes[],
        Region2D(0, 0, 2, 1), result).ok, "import RGB");
    bool writable;
    {
        scope auto view = result.tryWritableView(writable);
        verify(writable, "writable image");
        verify(view.trySetSample(0, 0, 0, 0), "red0");
        verify(view.trySetSample(1, 0, 0, 64), "green0");
        verify(view.trySetSample(2, 0, 0, 255), "blue0");
        verify(view.trySetSample(0, 1, 0, 128), "red1");
        verify(view.trySetSample(1, 1, 0, 192), "green1");
        verify(view.trySetSample(2, 1, 0, 17), "blue1");
    }
    return result;
}

private RasterLease!ubyte makeMask()
{
    auto memory = cast(ubyte*)malloc(2);
    verify(memory !is null, "malloc mask");
    OwnedByteResource owned;
    verify(tryAdoptMallocResource(memory, 2, owned), "adopt mask");
    const PlaneByteLayout[1] planes = [PlaneByteLayout(0, 2, 1)];
    RasterLease!ubyte result;
    verify(tryImportOwnedRaster!ubyte(owned, planes[],
        Region2D(0, 0, 2, 1), result).ok, "import mask");
    bool writable;
    {
        scope auto view = result.tryWritableView(writable);
        verify(writable && view.trySetSample(0, 0, 0, 255) &&
            view.trySetSample(0, 1, 0, 0),
            "set mask full / zero");
    }
    return result;
}

// Compile the actual advertised API under @safe and DIP1000, using only
// the archived DUB dependency and separately installed raster-d package.
@safe private LevelsError apply(
    scope RasterView!ubyte image, scope RasterView!ubyte mask,
    size_t budget, ref RasterLease!float published)
{
    bool[3] chosen = [true, true, false];
    return tryLevelsOwned!ubyte(image, Region2D(0, 0, 2, 1),
        chosen[], Levels(0, 1, 2, 0, 1), mask, budget, published);
}

@safe private LevelsError applyWithoutMask(
    scope RasterView!ubyte image,
    size_t budget, ref RasterLease!float published)
{
    bool[3] chosen = [true, true, false];
    return tryLevelsOwned!ubyte(image, Region2D(0, 0, 2, 1),
        chosen[], Levels(0, 1, 2, 0, 1), budget, published);
}

private bool close(float observed, float expected)
{
    auto difference = observed - expected;
    return difference >= -0.000004f && difference <= 0.000004f;
}

void main()
{
    static assert(LevelsError.init == LevelsError.notAttempted);
    auto input = makeInput();
    auto selection = makeMask();
    RgbHistogram256 histogram, selected;
    verify(tryRgbHistogram256(input.view(), Region2D(0, 0, 2, 1), histogram)
        == RgbHistogramError.none, "archived RGB histogram");
    verify(histogram.includedPixels == 2 && histogram.excludedPixels == 0 &&
        histogram.bins[0][0] == 1 && histogram.bins[0][128] == 1 &&
        histogram.bins[1][64] == 1 && histogram.bins[1][192] == 1 &&
        histogram.bins[2][255] == 1 && histogram.bins[2][17] == 1 &&
        histogram.mean == [64.0, 128.0, 136.0],
        "archived independent RGB bins and means");
    ulong[256][3] cumulative;
    ubyte[3] percentile;
    verify(tryRgbCumulativeCounts(histogram, cumulative) &&
        cumulative[0][127] == 1 && cumulative[0][255] == 2 &&
        tryRgbPercentile(histogram, 50, percentile) &&
        percentile == [0, 64, 17],
        "archived RGB cumulative and percentile API");
    verify(tryRgbHistogram256(input.view(), Region2D(0, 0, 2, 1),
        selection.view(), selected) == RgbHistogramError.none &&
        selected.includedPixels == 1 && selected.excludedPixels == 1 &&
        selected.mean == [0.0, 64.0, 255.0],
        "archived binary selection histogram");
    RasterLease!float output;
    enum size_t exact = 2 * 1 * 3 * float.sizeof;
    verify(apply(input.view(), selection.view(), exact, output)
        == LevelsError.none, "external full-budget masked call");
    {
        scope auto view = output.view();
        verify(view.width == 2 && view.height == 1 &&
            view.planeCount == 3, "ROI-sized RGB float owner");
        float red, green, blue, secondRed, secondBlue;
        verify(view.trySample(0, 0, 0, red) &&
            view.trySample(1, 0, 0, green) &&
            view.trySample(2, 0, 0, blue) &&
            view.trySample(0, 1, 0, secondRed) &&
            view.trySample(2, 1, 0, secondBlue), "sample output");
        verify(close(red, 0.0f) &&
            close(green, cast(float)sqrt(64.0 / 255.0)) &&
            close(blue, 1.0f), "unmasked RGB gamma + channel passthrough");
        verify(close(secondRed, cast(float)(128.0 / 255.0)) &&
            close(secondBlue, cast(float)(17.0 / 255.0)),
            "zero-weight second pixel passthrough");
    }
    // Failed publication must not modify the previously owned result.
    verify(apply(input.view(), selection.view(), exact - 1, output)
        == LevelsError.resultExceedsBudget, "budget failure");
    {
        scope auto view = output.view();
        float remain;
        verify(view.trySample(1, 0, 0, remain) &&
            close(remain, cast(float)sqrt(64.0/255.0)),
            "prior owner preserved");
    }
    verify(applyWithoutMask(input.view(), exact, output) ==
        LevelsError.none, "externally importable unmasked overload");
    {
        scope auto view = output.view();
        float second;
        verify(view.trySample(0, 1, 0, second) &&
            close(second, cast(float)sqrt(128.0 / 255.0)),
            "nonmasked gamma2 on second pixel");
    }
    writeln("M3_LEVELS_ARCHIVED_EXTERNAL=PASS; archived-package DUB, " ~
        "@safe masked/unmasked, owned RGB, gamma, mask, budget and rollback");
}
