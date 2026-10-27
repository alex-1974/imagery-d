module app;

import core.stdc.stdlib : malloc;
import std.math : sqrt;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import imagery :
    Levels, LevelsError, tryLevelsOwned, RgbHistogram256,
    RgbHistogramError, tryRgbHistogram256, tryRgbCumulativeCounts,
    tryRgbPercentile, tryRgbPercentileStretchLut,
    tryRgbEqualizationLut, LuminanceStretchError,
    tryRgbLuminanceStretchOwned;

static assert(LevelsError.init == LevelsError.notAttempted);
static assert(LevelsError.init != LevelsError.none);
static assert(LevelsError.invalidSource != LevelsError.invalidRegion);
static assert(LevelsError.resultExceedsBudget != LevelsError.allocationFailure);

private enum size_t W = 8;
private enum size_t H = 6;
private enum Layout : ubyte { planar, interleaved }

private void need(bool valid, string message)
{
    if (!valid)
        throw new Exception("M3 candidate independent consumer: " ~ message);
}

private uint pixelCode(size_t channel, size_t x, size_t y)
{
    return cast(uint)((x*31 + y*17 + channel*13) % 256);
}

private T sample(T)(size_t channel, size_t x, size_t y)
{
    static if (is(T == float))
    {
        if (channel == 0 && x == 2 && y == 1)
            return float.nan;
        if (channel == 1 && x == 5 && y == 4)
            return float.infinity;
        return cast(float)(cast(double)pixelCode(channel,x,y) / 255.0);
    }
    else static if (is(T == ushort))
        return cast(ushort)(pixelCode(channel,x,y) * 257);
    else
        return cast(ubyte)pixelCode(channel,x,y);
}

private ubyte coverage(size_t x, size_t y)
{
    switch ((x + 2*y) % 3)
    {
        case 0: return 0;
        case 1: return 128;
        default: return 255;
    }
}

private RasterLease!T makeOwner(T)(
    size_t width,size_t height,size_t bands,Layout layout,
    bool reverseRows = false, bool reverseSamples = false,
    size_t rowPadding = 0)
{
    const size_t channelsPerRow = layout == Layout.planar ? 1 : bands;
    const size_t rowBytes = (width * channelsPerRow + rowPadding) * T.sizeof;
    const size_t planeBytes = rowBytes * height;
    const size_t bytes = planeBytes * (layout == Layout.planar ? bands : 1);
    auto mem = cast(T*)malloc(bytes);
    need(mem !is null,"malloc image");
    OwnedByteResource owned;
    need(tryAdoptMallocResource(mem,bytes,owned),"adopt image");
    auto planes = new PlaneByteLayout[](bands);
    foreach (band; 0..bands)
    {
        const size_t sampleBytes = channelsPerRow * T.sizeof;
        const size_t start = layout == Layout.planar
            ? band * planeBytes : band * T.sizeof;
        planes[band] = PlaneByteLayout(
            start + (reverseRows ? (height - 1) * rowBytes : 0)
                + (reverseSamples ? (width - 1) * sampleBytes : 0),
            reverseRows ? -cast(ptrdiff_t)rowBytes : cast(ptrdiff_t)rowBytes,
            reverseSamples ? -cast(ptrdiff_t)sampleBytes : cast(ptrdiff_t)sampleBytes);
    }
    RasterLease!T lease;
    auto result = tryImportOwnedRaster!T(owned,planes[],
        Region2D(0,0,width,height),lease);
    need(result.ok,"import public raster-d owner");
    return lease;
}

private RasterLease!T makePixels(T)(size_t bands,Layout layout,
    bool reverseRows = false, bool reverseSamples = false,
    size_t rowPadding = 0)
{
    auto image=makeOwner!T(W,H,bands,layout,
        reverseRows,reverseSamples,rowPadding);
    bool writable;
    scope auto write=image.tryWritableView(writable);
    need(writable,"image writer");
    foreach(ch;0..bands)
    foreach(y;0..H)
    foreach(x;0..W)
        need(write.trySetSample(ch,x,y,sample!T(ch,x,y)),
            "image initialization");
    return image;
}

private RasterLease!ubyte makeSelection(
    bool reverseRows = false, bool reverseSamples = false,
    size_t rowPadding = 0)
{
    auto image=makeOwner!ubyte(W,H,1,Layout.planar,
        reverseRows,reverseSamples,rowPadding);
    bool writable;
    scope auto write=image.tryWritableView(writable);
    need(writable,"selection writer");
    foreach(y;0..H)
    foreach(x;0..W)
        need(write.trySetSample(0,x,y,coverage(x,y)),
            "selection mask initialization");
    return image;
}

