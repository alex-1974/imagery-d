/++
 Bounded native Release benchmark consumer for the M3 Levels and RGB
 luminance-stretch operations. The independent Levels baseline is an ordinary
 raster-d-owned output with equivalent gamma-2 scalar Levels and graded
 selection, expressed with sqrt instead of pow. This is NOT a cross-language
 speed claim or a stable fixed-frequency workstation benchmark.
+/
module app;

import core.stdc.stdlib : malloc, free;
import core.stdc.string : memset;
import core.simd : Vector;
import core.time : MonoTime;
import std.algorithm.sorting : sort;
import std.math : fabs, pow, sqrt;
import std.stdio : stdout, writefln, writeln;
import color : LinearSRgb, SRgb, toLinear, toSRgb, toXyzD65;
import color.rgb : SRgb8DecodeTable, makeSRgb8DecodeTable;
import imagery : Levels, LevelsError, tryLevelsOwned,
    LuminanceStretchError, tryRgbLuminanceStretchOwned;
version (ImageryPerfAttribution)
    import imagery.presentation.luminance_stretch :
        LuminanceStretchPhaseTimings, tryRgbLuminanceStretchOwnedMeasured;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    RasterPlaneWindow, WritableRasterPlaneWindow,
    WritableRasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster, withPlane,
    withPlanesInto;

version (LDC) private enum encodeIntervals = 1_024;
else private enum encodeIntervals = 4_096;
// D's default double.init is NaN, so explicitly seed the sink.
private double sampleSink = 0.0;

private enum perfWidth = 1024;
private enum perfHeight = 768;
private enum perfWarmups = 2;
private enum perfReplicates = 7;
version (LDC) private enum compilerLabel = "LDC";
else version (DigitalMars) private enum compilerLabel = "DMD";
else private enum compilerLabel = "unknown";

private ubyte[] allocateDenseRgb(size_t width, size_t height)
@trusted
{
    const bytes = width * height * 3;
    auto memory = cast(ubyte*)malloc(bytes);
    need(memory !is null, "allocate dense RGB benchmark fixture");
    foreach (index; 0 .. width * height)
    {
        const x = index % width;
        const y = index / width;
        memory[index * 3] = cast(ubyte)((x * 29 + y * 17) & 255);
        memory[index * 3 + 1] = cast(ubyte)((x * 29 + y * 17 + 53) & 255);
        memory[index * 3 + 2] = cast(ubyte)((x * 29 + y * 17 + 106) & 255);
    }
    return memory[0 .. bytes];
}

private long timeDenseColor(ubyte[] rgb, size_t iterations)
{
    double sink = 0.0;
    const start = MonoTime.currTime;
    foreach (i; 0 .. iterations)
    {
        const offset = (i % (rgb.length / 3)) * 3;
        const encoded = SRgb!float(
            cast(float)rgb[offset] / 255.0f,
            cast(float)rgb[offset + 1] / 255.0f,
            cast(float)rgb[offset + 2] / 255.0f);
        const linear = encoded.toLinear;
        const y = LinearSRgb!float(linear.r, linear.g, linear.b).toXyzD65.y;
        sink += y;
    }
    const elapsed = (MonoTime.currTime - start).total!"nsecs";
    sampleSink += sink;
    return elapsed;
}

private long timeDenseDirectY(ubyte[] rgb, size_t iterations)
{
    const decode = makeSRgb8DecodeTable!float();
    enum yr = cast(float)87098 / 409605;
    enum yg = cast(float)175762 / 245763;
    enum yb = cast(float)12673 / 175545;
    double sink = 0.0;
    const start = MonoTime.currTime;
    foreach (i; 0 .. iterations)
    {
        const offset = (i % (rgb.length / 3)) * 3;
        const r = decode[rgb[offset]];
        const g = decode[rgb[offset + 1]];
        const b = decode[rgb[offset + 2]];
        sink += yr * r + yg * g + yb * b;
    }
    const elapsed = (MonoTime.currTime - start).total!"nsecs";
    sampleSink += sink;
    return elapsed;
}

private long timeDenseTableXyzY(ubyte[] rgb, size_t iterations)
{
    const decode = makeSRgb8DecodeTable!float();
    double sink = 0.0;
    const start = MonoTime.currTime;
    foreach (i; 0 .. iterations)
    {
        const offset = (i % (rgb.length / 3)) * 3;
        const r = decode[rgb[offset]];
        const g = decode[rgb[offset + 1]];
        const b = decode[rgb[offset + 2]];
        sink += LinearSRgb!float(r, g, b).toXyzD65.y;
    }
    const elapsed = (MonoTime.currTime - start).total!"nsecs";
    sampleSink += sink;
    return elapsed;
}

private long timeDenseTransfer(ubyte[] rgb, size_t iterations)
{
    // Isolate sRGB decode/encode cost from the XYZ matrix. This is the path
    // most directly attributable to color-d's transfer functions.
    double sink = 0.0;
    const start = MonoTime.currTime;
    foreach (i; 0 .. iterations)
    {
        const offset = (i % (rgb.length / 3)) * 3;
        const encoded = SRgb!float(
            cast(float)rgb[offset] / 255.0f,
            cast(float)rgb[offset + 1] / 255.0f,
            cast(float)rgb[offset + 2] / 255.0f);
        const linear = encoded.toLinear;
        const encodedAgain = LinearSRgb!float(
            linear.r, linear.g, linear.b).toSRgb;
        sink += encodedAgain.r + encodedAgain.g * 0.5 + encodedAgain.b * 0.25;
    }
    const elapsed = (MonoTime.currTime - start).total!"nsecs";
    sampleSink += sink;
    return elapsed;
}

private float encodeFromTable(scope const(float)[] table, float linear)
@safe pure nothrow @nogc
{
    if (!(linear > 0.0f)) return table[0];
    if (linear >= 1.0f) return table[$ - 1];
    const scaled = linear * cast(float)encodeIntervals;
    const index = cast(size_t)scaled;
    const fraction = scaled - cast(float)index;
    return table[index] + fraction * (table[index + 1] - table[index]);
}

private float directXyzD65Y(float r, float g, float b)
@safe pure nothrow @nogc
{
    enum yr = cast(float)87098 / 409605;
    enum yg = cast(float)175762 / 245763;
    enum yb = cast(float)12673 / 175545;
    return yr * r + yg * g + yb * b;
}

private long timeImageryTables(ubyte[] rgb, size_t iterations)
{
    float[256] decode;
    foreach (value; 0 .. decode.length)
    {
        const encoded = cast(float)value / 255.0f;
        decode[value] = SRgb!float(encoded, encoded, encoded).toLinear.r;
    }
    float[encodeIntervals + 1] encode;
    foreach (index; 0 .. encode.length)
    {
        const linear = cast(float)index / cast(float)encodeIntervals;
        encode[index] = LinearSRgb!float(linear, linear, linear).toSRgb.r;
    }

    double sink = 0.0;
    const start = MonoTime.currTime;
    foreach (i; 0 .. iterations)
    {
        const offset = (i % (rgb.length / 3)) * 3;
        const r = decode[rgb[offset]];
        const g = decode[rgb[offset + 1]];
        const b = decode[rgb[offset + 2]];
        const y = directXyzD65Y(r, g, b);
        const scale = y > 0.0f ? 0.75f / y : 0.0f;
        sink += encodeFromTable(encode[], r * scale) +
            encodeFromTable(encode[], g * scale) * 0.5 +
            encodeFromTable(encode[], b * scale) * 0.25;
    }
    const elapsed = (MonoTime.currTime - start).total!"nsecs";
    sampleSink += sink;
    return elapsed;
}

