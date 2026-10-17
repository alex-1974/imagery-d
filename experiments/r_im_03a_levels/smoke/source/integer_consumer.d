/++
 R-IM-03b independent DUB consumer:
 - typed 8/16-bit outputs, deterministic half-up quantization
 - direct pow versus immutable prepared double LUT
 - selection-opacity and ROI-local pixel math
 - quantization oracle uses sqrt for gamma=2, not pow
 - independent raster-d storage/ownership.
 This is synthetic research validation, NOT a live GIMP/Photoshop app.
+/
module integer_consumer;

import core.stdc.stdlib : malloc;
import std.math : sqrt;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import imagery.presentation.levels_research :
    ResearchLevels, ResearchLevelsError;
import imagery.presentation.levels_integer_research :
    ResearchLevelsTable, tryLevelsIntegerDirectResearch,
    tryLevelsIntegerLutResearch;

private enum Layout : ubyte { planar, interleaved }
private enum size_t W=8, H=6;

private void insist(bool yes, string what)
{
    if (!yes) throw new Exception("R-IM-03b integer consumer: " ~ what);
}

private T fixture(T)(size_t band,size_t x,size_t y)
{
    const uint code=cast(uint)((31*x+17*y+13*band)%256);
    static if(is(T==ubyte))
        return cast(ubyte)code;
    else
        return cast(ushort)(code*257);
}

private ubyte coverage(size_t x,size_t y)
{
    switch ((x+2*y)%3)
    {
        case 0: return 0;
        case 1: return 128;
        default: return 255;
    }
}

private RasterLease!T owner(T)(
    size_t width,size_t height,size_t bands,Layout layout)
{
    const size_t count=width*height*bands;
    auto ptr=cast(T*)malloc(count*T.sizeof);
    insist(ptr !is null,"malloc raster-d backing");
    OwnedByteResource bytes;
    insist(tryAdoptMallocResource(ptr,count*T.sizeof,bytes),
        "adopt backing");
    auto descriptors=new PlaneByteLayout[](bands);
    foreach(band;0..bands)
        descriptors[band]=layout==Layout.planar
            ? PlaneByteLayout(band*width*height*T.sizeof,
                cast(ptrdiff_t)(width*T.sizeof),cast(ptrdiff_t)T.sizeof)
            : PlaneByteLayout(band*T.sizeof,
                cast(ptrdiff_t)(width*bands*T.sizeof),
                cast(ptrdiff_t)(bands*T.sizeof));
    RasterLease!T lease;
    auto imported=tryImportOwnedRaster!T(
        bytes,descriptors[],Region2D(0,0,width,height),lease);
    insist(imported.ok,"checked owner import");
    return lease;
}

private RasterLease!T image(T)(size_t bands,Layout layout)
{
    auto lease=owner!T(W,H,bands,layout);
    bool ok;
    scope auto view=lease.tryWritableView(ok);
    insist(ok,"source writer");
    foreach(band;0..bands)
    foreach(y;0..H)
    foreach(x;0..W)
        insist(view.trySetSample(band,x,y,fixture!T(band,x,y)),
            "source pixels");
    return lease;
}

private RasterLease!ubyte mask()
{
    auto lease=owner!ubyte(W,H,1,Layout.planar);
    bool ok;
    scope auto view=lease.tryWritableView(ok);
    insist(ok,"selection writer");
    foreach(y;0..H)
    foreach(x;0..W)
        insist(view.trySetSample(0,x,y,coverage(x,y)),
            "selection fixture");
    return lease;
}

// Oracle computes from the original integer code and independent formula,
// not from the prepared lookup table nor from the destination.
private T expected(T)(
    T code,bool selected,ubyte maskCode,ResearchLevels settings)
{
    if(!selected||maskCode==0)
        return code;
    enum double maximum = is(T == ubyte) ? 255.0 : 65535.0;
    const input=cast(double)code/maximum;
    double ratio=(input-settings.inputBlack) /
        (settings.inputWhite-settings.inputBlack);
    if(ratio<0.0)ratio=0.0;
    if(ratio>1.0)ratio=1.0;
    // Independent math; test profiles use gamma 1 and 2 only.
    const shaped=settings.gamma==2.0 ? sqrt(ratio) : ratio;
    const mapped=settings.outputBlack+
        (settings.outputWhite-settings.outputBlack)*shaped;
    const opacity=cast(double)maskCode/255.0;
    double blended=(1.0-opacity)*input+opacity*mapped;
    if(blended<=0.0)blended=0;
    if(blended>=1.0)blended=1;
    return cast(T)cast(uint)(blended*maximum+0.5);
}