// Mathematical fixture-domain oracle. It does not import the library's
// pixel normalization or gamma pow implementation.
private float expected(T)(
    size_t channel,size_t x,size_t y,size_t bands,
    bool masked,bool useGammaTwo)
{
    const float raw=sample!T(channel,x,y);
    static if (is(T == float))
        if (raw != raw || raw == float.infinity ||
            raw == -float.infinity)
            return raw;

    double v;
    static if (is(T == ubyte))
        v=cast(double)raw/255;
    else static if (is(T == ushort))
        v=cast(double)raw/65535;
    else
        v=cast(double)raw;

    if (bands==4 && channel==3)
        return cast(float)v; // channel 3 is explicitly unselected
    const weight=masked ? cast(double)coverage(x,y)/255 : 1.0;
    if(weight==0.0)
        return cast(float)v;

    double norm=(v-0.1)/0.8;
    if(norm<0.0) norm=0.0;
    if(norm>1.0) norm=1.0;
    // Identity gamma (1) and gamma 2 intentionally have independent
    // math implementation from library pow() through sqrt().
    const shaped=useGammaTwo ? sqrt(norm) : norm;
    const adjusted=0.05+0.90*shaped;
    return cast(float)(v*(1.0-weight)+weight*adjusted);
}

private bool sameFloat(float observed,float want)
{
    if(want!=want)
        return observed!=observed;
    if(want==float.infinity || want==-float.infinity)
        return observed==want;
    const d=observed-want;
    return d>=-0.000004f && d<=0.000004f;
}


private LevelsError ownedCall(T)(
    scope RasterView!T source,
    Region2D roi,
    scope const(bool)[] selection,
    Levels settings,
    RasterView!ubyte mask,
    bool withMask,
    size_t budget,
    ref RasterLease!float result)
{
    if (withMask)
        return tryLevelsOwned!T(
            source, roi, selection, settings, mask, budget, result);
    return tryLevelsOwned!T(
        source, roi, selection, settings, budget, result);
}

// Full-image and four ROI partitions must be bit-identical at every pixel.
// An independent fixture oracle uses sqrt for gamma=2 instead of pow().
private void runCase(T)(
    size_t bands, Layout layout, bool masked, bool gammaTwo)
{
    auto input = makePixels!T(bands, layout);
    auto maskOwner = makeSelection();
    auto mask = maskOwner.view();
    bool[4] rgbaSelection = [true, true, true, false];
    bool[1] graySelection = [true];
    const(bool)[] selected = bands == 4 ? rgbaSelection[] : graySelection[];
    Levels settings = Levels(0.1, 0.9,
        gammaTwo ? 2.0 : 1.0, 0.05, 0.95);
    const Region2D[5] rois = [
        Region2D(0,0,W,H),
        Region2D(0,0,4,3), Region2D(4,0,4,3),
        Region2D(0,3,4,3), Region2D(4,3,4,3)
    ];
    float[W*H*4] whole;
    foreach (iteration, roi; rois)
    {
        RasterLease!float output;
        const budget = roi.width * roi.height * bands * float.sizeof;
        need(ownedCall!T(
            input.view(), roi, selected, settings, mask, masked,
            budget, output) == LevelsError.none, "owned levels");
        scope auto view = output.view();
        need(view.planeCount == bands &&
            view.width == roi.width && view.height == roi.height,
            "owned output ROI shape");
        foreach (ch; 0 .. bands)
        foreach (yy; 0 .. roi.height)
        foreach (xx; 0 .. roi.width)
        {
            float actual;
            need(view.trySample(ch, xx, yy, actual), "owned pixel read");
            const x = roi.x + xx, y = roi.y + yy;
            need(sameFloat(actual,
                expected!T(ch, x, y, bands, masked, gammaTwo)),
                "independent scalar math oracle");
            const i = ch*W*H + y*W + x;
            if (iteration == 0)
                whole[i] = actual;
            else
                need((actual == whole[i]) ||
                    (actual != actual && whole[i] != whole[i]),
                    "whole vs quadrant exact equality");
        }
    }
}