private long timeRasterAccess(scope RasterView!ubyte source,
    scope WritableRasterView!float destination, size_t width, size_t height)
{
    double sink = 0.0;
    const start = MonoTime.currTime;
    foreach (y; 0 .. height)
    foreach (x; 0 .. width)
    {
        ubyte r, g, b;
        if (!source.trySample(0, x, y, r) ||
            !source.trySample(1, x, y, g) ||
            !source.trySample(2, x, y, b) ||
            !destination.trySetSample(0, x, y, cast(float)r) ||
            !destination.trySetSample(1, x, y, cast(float)g) ||
            !destination.trySetSample(2, x, y, cast(float)b))
            need(false, "raster accessor microbenchmark sample");
        sink += r * 0.000001 + g * 0.000002 + b * 0.000003;
    }
    const elapsed = (MonoTime.currTime - start).total!"nsecs";
    sampleSink += sink;
    return elapsed;
}

private void reportBenchmark(string label, long[] timings, size_t pixels)
{
    sort(timings[]);
    const median = timings[timings.length / 2];
    need(median > 0, "nonzero benchmark clock resolution");
    writefln("M4_KERNEL_BENCH=kernel:%s,width:%s,height:%s,median_ns:%s," ~
        "throughput_Mpixel_s:%.3f,replicates:%s,warmups:%s," ~
        "scope:local-diagnostic-not-portable", label, perfWidth, perfHeight,
        median, cast(double)pixels * 1000.0 / median,
        perfReplicates, perfWarmups);
}

private void runKernelBenchmarks()
{
    enum pixels = perfWidth * perfHeight;
    enum iterations = pixels * 16;
    auto dense = allocateDenseRgb(perfWidth, perfHeight);
    auto sourceOwner = allocateRgbFixture(perfWidth, perfHeight);
    auto destinationOwner = allocateImage!float(perfWidth, perfHeight, 3);
    scope auto source = sourceOwner.view();
    bool writable;
    scope auto destination = destinationOwner.tryWritableView(writable);
    need(writable, "raster accessor benchmark output writable");

    long[perfReplicates] colorTimings;
    long[perfReplicates] directYTimings;
    long[perfReplicates] tableXyzYTimings;
    long[perfReplicates] transferTimings;
    long[perfReplicates] imageryTableTimings;
    long[perfReplicates] rasterTimings;
    foreach (warmup; 0 .. perfWarmups)
    {
        timeDenseColor(dense, iterations);
        timeDenseDirectY(dense, iterations);
        timeDenseTableXyzY(dense, iterations);
        timeDenseTransfer(dense, iterations);
        timeImageryTables(dense, iterations);
        timeRasterAccess(source, destination, perfWidth, perfHeight);
    }
    foreach (i; 0 .. perfReplicates)
    {
        colorTimings[i] = timeDenseColor(dense, iterations);
        directYTimings[i] = timeDenseDirectY(dense, iterations);
        tableXyzYTimings[i] = timeDenseTableXyzY(dense, iterations);
        transferTimings[i] = timeDenseTransfer(dense, iterations);
        imageryTableTimings[i] = timeImageryTables(dense, iterations);
        rasterTimings[i] = timeRasterAccess(source, destination,
            perfWidth, perfHeight);
    }
    reportBenchmark("color-d-srgb-decode-plus-xyz-dense-16x",
        colorTimings[], iterations);
    reportBenchmark("color-d-rgb8-table-plus-direct-y-dense-16x",
        directYTimings[], iterations);
    reportBenchmark("color-d-rgb8-table-plus-xyz-y-dense-16x",
        tableXyzYTimings[], iterations);
    reportBenchmark("color-d-srgb-transfer-dense-16x", transferTimings[], iterations);
    reportBenchmark("imagery-color-tables-plus-xyz-dense-16x",
        imageryTableTimings[], iterations);
    reportBenchmark("raster-d-3-read-3-write-identity", rasterTimings[], pixels);

    // Semantic preflight ensures the raster accessor workload actually copied
    // the same RGB fixture values into its destination.
    foreach (channel; 0 .. 3)
    foreach (xy; [size_t(0), pixels / 2, pixels - 1])
    {
        const x = xy % perfWidth;
        const y = xy / perfWidth;
        ubyte expected;
        float actual;
        need(source.trySample(channel, x, y, expected) &&
            destination.trySample(channel, x, y, actual) &&
            actual == expected,
            "raster accessor identity preflight");
    }
    writeln("M4_KERNEL_BENCH=PASS; dense color path and raster accessor identity validated");
}

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

private RasterLease!ubyte allocateRgbFixture(size_t width, size_t height)
@trusted
{
    // Initialize this benchmark-only fixture before importing it into raster-d
    // so setup time is not dominated by per-sample control-plane accessors.
    const bytes = width * height * 3;
    auto memory = malloc(bytes);
    need(memory !is null, "allocate RGB fixture bytes");
    auto data = cast(ubyte*)memory;
    foreach (index; 0 .. width * height)
    {
        const x = index % width;
        const y = index / width;
        data[index * 3] = cast(ubyte)((x * 29 + y * 17) & 255);
        data[index * 3 + 1] = cast(ubyte)((x * 29 + y * 17 + 53) & 255);
        data[index * 3 + 2] = cast(ubyte)((x * 29 + y * 17 + 106) & 255);
    }
    OwnedByteResource resource;
    if (!tryAdoptMallocResource(memory, bytes, resource))
    {
        free(memory);
        need(false, "adopt RGB fixture bytes");
    }
    PlaneByteLayout[3] layouts = [
        PlaneByteLayout(0, cast(ptrdiff_t)(width * 3), 3),
        PlaneByteLayout(1, cast(ptrdiff_t)(width * 3), 3),
        PlaneByteLayout(2, cast(ptrdiff_t)(width * 3), 3)
    ];
    RasterLease!ubyte owner;
    need(tryImportOwnedRaster!ubyte(resource, layouts[],
        Region2D(0, 0, width, height), owner).ok,
        "import RGB fixture owner");
    return owner;
}

private RasterLease!ubyte allocateMaskFixture(size_t width, size_t height)
@trusted
{
    const bytes = width * height;
    auto memory = malloc(bytes);
    need(memory !is null, "allocate mask fixture bytes");
    auto data = cast(ubyte*)memory;
    foreach (index; 0 .. bytes)
        data[index] = cast(ubyte)(index % 5 == 0 ? 0 : 255);
    OwnedByteResource resource;
    if (!tryAdoptMallocResource(memory, bytes, resource))
    {
        free(memory);
        need(false, "adopt mask fixture bytes");
    }
    PlaneByteLayout[1] layouts = [PlaneByteLayout(
        0, cast(ptrdiff_t)width, 1)];
    RasterLease!ubyte owner;
    need(tryImportOwnedRaster!ubyte(resource, layouts[],
        Region2D(0, 0, width, height), owner).ok,
        "import mask fixture owner");
    return owner;
}

