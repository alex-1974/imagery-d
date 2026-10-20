/++
 Bounded paired native Release benchmark consumer for one concrete M3 Levels
 operation. The independent baseline is an ordinary raster-d-owned output
 with equivalent gamma-2 scalar Levels and graded selection, expressed with
 sqrt instead of pow. It is NOT a cross-language speed claim or a stable
 fixed-frequency workstation benchmark.
+/
module app;

import core.stdc.stdlib : malloc;
import core.time : MonoTime;
import std.algorithm.sorting : sort;
import std.math : fabs, sqrt;
import std.stdio : writefln, writeln;
import imagery : Levels, LevelsError, tryLevelsOwned;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;

// D's default double.init is NaN, so explicitly seed the sink.
private double sampleSink = 0.0;

private void need(bool b, string message)
{
    if (!b)
        throw new Exception("M3 Levels paired benchmark: " ~ message);
}

private RasterLease!T allocateImage(T)(size_t width, size_t height, size_t bands)
{
    // Bounded caller sizes are enforced in runShape; no generic allocator API.
    const bytes = width * height * bands * T.sizeof;
    auto mem = malloc(bytes);
    need(mem !is null, "malloc bounded image");
    OwnedByteResource resource;
    need(tryAdoptMallocResource(mem, bytes, resource), "adopt raster payload");

    auto layouts = new PlaneByteLayout[](bands);
    foreach (c; 0 .. bands)
        layouts[c] = PlaneByteLayout(c * T.sizeof,
            cast(ptrdiff_t)(width * bands * T.sizeof),
            cast(ptrdiff_t)(bands * T.sizeof));
    RasterLease!T owner;
    need(tryImportOwnedRaster!T(
        resource, layouts[], Region2D(0, 0, width, height), owner).ok,
        "import raster owner");
    return owner;
}

private RasterLease!float referenceLevels(
    scope RasterView!ubyte source,
    scope RasterView!ubyte mask,
    scope const(bool)[] selected,
    Region2D roi,
    Levels settings)
{
    auto result = allocateImage!float(roi.width, roi.height, source.planeCount);
    bool writable;
    scope auto target = result.tryWritableView(writable);
    need(writable, "reference writable output");

    // Semantically equivalent gamma=2 mapping with independent sqrt primitive.
    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        ubyte byteStrength;
        need(mask.trySample(0, x, y, byteStrength), "mask sample");
        const strength = cast(double)byteStrength / 255.0;
        foreach (c; 0 .. source.planeCount)
        {
            ubyte raw;
            need(source.trySample(c, x, y, raw), "source sample");
            const v = cast(double)raw / 255.0;
            double outValue = v;
            if (selected[c] && byteStrength != 0)
            {
                double t = (v - settings.inputBlack) /
                    (settings.inputWhite - settings.inputBlack);
                if (t < 0.0) t = 0.0;
                if (t > 1.0) t = 1.0;
                const mapped = settings.outputBlack +
                    sqrt(t) * (settings.outputWhite - settings.outputBlack);
                outValue = v + strength * (mapped - v);
            }
            need(target.trySetSample(
                c, x - roi.x, y - roi.y, cast(float)outValue),
                "reference sample write");
        }
    }
    return result;
}

private void compareComplete(
    scope RasterView!float actual, scope RasterView!float reference,
    size_t width, size_t height, out double maximumError)
{
    maximumError = 0.0;
    foreach (y; 0 .. height)
    foreach (x; 0 .. width)
    foreach (c; 0 .. 4)
    {
        float a, b;
        need(actual.trySample(c,x,y,a) &&
             reference.trySample(c,x,y,b), "independent comparison read");
        const e = fabs(cast(double)a - cast(double)b);
        if (e > maximumError)
            maximumError = e;
        need(e <= 0.000002, "paired reference numerical mismatch");
    }
}

private long oneTimed(
    bool candidate, scope RasterView!ubyte source,
    scope RasterView!ubyte mask, scope const(bool)[] selected,
    Region2D roi, Levels settings, size_t budget)
{
    auto start = MonoTime.currTime;
    RasterLease!float owned;
    if (candidate)
    {
        need(tryLevelsOwned!ubyte(source, roi, selected, settings,
            mask, budget, owned) == LevelsError.none,
            "candidate Levels failed");
    }
    else
        owned = referenceLevels(source, mask, selected, roi, settings);
    const elapsed = (MonoTime.currTime - start).total!"usecs";
    scope auto result = owned.view();
    float sample;
    need(result.trySample(0, roi.width / 2, roi.height / 2, sample),
         "timed output retained and sampled");
    sampleSink += sample;
    return elapsed;
}

