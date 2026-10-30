module app;

import candidate :
    OverlapBlendError, tryBlendLinearSrgbOverlapOwned;
import core.stdc.stdlib : free, malloc;
import std.math : floor, pow;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;

enum width = 260;
enum height = 9;
enum fullRoi = Region2D(2, 1, 256, 7);

private void need(bool condition, string message)
{
    if (!condition)
        throw new Exception("M5 overlap seam blend: " ~ message);
}

private RasterLease!ubyte allocateImage(
    size_t imageWidth, size_t imageHeight, size_t channels,
    bool planar, bool reverseRows = false, bool reverseSamples = false)
@trusted
{
    const bytes = imageWidth * imageHeight * channels;
    auto memory = malloc(bytes);
    need(memory !is null, "allocate fixture");
    OwnedByteResource resource;
    if (!tryAdoptMallocResource(memory, bytes, resource))
    {
        free(memory);
        need(false, "adopt fixture");
    }
    auto layouts = new PlaneByteLayout[](channels);
    if (planar)
    {
        const rowBytes = imageWidth;
        foreach (component; 0 .. channels)
            layouts[component] = PlaneByteLayout(
                component * imageWidth * imageHeight +
                    (reverseRows ? (imageHeight - 1) * rowBytes : 0) +
                    (reverseSamples ? imageWidth - 1 : 0),
                reverseRows ? -cast(ptrdiff_t)rowBytes :
                    cast(ptrdiff_t)rowBytes,
                reverseSamples ? -1 : 1);
    }
    else
    {
        const rowBytes = imageWidth * channels;
        foreach (component; 0 .. channels)
            layouts[component] = PlaneByteLayout(
                component +
                    (reverseRows ? (imageHeight - 1) * rowBytes : 0) +
                    (reverseSamples ? (imageWidth - 1) * channels : 0),
                reverseRows ? -cast(ptrdiff_t)rowBytes :
                    cast(ptrdiff_t)rowBytes,
                reverseSamples ? -cast(ptrdiff_t)channels :
                    cast(ptrdiff_t)channels);
    }
    RasterLease!ubyte owner;
    need(tryImportOwnedRaster!ubyte(resource, layouts[],
        Region2D(0, 0, imageWidth, imageHeight), owner).ok,
        "import fixture");
    return owner;
}

private ubyte sourceByte(
    bool second, size_t component, size_t x, size_t y)
{
    if (y == fullRoi.y)
        return second ? 255 : 0;
    if (second)
        return cast(ubyte)(255 -
            ((x * 29 + y * 11 + component * 43 + 7) & 255));
    return cast(ubyte)((x * 17 + y * 31 + component * 67 + 19) & 255);
}

private ubyte weightByte(size_t x)
{
    if (x < fullRoi.x || x >= fullRoi.x + fullRoi.width)
        return 0;
    return cast(ubyte)(x - fullRoi.x);
}

private void initializeSources(
    ref RasterLease!ubyte sourceA,
    ref RasterLease!ubyte sourceB,
    ref RasterLease!ubyte weights)
{
    bool writableA, writableB, writableWeights;
    scope auto a = sourceA.tryWritableView(writableA);
    scope auto b = sourceB.tryWritableView(writableB);
    scope auto w = weights.tryWritableView(writableWeights);
    need(writableA && writableB && writableWeights, "fixtures writable");
    foreach (y; 0 .. height)
    foreach (x; 0 .. width)
    {
        foreach (component; 0 .. 3)
        {
            need(a.trySetSample(component, x, y,
                sourceByte(false, component, x, y)), "initialize A");
            need(b.trySetSample(component, x, y,
                sourceByte(true, component, x, y)), "initialize B");
        }
        need(w.trySetSample(0, x, y, weightByte(x)),
            "initialize weights");
    }
}

private double decodeOracle(ubyte encoded)
{
    const value = cast(double)encoded / 255.0;
    if (value <= 0.04045)
        return value / 12.92;
    return pow((value + 0.055) / 1.055, 2.4);
}

private ubyte encodeOracle(double linear)
{
    const encoded = linear <= 0.0031308 ? linear * 12.92 :
        1.055 * pow(linear, 1.0 / 2.4) - 0.055;
    return cast(ubyte)cast(uint)floor(encoded * 255.0 + 0.5);
}

private ubyte expectedByte(size_t component, size_t x, size_t y)
{
    const factor = cast(double)weightByte(x) / 255.0;
    const linear = decodeOracle(sourceByte(false, component, x, y)) *
            (1.0 - factor) +
        decodeOracle(sourceByte(true, component, x, y)) * factor;
    return encodeOracle(linear);
}

private void checkAgainstOracle(
    scope RasterView!ubyte result,
    Region2D roi,
    ref size_t checks,
    ref uint maximumError)
{
    need(result.width == roi.width && result.height == roi.height &&
        result.planeCount == 3, "owned result shape");
    foreach (y; 0 .. roi.height)
    foreach (x; 0 .. roi.width)
    foreach (component; 0 .. 3)
    {
        ubyte actual;
        need(result.trySample(component, x, y, actual), "read result");
        const expected = expectedByte(component, roi.x + x, roi.y + y);
        const error = actual > expected ? actual - expected : expected - actual;
        if (error > maximumError)
            maximumError = error;
        need(error <= 1, "independent sRGB oracle tolerance");
        ++checks;
    }
}