private void regionCase(T)(
    size_t bands,Layout layout,bool useMask,bool gammaTwo)
{
    auto src=image!T(bands,layout);
    auto maskOwner=mask();
    auto selection=useMask ? maskOwner.view() : RasterView!ubyte.init;
    bool[4] rgba=[true,true,true,false];
    bool[1] gray=[true];
    const(bool)[] affected=bands==4 ? rgba[] : gray[];
    ResearchLevels params=ResearchLevels(
        0.1,0.9,gammaTwo?2.0:1.0,0.05,0.95);

    ResearchLevelsTable!T lut;
    insist(ResearchLevelsTable!T.prepare(params,lut)==
        ResearchLevelsError.none,"prepare immutable LUT");
    enum size_t expectedEntries = is(T==ubyte)?256:65536;
    insist(lut.prepared && lut.elementCount==expectedEntries,
        "LUT size matches integer sample domain");
    auto oldLut=lut;

    // Parameter errors must not discard a previously prepared table.
    auto invalid=params;
    invalid.gamma=0;
    insist(ResearchLevelsTable!T.prepare(invalid,lut)==
        ResearchLevelsError.invalidParameters &&
        lut.prepared && lut.elementCount==expectedEntries,
        "failed reprepare preserves LUT state");

    const Region2D[5] rois=[
        Region2D(0,0,W,H),
        Region2D(0,0,4,3),Region2D(4,0,4,3),
        Region2D(0,3,4,3),Region2D(4,3,4,3)
    ];

    T[W*H*4] whole;
    foreach(iteration,roi;rois)
    {
        auto direct=owner!T(roi.width,roi.height,bands,layout);
        auto tabled=owner!T(roi.width,roi.height,bands,
            layout==Layout.planar?Layout.interleaved:Layout.planar);
        bool ok1,ok2;
        scope auto d=direct.tryWritableView(ok1);
        scope auto l=tabled.tryWritableView(ok2);
        insist(ok1&&ok2,"independent result buffers");

        insist(tryLevelsIntegerDirectResearch!T(src.view(),roi,
            affected,params,selection,useMask,d)==ResearchLevelsError.none,
            "direct integer levels");
        insist(tryLevelsIntegerLutResearch!T(src.view(),roi,
            affected,lut,selection,useMask,l)==ResearchLevelsError.none,
            "prepared LUT levels");

        auto dRead=direct.view(), lRead=tabled.view();
        foreach(band;0..bands)
        foreach(y;0..roi.height)
        foreach(x;0..roi.width)
        {
            T observed,looked;
            insist(dRead.trySample(band,x,y,observed)&&
                lRead.trySample(band,x,y,looked),"read both variants");
            const xx=roi.x+x,yy=roi.y+y;
            const selectionValue=useMask?coverage(xx,yy):cast(ubyte)255;
            const oracle=expected!T(fixture!T(band,xx,yy),
                affected[band],selectionValue,params);
            // Allow at most one integer code difference from independent
            // sqrt/float rounding on a pathological near-half boundary.
            const obs=cast(int)observed, want=cast(int)oracle;
            insist(obs>=want-1&&obs<=want+1,"math+round oracle");
            insist(observed==looked,
                "direct and LUT bit-identical integer result");
            const i=band*W*H+yy*W+xx;
            if(iteration==0)
                whole[i]=observed;
            else
                insist(whole[i]==observed,
                    "whole vs partitioned exact same integer output");
            if(!affected[band]||selectionValue==0)
                insist(observed==fixture!T(band,xx,yy),
                    "nonselected channels / 0 strength exact copy");
        }
    }

    // Reselection of an existing table's original generation must not
    // be affected by preparing another one from different parameters.
    invalid=params;
    invalid.gamma=1.0;
    invalid.outputBlack=0.25;
    insist(ResearchLevelsTable!T.prepare(invalid,lut)==
        ResearchLevelsError.none,"prepare another generation");
    insist(oldLut.prepared&&oldLut.settings.outputBlack==params.outputBlack,
        "immutable prior LUT generation survived replacement");

    auto destination=owner!T(W,H,bands,Layout.planar);
    bool ok;
    scope auto dst=destination.tryWritableView(ok);
    insist(ok,"negative result view");
    foreach(band;0..bands)
    foreach(y;0..H)
    foreach(x;0..W)
        insist(dst.trySetSample(band,x,y,cast(T)17),
            "result sentinel");
    auto noTable=ResearchLevelsTable!T.init;
    insist(tryLevelsIntegerLutResearch!T(src.view(),rois[0],
        affected,noTable,selection,useMask,dst) ==
        ResearchLevelsError.invalidParameters,
        "reject unprepared table");
    insist(tryLevelsIntegerDirectResearch!T(src.view(),
        Region2D(W-1,H-1,2,2),affected,params,
        selection,useMask,dst) == ResearchLevelsError.invalidRegion,
        "reject invalid ROI");
    auto bad=params;
    bad.gamma=double.nan;
    insist(tryLevelsIntegerDirectResearch!T(src.view(),rois[0],
        affected,bad,selection,useMask,dst) ==
        ResearchLevelsError.invalidParameters,"reject NaN gamma");
    auto badSelection=RasterView!ubyte.init;
    insist(tryLevelsIntegerDirectResearch!T(src.view(),rois[0],
        affected,params,badSelection,true,dst) ==
        ResearchLevelsError.invalidMask,"reject absent selection mask");
    auto badOutput=owner!T(W-1,H,bands,Layout.planar);
    bool bw;
    scope auto shortDst=badOutput.tryWritableView(bw);
    insist(bw,"bad output view");
    insist(tryLevelsIntegerDirectResearch!T(src.view(),rois[0],
        affected,params,selection,useMask,shortDst) ==
        ResearchLevelsError.invalidDestination,
        "reject wrong-size destination");
    auto after=destination.view();
    foreach(band;0..bands)
    foreach(y;0..H)
    foreach(x;0..W)
    {
        T value;
        insist(after.trySample(band,x,y,value)&&value==17,
            "all live destination sentinels preserved after preflight");
    }
}

