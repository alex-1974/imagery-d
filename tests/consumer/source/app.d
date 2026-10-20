module app;

import core.stdc.stdlib : malloc;
import std.math : sqrt;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import imagery : Levels, LevelsError, tryLevelsOwned;

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
    size_t width,size_t height,size_t bands,Layout layout)
{
    const size_t bytes = width*height*bands*T.sizeof;
    auto mem = cast(T*)malloc(bytes);
    need(mem !is null,"malloc image");
    OwnedByteResource owned;
    need(tryAdoptMallocResource(mem,bytes,owned),"adopt image");
    auto planes = new PlaneByteLayout[](bands);
    foreach (band; 0..bands)
        planes[band] = layout == Layout.planar
            ? PlaneByteLayout(band*width*height*T.sizeof,
                cast(ptrdiff_t)(width*T.sizeof),
                cast(ptrdiff_t)T.sizeof)
            : PlaneByteLayout(band*T.sizeof,
                cast(ptrdiff_t)(width*bands*T.sizeof),
                cast(ptrdiff_t)(bands*T.sizeof));
    RasterLease!T lease;
    auto result = tryImportOwnedRaster!T(owned,planes[],
        Region2D(0,0,width,height),lease);
    need(result.ok,"import public raster-d owner");
    return lease;
}

private RasterLease!T makePixels(T)(size_t bands,Layout layout)
{
    auto image=makeOwner!T(W,H,bands,layout);
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

private RasterLease!ubyte makeSelection()
{
    auto image=makeOwner!ubyte(W,H,1,Layout.planar);
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
    writeln("M3_LEVELS_PRODUCTION_CONSUMER=PASS; 48 cases, 240 complete ROI outputs, 6 owned error paths and numeric audit");
}