private void runFailures(T)(bool masked)
{
    auto input = makePixels!T(4, Layout.interleaved);
    auto maskOwner = makeSelection();
    scope auto mask = maskOwner.view();
    bool[4] selected = [true, true, true, false];
    enum size_t exactBytes = W * H * 4 * float.sizeof;
    Levels settings = Levels(0.1, 0.9, 2.0, 0.05, 0.95);

    // Previous live owner stays unchanged on all returned failures.
    auto prior = makeOwner!float(1, 1, 1, Layout.planar);
    {
        bool writable;
        scope auto write = prior.tryWritableView(writable);
        need(writable && write.trySetSample(0, 0, 0, -987.0f),
            "old owner sentinel");
    }
    auto invalid = settings;
    invalid.gamma = 0;
    need(ownedCall!T(input.view(), Region2D(0,0,W,H),
        selected[], invalid, mask, masked, exactBytes, prior)
        == LevelsError.invalidParameters, "gamma zero reject");
    need(ownedCall!T(input.view(), Region2D(W-1,H-1,size_t.max,H),
        selected[], settings, mask, masked, exactBytes, prior)
        == LevelsError.invalidRegion, "out of bounds ROI reject");
    bool[1] shortSelection = [true];
    need(ownedCall!T(input.view(), Region2D(0,0,W,H),
        shortSelection[], settings, mask, masked, exactBytes, prior)
        == LevelsError.invalidChannelSelection, "channel count reject");
    need(ownedCall!T(input.view(), Region2D(0,0,W,H),
        selected[], Levels.init, mask, masked, exactBytes, prior)
        == LevelsError.invalidParameters, "invalid .init settings");
    need(ownedCall!T(input.view(), Region2D(0,0,W,H),
        selected[], settings, mask, masked, exactBytes-1, prior)
        == LevelsError.resultExceedsBudget, "one byte short budget");
    need(ownedCall!T(input.view(), Region2D(0,0,W,H),
        selected[], settings, mask, masked, 0, prior)
        == LevelsError.resultExceedsBudget, "zero budget");
    if (masked)
        need(tryLevelsOwned!T(input.view(), Region2D(0,0,W,H),
            selected[], settings, RasterView!ubyte.init,
            exactBytes, prior) == LevelsError.invalidMask,
            "explicit .init mask reject");

    {
        scope auto oldView = prior.view();
        float value;
        need(oldView.planeCount == 1 && oldView.width == 1 &&
            oldView.height == 1 &&
            oldView.trySample(0,0,0,value) && value == -987.0f,
            "returned errors preserve live owner");
    }

    need(ownedCall!T(input.view(), Region2D(0,0,W,H),
        selected[], settings, mask, masked, exactBytes, prior)
        == LevelsError.none, "exact byte budget accepted");
    scope auto output = prior.view();
    need(output.planeCount == 4 &&
        output.width == W && output.height == H,
        "owned result published");
    foreach (ch;0..4)
    foreach (y;0..H)
    foreach (x;0..W)
    {
        float found;
        need(output.trySample(ch,x,y,found) &&
            sameFloat(found, expected!T(ch,x,y,4,masked,true)),
            "owned old replacement numeric oracle");
    }
}


/++
 Independently check finite but overflowing threshold spans, gamma extremes,
 nonfinite inputs, channel passthrough and failure publication.
 The main 48-case corpus deliberately uses ordinary [0,1] thresholds, so
 these exact boundary inputs must be validated separately.