private void exhaustive(T)()
{
    enum size_t N=is(T==ubyte)?256:65536;
    auto src=owner!T(N,1,1,Layout.planar);
    bool sw;
    scope auto writer=src.tryWritableView(sw);
    insist(sw,"exhaustive source writer");
    foreach(i;0..N)
        insist(writer.trySetSample(0,i,0,cast(T)i),
            "exhaustive integer input");

    bool[1] selected=[true];
    const ResearchLevels p=ResearchLevels(0.1,0.9,2.0,0.05,0.95);
    ResearchLevelsTable!T table;
    insist(ResearchLevelsTable!T.prepare(p,table)==
        ResearchLevelsError.none,"prepare exhaustive table");
    auto direct=owner!T(N,1,1,Layout.planar);
    auto lookup=owner!T(N,1,1,Layout.planar);
    bool ok1,ok2;
    scope auto wDirect=direct.tryWritableView(ok1);
    scope auto wLut=lookup.tryWritableView(ok2);
    insist(ok1&&ok2,"full-domain destinations");
    const roi=Region2D(0,0,N,1);
    insist(tryLevelsIntegerDirectResearch!T(
        src.view(),roi,selected[],p,RasterView!ubyte.init,
        false,wDirect)==ResearchLevelsError.none,
        "full integer-domain direct");
    insist(tryLevelsIntegerLutResearch!T(
        src.view(),roi,selected[],table,RasterView!ubyte.init,
        false,wLut)==ResearchLevelsError.none,
        "full integer-domain LUT");

    auto a=direct.view(),b=lookup.view();
    foreach(i;0..N)
    {
        T first,second;
        insist(a.trySample(0,i,0,first) &&
            b.trySample(0,i,0,second),"compare all input values");
        const wanted=expected!T(cast(T)i,true,255,p);
        insist(first==second,"full-domain direct-LUT equality");
        const delta=cast(int)first-cast(int)wanted;
        insist(delta>=-1&&delta<=1,"full-domain independent oracle");
    }
}

void runIntegerConsumer()
{
    foreach(bands;[cast(size_t)1,cast(size_t)4])
    foreach(layout;[Layout.planar,Layout.interleaved])
    foreach(masked;[false,true])
    foreach(gammaTwo;[false,true])
    {
        regionCase!ubyte(bands,layout,masked,gammaTwo);
        regionCase!ushort(bands,layout,masked,gammaTwo);
    }
    exhaustive!ubyte();
    exhaustive!ushort();
    writeln("R-IM-03b Integer Levels PASS: 32 cases, ",
        "160 ROI pairs, exhaustive 256+65536 codes, ",
        "direct/LUT equality, ROI and ownership preflight");
}