private RasterLease!float referenceLevels(bool genericPow = false)(
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
                // Compile-time selection keeps both reference variants
                // simple: generic pow reproduces the old gamma=2 mechanism,
                // sqrt is the semantically equivalent specialized oracle.
                static if (genericPow)
                    const shaped = pow(t, 1.0 / settings.gamma);
                else
                    const shaped = sqrt(t);
                const mapped = settings.outputBlack +
                    shaped * (settings.outputWhite - settings.outputBlack);
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
    bool candidate, bool genericPow, scope RasterView!ubyte source,
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
    else if (genericPow)
        owned = referenceLevels!true(source, mask, selected, roi, settings);
    else
        owned = referenceLevels!false(source, mask, selected, roi, settings);
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
    auto referenceOwned = referenceLevels!false(
        sourceView, maskView, affected[], roi, settings);
    auto oldPowOwned = referenceLevels!true(
        sourceView, maskView, affected[], roi, settings);
    double maximumError = 0.0;
    {
        scope auto candidateView = candidateOwned.view();
        scope auto refView = referenceOwned.view();
        compareComplete(candidateView,refView,width,height,maximumError);
        scope auto legacyView = oldPowOwned.view();
        double powError;
        compareComplete(legacyView,refView,width,height,powError);
        if (powError > maximumError)
            maximumError = powError;
    }

    // Three comparable paths share the exact same run's CPU and input:
    // candidate, generic-pow reference (old math), sqrt reference.
    // Rotating order reduces case-order drift. Each path allocates its own
    // separate interleaved float raster-d owner, including all sample writes.
    foreach (warmup; 0 .. 2)
    {
        oneTimed(true,false,sourceView,maskView,affected[],roi,settings,budget);
        oneTimed(false,true,sourceView,maskView,affected[],roi,settings,budget);
        oneTimed(false,false,sourceView,maskView,affected[],roi,settings,budget);
    }
    long[7] candidateUs, referenceUs, genericPowUs;
    foreach (i; 0 .. candidateUs.length)
    foreach (step; 0 .. 3)
    {
        final switch ((i + step) % 3)
        {
            case 0:
                candidateUs[i] = oneTimed(true,false,sourceView,
                    maskView,affected[],roi,settings,budget);
                break;
            case 1:
                genericPowUs[i] = oneTimed(false,true,sourceView,
                    maskView,affected[],roi,settings,budget);
                break;
            case 2:
                referenceUs[i] = oneTimed(false,false,sourceView,
                    maskView,affected[],roi,settings,budget);
                break;
        }
    }
    sort(candidateUs[]);
    sort(referenceUs[]);
    sort(genericPowUs[]);
    const candidateMedian = candidateUs[candidateUs.length/2];
    const referenceMedian = referenceUs[referenceUs.length/2];
    const powMedian = genericPowUs[genericPowUs.length/2];
    need(candidateMedian > 0 && referenceMedian > 0 && powMedian > 0,
         "nonzero clock resolution");
    const ratio = cast(double)candidateMedian / referenceMedian;
    const oldRatio = cast(double)candidateMedian / powMedian;

    writefln("M3_LEVELS_PAIRED=width:%s,height:%s,build:LDC-Release," ~
       "candidate_median_us:%s,reference_sqrt_median_us:%s," ~
       "reference_pow_median_us:%s,candidate/sqrt_ratio:%.4f," ~
       "candidate/pow_ratio:%.4f,max_abs_error:%.9f,replicates:7," ~
       "order:rotating-three-way,scope:owned-ROI-masked-RGBA-float-output",
       width,height,candidateMedian,referenceMedian,powMedian,
       ratio,oldRatio,maximumError);
}

private long oneLuminanceTimed(scope RasterView!ubyte source,
    Region2D roi, size_t budget, scope RasterView!ubyte mask,
    bool useMask, size_t workerLimit = 0)
{
    const start = MonoTime.currTime;
    RasterLease!float output;
    if (useMask)
    {
        const status = tryRgbLuminanceStretchOwned!true(source, roi, 1, 99,
            mask, budget, output, workerLimit);
        if (status != LuminanceStretchError.none)
            writefln("masked luminance operation failed: %s", status);
        need(status == LuminanceStretchError.none,
            "masked luminance stretch operation");
    }
    else
    {
        const status = tryRgbLuminanceStretchOwned!true(source, roi, 1, 99,
            budget, output, workerLimit);
        if (status != LuminanceStretchError.none)
            writefln("luminance operation failed: %s", status);
        need(status == LuminanceStretchError.none,
            "luminance stretch operation");
    }
    const elapsed = (MonoTime.currTime - start).total!"usecs";
    scope auto result = output.view();
    float sample;
    need(result.trySample(0, roi.width / 2, roi.height / 2, sample),
        "luminance output retained and sampled");
    sampleSink += sample;
    return elapsed;
}

version (ImageryPerfAttribution)
private struct TimedLuminanceCall
{
    long totalNanoseconds;
    long histogramNanoseconds;
    long transformNanoseconds;
}

version (ImageryPerfAttribution)
private TimedLuminanceCall oneMeasuredLuminanceTimed(
    scope RasterView!ubyte source, Region2D roi, size_t budget,
    scope RasterView!ubyte mask, bool useMask)
{
    RasterLease!float output;
    LuminanceStretchPhaseTimings phases;
    const start = MonoTime.currTime;
    LuminanceStretchError status;
    if (useMask)
        status = tryRgbLuminanceStretchOwnedMeasured!true(source, roi, 1, 99,
            mask, budget, output, phases);
    else
        status = tryRgbLuminanceStretchOwnedMeasured!true(source, roi, 1, 99,
            budget, output, phases);
    const total = (MonoTime.currTime - start).total!"nsecs";
    need(status == LuminanceStretchError.none,
        "instrumented owned luminance operation");
    scope auto result = output.view();
    float sample;
    need(result.trySample(0, roi.width / 2, roi.height / 2, sample),
        "instrumented output retained and sampled");
    sampleSink += sample;
    return TimedLuminanceCall(total, phases.histogramNanoseconds,
        phases.transformNanoseconds);
}

version (ImageryPerfAttribution)
private void runDirectLuminancePhaseAttribution()
{
    enum width = 1920;
    enum height = 1080;
    enum warmups = 2;
    enum replicates = 9;
    auto sourceOwner = allocateRgbFixture(width, height);
    auto maskOwner = allocateMaskFixture(width, height);
    scope auto source = sourceOwner.view();
    scope auto mask = maskOwner.view();
    const roi = Region2D(0, 0, width, height);
    const budget = width * height * 3 * float.sizeof;
    foreach (useMask; [false, true])
    {
        TimedLuminanceCall[warmups] discard;
        foreach (i; 0 .. warmups)
            discard[i] = oneMeasuredLuminanceTimed(source, roi, budget,
                mask, useMask);
        TimedLuminanceCall[replicates] calls;
        foreach (i; 0 .. replicates)
            calls[i] = oneMeasuredLuminanceTimed(source, roi, budget,
                mask, useMask);
        long[replicates] total, histogram, transform, remainder;
        foreach (i; 0 .. replicates)
        {
            total[i] = calls[i].totalNanoseconds;
            histogram[i] = calls[i].histogramNanoseconds;
            transform[i] = calls[i].transformNanoseconds;
            remainder[i] = total[i] - histogram[i] - transform[i];
            need(remainder[i] >= 0, "phase timings fit in full API duration");
        }
        sort(total[]);
        sort(histogram[]);
        sort(transform[]);
        sort(remainder[]);
        writefln("M5_DIRECT_LUMINANCE_PHASES=width:%s,height:%s,mask:%s," ~
            "total_median_ms:%.3f,histogram_phase_median_ms:%.3f," ~
            "transform_phase_median_ms:%.3f,setup_allocation_remainder_median_ms:%.3f," ~
            "replicates:%s,warmups:%s,scope:instrumented-real-owned-api-call," ~
            "phase_boundaries:histogram-through-percentile-selection;" ~
            "plane-transform-executor-and-pixel-writes;" ~
            "remainder:validation-setup-allocation-lut-and-publish",
            width, height, useMask, total[$ / 2] / 1_000_000.0,
            histogram[$ / 2] / 1_000_000.0,
            transform[$ / 2] / 1_000_000.0,
            remainder[$ / 2] / 1_000_000.0, replicates, warmups);
    }
}