+/
private void runNumericAudit()
{
    auto source = makeOwner!float(1, 1, 1, Layout.planar);
    bool writable;
    {
        scope auto write = source.tryWritableView(writable);
        need(writable && write.trySetSample(0, 0, 0, 0.0f),
            "numeric audit initializes source");
    }

    bool[1] chosen = [true];
    RasterLease!float previous;
    const roi = Region2D(0, 0, 1, 1);

    // A mathematically symmetric valid threshold interval spans ~2*DBL_MAX:
    // subtraction overflows but the exact normalized input 0 is 1/2.
    const hugeSpan = Levels(-double.max, double.max, 1, 0, 1);
    need(tryLevelsOwned!float(
        source.view(), roi, chosen[], hugeSpan, float.sizeof, previous)
        == LevelsError.none, "finite huge threshold interval accepted");
    {
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) &&
            actual == 0.5f,
            "huge-span normalized point is one half, not zero");
    }

    // Gamma=2 has an independent sqrt reference even for overflowing span.
    const hugeGamma = Levels(-double.max, double.max, 2, 0, 1);
    need(tryLevelsOwned!float(
        source.view(), roi, chosen[], hugeGamma, float.sizeof, previous)
        == LevelsError.none, "huge span + gamma succeeds");
    {
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) &&
            sameFloat(actual, cast(float)sqrt(0.5)),
            "huge-span gamma2 independent sqrt oracle");
    }

    // Extreme positive gamma remains representable as a parameter even
    // if its reciprocal underflows/overflows in intermediate arithmetic.
    {
        scope auto write = source.tryWritableView(writable);
        need(writable && write.trySetSample(0, 0, 0, 0.5f),
            "gamma source initialization");
    }
    const tinyGamma = Levels(0, 1, 1.0e-300 / 1.0e20, 0, 1);
    const hugeGammaParam = Levels(0, 1, double.max, 0, 1);
    need(tryLevelsOwned!float(
        source.view(), roi, chosen[], tinyGamma, float.sizeof, previous)
        == LevelsError.none, "subnormal positive gamma accepted");
    {
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) &&
            actual >= 0.0f && actual < 0.001f,
            "extremely small gamma maps half-channel near zero");
    }
    need(tryLevelsOwned!float(
        source.view(), roi, chosen[], hugeGammaParam, float.sizeof, previous)
        == LevelsError.none, "very large positive gamma accepted");
    {
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) &&
            actual > 0.999f && actual <= 1.0f,
            "huge gamma maps interior sample near one");
    }

    // The new gamma==2 sqrt fast path must not silently replace the
    // general pow semantics. Gamma=4 exercises the fallback, compared
    // independently with nested square roots rather than pow().
    const quarterPower = Levels(0, 1, 4, 0, 1);
    need(tryLevelsOwned!float(
        source.view(), roi, chosen[], quarterPower, float.sizeof, previous)
        == LevelsError.none, "gamma4 fallback remains supported");
    {
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) &&
            sameFloat(actual, cast(float)sqrt(sqrt(0.5))),
            "gamma4 pow fallback vs independent nested sqrt");
    }

    // Permanent regression from 90-digit Decimal differential testing:
    // with original=-float.max and full selection, computing
    // original + (mapped-original) cancels to 0 instead of mapping to
    // outputBlack=0.05. Cover both public overloads and zero strength.
    {
        bool changed;
        scope auto writer = source.tryWritableView(changed);
        need(changed && writer.trySetSample(0, 0, 0, -float.max),
            "high-dynamic-range cancellation source");
    }
    const cancellation = Levels(-2, 2, 4, 0.05, 0.95);
    need(tryLevelsOwned!float(source.view(), roi, chosen[],
        cancellation, float.sizeof, previous) == LevelsError.none,
        "full-strength HDR no-mask mapping");
    {
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) &&
            sameFloat(actual, 0.05f), "full-strength HDR no cancellation");
    }
    auto editMask = makeOwner!ubyte(1, 1, 1, Layout.planar);
    {
        bool changed;
        scope auto writer = editMask.tryWritableView(changed);
        need(changed && writer.trySetSample(0, 0, 0, 255),
            "full edit-mask coverage");
    }
    need(tryLevelsOwned!float(source.view(), roi, chosen[],
        cancellation, editMask.view(), float.sizeof, previous)
        == LevelsError.none, "full-strength HDR masked mapping");
    {
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) &&
            sameFloat(actual, 0.05f), "full-strength edit-mask no cancellation");
    }
    {
        bool changed;
        scope auto writer = editMask.tryWritableView(changed);
        need(changed && writer.trySetSample(0, 0, 0, 0),
            "zero edit-mask coverage");
    }
    need(tryLevelsOwned!float(source.view(), roi, chosen[],
        cancellation, editMask.view(), float.sizeof, previous)
        == LevelsError.none, "zero mask pass-through");
    {
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) && actual == -float.max,
            "zero mask preserves finite extreme source");
    }
    {
        bool changed;
        scope auto writer = source.tryWritableView(changed);
        need(changed && writer.trySetSample(0, 0, 0, 0.5f),
            "reset after cancellation audit");
    }

    // No edit channel means *numeric* passthrough, not implicit alpha.
    bool[1] noneSelected = [false];
    need(tryLevelsOwned!float(
        source.view(), roi, noneSelected[], hugeSpan,
        float.sizeof, previous) == LevelsError.none,
        "all channels unselected is a defined passthrough");
    {
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) && actual == 0.5f,
            "unselected numeric channel unchanged");
    }

    // Validate a selected NaN and both infinity signs (not a NoData mask).
    foreach (special; [float.nan, float.infinity, -float.infinity])
    {
        {
            scope auto write = source.tryWritableView(writable);
            need(writable && write.trySetSample(0, 0, 0, special),
                "nonfinite input initialization");
        }
        need(tryLevelsOwned!float(
            source.view(), roi, chosen[], Levels(0, 1, 2, 0, 1),
            float.sizeof, previous) == LevelsError.none,
            "nonfinite float copied, not edited");
        scope auto view = previous.view();
        float actual;
        need(view.trySample(0, 0, 0, actual) &&
            (special != special ? actual != actual : actual == special),
            "nonfinite preserved numerically");
    }

    // Invalid settings and budget must preserve the last result lease.
    need(tryLevelsOwned!float(
        source.view(), roi, chosen[],
        Levels(-double.infinity, 1, 1, 0, 1),
        float.sizeof, previous) == LevelsError.invalidParameters,
        "nonfinite input threshold rejected before allocation");
    need(tryLevelsOwned!float(
        source.view(), roi, chosen[],
        Levels(0, 1, 1, 0, 1), 0, previous)
        == LevelsError.resultExceedsBudget,
        "zero payload budget rejected after numeric setup");
    {
        scope auto view = previous.view();
        float actual;
        need(view.planeCount == 1 && view.width == 1 &&
            view.trySample(0, 0, 0, actual) &&
            actual == -float.infinity,
            "returned failures retain old nonfinite result");
    }
    writeln("M3_LEVELS_NUMERIC_AUDIT=PASS");
}

/++
 Owner-alias audit: the published lease may be the owner that provides the
 input borrowed view. Read must complete before replacing that same owner.
 A separately retained copy of the old backing proves the new result
 cannot alias old pixels, and returned failures preserve the new owner.