private void verifySuccessMatrix()
{
    size_t oracleChecks;
    size_t partitionChecks;
    uint maximumError;
    foreach (layoutCase; 0 .. 8)
    {
        auto sourceA = allocateImage(width, height, 3,
            (layoutCase & 1) != 0, (layoutCase & 2) != 0,
            (layoutCase & 4) != 0);
        auto sourceB = allocateImage(width, height, 3,
            (layoutCase & 1) == 0, (layoutCase & 4) != 0,
            (layoutCase & 2) != 0);
        auto weights = allocateImage(width, height, 1, true,
            (layoutCase & 2) == 0, (layoutCase & 1) != 0);
        initializeSources(sourceA, sourceB, weights);

        RasterLease!ubyte whole;
        const wholeBudget = fullRoi.width * fullRoi.height * 3;
        need(tryBlendLinearSrgbOverlapOwned(sourceA.view(), sourceB.view(),
            weights.view(), fullRoi, wholeBudget, whole) ==
            OverlapBlendError.none, "blend full overlap");
        checkAgainstOracle(whole.view(), fullRoi, oracleChecks, maximumError);

        const leftRoi = Region2D(fullRoi.x, fullRoi.y,
            fullRoi.width / 2, fullRoi.height);
        const rightRoi = Region2D(fullRoi.x + fullRoi.width / 2,
            fullRoi.y, fullRoi.width / 2, fullRoi.height);
        RasterLease!ubyte left, right;
        need(tryBlendLinearSrgbOverlapOwned(sourceA.view(), sourceB.view(),
            weights.view(), leftRoi, leftRoi.width * leftRoi.height * 3,
            left) == OverlapBlendError.none, "blend left partition");
        need(tryBlendLinearSrgbOverlapOwned(sourceA.view(), sourceB.view(),
            weights.view(), rightRoi, rightRoi.width * rightRoi.height * 3,
            right) == OverlapBlendError.none, "blend right partition");
        scope auto wholeView = whole.view();
        scope auto leftView = left.view();
        scope auto rightView = right.view();
        foreach (y; 0 .. fullRoi.height)
        foreach (x; 0 .. fullRoi.width)
        foreach (component; 0 .. 3)
        {
            ubyte expected, actual;
            need(wholeView.trySample(component, x, y, expected),
                "whole partition reference");
            const fromLeft = x < leftRoi.width;
            need((fromLeft ? leftView : rightView).trySample(
                component, fromLeft ? x : x - leftRoi.width, y, actual) &&
                actual == expected, "whole/partition seam equality");
            ++partitionChecks;
        }

        // The black-to-white row proves linear-light rather than encoded-byte
        // interpolation: 50% linear light encodes near 188, not 128.
        ubyte midpoint, first, last, previous;
        need(wholeView.trySample(0, 128, 0, midpoint) && midpoint == 188,
            "linear-light midpoint");
        need(wholeView.trySample(0, 0, 0, first) && first == 0 &&
            wholeView.trySample(0, 255, 0, last) && last == 255,
            "exact blend endpoints");
        previous = first;
        foreach (x; 1 .. fullRoi.width)
        {
            ubyte current;
            need(wholeView.trySample(0, x, 0, current) && current >= previous,
                "monotonic feather ramp");
            previous = current;
        }
    }
    need(oracleChecks == 43_008 && partitionChecks == 43_008,
        "complete matrix counts");
    writeln("M5_OVERLAP_SEAM_BLEND=PASS;outputs:24,oracle_checks:43008," ~
        "partition_checks:43008,max_byte_error:", maximumError,
        ",weights:0..255,linear_midpoint:188,layouts:8");
}

private void verifyFailures()
{
    auto sourceA = allocateImage(width, height, 3, false);
    auto sourceB = allocateImage(width, height, 3, true);
    auto weights = allocateImage(width, height, 1, true);
    initializeSources(sourceA, sourceB, weights);
    auto prior = allocateImage(1, 1, 3, false);
    {
        bool writable;
        scope auto output = prior.tryWritableView(writable);
        need(writable && output.trySetSample(0, 0, 0, 211),
            "prior sentinel");
    }
    void retained(OverlapBlendError observed, OverlapBlendError expected,
        string label)
    {
        ubyte sentinel;
        scope auto result = prior.view();
        need(observed == expected && result.width == 1 &&
            result.trySample(0, 0, 0, sentinel) && sentinel == 211,
            label ~ " preserves prior publication");
    }

    auto wrongSource = allocateImage(width - 1, height, 3, false);
    retained(tryBlendLinearSrgbOverlapOwned(sourceA.view(), wrongSource.view(),
        weights.view(), fullRoi, 5_376, prior),
        OverlapBlendError.invalidSource, "source grid mismatch");
    auto wrongWeights = allocateImage(width, height, 3, false);
    retained(tryBlendLinearSrgbOverlapOwned(sourceA.view(), sourceB.view(),
        wrongWeights.view(), fullRoi, 5_376, prior),
        OverlapBlendError.invalidWeights, "weight planes");
    retained(tryBlendLinearSrgbOverlapOwned(sourceA.view(), sourceB.view(),
        weights.view(), Region2D(0, 0, 0, 1), 5_376, prior),
        OverlapBlendError.invalidRegion, "empty ROI");
    retained(tryBlendLinearSrgbOverlapOwned(sourceA.view(), sourceB.view(),
        weights.view(), Region2D(width - 1, 0, 2, 1), 5_376, prior),
        OverlapBlendError.invalidRegion, "outside ROI");
    retained(tryBlendLinearSrgbOverlapOwned(sourceA.view(), sourceB.view(),
        weights.view(), fullRoi, 5_375, prior),
        OverlapBlendError.resultExceedsBudget, "short budget");
}

void main()
{
    verifySuccessMatrix();
    verifyFailures();
}
