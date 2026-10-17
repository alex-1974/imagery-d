/++
 R-IM-03c research benchmark: same raster-d views and integer Levels
 operation across four math mechanisms, same inputs and destinations.
 Values are NOT scientific/satellite measurements or colour profiles.
 Nothing here is a public API, native measurement receipt or Clang parity.
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
    tryLevelsIntegerLlvmPowResearch, tryLevelsIntegerSqrt2Research,
    tryLevelsIntegerLutResearch;

private void require(bool yes,string name)
{
    if(!yes) throw new Exception("R-IM-03c benchmark: "~name);
}

private RasterLease!T make(T)(
    size_t width,size_t height,size_t bands,bool interleaved)
{
    const n=width*height*bands;
    auto p=cast(T*)malloc(n*T.sizeof);
    require(p !is null,"malloc raster");
    OwnedByteResource owned;
    require(tryAdoptMallocResource(p,n*T.sizeof,owned),"adopt");
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
    require(tryImportOwnedRaster!T(
        owned,layouts[],Region2D(0,0,width,height),result).ok,
        "import raster");
    return result;
}

private T code(T)(
    size_t x,size_t y,size_t channel,size_t w,size_t h,int pattern)
{
    const v=cast(uint)((x*31+y*17+channel*13)%256);
    static if(is(T==ubyte))
        return cast(ubyte)v;
    else
    {
        if(pattern==0)
            return cast(ushort)(257*v); // old 8-bit expansion
        if(pattern==1)
        {
            // Multiplication by odd 40503 permutes all 65536 codes.
            // At 1024x1024 the fixture has complete u16 coverage.
            const linear=cast(uint)(x+y*w);
            return cast(ushort)((linear*40503u+
                cast(uint)channel*8111u)&65535u);
        }
        // Smooth photographic-gradient-like distribution, not a real
        // photograph. This is a distinct low-spatial-frequency cohort.
        const gx=cast(uint)(x*65535/(w-1));
        const gy=cast(uint)(y*65535/(h-1));
        return cast(ushort)(((3u*gx+gy)/4u+
            cast(uint)channel*127u)&65535u);
    }
}

private long median(long[] samples)
{
    auto copy=samples.dup;
    sort(copy);
    return copy[copy.length/2];
}

