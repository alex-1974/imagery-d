/++
 Independently built DUB photo-editor-like scalar Levels consumer.
 Pixel oracle uses independent fixture maths and sqrt instead of pow.
 This is research validation, NOT adoption by a deployed application.
+/
module app;

import core.stdc.stdlib : malloc;
import std.math : sqrt;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import imagery.presentation.levels_research :
    ResearchLevels, ResearchLevelsError, tryLevelsIntoResearch;
import imagery.presentation.levels_owned_research :
    tryLevelsOwnedResearch;

private enum size_t W = 8;
private enum size_t H = 6;
private enum Layout : ubyte { planar, interleaved }

private void need(bool valid, string message)
{
    if (!valid)
        throw new Exception("R-IM-03a image-editor consumer: " ~ message);
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

private void runCase(T)(
    size_t bands,Layout layout,bool useMask,bool gammaTwo)
{
    auto input=makePixels!T(bands,layout);
    auto selectionOwner=makeSelection();
    auto selection=useMask ? selectionOwner.view()
        : RasterView!ubyte.init;
    bool[4] rgbaSelection=[true,true,true,false];
    bool[1] graySelection=[true];
    const(bool)[] selected=bands==4 ?
        rgbaSelection[] : graySelection[];

    ResearchLevels levels=ResearchLevels(
        0.1,0.9,gammaTwo ? 2.0 : 1.0,0.05,0.95);
    const Region2D[5] rois=[
        Region2D(0,0,W,H),
        Region2D(0,0,4,3),Region2D(4,0,4,3),
        Region2D(0,3,4,3),Region2D(4,3,4,3)
    ];
    float[W*H*4] fullResults;

    foreach(iteration,roi;rois)
    {
        auto owner=makeOwner!float(roi.width,roi.height,bands,
            layout==Layout.planar ? Layout.interleaved : Layout.planar);
        bool writable;
        scope auto dst=owner.tryWritableView(writable);
        need(writable,"destination writer");
        auto status=tryLevelsIntoResearch!T(
            input.view(),roi,selected,levels,selection,useMask,dst);
        need(status==ResearchLevelsError.none,"levels kernel");
        auto result=owner.view();
        foreach(ch;0..bands)
        foreach(yy;0..roi.height)
        foreach(xx;0..roi.width)
        {
            float found;
            need(result.trySample(ch,xx,yy,found),
                "output pixel read");
            const x=roi.x+xx,y=roi.y+yy;
            const want=expected!T(ch,x,y,bands,useMask,gammaTwo);
            need(sameFloat(found,want),"independent pixel oracle");
            const n=ch*W*H+y*W+x;
            if(iteration==0)
                fullResults[n]=found;
            else
            {
                const origin=fullResults[n];
                need((found==origin) ||
                    (found!=found && origin!=origin),
                    "whole vs quadrant exact equality");
            }
        }
    }

    // All parameter/region/mask failures are detected before a single
    // overwrite of a live, initialized caller-owned output destination.
    auto owner=makeOwner!float(W,H,bands,Layout.planar);
    bool writable;
    scope auto dst=owner.tryWritableView(writable);
    need(writable,"negative destination");
    foreach(ch;0..bands)
    foreach(y;0..H)
    foreach(x;0..W)
        need(dst.trySetSample(ch,x,y,-777.0f),
            "write sentinel");

    need(tryLevelsIntoResearch!T(input.view(),
        Region2D(W-1,H-1,2,2),selected,levels,selection,
        useMask,dst)==ResearchLevelsError.invalidRegion,
        "bad ROI preflight");

    bool[1] tooFew=[true];
    if(bands==4)
        need(tryLevelsIntoResearch!T(input.view(),rois[0],
            tooFew[],levels,selection,useMask,dst) ==
            ResearchLevelsError.invalidChannelSelection,
            "bad channel selection");

    auto bad=levels;
    bad.gamma=0.0;
    need(tryLevelsIntoResearch!T(input.view(),rois[0],
        selected,bad,selection,useMask,dst) ==
        ResearchLevelsError.invalidParameters,
        "bad gamma");

    bad=levels;
    bad.inputWhite=bad.inputBlack;
    need(tryLevelsIntoResearch!T(input.view(),rois[0],
        selected,bad,selection,useMask,dst) ==
        ResearchLevelsError.invalidParameters,
        "collapsed input interval");

    bad=levels;
    bad.outputBlack=2.0;
    need(tryLevelsIntoResearch!T(input.view(),rois[0],
        selected,bad,selection,useMask,dst) ==
        ResearchLevelsError.invalidParameters,
        "bad output interval");

    need(tryLevelsIntoResearch!T(input.view(),rois[0],
        selected,levels,RasterView!ubyte.init,true,dst) ==
        ResearchLevelsError.invalidMask,
        "missing selected mask");

    auto shortOutput=makeOwner!float(W-1,H,bands,Layout.planar);
    bool shortWritable;
    scope auto shortDest=shortOutput.tryWritableView(shortWritable);
    need(shortWritable,"short output writer");
    need(tryLevelsIntoResearch!T(input.view(),rois[0],
        selected,levels,selection,useMask,shortDest) ==
        ResearchLevelsError.invalidDestination,
        "incorrect output shape");

    auto check=owner.view();
    foreach(ch;0..bands)
    foreach(y;0..H)
    foreach(x;0..W)
    {
        float observed;
        need(check.trySample(ch,x,y,observed) &&
            observed==-777.0f,
            "rejected calls preserve every destination channel");
    }
}


/++
 Owned-result gate: no caller-destination aliases are required. This tests
 strong publish-on-success: invalid settings preserve a pre-existing owner,
 while valid settings create a complete, separately retained result.
+/
private void runOwnedCase(T)(bool masked)
{
    auto input = makePixels!T(4, Layout.interleaved);
    auto maskOwner = makeSelection();
    auto mask = masked ? maskOwner.view() : RasterView!ubyte.init;
    bool[4] selected = [true, true, true, false];
    ResearchLevels settings = ResearchLevels(
        0.1, 0.9, 2.0, 0.05, 0.95);
    enum size_t requiredPayload = W * H * 4 * float.sizeof;
    auto result = makeOwner!float(1, 1, 1, Layout.planar);
    {
        bool writable;
        scope auto write = result.tryWritableView(writable);
        need(writable && write.trySetSample(0, 0, 0, -987.0f),
            "owned old output sentinel");
    }

    auto bad = settings;
    bad.gamma = 0.0;
    const error = tryLevelsOwnedResearch!T(
        input.view(), Region2D(0, 0, W, H),
        selected[], bad, mask, masked, requiredPayload, result);
    need(error == ResearchLevelsError.invalidParameters,
        "owned input preflight reject");

    // A huge invalid ROI is rejected semantically before the producer can
    // attempt malloc() or overflow its byte/stride calculations.
    need(tryLevelsOwnedResearch!T(
        input.view(), Region2D(W - 1, H - 1, size_t.max, H),
        selected[], settings, mask, masked, requiredPayload, result)
        == ResearchLevelsError.invalidRegion,
        "owned huge ROI rejected before any allocation");
    bool[1] missingChannels = [true];
    need(tryLevelsOwnedResearch!T(
        input.view(), Region2D(0, 0, W, H),
        missingChannels[], settings, mask, masked, requiredPayload, result)
        == ResearchLevelsError.invalidChannelSelection,
        "owned malformed selection preflight");
    if (masked)
        need(tryLevelsOwnedResearch!T(
            input.view(), Region2D(0, 0, W, H),
            selected[], settings, RasterView!ubyte.init, true,
            requiredPayload, result)
            == ResearchLevelsError.invalidMask,
            "owned missing mask rejected before allocation");
    // Exact new-payload boundary: one byte short and zero must fail
    // without replacing the existing lease or allocating output bytes.
    need(tryLevelsOwnedResearch!T(
        input.view(), Region2D(0, 0, W, H),
        selected[], settings, mask, masked, requiredPayload - 1, result)
        == ResearchLevelsError.resultExceedsBudget,
        "owned byte budget one short");
    need(tryLevelsOwnedResearch!T(
        input.view(), Region2D(0, 0, W, H),
        selected[], settings, mask, masked, 0, result)
        == ResearchLevelsError.resultExceedsBudget,
        "owned zero budget");

    {
        scope auto before = result.view();
        float oldValue;
        need(before.planeCount == 1 && before.width == 1 &&
            before.height == 1 &&
            before.trySample(0, 0, 0, oldValue) &&
            oldValue == -987.0f,
            "failed owned operation preserves original live raster");
    }

    const status = tryLevelsOwnedResearch!T(
        input.view(), Region2D(0, 0, W, H),
        selected[], settings, mask, masked, requiredPayload, result);
    need(status == ResearchLevelsError.none,
        "owned result completion");
    scope auto image = result.view();
    need(image.planeCount == 4 && image.width == W && image.height == H,
        "owned result shape");
    foreach (channel; 0 .. 4)
    foreach (y; 0 .. H)
    foreach (x; 0 .. W)
    {
        float got;
        need(image.trySample(channel, x, y, got),
            "owned result sample");
        need(sameFloat(got,
            expected!T(channel, x, y, 4, masked, true)),
            "owned independent full pixel oracle");
    }
}

void main()
{
    foreach(bands;[cast(size_t)1,cast(size_t)4])
    foreach(layout;[Layout.planar,Layout.interleaved])
    foreach(masked;[false,true])
    foreach(gammaTwo;[false,true])
    {
        runCase!ubyte(bands,layout,masked,gammaTwo);
        runCase!ushort(bands,layout,masked,gammaTwo);
        runCase!float(bands,layout,masked,gammaTwo);
    }
    foreach (masked; [false, true])
    {
        runOwnedCase!ubyte(masked);
        runOwnedCase!ushort(masked);
        runOwnedCase!float(masked);
    }
    writeln("R-IM-03a owned Levels consumer PASS: 6 complete RGBA result cases, ",
        "failed publish keeps old owner, all 1152 output channel samples");
    writeln("R-IM-03a general Levels consumer PASS: 48 cases, ",
        "240 complete ROI outputs, grayscale/RGBA, u8/u16/f32, ",
        "selection opacity, alpha pass-through, exact ROI partitions");
}