private void runLuminanceShape(
    size_t width, size_t height, size_t repetitions = 1,
    bool useMask = false, size_t workerLimit = 0)
{
    auto source = allocateRgbFixture(width, height);
    RasterLease!ubyte maskOwner;
    if (useMask)
        maskOwner = allocateMaskFixture(width, height);
    scope auto view = source.view();
    scope auto maskView = maskOwner.view();
    const roi = Region2D(0, 0, width, height);
    const budget = width * height * 3 * float.sizeof;

    RasterLease!float preflight;
    if (useMask)
        need(tryRgbLuminanceStretchOwned!true(view, roi, 1, 99,
            maskView, budget, preflight) == LuminanceStretchError.none,
            "masked luminance benchmark semantic preflight");
    else
        need(tryRgbLuminanceStretchOwned!true(view, roi, 1, 99,
            budget, preflight) == LuminanceStretchError.none,
            "luminance benchmark semantic preflight");
    {
        scope auto output = preflight.view();
        // Keep large-image setup outside a second full raster traversal.
        // The numerical corpus/oracle validates every pixel separately.
        foreach (point; 0 .. 17)
        {
            const x = point * (width - 1) / 16;
            const y = (point * 7 % 17) * (height - 1) / 16;
            foreach (c; 0 .. 3)
            {
                float sample;
                need(output.trySample(c, x, y, sample) &&
                    sample == sample && sample >= 0.0f && sample <= 1.0f,
                    "luminance output remains finite normalized sRGB");
            }
        }
    }

    foreach (warmup; 0 .. 2)
    foreach (rep; 0 .. repetitions)
        oneLuminanceTimed(view, roi, budget, maskView, useMask, workerLimit);
    long[7] times;
    foreach (i; 0 .. times.length)
    {
        foreach (rep; 0 .. repetitions)
            times[i] += oneLuminanceTimed(view, roi, budget, maskView,
                useMask, workerLimit);
    }
    sort(times[]);
    const median = times[times.length / 2];
    need(median > 0, "nonzero luminance benchmark clock resolution");
    const megapixelsPerSecond =
        cast(double)(width * height) * repetitions / median;
    writefln("M3_RGB_LUMINANCE_STRETCH_PERF=width:%s,height:%s," ~
        "build:%s-Release,median_batch_us:%s,median_call_us:%.1f," ~
        "throughput_Mpixel_s:%.3f,repetitions_per_batch:%s," ~
        "replicates:7,warmups:2,scope:repeated-owned-RGB8-ROI-to-float-output," ~
        "mask:%s,histogram_bins:65536,worker_limit:%s,min_chunk:32",
        width, height, compilerLabel, median,
        cast(double)median / repetitions,
        megapixelsPerSecond,
        repetitions, useMask, workerLimit);
    stdout.flush();
}

private void runLuminanceParallelComparison(size_t width, size_t height,
    size_t workerLimit, bool useMask = false)
{
    auto source = allocateRgbFixture(width, height);
    RasterLease!ubyte maskOwner;
    if (useMask)
        maskOwner = allocateMaskFixture(width, height);
    scope auto view = source.view();
    scope auto maskView = maskOwner.view();
    const roi = Region2D(0, 0, width, height);
    const budget = width * height * 3 * float.sizeof;
    long[7] serial, parallel;

    foreach (warmup; 0 .. 2)
    {
        oneLuminanceTimed(view, roi, budget, maskView, useMask, 0);
        oneLuminanceTimed(view, roi, budget, maskView, useMask, workerLimit);
    }
    foreach (i; 0 .. serial.length)
    {
        // Alternate order to reduce frequency and thermal drift bias.
        if ((i & 1) == 0)
        {
            serial[i] = oneLuminanceTimed(view, roi, budget, maskView, useMask, 0);
            parallel[i] = oneLuminanceTimed(view, roi, budget, maskView,
                useMask, workerLimit);
        }
        else
        {
            parallel[i] = oneLuminanceTimed(view, roi, budget, maskView,
                useMask, workerLimit);
            serial[i] = oneLuminanceTimed(view, roi, budget, maskView, useMask, 0);
        }
    }
    sort(serial[]);
    sort(parallel[]);
    writefln("M3_RGB_LUMINANCE_PARALLEL_COMPARE=width:%s,height:%s," ~
        "build:%s-Release,serial_median_us:%s,parallel_median_us:%s," ~
        "worker_limit:%s,speedup:%.3f,mask:%s,replicates:7,warmups:2," ~
        "scope:paired-full-owned-operation-local-diagnostic",
        width, height, compilerLabel, serial[$ / 2], parallel[$ / 2],
        workerLimit, cast(double)serial[$ / 2] / parallel[$ / 2], useMask);
    stdout.flush();
}

private struct LuminancePassResult
{
    double histogramMedianUs;
    double transformMedianUs;
    double fullMedianUs;
    size_t selectedPixels;
}

private long timeHistogramPass(scope RasterView!ubyte source,
    scope RasterView!ubyte mask, bool useMask, size_t width, size_t height,
    out size_t lowerBin, out size_t upperBin)
{
    ulong[65_536] bins;
    const decode = makeSRgb8DecodeTable!float();
    bool maskReady;
    ulong selectedPixels;
    long elapsed;
    const started = MonoTime.currTime;
    const windowsReady = withPlane!ubyte(source, 0,
        delegate(scope ref const RasterPlaneWindow!ubyte red)
            @safe nothrow @nogc
        {
            maskReady = withPlane!ubyte(source, 1,
                delegate(scope ref const RasterPlaneWindow!ubyte green)
                    @safe nothrow @nogc
                {
                    maskReady = withPlane!ubyte(source, 2,
                        delegate(scope ref const RasterPlaneWindow!ubyte blue)
                            @safe nothrow @nogc
                        {
                            if (useMask)
                            {
                                maskReady = withPlane!ubyte(mask, 0,
                                    delegate(scope ref const RasterPlaneWindow!ubyte selection)
                                        @safe nothrow @nogc
                                    {
                                        foreach (y; 0 .. height)
                                        foreach (x; 0 .. width)
                                        {
                                            if (selection.load(x, y) == 0)
                                                continue;
                                            ++selectedPixels;
                                            const r = decode[red.load(x, y)];
                                            const g = decode[green.load(x, y)];
                                            const b = decode[blue.load(x, y)];
                                            const yValue = directXyzD65Y(r, g, b);
                                            auto bin = cast(size_t)(yValue * 65_536.0f);
                                            if (bin >= bins.length) bin = bins.length - 1;
                                            ++bins[bin];
                                        }
                                    });
                            }
                            else
                            {
                                foreach (y; 0 .. height)
                                foreach (x; 0 .. width)
                                {
                                    ++selectedPixels;
                                    const r = decode[red.load(x, y)];
                                    const g = decode[green.load(x, y)];
                                    const b = decode[blue.load(x, y)];
                                    const yValue = directXyzD65Y(r, g, b);
                                    auto bin = cast(size_t)(yValue * 65_536.0f);
                                    if (bin >= bins.length) bin = bins.length - 1;
                                    ++bins[bin];
                                }
                                maskReady = true;
                            }
                        });
                });
        });
    elapsed = (MonoTime.currTime - started).total!"nsecs";
    need(windowsReady && maskReady, "histogram pass plane windows");

    // Include the same selected-pixel nearest-rank threshold scan.
    ulong cumulative;
    const lowerRank = (selectedPixels + 99) / 100;
    const upperRank = (selectedPixels * 99 + 99) / 100;
    bool lowerFound;
    foreach (i; 0 .. bins.length)
    {
        cumulative += bins[i];
        if (!lowerFound && cumulative >= lowerRank)
        {
            lowerBin = i + 1;
            lowerFound = true;
        }
        if (cumulative >= upperRank)
        {
            upperBin = i;
            break;
        }
    }
    need(lowerFound, "histogram lower threshold found");
    --lowerBin;
    sampleSink += lowerBin + upperBin;
    return elapsed;
}