+/
private void runOwnershipAudit()
{
    auto image = makeOwner!float(1, 1, 1, Layout.planar);
    bool writable;
    {
        scope auto write = image.tryWritableView(writable);
        need(writable && write.trySetSample(0, 0, 0, 0.25f),
            "owner-alias source setup");
    }
    auto priorOwner = image; // Independent lease retains original backing.
    bool[1] chosen = [true];
    const roi = Region2D(0, 0, 1, 1);
    const levels = Levels(0, 1, 2, 0, 1);

    need(tryLevelsOwned!float(
        image.view(), roi, chosen[], levels, float.sizeof, image)
        == LevelsError.none, "aliasing owner replacement succeeds");
    {
        scope auto oldView = priorOwner.view();
        scope auto newView = image.view();
        float before, after;
        need(oldView.trySample(0, 0, 0, before) &&
             newView.trySample(0, 0, 0, after) &&
             before == 0.25f && after == 0.5f,
             "fresh result does not alias retained source backing");
    }

    // Write to the old resource after replacement. The new owner MUST
    // remain unaffected even though its input was the earlier owner.
    {
        scope auto oldWritable = priorOwner.tryWritableView(writable);
        need(writable && oldWritable.trySetSample(0, 0, 0, 1.0f),
             "write to retained old owner");
    }
    {
        scope auto newView = image.view();
        float after;
        need(newView.trySample(0, 0, 0, after) && after == 0.5f,
             "new result physically independent of old backing");
    }

    need(tryLevelsOwned!float(
        image.view(), roi, chosen[], levels, 0, image)
        == LevelsError.resultExceedsBudget,
        "self-owner request with rejected budget");
    {
        scope auto newView = image.view();
        float after;
        need(newView.trySample(0, 0, 0, after) && after == 0.5f,
             "self-owner returned failure preserves result");
    }
    writeln("M3_LEVELS_OWNER_ALIAS_AUDIT=PASS");
}

/++
 Independent image RGB histogram oracle using three actual u8 channels
 and the ordinary raster-d planar/interleaved owner constructors above.
 Expected statistics are computed directly from the synthetic source
 function, NOT from the histogram implementation.
