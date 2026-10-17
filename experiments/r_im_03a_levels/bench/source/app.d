/++
 R-IM-03b optional native XPS benchmark: no result is implied by building.
 Measure table preparation separately from repeated direct/LUT operations.
 Reuse allocated input/output buffers, pair and alternate run order, and
 verify equal complete results before reporting timing.
+
 N.B. OS, CPU frequency, allocator and warm-up variability must be recorded
 by the invoking run receipt. Hosted CI timing is NOT XPS performance.
+/
module app;

import core.stdc.stdlib : malloc;
import core.time : MonoTime;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import imagery.presentation.levels_research :
    ResearchLevels, ResearchLevelsError;
import imagery.presentation.levels_integer_research :
    ResearchLevelsTable, tryLevelsIntegerDirectResearch,
    tryLevelsIntegerLutResearch;

private void check(bool ok, string what)
{
    if (!ok) throw new Exception("R-IM-03b benchmark: "~what);
}

private RasterLease!T own(T)(
    size_t width,size_t height,size_t bands,bool interleaved)
{
    const count=width*height*bands;
    auto raw=cast(T*)malloc(count*T.sizeof);
    check(raw !is null,"malloc");
    OwnedByteResource bytes;
    check(tryAdoptMallocResource(raw,count*T.sizeof,bytes),
        "adopt raster");
    auto layouts=new PlaneByteLayout[](bands);
    foreach(c;0..bands)
        layouts[c]=interleaved
            ? PlaneByteLayout(c*T.sizeof,
                cast(ptrdiff_t)(width*bands*T.sizeof),
                cast(ptrdiff_t)(bands*T.sizeof))
            : PlaneByteLayout(c*width*height*T.sizeof,
                cast(ptrdiff_t)(width*T.sizeof),
                cast(ptrdiff_t)T.sizeof);
    RasterLease!T result;
    check(tryImportOwnedRaster!T(
        bytes,layouts[],Region2D(0,0,width,height),result).ok,
        "import owned resource");
    return result;
}

private long middle(long[] xs)
{
    auto ordered=xs.dup;
    sort(ordered);
    return ordered[ordered.length/2];
}

private void run(T)(
    size_t width,size_t height,size_t repeats,bool interleaved,
    bool masked)
{
    enum size_t channels=4;
    auto src=own!T(width,height,channels,interleaved);
    auto dstDirect=own!T(width,height,channels,!interleaved);
    auto dstLut=own!T(width,height,channels,!interleaved);
    auto mask=own!ubyte(width,height,1,false);
    bool srcOk,maskOk;
    scope auto srcW=src.tryWritableView(srcOk);
    scope auto maskW=mask.tryWritableView(maskOk);
    check(srcOk&&maskOk,"prepare source writers");

    foreach(y;0..height)
    foreach(x;0..width)
    {
        foreach(c;0..channels)
        {
            const code=cast(uint)((x*31+y*17+c*13)%256);
            static if(is(T==ubyte))
                const v=cast(ubyte)code;
            else
                const v=cast(ushort)(257*code);
            check(srcW.trySetSample(c,x,y,v),"write source");
        }
        check(maskW.trySetSample(0,x,y,
            cast(ubyte)((x+y)%3==0?0:(x+y)%3==1?128:255)),
            "write opacity mask");
    }

    ResearchLevels p=ResearchLevels(0.1,0.9,2.0,0.05,0.95);
    ResearchLevelsTable!T table;
    const prepareStart=MonoTime.currTime;
    check(ResearchLevelsTable!T.prepare(p,table)==
        ResearchLevelsError.none,"prepare table");
    const preparationMicros=(MonoTime.currTime-prepareStart).total!"usecs";

    bool[4] selected=[true,true,true,false];
    const roi=Region2D(0,0,width,height);
    auto selection=masked?mask.view():RasterView!ubyte.init;
    bool dw,lw;
    scope auto directOut=dstDirect.tryWritableView(dw);
    scope auto lutOut=dstLut.tryWritableView(lw);
    check(dw&&lw,"output writable leases");
    auto input=src.view();

    // First run is a correctness gate, OUTSIDE the timing distributions.
    check(tryLevelsIntegerDirectResearch!T(input,roi,selected[],p,
        selection,masked,directOut)==ResearchLevelsError.none,
        "direct warmup");
    check(tryLevelsIntegerLutResearch!T(input,roi,selected[],table,
        selection,masked,lutOut)==ResearchLevelsError.none,
        "LUT warmup");
    auto da=dstDirect.view();
    auto lb=dstLut.view();
    ulong fingerprint=0;
    foreach(y;0..height)
    foreach(x;0..width)
    foreach(c;0..channels)
    {
        T first,second;
        check(da.trySample(c,x,y,first)&&
            lb.trySample(c,x,y,second)&&first==second,
            "full image numeric equivalence");
        fingerprint+=first;
    }

    long[] directTime;
    long[] lutTime;
    foreach(round;0..repeats)
    {
        // Alternate ordering for drift-sensitive paired comparisons.
        foreach(switchIndex;0..2)
        {
            const doDirect=((round+switchIndex)%2)==0;
            const begin=MonoTime.currTime;
            if(doDirect)
            {
                check(tryLevelsIntegerDirectResearch!T(
                    input,roi,selected[],p,selection,masked,
                    directOut)==ResearchLevelsError.none,"direct round");
            }
            else
            {
                check(tryLevelsIntegerLutResearch!T(
                    input,roi,selected[],table,selection,masked,
                    lutOut)==ResearchLevelsError.none,"LUT round");
            }
            const micros=(MonoTime.currTime-begin).total!"usecs";
            if(doDirect)directTime~=micros;
            else lutTime~=micros;
        }
    }

    const md=middle(directTime), ml=middle(lutTime);
    const benefit=md-ml;
    const breakEven = benefit>0 ?
        cast(double)preparationMicros/benefit : -1.0;
    static if(is(T==ubyte))
        enum kind="ubyte";
    else
        enum kind="ushort";
    writeln("RIM03B_CSV,",kind,",",width,",",height,",",
        interleaved?"interleaved":"planar",",",
        masked?"mask":"no-mask",",",
        repeats,",",preparationMicros,",",md,",",ml,",",
        breakEven,",",table.elementCount*double.sizeof,",",
        fingerprint);
}

void main(string[] args)
{
    const width=args.length>=2?to!size_t(args[1]):cast(size_t)512;
    const repeats=args.length>=3?to!size_t(args[2]):cast(size_t)3;
    check(width>0&&width<=4096,"width within measured research bounds");
    check(repeats>0&&repeats<=100,"repeat count in bounds");
    writeln("RIM03B_FIELDS,type,width,height,layout,mask,rounds,",
        "prep_us,direct_median_us,lut_median_us,break_even_reuses,",
        "retained_lut_payload_bytes,checksum");
    foreach(interleaved;[false,true])
    foreach(masked;[false,true])
    {
        run!ubyte(width,width,repeats,interleaved,masked);
        run!ushort(width,width,repeats,interleaved,masked);
    }
}