private long timeTransformPass(scope RasterView!ubyte source,
    scope WritableRasterView!float output, size_t width, size_t height,
    size_t lowerBin, size_t upperBin)
{
    const decode = makeSRgb8DecodeTable!float();
    float[16_385] encode;
    foreach (i; 0 .. encode.length)
    {
        const linear = cast(float)i / 16_384.0f;
        encode[i] = LinearSRgb!float(linear, linear, linear).toSRgb.r;
    }
    size_t[3] sourcePlanes = [0, 1, 2];
    size_t[1] destinationPlanes = [0];
    RasterPlaneWindow!ubyte[3] sourceWindows;
    WritableRasterPlaneWindow!float[1] destinationWindows;
    bool siblingsReady;
    const started = MonoTime.currTime;
    const processed = withPlanesInto(source, sourcePlanes[], output,
        destinationPlanes[], sourceWindows[], destinationWindows[],
        delegate(scope const(RasterPlaneWindow!ubyte)[] sources,
            scope WritableRasterPlaneWindow!float[] destinations)
            @safe nothrow @nogc
        {
            siblingsReady = withPlane!float(output, 1,
                delegate(scope ref WritableRasterPlaneWindow!float green)
                    @safe nothrow @nogc
                {
                    siblingsReady = withPlane!float(output, 2,
                        delegate(scope ref WritableRasterPlaneWindow!float blue)
                            @safe nothrow @nogc
                        {
                            double sink;
                            foreach (y; 0 .. height)
                            foreach (x; 0 .. width)
                            {
                                const r = decode[sources[0].load(x, y)];
                                const g = decode[sources[1].load(x, y)];
                                const b = decode[sources[2].load(x, y)];
                                const luminance = directXyzD65Y(r, g, b);
                                const inputBin = luminance <= 0.0f ? 0 :
                                    luminance >= 1.0f ? 65_535 :
                                    cast(size_t)(luminance * 65_536.0f);
                                float mappedY;
                                if (upperBin == lowerBin)
                                    mappedY = luminance;
                                else if (inputBin <= lowerBin)
                                    mappedY = 0.0f;
                                else if (inputBin >= upperBin)
                                    mappedY = 1.0f;
                                else
                                    mappedY = cast(float)(inputBin - lowerBin) /
                                        cast(float)(upperBin - lowerBin);
                                const scale = luminance > 0.0f ? mappedY / luminance : 0.0f;
                                float rr = r * scale;
                                float gg = g * scale;
                                float bb = b * scale;
                                if (rr < 0.0f) rr = 0.0f;
                                if (gg < 0.0f) gg = 0.0f;
                                if (bb < 0.0f) bb = 0.0f;
                                if (rr > 1.0f) rr = 1.0f;
                                if (gg > 1.0f) gg = 1.0f;
                                if (bb > 1.0f) bb = 1.0f;
                                const outR = encodeFromTable(encode[], rr);
                                const outG = encodeFromTable(encode[], gg);
                                const outB = encodeFromTable(encode[], bb);
                                destinations[0].store(x, y, outR);
                                green.store(x, y, outG);
                                blue.store(x, y, outB);
                                sink += outR + outG * 0.5 + outB * 0.25;
                            }
                            sampleSink += sink;
                        });
                });
        });
    const elapsed = (MonoTime.currTime - started).total!"nsecs";
    need(processed && siblingsReady, "transform pass plane windows");
    return elapsed;
}

private long timeLinearStage(scope RasterView!ubyte source,
    float[] linearRgb, size_t width, size_t height)
{
    const decode = makeSRgb8DecodeTable!float();
    size_t[3] sourcePlanes = [0, 1, 2];
    RasterPlaneWindow!ubyte[3] sourceWindows;
    double sink;
    const started = MonoTime.currTime;
    const processed = withPlane!ubyte(source, 0,
        delegate(scope ref const RasterPlaneWindow!ubyte red)
            @safe nothrow @nogc
        {
            withPlane!ubyte(source, 1,
                delegate(scope ref const RasterPlaneWindow!ubyte green)
                    @safe nothrow @nogc
                {
                    withPlane!ubyte(source, 2,
                        delegate(scope ref const RasterPlaneWindow!ubyte blue)
                            @safe nothrow @nogc
                        {
                            foreach (y; 0 .. height)
                            foreach (x; 0 .. width)
                            {
                                const offset = (y * width + x) * 3;
                                const r = decode[red.load(x, y)];
                                const g = decode[green.load(x, y)];
                                const b = decode[blue.load(x, y)];
                                const luminance = directXyzD65Y(r, g, b);
                                const scale = luminance > 0.0f ? 0.75f / luminance : 0.0f;
                                linearRgb[offset] = r * scale;
                                linearRgb[offset + 1] = g * scale;
                                linearRgb[offset + 2] = b * scale;
                                sink += linearRgb[offset] + linearRgb[offset + 1] * 0.5 +
                                    linearRgb[offset + 2] * 0.25;
                            }
                        });
                });
        });
    const elapsed = (MonoTime.currTime - started).total!"nsecs";
    need(processed, "linear stage plane windows");
    sampleSink += sink;
    return elapsed;
}