+/
private void runRgbHistogramAudit()
{
    static assert(RgbHistogramError.init == RgbHistogramError.notAttempted);
    static assert(RgbHistogramError.init != RgbHistogramError.none);
    enum Region2D full = Region2D(0, 0, W, H);
    const Region2D[5] rois = [
        Region2D(0, 0, W, H), Region2D(0, 0, 4, 3),
        Region2D(4, 0, 4, 3), Region2D(0, 3, 4, 3),
        Region2D(4, 3, 4, 3)
    ];
    foreach (layout; [Layout.planar, Layout.interleaved])
    foreach (reverseRows; [false, true])
    foreach (reverseSamples; [false, true])
    foreach (masked; [false, true])
    {
        const size_t padding = reverseRows || reverseSamples ? 5 : 0;
        auto image = makePixels!ubyte(3, layout,
            reverseRows, reverseSamples, padding);
        // Deliberately use a different mask layout from the RGB raster.
        auto selection = makeSelection(!reverseRows, !reverseSamples, 3);
        RgbHistogram256[5] records;
        foreach (index, roi; rois)
        {
            RgbHistogram256 observed;
            const status = masked
                ? tryRgbHistogram256(image.view(), roi,
                    selection.view(), observed)
                : tryRgbHistogram256(image.view(), roi, observed);
            need(status == RgbHistogramError.none,
                "RGB histogram completed");

            ulong[256][3] expectedBins;
            ulong[3] expectedSum;
            ulong included, excluded;
            ubyte[3] minimum, maximum;
            foreach (y; roi.y .. roi.y + roi.height)
            foreach (x; roi.x .. roi.x + roi.width)
            {
                if (masked && coverage(x, y) == 0)
                {
                    ++excluded;
                    continue;
                }
                foreach (channel; 0 .. 3)
                {
                    const value = cast(ubyte)pixelCode(channel, x, y);
                    ++expectedBins[channel][value];
                    expectedSum[channel] += value;
                    if (included == 0 || value < minimum[channel])
                        minimum[channel] = value;
                    if (included == 0 || value > maximum[channel])
                        maximum[channel] = value;
                }
                ++included;
            }
            need(observed.includedPixels == included &&
                 observed.excludedPixels == excluded &&
                 included + excluded == roi.width * roi.height,
                 "RGB selected/excluded ROI cardinality");
            foreach (channel; 0 .. 3)
            {
                ulong summed;
                foreach (v; 0 .. 256)
                {
                    need(observed.bins[channel][v] ==
                        expectedBins[channel][v],
                        "independent RGB bin oracle");
                    summed += observed.bins[channel][v];
                }
                need(summed == included, "RGB channel sum");
                need(observed.minimum[channel] == minimum[channel] &&
                     observed.maximum[channel] == maximum[channel],
                     "RGB observed extrema");
                const mean = included == 0 ? 0.0 :
                    cast(double)expectedSum[channel] / included;
                const delta = observed.mean[channel] - mean;
                need(delta >= -1.0e-12 && delta <= 1.0e-12,
                    "RGB independent mean");
            }
            ulong[256][3] cumulative;
            need(tryRgbCumulativeCounts(observed, cumulative),
                "RGB cumulative counts accepted");
            foreach (channel; 0 .. 3)
            {
                ulong count;
                foreach (v; 0 .. 256)
                {
                    count += expectedBins[channel][v];
                    need(cumulative[channel][v] == count,
                        "RGB independent cumulative count");
                }
            }
            foreach (percentile; [0U, 1U, 50U, 99U, 100U])
            {
                ubyte[3] actual;
                need(tryRgbPercentile(observed, percentile, actual) ==
                    (included != 0), "RGB percentile availability");
                if (included == 0)
                    continue;
                const rank = percentile == 0 ? 1UL :
                    (percentile * included + 99) / 100;
                foreach (channel; 0 .. 3)
                {
                    ulong count;
                    foreach (v; 0 .. 256)
                    {
                        count += expectedBins[channel][v];
                        if (count >= rank)
                        {
                            need(actual[channel] == v,
                                "RGB independent percentile rank");
                            break;
                        }
                    }
                }
            }
            ubyte[256][3] lut;
            need(tryRgbPercentileStretchLut(observed, 1, 99, lut) ==
                (included != 0), "RGB contrast LUT availability");
            if (included != 0)
                foreach (channel; 0 .. 3)
                {
                    ubyte[2] bounds;
                    foreach (boundaryIndex, percentile; [1U, 99U])
                    {
                        const rank = (percentile * included + 99) / 100;
                        ulong count;
                        foreach (v; 0 .. 256)
                        {
                            count += expectedBins[channel][v];
                            if (count >= rank)
                            {
                                bounds[boundaryIndex] = cast(ubyte)v;
                                break;
                            }
                        }
                    }
                    foreach (v; 0 .. 256)
                    {
                        uint expected;
                        if (bounds[0] == bounds[1])
                            expected = cast(uint)v;
                        else if (v <= bounds[0])
                            expected = 0;
                        else if (v >= bounds[1])
                            expected = 255;
                        else
                            expected = cast(uint)(
                                cast(double)(v - bounds[0]) * 255 /
                                (bounds[1] - bounds[0]) + 0.5);
                        need(lut[channel][v] == expected,
                            "RGB independent contrast LUT mapping");
                        if (v != 0)
                            need(lut[channel][v - 1] <= lut[channel][v],
                                "RGB contrast LUT monotonicity");
                    }
                }
            ubyte[256][3] equalized;
            need(tryRgbEqualizationLut(observed, equalized) ==
                (included != 0), "RGB equalization LUT availability");
            if (included != 0)
                foreach (channel; 0 .. 3)
                {
                    ulong firstCount;
                    foreach (count; expectedBins[channel])
                        if (count != 0)
                        {
                            firstCount = count;
                            break;
                        }
                    ulong count;
                    foreach (v; 0 .. 256)
                    {
                        count += expectedBins[channel][v];
                        const expected = firstCount == included
                            ? cast(uint)v
                            : count <= firstCount ? 0U
                            : cast(uint)(255.0 * (count - firstCount) /
                                (included - firstCount) + 0.5);
                        need(equalized[channel][v] == expected,
                            "RGB independent equalization LUT mapping");
                        if (v != 0)
                            need(equalized[channel][v - 1] <=
                                equalized[channel][v],
                                "RGB equalization LUT monotonicity");
                    }
                }
            records[index] = observed;
        }

        foreach (channel; 0 .. 3)
        foreach (v; 0 .. 256)
        {
            ulong parts;
            foreach (i; 1 .. 5)
                parts += records[i].bins[channel][v];
            need(parts == records[0].bins[channel][v],
                "RGB whole vs four quadrant exact bins");
        }
        ulong selectedParts, skippedParts;
        foreach (i; 1 .. 5)
        {
            selectedParts += records[i].includedPixels;
            skippedParts += records[i].excludedPixels;
        }
        need(selectedParts == records[0].includedPixels &&
            skippedParts == records[0].excludedPixels,
            "RGB whole vs partition selection accounting");

        // Source and mask may already be non-origin ROI views. The API's
        // ROI and mask shape are relative to these supplied views.
        {
            bool imageOk, maskOk;
            scope auto subimage = image.view().tryRoi(
                Region2D(1, 1, W - 2, H - 2), imageOk);
            scope auto submask = selection.view().tryRoi(
                Region2D(1, 1, W - 2, H - 2), maskOk);
            need(imageOk && maskOk, "RGB nested ROI setup");
            RgbHistogram256 nested, direct;
            const local = Region2D(1, 1, 2, 2);
            const absolute = Region2D(2, 2, 2, 2);
            const nestedStatus = masked
                ? tryRgbHistogram256(subimage, local, submask, nested)
                : tryRgbHistogram256(subimage, local, nested);
            const directStatus = masked
                ? tryRgbHistogram256(image.view(), absolute, selection.view(), direct)
                : tryRgbHistogram256(image.view(), absolute, direct);
            need(nestedStatus == RgbHistogramError.none &&
                directStatus == RgbHistogramError.none && nested == direct,
                "RGB nested source/mask ROI coordinates");
        }

        // Distinct prior value must survive each classified error.
        auto prior = records[0];
        const previous = prior;
        auto gray = makeOwner!ubyte(W, H, 1, Layout.planar);
        need(tryRgbHistogram256(gray.view(), full, prior) ==
            RgbHistogramError.invalidSource && prior == previous,
            "RGB rejects 1-plane image and keeps prior");
        need(tryRgbHistogram256(image.view(), Region2D(W, 0, 1, 1),
            prior) == RgbHistogramError.invalidRegion &&
            prior == previous, "RGB ROI out of bounds retains prior");
        need(tryRgbHistogram256(image.view(), Region2D(0, 0, 0, 1),
            prior) == RgbHistogramError.invalidRegion &&
            prior == previous, "RGB empty ROI retains prior");
        need(tryRgbHistogram256(image.view(), full,
            RasterView!ubyte.init, prior) ==
            RgbHistogramError.invalidMask && prior == previous,
            "RGB invalid selection retains prior");
        need(tryRgbHistogram256(image.view(), full,
            image.view(), prior) == RgbHistogramError.invalidMask &&
            prior == previous, "RGB three-plane mask rejected");

        // An all-nonzero mask must agree with the generic unmasked
        // reduction, regardless of its magnitude (binary, not weighted).
        {
            bool writable;
            auto all = makeOwner!ubyte(W, H, 1, Layout.planar,
                !reverseRows, reverseSamples, 2);
            {
                scope auto write = all.tryWritableView(writable);
                foreach (y; 0 .. H)
                foreach (x; 0 .. W)
                    need(writable && write.trySetSample(0, x, y,
                        cast(ubyte)(1 + (x + y) % 255)), "RGB all-active mask");
            }
            RgbHistogram256 unmasked, maskedResult;
            need(tryRgbHistogram256(image.view(), full, unmasked) ==
                RgbHistogramError.none &&
                tryRgbHistogram256(image.view(), full, all.view(), maskedResult) ==
                RgbHistogramError.none && unmasked == maskedResult,
                "RGB generic unmasked vs all-active selection equality");
        }

        auto wrongShape = makeOwner!ubyte(W - 1, H, 1, Layout.planar);
        need(tryRgbHistogram256(image.view(), full, wrongShape.view(), prior) ==
            RgbHistogramError.invalidMask && prior == previous,
            "RGB mask grid mismatch retains prior");

        // All excluded is successful; a mask byte of 1 includes once.
        auto chosen = makeOwner!ubyte(W, H, 1, Layout.planar);
        bool writable;
        {
            scope auto write = chosen.tryWritableView(writable);
            need(writable, "RGB test mask writable");
            foreach (y; 0 .. H)
            foreach (x; 0 .. W)
                need(write.trySetSample(0, x, y, 0),
                    "RGB clear mask");
        }
        RgbHistogram256 none;
        need(tryRgbHistogram256(image.view(), full,
            chosen.view(), none) == RgbHistogramError.none &&
            none.includedPixels == 0 &&
            none.excludedPixels == W * H,
            "RGB all-excluded succeeds");
        foreach (channel; 0 .. 3)
        {
            need(none.minimum[channel] == 0 &&
                 none.maximum[channel] == 0 &&
                 none.mean[channel] == 0,
                 "RGB empty statistics defined");
            foreach (v; 0 .. 256)
                need(none.bins[channel][v] == 0,
                     "RGB empty histogram bins");
        }
        {
            scope auto write = chosen.tryWritableView(writable);
            need(writable && write.trySetSample(0, 1, 0, 1),
                "RGB nonzero one-byte inclusion");
        }
        need(tryRgbHistogram256(image.view(), full,
            chosen.view(), none) == RgbHistogramError.none &&
            none.includedPixels == 1 &&
            none.excludedPixels == W * H - 1,
            "RGB mask byte 1 includes exactly once");
        foreach (channel; 0 .. 3)
        {
            const value = cast(ubyte)pixelCode(channel, 1, 0);
            need(none.bins[channel][value] == 1 &&
                none.minimum[channel] == value &&
                none.maximum[channel] == value &&
                none.mean[channel] == value,
                "RGB selected single-pixel oracle");
        }
    }
    writeln("M3_RGB_HISTOGRAM_CONSUMER=PASS; 80 whole/ROI cases, signed strides and padding, " ~
        "exact bins and partition identity, explicit binary mask, rollback");
}

