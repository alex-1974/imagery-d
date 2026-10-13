module app;

// Evidence-only RGBA sRGB8 LUT comparison INSIDE public raster.zipTransformInto.
// The D "pure" zip transform accepts no runtime context. D-spec-compliant
// shared static constructor initializes one immutable table *at runtime*.
// This retains the source and destination physical overlap proofs implemented
// by raster-d; it does not provide checked per-pixel quantization error reporting.
// No public production API or sibling library source changes.
import core.memory : GC;
import core.stdc.stdlib : malloc;
import std.algorithm.searching : startsWith;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln;
import color :
    Alpha, LinearSRgbd, SRgbd, SRgba8,
    premultiply, sourceOver, unpremultiply, toLinear, toSRgb, tryToSRgba8;
import imagery.presentation.composite :
    DecodedRgbaLayer, RgbaEncoding, RgbaAssociation, RgbaCompositeError,
    tryCompositeRgbaSourceOver;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    RasterZipTransformError, isRasterSampleType, zipTransformInto,
    tryAdoptMallocResource, tryImportOwnedRaster;

static assert(isRasterSampleType!SRgba8);
static assert(SRgba8.sizeof == 4);

private enum double opacity = 0.37;

// Module immutable data can be initialized exactly once by shared static this.
// The callback may then read it from @safe pure nothrow @nogc code.
// Unlike CTFE, table generation uses the actual compiler's runtime color-d path.
// This table has program lifetime and is NOT a general, caller-owned LUT API.
private struct PreparedLut {
    double[256] values;
    long setupUs;
}
private immutable PreparedLut preparedLut;
private PreparedLut makeRuntimeTable()
@safe nothrow @nogc {
    PreparedLut result;
    foreach (i; 0 .. 256) {
        const ubyte b = cast(ubyte)i;
        const p = SRgba8(b,b,b,255).toAlphaSRgb!double();
        result.values[i] = p.color.toLinear().r;
    }
    return result;
}
shared static this() {
    StopWatch stopwatch;
    stopwatch.start();
    auto result = makeRuntimeTable();
    stopwatch.stop();
    result.setupUs = stopwatch.peek.total!"usecs";
    preparedLut = result;
}
private void require(bool success, string label) {
    if (!success) throw new Exception("M3 zip LUT: " ~ label);
}
private enum Pattern : ubyte { mixed, opaque, transparent }
private enum Layout : ubyte { compact, padded }
private struct Config {
    size_t width=64;
    size_t height=64;
    size_t rounds=3;
    size_t iterations=2;
    bool partial;
    size_t roiSide; // 0 = original whole/near-full ROI; otherwise offset square
    Pattern pattern=Pattern.mixed;
    Layout layout=Layout.compact;
}
private Config parse(string[] args) {
    Config c;
    foreach (a; args[1 .. $]) {
        if (a.startsWith("--width=")) c.width=to!size_t(a[8..$]);
        else if (a.startsWith("--height=")) c.height=to!size_t(a[9..$]);
        else if (a.startsWith("--rounds=")) c.rounds=to!size_t(a[9..$]);
        else if (a.startsWith("--iterations=")) c.iterations=to!size_t(a[13..$]);
        else if (a=="--partial") c.partial=true;
        else if (a.startsWith("--roi-side=")) c.roiSide=to!size_t(a[11..$]);
        else if (a=="--pattern=mixed") c.pattern=Pattern.mixed;
        else if (a=="--pattern=opaque") c.pattern=Pattern.opaque;
        else if (a=="--pattern=transparent") c.pattern=Pattern.transparent;
        else if (a=="--layout=compact") c.layout=Layout.compact;
        else if (a=="--layout=padded") c.layout=Layout.padded;
        else throw new Exception("Unknown zip LUT option: " ~ a);
    }
    require(c.width>=32 && c.height>=32 &&
        c.width<=cast(size_t)ptrdiff_t.max/4-4 &&
        c.width<=size_t.max/c.height &&
        c.height<=size_t.max/(4*(c.width+4)) &&
        c.rounds>0 && c.rounds<=100 &&
        c.iterations>0 && c.iterations<=200,
        "valid dimensions and repetitions");
    require(c.roiSide==0 || (!c.partial && c.width>=7 &&
        c.height>=11 && c.roiSide>=1 &&
        c.roiSide<=c.width-7 && c.roiSide<=c.height-11),
        "offset square ROI must fit the resident image and exclude --partial");
    return c;
}
private Region2D selected(Config c)
@safe pure nothrow @nogc {
    if (c.roiSide != 0)
        return Region2D(7,11,c.roiSide,c.roiSide);
    return c.partial ? Region2D(7,11,c.width-14,c.height-22)
                     : Region2D(0,0,c.width,c.height);
}
private string name(Pattern x) @safe pure nothrow @nogc {
    final switch(x) {
        case Pattern.mixed: return "mixed";
        case Pattern.opaque: return "opaque";
        case Pattern.transparent: return "transparent";
    }
}
private SRgba8 fixture(size_t layer,size_t x,size_t y,Pattern pattern)
@safe pure nothrow @nogc {
    uint a;
    final switch(pattern) {
        case Pattern.opaque: a=255; break;
        case Pattern.transparent: a=0; break;
        case Pattern.mixed:
            a=((x+y+layer)%7==0) ? 0 :
              ((x+2*y+layer)%3==0) ? 128 : 255;
            break;
    }
    return SRgba8(
        cast(ubyte)((37*x+17*y+71*layer+13)%256),
        cast(ubyte)((11*x+41*y+43*layer+29)%256),
        cast(ubyte)((19*x+23*y+97*layer+53)%256),
        cast(ubyte)a);
}
private Alpha!LinearSRgbd decode(bool useTable)(SRgba8 p)
@safe pure nothrow @nogc {
    auto straight=p.toAlphaSRgb!double();
    static if (useTable) {
        return Alpha!LinearSRgbd(
            LinearSRgbd(preparedLut.values[p.r],
                preparedLut.values[p.g],preparedLut.values[p.b]),
            straight.alpha);
    } else {
        return Alpha!LinearSRgbd(straight.color.toLinear(),straight.alpha);
    }
}
private SRgba8 apply(bool useTable)(SRgba8 fg,SRgba8 bg)
@safe pure nothrow @nogc {
    auto top=premultiply(decode!useTable(fg));
    auto lower=premultiply(decode!useTable(bg));
    const adjusted=typeof(top)(
        LinearSRgbd(top.color.r*opacity,top.color.g*opacity,
            top.color.b*opacity),top.alpha*opacity);
    const mixed=sourceOver(adjusted,lower);
    const straight=unpremultiply(mixed);
    SRgba8 outPixel;
    // Research limitation: callback's T,T->T result type cannot carry
    // a checked quantization error. Never promote this sentinel branch.
    if(!tryToSRgba8(Alpha!SRgbd(straight.color.toSRgb(),
            straight.alpha),outPixel))
        return SRgba8.init;
    return outPixel;
}
private SRgba8 direct(SRgba8 a,SRgba8 b)
@safe pure nothrow @nogc {
    return apply!false(a,b);
}
private SRgba8 exactTable(SRgba8 a,SRgba8 b)
@safe pure nothrow @nogc {
    return apply!true(a,b);
}
private RasterLease!T makeLease(T)(
    size_t w,size_t h,Layout layout,size_t layer,Pattern pattern,bool populate
) {
    const size_t rowbytes=4*(w+(layout==Layout.padded ? 4 : 0));
    const size_t bytes=rowbytes*h;
    auto memory=cast(ubyte*)malloc(bytes);
    require(memory !is null,"allocate owner");
    OwnedByteResource owned;
    require(tryAdoptMallocResource(memory,bytes,owned),"adopt owner");
    RasterLease!T lease;
    static if (is(T==SRgba8)) {
        const PlaneByteLayout[1] planes=[
            PlaneByteLayout(0,cast(ptrdiff_t)rowbytes,4)];
        require(tryImportOwnedRaster!T(owned,planes[],
            Region2D(0,0,w,h),lease).ok,"import packed lease");
    } else {
        PlaneByteLayout[4] planes;
        foreach(c;0..4)
            planes[c]=PlaneByteLayout(c,cast(ptrdiff_t)rowbytes,4);
        require(tryImportOwnedRaster!T(owned,planes[],
            Region2D(0,0,w,h),lease).ok,"import byte planes");
    }
    bool ok;
    scope auto output=lease.tryWritableView(ok);
    require(ok,"get writer");
    foreach(y;0..h)
    foreach(x;0..w) {
        auto p=populate ? fixture(layer,x,y,pattern)
                        : SRgba8(211,211,211,211);
        static if (is(T==SRgba8))
            require(output.trySetSample(0,x,y,p),"fill packed");
        else
            require(output.trySetSample(0,x,y,p.r) &&
                output.trySetSample(1,x,y,p.g) &&
                output.trySetSample(2,x,y,p.b) &&
                output.trySetSample(3,x,y,p.a),"fill channels");
    }
    return lease;
}
private bool zipOne(bool useLut)(
    ref RasterLease!SRgba8 top,ref RasterLease!SRgba8 bottom,
    ref RasterLease!SRgba8 destination,Region2D region,
    out RasterZipTransformError err
) {
    scope auto upper=top.view();
    scope auto lower=bottom.view();
    bool ok;
    scope auto writer=destination.tryWritableView(ok);
    if (!ok) {err=RasterZipTransformError.invalidDestinationPlane;return false;}
    bool aOk,bOk,cOk;
    scope auto left=upper.tryRoi(region,aOk);
    scope auto right=lower.tryRoi(region,bOk);
    scope auto target=writer.tryRoi(region,cOk);
    if(!aOk||!bOk||!cOk) {
        err=RasterZipTransformError.shapeMismatch;return false;
    }
    static if(useLut)
        return left.zipTransformInto!exactTable(0,right,0,target,0,err);
    else
        return left.zipTransformInto!direct(0,right,0,target,0,err);
}
private bool fourPlane(
    ref RasterLease!ubyte top,ref RasterLease!ubyte bottom,
    ref RasterLease!ubyte destination,Region2D region
) {
    bool ok;
    scope auto writer=destination.tryWritableView(ok);
    if(!ok) return false;
    bool selectedOk;
    scope auto target=writer.tryRoi(region,selectedOk);
    if(!selectedOk) return false;
    return tryCompositeRgbaSourceOver(
        DecodedRgbaLayer(top.view(),RgbaEncoding.encodedSRgb,
            RgbaAssociation.straight),
        DecodedRgbaLayer(bottom.view(),RgbaEncoding.encodedSRgb,
            RgbaAssociation.straight),
        region,opacity,target)==RgbaCompositeError.none;
}
private void assertSameOutput(
    ref RasterLease!SRgba8 directDst,
    ref RasterLease!SRgba8 tableDst,
    ref RasterLease!ubyte referenceDst,
    Config cfg
) {
    scope auto a=directDst.view();
    scope auto b=tableDst.view();
    scope auto reference=referenceDst.view();
    const r=selected(cfg);
    foreach(y;0..cfg.height)
    foreach(x;0..cfg.width) {
        SRgba8 directPx,tablePx;
        require(a.trySample(0,x,y,directPx),"read direct output");
        require(b.trySample(0,x,y,tablePx),"read LUT output");
        require(directPx==tablePx,"LUT/direct exact RGBA equality");
        ubyte[4] expected;
        foreach(c;0..4)
            require(reference.trySample(c,x,y,expected[c]),
                "read four-plane oracle");
        if(x>=r.x && x<r.x+r.width && y>=r.y && y<r.y+r.height)
            require(tablePx.r==expected[0] &&
                tablePx.g==expected[1] && tablePx.b==expected[2] &&
                tablePx.a==expected[3],"canonical all-pixel oracle equality");
        else
            require(tablePx==SRgba8(211,211,211,211) &&
                expected==[cast(ubyte)211,211,211,211],
                "ROI outside remains unmodified");
    }
}
private ulong checksum(
    ref RasterLease!SRgba8 dst,Config cfg
) {
    scope auto v=dst.view();
    ulong h=1469598103934665603UL;
    foreach(y;0..cfg.height)
    foreach(x;0..cfg.width) {
        SRgba8 p;
        require(v.trySample(0,x,y,p),"read checksum");
        h=(h^p.r)*1099511628211UL;
        h=(h^p.g)*1099511628211UL;
        h=(h^p.b)*1099511628211UL;
        h=(h^p.a)*1099511628211UL;
    }
    return h;
}
private void checkLutChannels() {
    foreach(i;0..256) {
        const ubyte byteValue=cast(ubyte)i;
        const directValue=SRgba8(byteValue,byteValue,byteValue,255)
            .toAlphaSRgb!double().color.toLinear().r;
        require(preparedLut.values[i]==directValue,
            "runtime table matches color-d for each byte");
    }
}
private void verifyAlias(
    ref RasterLease!SRgba8 top,
    ref RasterLease!SRgba8 bottom,
    Config cfg
) {
    const r=selected(cfg);
    scope auto upper=top.view();
    scope auto lower=bottom.view();
    bool ok;
    scope auto topWriter=top.tryWritableView(ok);
    require(ok,"alias writable top");
    bool roiOk;
    scope auto upperROI=upper.tryRoi(r,roiOk);
    require(roiOk,"alias upper ROI");
    scope auto lowerROI=lower.tryRoi(r,roiOk);
    require(roiOk,"alias lower ROI");
    scope auto topTarget=topWriter.tryRoi(r,roiOk);
    require(roiOk,"alias writable top ROI");
    RasterZipTransformError error;
    require(!upperROI.zipTransformInto!exactTable(
        0,lowerROI,0,topTarget,0,error),
        "LUT zip left/dest overlap rejected");
    require(error==RasterZipTransformError.leftDestinationOverlap,
        "left/dest classification");
    // Must end borrow of writable top before reading through readonly
    // borrow; lexical scope is restricted below in a separate test.
}
private void verifyRightAlias(
    ref RasterLease!SRgba8 top,
    ref RasterLease!SRgba8 bottom,Config cfg
) {
    const r=selected(cfg);
    scope auto upper=top.view();
    scope auto lower=bottom.view();
    bool ok,roiOk;
    scope auto target=bottom.tryWritableView(ok);
    require(ok,"right-alias writable view");
    scope auto topROI=upper.tryRoi(r,roiOk);
    require(roiOk,"upper ROI");
    scope auto bottomROI=lower.tryRoi(r,roiOk);
    require(roiOk,"bottom ROI");
    scope auto writerROI=target.tryRoi(r,roiOk);
    require(roiOk,"right-alias writer ROI");
    RasterZipTransformError error;
    require(!topROI.zipTransformInto!exactTable(
        0,bottomROI,0,writerROI,0,error),
        "LUT zip right/dest overlap rejected");
    require(error==RasterZipTransformError.rightDestinationOverlap,
        "right/dest classification");
}
private void verifySourcesIntact(
    ref RasterLease!SRgba8 lease,size_t layer,Config cfg
) {
    scope auto view=lease.view();
    foreach(y;0..cfg.height)
    foreach(x;0..cfg.width) {
        SRgba8 pixel;
        require(view.trySample(0,x,y,pixel) &&
            pixel==fixture(layer,x,y,cfg.pattern),
            "preflight rejection changed input buffer");
    }
}
private struct Measure {
    long us;
    size_t gc;
}
private Measure timeZip(bool lut,
    ref RasterLease!SRgba8 top,
    ref RasterLease!SRgba8 bottom,
    ref RasterLease!SRgba8 output,
    Config cfg
) {
    StopWatch watch;
    const start=GC.stats().allocatedInCurrentThread;
    watch.start();
    foreach(i;0..cfg.iterations) {
        RasterZipTransformError err;
        if(lut)
            require(zipOne!true(top,bottom,output,selected(cfg),err) &&
                err==RasterZipTransformError.none,"timed LUT zip");
        else
            require(zipOne!false(top,bottom,output,selected(cfg),err) &&
                err==RasterZipTransformError.none,"timed direct zip");
    }
    watch.stop();
    const end=GC.stats().allocatedInCurrentThread;
    require(end>=start && end-start==0,"zero GC bytes in zip hot call");
    return Measure(watch.peek.total!"usecs",end-start);
}
void main(string[] args) {
    const cfg=parse(args);
    checkLutChannels();
    auto top=makeLease!SRgba8(cfg.width,cfg.height,cfg.layout,0,cfg.pattern,true);
    auto bottom=makeLease!SRgba8(cfg.width,cfg.height,cfg.layout,1,cfg.pattern,true);
    auto directOut=makeLease!SRgba8(cfg.width,cfg.height,cfg.layout,0,cfg.pattern,false);
    auto lutOut=makeLease!SRgba8(cfg.width,cfg.height,cfg.layout,0,cfg.pattern,false);
    auto topBytes=makeLease!ubyte(cfg.width,cfg.height,cfg.layout,0,cfg.pattern,true);
    auto lowerBytes=makeLease!ubyte(cfg.width,cfg.height,cfg.layout,1,cfg.pattern,true);
    auto oracle=makeLease!ubyte(cfg.width,cfg.height,cfg.layout,0,cfg.pattern,false);
    verifyAlias(top,bottom,cfg);
    verifySourcesIntact(top,0,cfg);
    verifyRightAlias(top,bottom,cfg);
    verifySourcesIntact(bottom,1,cfg);
    RasterZipTransformError failure;
    require(zipOne!false(top,bottom,directOut,selected(cfg),failure) &&
        failure==RasterZipTransformError.none,"warm direct zip");
    require(zipOne!true(top,bottom,lutOut,selected(cfg),failure) &&
        failure==RasterZipTransformError.none,"warm LUT zip");
    require(fourPlane(topBytes,lowerBytes,oracle,selected(cfg)),
        "warm four-plane oracle");
    assertSameOutput(directOut,lutOut,oracle,cfg);
    const expected=checksum(lutOut,cfg);
    writeln("pattern,layout,roi,width,height,pixels,round,iterations,",
        "direct_zip_us,lut_zip_us,thread_gc_bytes,output_checksum,",
        "pixel_differences,lut_init_us");
    foreach(round;0..cfg.rounds) {
        Measure directMeasure,lutMeasure;
        if(round%2==0) {
            directMeasure=timeZip(false,top,bottom,directOut,cfg);
            lutMeasure=timeZip(true,top,bottom,lutOut,cfg);
        } else {
            lutMeasure=timeZip(true,top,bottom,lutOut,cfg);
            directMeasure=timeZip(false,top,bottom,directOut,cfg);
        }
        assertSameOutput(directOut,lutOut,oracle,cfg);
        require(checksum(lutOut,cfg)==expected,"stable output checksum");
        writeln(name(cfg.pattern),",",
            cfg.layout==Layout.compact?"compact":"padded",",",
            cfg.roiSide ? "square"~to!string(cfg.roiSide) :
                cfg.partial?"partial":"whole",",",
            cfg.width,",",cfg.height,",",
            selected(cfg).width*selected(cfg).height,",",
            round,",",cfg.iterations,",",
            directMeasure.us,",",lutMeasure.us,",",
            directMeasure.gc+lutMeasure.gc,",",expected,",0,",
            preparedLut.setupUs);
    }
    writeln("ZIP-EXACT-LUT PASS: all RGBA bytes equal; ",
        "both physical overlap directions rejected prewrite");
}
