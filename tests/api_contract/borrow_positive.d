// Compile-only positive control: DUB paths and DIP1000 are configured.
module borrow_positive;
import raster : RasterLease;
@safe bool localBorrow()
{
    RasterLease!ubyte lease;
    scope auto view = lease.view();
    return view.planeCount == 0;
}

// Named-argument and UFCS probes are compile-only public syntax contracts.
// Invalid views are deliberately used: executing them is unnecessary.
import imagery : Levels, LevelsError, tryLevelsOwned;

// The draft public enum's .init must not silently claim successful work.
static assert(LevelsError.init == LevelsError.notAttempted);
static assert(LevelsError.init != LevelsError.none);
static assert(LevelsError.notAttempted != LevelsError.none);
import raster : RasterView, Region2D;

void ordinaryPublicCalls()
{
    bool[1] selected = [true];
    RasterLease!float published;
    auto source = RasterView!ubyte.init;
    auto mask = RasterView!ubyte.init;
    auto unmasked = tryLevelsOwned!ubyte(
        pixels: source, roi: Region2D(0, 0, 1, 1),
        affected: selected[], settings: Levels(0, 1, 1, 0, 1),
        maxResultBytes: float.sizeof, published: published);
    auto masked = tryLevelsOwned!ubyte(
        pixels: source, roi: Region2D(0, 0, 1, 1),
        affected: selected[], settings: Levels(0, 1, 1, 0, 1),
        selection: mask, maxResultBytes: float.sizeof,
        published: published);
    auto ufcs = source.tryLevelsOwned!ubyte(
        Region2D(0, 0, 1, 1), selected[],
        Levels(0, 1, 1, 0, 1), float.sizeof, published);
    assert(unmasked == LevelsError.invalidSource &&
        masked == LevelsError.invalidSource &&
        ufcs == LevelsError.invalidSource);
}


// The public candidate must remain invocable directly from @safe code.
// No caller-owned raw pointer, fabricated safety wrapper or @trusted
// bridge is involved in these positive source-compilation checks.
@safe LevelsError safelyCallUnmasked(
    scope RasterView!ubyte pixels,
    ref RasterLease!float published)
{
    bool[1] affected = [true];
    return tryLevelsOwned!ubyte(
        pixels, Region2D(0, 0, 1, 1), affected[],
        Levels(0, 1, 1, 0, 1), float.sizeof, published);
}
@safe LevelsError safelyCallMasked(
    scope RasterView!float pixels,
    scope RasterView!ubyte mask,
    ref RasterLease!float published)
{
    bool[1] affected = [true];
    return tryLevelsOwned!float(
        pixels, Region2D(0, 0, 1, 1), affected[],
        Levels(0, 1, 1, 0, 1), mask, float.sizeof, published);
}


// Public RGB image histogram API, including named call syntax and @safe
// invocation, must be compile-valid in DMD/LDC DIP1000 contexts.
import imagery : RgbHistogram256, RgbHistogramError, tryRgbHistogram256,
    tryRgbCumulativeCounts, tryRgbPercentile, tryRgbPercentileStretchLut;
static assert(RgbHistogramError.init == RgbHistogramError.notAttempted);
@safe RgbHistogramError safelyHistogram(
    scope RasterView!ubyte rgb, scope RasterView!ubyte selection)
{
    RgbHistogram256 published;
    auto withoutMask = tryRgbHistogram256(
        rgb: rgb, roi: Region2D(0, 0, 1, 1),
        published: published);
    auto withMask = tryRgbHistogram256(
        rgb: rgb, roi: Region2D(0, 0, 1, 1),
        selection: selection, published: published);
    assert(withoutMask == RgbHistogramError.invalidSource);
    ulong[256][3] cumulative;
    ubyte[3] percentile;
    assert(tryRgbCumulativeCounts(published, cumulative));
    assert(!tryRgbPercentile(published, 50, percentile));
    ubyte[256][3] lut;
    assert(!tryRgbPercentileStretchLut(published, 1, 99, lut));
    return withMask;
}

// The derived lookup can run in a no-GC, nonthrowing pure consumer.
@safe pure nothrow @nogc bool safelyBuildContrastLut(
    const ref RgbHistogram256 histogram,
    ref ubyte[256][3] published)
{
    return tryRgbPercentileStretchLut(histogram, 1, 99, published);
}