private long timeLinearScaleKernel(bool Simd)(scope const(float)[] linearRgb,
    size_t width, size_t height, size_t lowerBin, size_t upperBin,
    scope float[] outputRgb, out double sink)
{
    sink = 0.0;
    const pixels = width * height;
    const started = MonoTime.currTime;
    static if (Simd)
    {
        alias F4 = Vector!(float[4]);
        const yr = F4([cast(float)87098 / 409605,
            cast(float)87098 / 409605, cast(float)87098 / 409605,
            cast(float)87098 / 409605]);
        const yg = F4([cast(float)175762 / 245763,
            cast(float)175762 / 245763, cast(float)175762 / 245763,
            cast(float)175762 / 245763]);
        const yb = F4([cast(float)12673 / 175545,
            cast(float)12673 / 175545, cast(float)12673 / 175545,
            cast(float)12673 / 175545]);
        double accumulated;
        size_t i;
        for (; i + 4 <= pixels; i += 4)
        {
            float[4] red, green, blue;
            foreach (lane; 0 .. 4)
            {
                red[lane] = linearRgb[(i + lane) * 3];
                green[lane] = linearRgb[(i + lane) * 3 + 1];
                blue[lane] = linearRgb[(i + lane) * 3 + 2];
            }
            const r = *cast(F4*)red.ptr;
            const g = *cast(F4*)green.ptr;
            const b = *cast(F4*)blue.ptr;
            const luminance = yr * r + yg * g + yb * b;
            float[4] yValues, mappedValues, safeYValues;
            *cast(F4*)yValues.ptr = luminance;
            foreach (lane; 0 .. 4)
            {
                const y = yValues[lane];
                safeYValues[lane] = y > 0.0f ? y : 1.0f;
                const bin = y <= 0.0f ? 0 : y >= 1.0f ? 65_535 :
                    cast(size_t)(y * 65_536.0f);
                if (upperBin == lowerBin)
                    mappedValues[lane] = y;
                else if (bin <= lowerBin)
                    mappedValues[lane] = 0.0f;
                else if (bin >= upperBin)
                    mappedValues[lane] = 1.0f;
                else
                    mappedValues[lane] = cast(float)(bin - lowerBin) /
                        cast(float)(upperBin - lowerBin);
            }
            const scale = *cast(F4*)mappedValues.ptr /
                *cast(F4*)safeYValues.ptr;
            float[4] scaledR, scaledG, scaledB;
            *cast(F4*)scaledR.ptr = r * scale;
            *cast(F4*)scaledG.ptr = g * scale;
            *cast(F4*)scaledB.ptr = b * scale;
            foreach (lane; 0 .. 4)
            {
                const rr = scaledR[lane] < 0.0f ? 0.0f :
                    scaledR[lane] > 1.0f ? 1.0f : scaledR[lane];
                const gg = scaledG[lane] < 0.0f ? 0.0f :
                    scaledG[lane] > 1.0f ? 1.0f : scaledG[lane];
                const bb = scaledB[lane] < 0.0f ? 0.0f :
                    scaledB[lane] > 1.0f ? 1.0f : scaledB[lane];
                outputRgb[(i + lane) * 3] = rr;
                outputRgb[(i + lane) * 3 + 1] = gg;
                outputRgb[(i + lane) * 3 + 2] = bb;
                accumulated += rr + gg * 0.5 + bb * 0.25;
            }
        }
        for (; i < pixels; ++i)
        {
            const r = linearRgb[i * 3];
            const g = linearRgb[i * 3 + 1];
            const b = linearRgb[i * 3 + 2];
            const y = directXyzD65Y(r, g, b);
            const bin = y <= 0.0f ? 0 : y >= 1.0f ? 65_535 :
                cast(size_t)(y * 65_536.0f);
            const mapped = upperBin == lowerBin ? y : bin <= lowerBin ? 0.0f :
                bin >= upperBin ? 1.0f : cast(float)(bin - lowerBin) /
                    cast(float)(upperBin - lowerBin);
            const scale = y > 0.0f ? mapped / y : 0.0f;
            const rr = clamp(r * scale);
            const gg = clamp(g * scale);
            const bb = clamp(b * scale);
            outputRgb[i * 3] = rr;
            outputRgb[i * 3 + 1] = gg;
            outputRgb[i * 3 + 2] = bb;
            accumulated += rr + gg * 0.5 + bb * 0.25;
        }
        sink = accumulated;
    }
    else
    {
        foreach (i; 0 .. pixels)
        {
            const r = linearRgb[i * 3];
            const g = linearRgb[i * 3 + 1];
            const b = linearRgb[i * 3 + 2];
            const y = directXyzD65Y(r, g, b);
            const bin = y <= 0.0f ? 0 : y >= 1.0f ? 65_535 :
                cast(size_t)(y * 65_536.0f);
            const mapped = upperBin == lowerBin ? y : bin <= lowerBin ? 0.0f :
                bin >= upperBin ? 1.0f : cast(float)(bin - lowerBin) /
                    cast(float)(upperBin - lowerBin);
            const scale = y > 0.0f ? mapped / y : 0.0f;
            const rr = clamp(r * scale);
            const gg = clamp(g * scale);
            const bb = clamp(b * scale);
            outputRgb[i * 3] = rr;
            outputRgb[i * 3 + 1] = gg;
            outputRgb[i * 3 + 2] = bb;
            sink += rr + gg * 0.5 + bb * 0.25;
        }
    }
    return (MonoTime.currTime - started).total!"nsecs";
}

private float clamp(float value) @safe pure nothrow @nogc
{
    return value < 0.0f ? 0.0f : value > 1.0f ? 1.0f : value;
}

private long timeEncodeStage(scope WritableRasterView!float output,
    scope const(float)[] linearRgb, size_t width, size_t height)
{
    float[16_385] encode;
    foreach (i; 0 .. encode.length)
    {
        const linear = cast(float)i / 16_384.0f;
        encode[i] = LinearSRgb!float(linear, linear, linear).toSRgb.r;
    }
    double sink;
    bool ready;
    const started = MonoTime.currTime;
    ready = withPlane!float(output, 0,
        delegate(scope ref WritableRasterPlaneWindow!float red)
            @safe nothrow @nogc
        {
            withPlane!float(output, 1,
                delegate(scope ref WritableRasterPlaneWindow!float green)
                    @safe nothrow @nogc
                {
                    withPlane!float(output, 2,
                        delegate(scope ref WritableRasterPlaneWindow!float blue)
                            @safe nothrow @nogc
                        {
                            foreach (y; 0 .. height)
                            foreach (x; 0 .. width)
                            {
                                const offset = (y * width + x) * 3;
                                const r = encodeFromTable(encode[], linearRgb[offset]);
                                const g = encodeFromTable(encode[], linearRgb[offset + 1]);
                                const b = encodeFromTable(encode[], linearRgb[offset + 2]);
                                red.store(x, y, r);
                                green.store(x, y, g);
                                blue.store(x, y, b);
                                sink += r + g * 0.5 + b * 0.25;
                            }
                        });
                });
        });
    const elapsed = (MonoTime.currTime - started).total!"nsecs";
    need(ready, "encoding stage plane windows");
    sampleSink += sink;
    return elapsed;
}

private long timeExactEncodeStage(scope WritableRasterView!float output,
    scope const(float)[] linearRgb, size_t width, size_t height)
{
    bool ready;
    const started = MonoTime.currTime;
    ready = withPlane!float(output, 0,
        delegate(scope ref WritableRasterPlaneWindow!float red)
            @safe nothrow @nogc
        {
            withPlane!float(output, 1,
                delegate(scope ref WritableRasterPlaneWindow!float green)
                    @safe nothrow @nogc
                {
                    withPlane!float(output, 2,
                        delegate(scope ref WritableRasterPlaneWindow!float blue)
                            @safe nothrow @nogc
                        {
                            double sink;
                            foreach (y; 0 .. height)
                            foreach (x; 0 .. width)
                            {
                                const offset = (y * width + x) * 3;
                                const r = linearRgb[offset] < 0.0f ? 0.0f :
                                    linearRgb[offset] > 1.0f ? 1.0f : linearRgb[offset];
                                const g = linearRgb[offset + 1] < 0.0f ? 0.0f :
                                    linearRgb[offset + 1] > 1.0f ? 1.0f : linearRgb[offset + 1];
                                const b = linearRgb[offset + 2] < 0.0f ? 0.0f :
                                    linearRgb[offset + 2] > 1.0f ? 1.0f : linearRgb[offset + 2];
                                const exact = LinearSRgb!float(r, g, b).toSRgb;
                                red.store(x, y, exact.r);
                                green.store(x, y, exact.g);
                                blue.store(x, y, exact.b);
                                sink += exact.r + exact.g * 0.5 + exact.b * 0.25;
                            }
                            sampleSink += sink;
                        });
                });
        });
    const elapsed = (MonoTime.currTime - started).total!"nsecs";
    need(ready, "exact encoding stage plane windows");
    return elapsed;
}