private void runShape(size_t width, size_t height)
{
    need(width > 0 && height > 0 && width <= 1024 && height <= 768,
         "fixture shape is deliberately bounded");
    auto source = allocateImage!ubyte(width, height, 4);
    auto mask = allocateImage!ubyte(width, height, 1);
    bool writable;
    {
        scope auto inputWriter = source.tryWritableView(writable);
        need(writable, "source writable");
        foreach (y; 0 .. height)
        foreach (x; 0 .. width)
        foreach (c; 0 .. 4)
            need(inputWriter.trySetSample(
                c, x, y, cast(ubyte)((x * 29 + y * 17 + c * 53) & 255)),
                "source fixture write");
    }
    {
        scope auto maskWriter = mask.tryWritableView(writable);
        need(writable, "mask writable");
        foreach (y; 0 .. height)
        foreach (x; 0 .. width)
        {
            const phase = (x + 2*y) % 3;
            need(maskWriter.trySetSample(0, x, y,
                cast(ubyte)(phase == 0 ? 0 : phase == 1 ? 128 : 255)),
                "mask fixture write");
        }
    }

    scope auto sourceView = source.view();
    scope auto maskView = mask.view();
    bool[4] affected = [true, true, true, false];
    const Levels settings = Levels(0.08, 0.91, 2.0, 0.05, 0.95);
    const roi = Region2D(0, 0, width, height);
    const size_t budget = width * height * 4 * float.sizeof;

    RasterLease!float candidateOwned;
    need(tryLevelsOwned!ubyte(sourceView,roi,affected[],
        settings,maskView,budget,candidateOwned) == LevelsError.none,
        "initial candidate oracle");
    auto referenceOwned = referenceLevels(
        sourceView, maskView, affected[], roi, settings);
    double maximumError;
    {
        scope auto candidateView = candidateOwned.view();
        scope auto refView = referenceOwned.view();
        compareComplete(candidateView,refView,width,height,maximumError);
    }

    // One pair per side of each ordering: varied order checks the hot-loop
    // confound without treating hosted CPU governor noise as a speed claim.
    foreach (warmup; 0 .. 2)
    {
        oneTimed(true,sourceView,maskView,affected[],roi,settings,budget);
        oneTimed(false,sourceView,maskView,affected[],roi,settings,budget);
    }
    long[7] candidateUs, referenceUs;
    foreach (i; 0 .. candidateUs.length)
    {
        if (i % 2 == 0)
        {
            candidateUs[i] = oneTimed(true,sourceView,maskView,
                                     affected[],roi,settings,budget);
            referenceUs[i] = oneTimed(false,sourceView,maskView,
                                     affected[],roi,settings,budget);
        }
        else
        {
            referenceUs[i] = oneTimed(false,sourceView,maskView,
                                     affected[],roi,settings,budget);
            candidateUs[i] = oneTimed(true,sourceView,maskView,
                                     affected[],roi,settings,budget);
        }
    }
    sort(candidateUs[]);
    sort(referenceUs[]);
    const candidateMedian = candidateUs[candidateUs.length/2];
    const referenceMedian = referenceUs[referenceUs.length/2];
    need(candidateMedian > 0 && referenceMedian > 0,
         "nonzero clock resolution");
    const ratio = cast(double)candidateMedian / referenceMedian;

    writefln("M3_LEVELS_PAIRED=width:%s,height:%s,build:LDC-Release," ~
       "candidate_median_us:%s,reference_sqrt_median_us:%s," ~
       "candidate/reference_ratio:%.4f,max_abs_error:%.9f,replicates:7," ~
       "order:alternating,scope:owned-ROI-masked-RGBA-float-output",
       width,height,candidateMedian,referenceMedian,ratio,maximumError);
}

void main()
{
    runShape(512, 384);
    runShape(1024, 768);
    need(sampleSink >= 0.0, "observable results");
    writeln("M3_LEVELS_PAIRED_PERF=PASS; paired reference, accuracy and bounded workload");
}