private void run(T)(
    size_t width,size_t repeats,int pattern,bool interleaved,bool masked)
{
    enum size_t bands=4;
    auto source=make!T(width,width,bands,interleaved);
    auto out0=make!T(width,width,bands,!interleaved);
    auto out1=make!T(width,width,bands,!interleaved);
    auto out2=make!T(width,width,bands,!interleaved);
    auto out3=make!T(width,width,bands,!interleaved);
    auto mask=make!ubyte(width,width,1,false);
    bool si,mi;
    scope auto sw=source.tryWritableView(si);
    scope auto mw=mask.tryWritableView(mi);
    require(si&&mi,"source writers");
    static if(is(T==ubyte))
        enum domain=256;
    else
        enum domain=65536;
    bool[domain] distinctCodes;
    size_t distinct=0;

    foreach(y;0..width)
    foreach(x;0..width)
    {
        foreach(c;0..bands)
        {
            const v=code!T(x,y,c,width,width,pattern);
            if(!distinctCodes[cast(size_t)v])
            {
                distinctCodes[cast(size_t)v]=true;
                ++distinct;
            }
            require(sw.trySetSample(c,x,y,v),"source fixture write");
        }
        const n=cast(ubyte)((x+2*y)%3==0?0:
            (x+2*y)%3==1?128:255);
        require(mw.trySetSample(0,x,y,n),"mask fixture");
    }
    // Verify the 16-bit "full entropy" cohort really exercises more
    // than 8-bit magnitudes on production-size benchmark inputs.
    static if(is(T==ushort))
        if(pattern==1&&width>=256)
            require(distinct>50000,"full 16-bit code diversity");

    const p=ResearchLevels(0.1,0.9,2.0,0.05,0.95);
    ResearchLevelsTable!T table;
    const start=MonoTime.currTime;
    require(ResearchLevelsTable!T.prepare(p,table)==
        ResearchLevelsError.none,"prepare double LUT");
    const prep=(MonoTime.currTime-start).total!"usecs";

    bool[4] selected=[true,true,true,false];
    const roi=Region2D(0,0,width,width);
    auto input=source.view();
    auto selectedMask=masked?mask.view():RasterView!ubyte.init;
    bool o0,o1,o2,o3;
    scope auto w0=out0.tryWritableView(o0);
    scope auto w1=out1.tryWritableView(o1);
    scope auto w2=out2.tryWritableView(o2);
    scope auto w3=out3.tryWritableView(o3);
    require(o0&&o1&&o2&&o3,"disjoint output owners");

    // Warm all four mechanisms. The no-alias assumption is explicit.
    require(tryLevelsIntegerDirectResearch!T(input,roi,
        selected[],p,selectedMask,masked,w0)==
        ResearchLevelsError.none,"Phobos warmup");
    require(tryLevelsIntegerLlvmPowResearch!T(input,roi,
        selected[],p,selectedMask,masked,w1)==
        ResearchLevelsError.none,"LLVM warmup");
    require(tryLevelsIntegerSqrt2Research!T(input,roi,
        selected[],p,selectedMask,masked,w2)==
        ResearchLevelsError.none,"sqrt warmup");
    require(tryLevelsIntegerLutResearch!T(input,roi,
        selected[],table,selectedMask,masked,w3)==
        ResearchLevelsError.none,"LUT warmup");

    auto r0=out0.view(),r1=out1.view();
    auto r2=out2.view(),r3=out3.view();
    ulong fingerprint=0;
    size_t llvmMismatch=0,sqrtMismatch=0;
    foreach(y;0..width)
    foreach(x;0..width)
    foreach(c;0..bands)
    {
        T a,b,d,e;
        require(r0.trySample(c,x,y,a)&&
            r1.trySample(c,x,y,b)&&
            r2.trySample(c,x,y,d)&&
            r3.trySample(c,x,y,e),"verify all four");
        require(a==e,"Phobos and prepared LUT exact equality");
        const dl=cast(int)b-cast(int)a;
        const ds=cast(int)d-cast(int)a;
        require(dl>=-1&&dl<=1,
            "LLVM differs by more than one output code");
        require(ds>=-1&&ds<=1,
            "sqrt differs by more than one output code");
        if(dl!=0)++llvmMismatch;
        if(ds!=0)++sqrtMismatch;
        if(c==3)
            require(a==code!T(x,y,c,width,width,pattern),
                "unselected alpha exact copy");
        fingerprint+=a;
    }

    static if(is(T==ubyte))
        enum kind="u8";
    else
        enum kind="u16";
    long[][4] samples;
    foreach(round;0..repeats)
    foreach(step;0..4)
    {
        const method=cast(int)((round+step)%4);
        const begin=MonoTime.currTime;
        ResearchLevelsError result;
        switch(method)
        {
            case 0:
                result=tryLevelsIntegerDirectResearch!T(input,roi,
                    selected[],p,selectedMask,masked,w0);
                break;
            case 1:
                result=tryLevelsIntegerLlvmPowResearch!T(input,roi,
                    selected[],p,selectedMask,masked,w1);
                break;
            case 2:
                result=tryLevelsIntegerSqrt2Research!T(input,roi,
                    selected[],p,selectedMask,masked,w2);
                break;
            default:
                result=tryLevelsIntegerLutResearch!T(input,roi,
                    selected[],table,selectedMask,masked,w3);
                break;
        }
        const micros=(MonoTime.currTime-begin).total!"usecs";
        require(result==ResearchLevelsError.none,"timed method");
        samples[method]~=micros;
        writeln("RIM03C_RAW,",kind,",",pattern,",",
            width,",",interleaved?"interleaved":"planar",",",
            masked?"mask":"none",",",round,",",method,",",micros);
    }
    writeln("RIM03C_SUMMARY,",kind,",",pattern,",",
        width,",",interleaved?"interleaved":"planar",",",
        masked?"mask":"none",",",repeats,",",distinct,",",
        prep,",",median(samples[0]),",",median(samples[1]),",",
        median(samples[2]),",",median(samples[3]),",",
        llvmMismatch,",",sqrtMismatch,",",
        table.elementCount*double.sizeof,",",fingerprint);
}

void main(string[] args)
{
    const side=args.length>1?to!size_t(args[1]):cast(size_t)512;
    const rounds=args.length>2?to!size_t(args[2]):cast(size_t)5;
    const pattern=args.length>3?to!int(args[3]):1;
    require(side>=16&&side<=4096,"side range 16..4096");
    require(rounds>=1&&rounds<=100,"rounds range 1..100");
    require(pattern>=0&&pattern<=2,"pattern: 0=expanded,1=full,2=smooth");
    writeln("RIM03C_SCHEMA,1,kind,pattern,side,layout,mask,rounds,",
        "unique_codes,prep_us,phobos_median_us,llvm_median_us,",
        "sqrt2_median_us,lut_median_us,llvm_mismatches,",
        "sqrt_mismatches,lut_payload_bytes,checksum");
    foreach(interleaved;[false,true])
    foreach(masked;[false,true])
    {
        run!ubyte(side,rounds,pattern,interleaved,masked);
        run!ushort(side,rounds,pattern,interleaved,masked);
    }
}