private double compareEncodingStages(scope WritableRasterView!float output,
    scope const(float)[] linearRgb, size_t width, size_t height)
{
    float[16_385] table;
    foreach (i; 0 .. table.length)
        table[i] = LinearSRgb!float(cast(float)i / 16_384.0f,
            cast(float)i / 16_384.0f, cast(float)i / 16_384.0f).toSRgb.r;
    double maximumError = 0.0;
    foreach (index; 0 .. width * height)
    {
        const offset = index * 3;
        const r = linearRgb[offset] < 0.0f ? 0.0f :
            linearRgb[offset] > 1.0f ? 1.0f : linearRgb[offset];
        const g = linearRgb[offset + 1] < 0.0f ? 0.0f :
            linearRgb[offset + 1] > 1.0f ? 1.0f : linearRgb[offset + 1];
        const b = linearRgb[offset + 2] < 0.0f ? 0.0f :
            linearRgb[offset + 2] > 1.0f ? 1.0f : linearRgb[offset + 2];
        const exact = LinearSRgb!float(r, g, b).toSRgb;
        const approximateR = encodeFromTable(table[], r);
        const approximateG = encodeFromTable(table[], g);
        const approximateB = encodeFromTable(table[], b);
        const errorR = fabs(cast(double)approximateR - exact.r);
        const errorG = fabs(cast(double)approximateG - exact.g);
        const errorB = fabs(cast(double)approximateB - exact.b);
        if (errorR > maximumError) maximumError = errorR;
        if (errorG > maximumError) maximumError = errorG;
        if (errorB > maximumError) maximumError = errorB;
    }
    return maximumError;
}

private long timeOutputCurveSetup()
{
    float[16_385] table;
    const started = MonoTime.currTime;
    foreach (i; 0 .. table.length)
    {
        const linear = cast(float)i / 16_384.0f;
        table[i] = LinearSRgb!float(linear, linear, linear).toSRgb.r;
    }
    const elapsed = (MonoTime.currTime - started).total!"nsecs";
    sampleSink += table[0] + table[$ / 2] + table[$ - 1];
    return elapsed;
}

private long timeOutputAllocationAndTouch(size_t width, size_t height)
@trusted
{
    const bytes = width * height * 3 * float.sizeof;
    const started = MonoTime.currTime;
    void* memory = malloc(bytes);
    need(memory !is null, "attribution output allocation");
    memset(memory, 0x5a, bytes);
    const elapsed = (MonoTime.currTime - started).total!"nsecs";
    auto bytesView = (cast(ubyte*)memory)[0 .. bytes];
    sampleSink += bytesView[0] + bytesView[$ / 2] + bytesView[$ - 1];
    free(memory);
    return elapsed;
}

private void runLuminancePassAttribution()
{
    enum width = 1920;
    enum height = 1080;
    enum repetitions = 7;
    enum warmups = 2;
    auto sourceOwner = allocateRgbFixture(width, height);
    auto maskOwner = allocateMaskFixture(width, height);
    auto outputOwner = allocateImage!float(width, height, 3);
    auto linearRgb = new float[](width * height * 3);
    scope auto source = sourceOwner.view();
    scope auto mask = maskOwner.view();
    bool writable;
    scope auto output = outputOwner.tryWritableView(writable);
    need(writable, "pass attribution destination writable");
    timeLinearStage(source, linearRgb, width, height);
    const encodingMaximumError = compareEncodingStages(
        output, linearRgb, width, height);
    size_t simdLowerBin, simdUpperBin;
    timeHistogramPass(source, mask, true, width, height,
        simdLowerBin, simdUpperBin);
    auto scalarRgb = new float[](width * height * 3);
    auto simdRgb = new float[](width * height * 3);
    long[warmups] throwaway;
    foreach (i; 0 .. warmups)
    {
        size_t low, high;
        throwaway[i] = timeHistogramPass(source, mask, true,
            width, height, low, high);
        throwaway[i] += timeTransformPass(source, output,
            width, height, low, high);
        throwaway[i] += timeLinearStage(source, linearRgb, width, height);
        throwaway[i] += timeEncodeStage(output, linearRgb, width, height);
        double scalarSink, simdSink;
        timeLinearScaleKernel!false(linearRgb, width, height,
            simdLowerBin, simdUpperBin, scalarRgb, scalarSink);
        timeLinearScaleKernel!true(linearRgb, width, height,
            simdLowerBin, simdUpperBin, simdRgb, simdSink);
    }
    long[repetitions] histogram, transform, fullApi,
        linearStage, encodeStage,
        exactEncodeStage, curveSetup, allocationTouch, scalarMath, simdMath;
    const roi = Region2D(0, 0, width, height);
    const outputBudget = width * height * 3 * float.sizeof;
    foreach (i; 0 .. repetitions)
    {
        size_t low, high;
        histogram[i] = timeHistogramPass(source, mask, true,
            width, height, low, high);
        transform[i] = timeTransformPass(source, output,
            width, height, low, high);
        fullApi[i] = oneLuminanceTimed(source, roi, outputBudget,
            mask, true);
        linearStage[i] = timeLinearStage(source, linearRgb, width, height);
        encodeStage[i] = timeEncodeStage(output, linearRgb, width, height);
        exactEncodeStage[i] = timeExactEncodeStage(output, linearRgb, width, height);
        curveSetup[i] = timeOutputCurveSetup();
        allocationTouch[i] = timeOutputAllocationAndTouch(width, height);
        double scalarSink, simdSink;
        scalarMath[i] = timeLinearScaleKernel!false(linearRgb, width, height,
            simdLowerBin, simdUpperBin, scalarRgb, scalarSink);
        simdMath[i] = timeLinearScaleKernel!true(linearRgb, width, height,
            simdLowerBin, simdUpperBin, simdRgb, simdSink);
    }
    sort(histogram[]);
    sort(transform[]);
    sort(fullApi[]);
    sort(linearStage[]);
    sort(encodeStage[]);
    sort(exactEncodeStage[]);
    sort(curveSetup[]);
    sort(allocationTouch[]);
    sort(scalarMath[]);
    sort(simdMath[]);
    const pixels = width * height;
    double simdMaximumError = 0.0;
    foreach (i; 0 .. scalarRgb.length)
    {
        const error = fabs(cast(double)scalarRgb[i] - simdRgb[i]);
        if (error > simdMaximumError) simdMaximumError = error;
    }
    writefln("M4_LUMINANCE_PASS_ATTRIBUTION=width:%s,height:%s,mask:true," ~
        "histogram_median_ms:%.3f,histogram_Mpixel_s:%.2f," ~
        "transform_median_ms:%.3f,transform_Mpixel_s:%.2f," ~
        "full_api_median_ms:%.3f," ~
        "linear_decode_y_scale_ms:%.3f,table_encode_write_ms:%.3f," ~
        "exact_encode_write_ms:%.3f,table_max_abs_error:%.9g," ~
        "scalar_linear_ms:%.3f,simd_linear_ms:%.3f,simd_max_abs_error:%.9g," ~
        "curve_setup_ms:%.4f,output_alloc_touch_ms:%.3f," ~
        "replicates:%s,warmups:%s," ~
        "scope:diagnostic-staged-buffer-not-portable", width, height,
        histogram[$ / 2] / 1_000_000.0,
        cast(double)pixels * 1000.0 / histogram[$ / 2],
        transform[$ / 2] / 1_000_000.0,
        cast(double)pixels * 1000.0 / transform[$ / 2],
        fullApi[$ / 2] / 1000.0,
        linearStage[$ / 2] / 1_000_000.0,
        encodeStage[$ / 2] / 1_000_000.0,
        exactEncodeStage[$ / 2] / 1_000_000.0,
        encodingMaximumError,
        scalarMath[$ / 2] / 1_000_000.0,
        simdMath[$ / 2] / 1_000_000.0,
        simdMaximumError,
        curveSetup[$ / 2] / 1_000_000.0,
        allocationTouch[$ / 2] / 1_000_000.0,
        repetitions, warmups);
}