private void runLuminanceStretchConsumer()
{
    auto input = makeOwner!ubyte(4, 1, 3, Layout.planar);
    ubyte[4] levels = [16, 64, 128, 240];
    bool writable;
    {
        scope auto writer = input.tryWritableView(writable);
        need(writable, "luminance fixture writer");
        foreach (channel; 0 .. 3)
        foreach (x; 0 .. 4)
            need(writer.trySetSample(channel, x, 0,
                levels[x]),
                "initialize neutral luminance fixture");
    }
    RasterLease!float output;
    const status = tryRgbLuminanceStretchOwned!true(
        input.view(), Region2D(0, 0, 4, 1), 0, 100,
        4 * 3 * float.sizeof, output);
    need(status == LuminanceStretchError.none,
        "compiled color-d XYZ-Y consumer call");
    scope auto view = output.view();
    float r, g, b;
    need(view.trySample(0, 0, 0, r) &&
        view.trySample(1, 0, 0, g) && view.trySample(2, 0, 0, b),
        "read luminance result");
    need(r == g && g == b && r == 0.0f,
        "neutral black endpoint remains neutral");
    need(view.trySample(0, 3, 0, r) && r > 0.99f,
        "white endpoint stretches to white");

    auto selection = makeOwner!ubyte(4, 1, 1, Layout.planar);
    {
        scope auto writer = selection.tryWritableView(writable);
        need(writable, "luminance mask writer");
        const ubyte[4] mask = [0, 255, 255, 0];
        foreach (x; 0 .. 4)
            need(writer.trySetSample(0, x, 0, mask[x]),
                "initialize luminance selection mask");
    }
    need(tryRgbLuminanceStretchOwned!true(
            input.view(), Region2D(0, 0, 4, 1), 0, 100,
            selection.view(), 4 * 3 * float.sizeof, output) ==
        LuminanceStretchError.none,
        "masked luminance thresholds");
    {
        scope auto masked = output.view();
        need(masked.width == 4 && masked.height == 1,
            "mask does not crop output");
        need(masked.trySample(0, 0, 0, r) && r == 0.0f,
            "unselected low source pixel is still transformed");
        need(masked.trySample(0, 3, 0, r) && r > 0.99f,
            "unselected high source pixel is still transformed");
    }

    need(tryRgbLuminanceStretchOwned!true(
            input.view(), Region2D(1, 0, 2, 1), 0, 100,
            2 * 3 * float.sizeof, output) == LuminanceStretchError.none,
        "ROI-local luminance result");
    {
        scope auto cropped = output.view();
        need(cropped.width == 2 && cropped.height == 1,
            "output dimensions equal ROI dimensions");
    }

    auto emptySelection = makeOwner!ubyte(4, 1, 1, Layout.planar);
    {
        scope auto writer = emptySelection.tryWritableView(writable);
        need(writable, "empty luminance mask writer");
        foreach (x; 0 .. 4)
            need(writer.trySetSample(0, x, 0, 0),
                "initialize empty selection mask");
    }
    need(tryRgbLuminanceStretchOwned!true(
            input.view(), Region2D(0, 0, 4, 1), 0, 100,
            emptySelection.view(), 4 * 3 * float.sizeof, output) ==
        LuminanceStretchError.invalidMask,
        "empty mask rejected");
    {
        scope auto retained = output.view();
        need(retained.width == 2,
            "empty mask failure preserves prior ROI result");
    }

    auto colored = makeOwner!ubyte(3, 4, 3, Layout.planar);
    {
        scope auto writer = colored.tryWritableView(writable);
        need(writable, "colored gamut fixture writer");
        const ubyte[3][3] colors = [
            [0, 0, 0], [255, 0, 0], [255, 0, 0]
        ];
        foreach (y; 0 .. 4)
        foreach (x; 0 .. 3)
        foreach (channel; 0 .. 3)
            need(writer.trySetSample(channel, x, y, colors[x][channel]),
                "initialize gamut fixture");
    }
    need(tryRgbLuminanceStretchOwned!false(
            colored.view(), Region2D(0, 0, 3, 4), 0, 100,
            3 * 4 * 3 * float.sizeof, output, 4, 1) ==
        LuminanceStretchError.outOfGamut,
        "parallel non-clipping template joins workers and rolls back");
    {
        scope auto retained = output.view();
        need(retained.width == 2 && retained.trySample(0, 1, 0, r) &&
            r > 0.99f,
            "out-of-gamut failure preserves published result");
    }
    writeln("M3_RGB_LUMINANCE_STRETCH=PASS; independent color-d XYZ-D65-Y consumer");
}

void main()
{
    LevelsError neverCalled;
    need(neverCalled == LevelsError.notAttempted &&
         neverCalled != LevelsError.none,
         "default status must not represent an attempted success");
    foreach (bands; [cast(size_t)1, cast(size_t)4])
    foreach (layout; [Layout.planar, Layout.interleaved])
    foreach (masked; [false, true])
    foreach (gammaTwo; [false, true])
    {
        runCase!ubyte(bands,layout,masked,gammaTwo);
        runCase!ushort(bands,layout,masked,gammaTwo);
        runCase!float(bands,layout,masked,gammaTwo);
    }
    foreach(masked;[false,true])
    {
        runFailures!ubyte(masked);
        runFailures!ushort(masked);
        runFailures!float(masked);
    }
    runNumericAudit();
    runOwnershipAudit();
    runRgbHistogramAudit();
    runLuminanceStretchConsumer();
    writeln("M3_LEVELS_PRODUCTION_CONSUMER=PASS; 48 cases, 240 complete ROI outputs, 6 owned error paths and numeric audit");
}