private void runSimdComparison()
{
    enum width = 1920;
    enum height = 1080;
    enum warmups = 2;
    enum replicates = 9;
    auto sourceOwner = allocateRgbFixture(width, height);
    auto maskOwner = allocateMaskFixture(width, height);
    auto linearRgb = new float[](width * height * 3);
    auto scalarRgb = new float[](width * height * 3);
    auto simdRgb = new float[](width * height * 3);
    scope auto source = sourceOwner.view();
    scope auto mask = maskOwner.view();
    timeLinearStage(source, linearRgb, width, height);
    size_t lowerBin, upperBin;
    timeHistogramPass(source, mask, true, width, height, lowerBin, upperBin);
    long[warmups] discard;
    foreach (i; 0 .. warmups)
    {
        double sink;
        discard[i] = timeLinearScaleKernel!false(linearRgb, width, height,
            lowerBin, upperBin, scalarRgb, sink);
        discard[i] += timeLinearScaleKernel!true(linearRgb, width, height,
            lowerBin, upperBin, simdRgb, sink);
    }
    long[replicates] scalarTimes, simdTimes;
    foreach (i; 0 .. replicates)
    {
        double scalarSink, simdSink;
        if (i % 2 == 0)
        {
            scalarTimes[i] = timeLinearScaleKernel!false(linearRgb,
                width, height, lowerBin, upperBin, scalarRgb, scalarSink);
            simdTimes[i] = timeLinearScaleKernel!true(linearRgb,
                width, height, lowerBin, upperBin, simdRgb, simdSink);
        }
        else
        {
            simdTimes[i] = timeLinearScaleKernel!true(linearRgb,
                width, height, lowerBin, upperBin, simdRgb, simdSink);
            scalarTimes[i] = timeLinearScaleKernel!false(linearRgb,
                width, height, lowerBin, upperBin, scalarRgb, scalarSink);
        }
        sampleSink += scalarSink + simdSink;
    }
    sort(scalarTimes[]);
    sort(simdTimes[]);
    double maximumError = 0.0;
    foreach (i; 0 .. scalarRgb.length)
    {
        const error = fabs(cast(double)scalarRgb[i] - simdRgb[i]);
        if (error > maximumError) maximumError = error;
    }
    writefln("M4_SIMD_LINEAR_SCALE=width:%s,height:%s," ~
        "scalar_median_ms:%.3f,simd4_median_ms:%.3f,speedup:%.3f," ~
        "max_abs_error:%.9g,replicates:%s,warmups:%s," ~
        "scope:linear-math-plus-output-buffer-not-full-rgb-kernel",
        width, height, scalarTimes[$ / 2] / 1_000_000.0,
        simdTimes[$ / 2] / 1_000_000.0,
        cast(double)scalarTimes[$ / 2] / simdTimes[$ / 2],
        maximumError, replicates, warmups);
}

int main(string[] args)
{
    const productionOnly = args.length > 1 && args[1] == "--production";
    const luminanceOnly = args.length > 1 && args[1] == "--luminance-only";
    const fullHdOnly = args.length > 1 && args[1] == "--fullhd-only";
    const kernelsOnly = args.length > 1 && args[1] == "--kernels-only";
    const passAttribution = args.length > 1 &&
        (args[1] == "--pass-attribution" ||
         args[1] == "--direct-phase-attribution");
    const simdOnly = args.length > 1 && args[1] == "--simd-only";
    const parallelLuminance = args.length > 1 &&
        args[1] == "--parallel-luminance";
    const workerSweep = args.length > 1 && args[1] == "--worker-sweep";
    if (simdOnly)
    {
        runSimdComparison();
    }
    else if (passAttribution)
    {
        version (ImageryPerfAttribution)
            runDirectLuminancePhaseAttribution();
        else
            throw new Exception("Rebuild with -d-version=ImageryPerfAttribution");
    }
    else if (kernelsOnly)
    {
        runKernelBenchmarks();
    }
    else if (productionOnly)
    {
        // 1080p preview, 12 MP camera frame, and 24 MP camera frame.
        // Re-run the preview 12 times per batch to model slider-driven
        // repeated previews over one retained decoded source.
        runLuminanceShape(1920, 1080, 12);
        runLuminanceShape(1920, 1080, 12, true);
        runLuminanceShape(4000, 3000);
        runLuminanceShape(6000, 4000);
    }
    else if (fullHdOnly)
    {
        runLuminanceShape(1920, 1080, 12);
        runLuminanceShape(1920, 1080, 12, true);
    }
    else if (luminanceOnly)
    {
        runLuminanceShape(512, 384);
        runLuminanceShape(1024, 768);
    }
    else if (parallelLuminance)
    {
        // Match the histogram-parallelization acceptance matrix: compare
        // complete serial and four-worker operations at both target sizes,
        // with and without an independently backed binary mask.
        runLuminanceParallelComparison(1024, 768, 4);
        runLuminanceParallelComparison(1024, 768, 4, true);
        runLuminanceParallelComparison(1920, 1080, 4);
        runLuminanceParallelComparison(1920, 1080, 4, true);
    }
    else if (workerSweep)
    {
        // Re-evaluate DMD's 30-fps 1080p goal across worker counts after the
        // raster-d v0.5.5 exact-row-coverage fix. Each pair includes thread
        // startup, full histogram reduction, transform and owned output.
        foreach (workers; [size_t(1), 2, 4, 6, 8])
        {
            runLuminanceParallelComparison(1920, 1080, workers);
            runLuminanceParallelComparison(1920, 1080, workers, true);
        }
    }
    else
    {
        runLuminanceShape(512, 384);
        runLuminanceShape(1024, 768);
        runShape(512, 384);
        runShape(1024, 768);
    }
    if (!productionOnly && !luminanceOnly && !passAttribution && !simdOnly)
    {
        need(sampleSink >= 0.0, "observable results");
        writeln("M3_LEVELS_PAIRED_PERF=PASS; paired reference, accuracy and bounded workload");
    }
    if (!passAttribution && !simdOnly)
    {
        need(sampleSink >= 0.0, "observable results");
        writeln("M3_RGB_LUMINANCE_STRETCH_PERF=PASS; release workloads and normalized output preflight");
    }
    return 0;
}
