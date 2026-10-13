module app;

// RESEARCH ONLY: a runtime-prepared table of 256 exactly color-d-produced
// binary64 decode values, not a new public color model or production renderer.
// All source-over, alpha and quantization semantics remain in color-d.
import core.memory : GC;
import core.stdc.stdlib : malloc;
import std.algorithm.searching : startsWith;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln;
import color :
    Alpha, LinearSRgbd, Premultiplied, SRgbd, SRgba8,
    premultiply, sourceOver, unpremultiply, tryToSRgba8, toLinear, toSRgb;
import imagery.presentation.composite :
    DecodedRgbaLayer, RgbaEncoding, RgbaAssociation, RgbaCompositeError,
    tryCompositeRgbaSourceOver;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;

private alias LinearAlpha = Alpha!LinearSRgbd;
private alias PM = Premultiplied!LinearSRgbd;

private enum Pattern : ubyte { mixed, opaque, transparent, topTransparent, bottomTransparent }
private enum Layout : ubyte { interleaved, planar }
private struct Config {
    size_t width = 128;
    size_t height = 64;
    size_t rounds = 3;
    size_t iterations = 2;
    bool partial;
    Pattern pattern = Pattern.mixed;
    Layout layout = Layout.interleaved;
    double opacity = 0.37;
}

private void check(bool ok, string explanation) {
    if (!ok) throw new Exception("RGBA exact LUT: " ~ explanation);
}
private Config parse(string[] args) {
    Config c;
    foreach (a; args[1 .. $]) {
        if (a.startsWith("--width=")) c.width = to!size_t(a[8 .. $]);
        else if (a.startsWith("--height=")) c.height = to!size_t(a[9 .. $]);
        else if (a.startsWith("--rounds=")) c.rounds = to!size_t(a[9 .. $]);
        else if (a.startsWith("--iterations=")) c.iterations = to!size_t(a[13 .. $]);
        else if (a.startsWith("--opacity=")) c.opacity = to!double(a[10 .. $]);
        else if (a == "--partial") c.partial = true;
        else if (a == "--layout=interleaved") c.layout = Layout.interleaved;
        else if (a == "--layout=planar") c.layout = Layout.planar;
        else if (a == "--pattern=mixed") c.pattern = Pattern.mixed;
        else if (a == "--pattern=opaque") c.pattern = Pattern.opaque;
        else if (a == "--pattern=transparent") c.pattern = Pattern.transparent;
        else if (a == "--pattern=top-transparent") c.pattern = Pattern.topTransparent;
        else if (a == "--pattern=bottom-transparent") c.pattern = Pattern.bottomTransparent;
        else throw new Exception("Unknown argument: " ~ a);
    }
    check(c.width >= 32 && c.height >= 32 &&
        c.width <= cast(size_t)ptrdiff_t.max / 4 &&
        c.width <= size_t.max / c.height &&
        c.width * c.height <= cast(size_t)ptrdiff_t.max / 4,
        "valid dimensions");
    check(c.rounds > 0 && c.rounds <= 200 &&
        c.iterations > 0 && c.iterations <= 200,
        "valid repetitions");
    check(c.opacity >= 0.0 && c.opacity <= 1.0,
        "opacity in inclusive unit interval");
    return c;
}
private Region2D roi(Config c) @safe pure nothrow @nogc {
    return c.partial
        ? Region2D(7, 11, c.width - 14, c.height - 22)
        : Region2D(0, 0, c.width, c.height);
}
private string label(Pattern p) @safe pure nothrow @nogc {
    final switch (p) {
        case Pattern.mixed: return "mixed";
        case Pattern.opaque: return "opaque";
        case Pattern.transparent: return "transparent";
        case Pattern.topTransparent: return "top-transparent";
        case Pattern.bottomTransparent: return "bottom-transparent";
    }
}
private SRgba8 fixture(
    size_t layer, size_t x, size_t y, Pattern pattern
) @safe pure nothrow @nogc {
    uint alpha;
    final switch (pattern) {
        case Pattern.opaque: alpha = 255; break;
        case Pattern.transparent: alpha = 0; break;
        case Pattern.topTransparent: alpha = layer == 0 ? 0 : 128; break;
        case Pattern.bottomTransparent: alpha = layer == 1 ? 0 : 128; break;
        case Pattern.mixed:
            alpha = ((x + y + layer) % 7 == 0) ? 0
                : ((x + 2*y + layer) % 5 == 0) ? 1
                : ((x + 3*y + layer) % 11 == 0) ? 254
                : ((x + 2*y + layer) % 3 == 0) ? 128 : 255;
            break;
    }
    return SRgba8(
        cast(ubyte)((37*x + 17*y + 71*layer + 13) % 256),
        cast(ubyte)((11*x + 41*y + 43*layer + 29) % 256),
        cast(ubyte)((19*x + 23*y + 97*layer + 53) % 256),
        cast(ubyte)alpha);
}
private struct DecodeLut {
    double[256] channel;
}
private DecodeLut makeRuntimeLut()
@safe nothrow @nogc {
    DecodeLut table;
    // The only source for each value is color-d v0.2.0's public
    // runtime conversion. No local sRGB formula or re-quantization.
    foreach (i; 0 .. 256) {
        const ubyte b = cast(ubyte)i;
        const p = SRgba8(b, b, b, 255).toAlphaSRgb!double();
        table.channel[i] = p.color.toLinear().r;
    }
    return table;
}
private LinearAlpha decodeDirect(SRgba8 value)
@safe nothrow @nogc {
    const p = value.toAlphaSRgb!double();
    return LinearAlpha(p.color.toLinear(), p.alpha);
}
private LinearAlpha decodeLut(SRgba8 value, ref const DecodeLut table)
@safe nothrow @nogc {
    return LinearAlpha(
        LinearSRgbd(table.channel[value.r],
            table.channel[value.g], table.channel[value.b]),
        cast(double)value.a / 255.0);
}
private PM withOpacity(PM source, double opacity)
@safe pure nothrow @nogc {
    return PM(LinearSRgbd(
        source.color.r * opacity,
        source.color.g * opacity,
        source.color.b * opacity), source.alpha * opacity);
}
private bool pixel(bool tableMode)(
    SRgba8 top, SRgba8 bottom, ref const DecodeLut table,
    double opacity, out SRgba8 result
) @safe nothrow @nogc {
    static if (tableMode) {
        const foreground = premultiply(decodeLut(top, table));
        const background = premultiply(decodeLut(bottom, table));
    } else {
        const foreground = premultiply(decodeDirect(top));
        const background = premultiply(decodeDirect(bottom));
    }
    const mixed = sourceOver(withOpacity(foreground, opacity), background);
    const straight = unpremultiply(mixed);
    return tryToSRgba8(
        Alpha!SRgbd(straight.color.toSRgb(), straight.alpha), result);
}
private RasterLease!ubyte makeLease(
    size_t width, size_t height, Layout layout
) {
    const bytes = width * height * 4;
    auto raw = cast(ubyte*)malloc(bytes);
    check(raw !is null, "allocate independent four-plane buffer");
    OwnedByteResource owned;
    check(tryAdoptMallocResource(raw, bytes, owned), "adopt malloc storage");
    PlaneByteLayout[4] planes;
    foreach (c; 0 .. 4) {
        planes[c] = layout == Layout.planar
            ? PlaneByteLayout(c * width * height, cast(ptrdiff_t)width, 1)
            : PlaneByteLayout(c, cast(ptrdiff_t)(4*width), 4);
    }
    RasterLease!ubyte lease;
    check(tryImportOwnedRaster!ubyte(
        owned, planes[], Region2D(0,0,width,height), lease).ok,
        "import backed view with explicit layout");
    return lease;
}
private void fill(
    ref RasterLease!ubyte lease, const(SRgba8)[] pixels,
    size_t width, size_t height
) {
    bool ok;
    scope auto view = lease.tryWritableView(ok);
    check(ok, "writable source");
    foreach (y; 0 .. height)
    foreach (x; 0 .. width) {
        const v = pixels[y*width+x];
        check(view.trySetSample(0,x,y,v.r) &&
            view.trySetSample(1,x,y,v.g) &&
            view.trySetSample(2,x,y,v.b) &&
            view.trySetSample(3,x,y,v.a), "source write");
    }
}
private struct Work {
    Config cfg;
    Region2D selected;
    DecodeLut table;
    SRgba8[] top;
    SRgba8[] bottom;
    SRgba8[] directOut;
    SRgba8[] tableOut;
    LinearAlpha[] directTop;
    LinearAlpha[] directBottom;
    LinearAlpha[] tableTop;
    LinearAlpha[] tableBottom;
    RasterLease!ubyte upperLease;
    RasterLease!ubyte lowerLease;
    RasterLease!ubyte outputLease;
}
private Work setup(Config cfg) {
    Work w;
    w.cfg = cfg;
    w.selected = roi(cfg);
    w.table = makeRuntimeLut();
    const n = cfg.width * cfg.height;
    w.top = new SRgba8[n];
    w.bottom = new SRgba8[n];
    w.directOut = new SRgba8[n];
    w.tableOut = new SRgba8[n];
    w.directTop = new LinearAlpha[n];
    w.directBottom = new LinearAlpha[n];
    w.tableTop = new LinearAlpha[n];
    w.tableBottom = new LinearAlpha[n];
    foreach (y; 0 .. cfg.height)
    foreach (x; 0 .. cfg.width) {
        const idx = y*cfg.width+x;
        w.top[idx] = fixture(0,x,y,cfg.pattern);
        w.bottom[idx] = fixture(1,x,y,cfg.pattern);
    }
    w.upperLease = makeLease(cfg.width,cfg.height,cfg.layout);
    w.lowerLease = makeLease(cfg.width,cfg.height,cfg.layout);
    w.outputLease = makeLease(w.selected.width,w.selected.height,cfg.layout);
    fill(w.upperLease,w.top,cfg.width,cfg.height);
    fill(w.lowerLease,w.bottom,cfg.width,cfg.height);
    return w;
}
private bool decodeLoop(bool tableMode)(Work* w)
@safe nothrow @nogc {
    const r = w.selected;
    foreach (y; 0 .. r.height)
    foreach (x; 0 .. r.width) {
        const i = (r.y+y)*w.cfg.width+r.x+x;
        static if (tableMode) {
            w.tableTop[i] = decodeLut(w.top[i], w.table);
            w.tableBottom[i] = decodeLut(w.bottom[i], w.table);
        } else {
            w.directTop[i] = decodeDirect(w.top[i]);
            w.directBottom[i] = decodeDirect(w.bottom[i]);
        }
    }
    return true;
}
private bool fullLoop(bool tableMode)(Work* w)
@safe nothrow @nogc {
    const r = w.selected;
    foreach (y; 0 .. r.height)
    foreach (x; 0 .. r.width) {
        const i = (r.y+y)*w.cfg.width+r.x+x;
        static if (tableMode) {
            if (!pixel!true(w.top[i],w.bottom[i],w.table,
                w.cfg.opacity,w.tableOut[i])) return false;
        } else {
            if (!pixel!false(w.top[i],w.bottom[i],w.table,
                w.cfg.opacity,w.directOut[i])) return false;
        }
    }
    return true;
}
private uint checkAll256(Work* w) {
    uint mismatches = 0;
    foreach (i; 0 .. 256) {
        const b = cast(ubyte)i;
        const direct = decodeDirect(SRgba8(b,b,b,255));
        const actual = w.table.channel[i];
        // All normal finite nonnegative binary64; numerical equality of
        // the same input is exact here (no tolerance, no rounded bytes).
        if (!(direct.color.r == actual && direct.color.g == actual &&
            direct.color.b == actual)) ++mismatches;
    }
    check(mismatches == 0, "256 runtime table entries exactly equal color-d");
    return mismatches;
}
private void verify(Work* w) {
    check(decodeLoop!false(w) && decodeLoop!true(w),
        "two isolated decode implementations");
    const r = w.selected;
    foreach (y; 0 .. r.height)
    foreach (x; 0 .. r.width) {
        const i = (r.y+y)*w.cfg.width+r.x+x;
        check(w.directTop[i] == w.tableTop[i] &&
            w.directBottom[i] == w.tableBottom[i],
            "decoded channel/alpha values binary64 equal");
    }
    check(fullLoop!false(w) && fullLoop!true(w),
        "two complete RGBA array implementations");

    scope auto a = w.upperLease.view();
    scope auto b = w.lowerLease.view();
    bool writable;
    scope auto dest = w.outputLease.tryWritableView(writable);
    check(writable, "caller-owned destination");
    check(tryCompositeRgbaSourceOver(
        DecodedRgbaLayer(a,RgbaEncoding.encodedSRgb,RgbaAssociation.straight),
        DecodedRgbaLayer(b,RgbaEncoding.encodedSRgb,RgbaAssociation.straight),
        r, w.cfg.opacity, dest) == RgbaCompositeError.none,
        "canonical four-plane compositor");
    scope auto result = w.outputLease.view();
    foreach (y; 0 .. r.height)
    foreach (x; 0 .. r.width) {
        const i = (r.y+y)*w.cfg.width+r.x+x;
        check(w.directOut[i] == w.tableOut[i],
            "runtime LUT matches direct full RGB output");
        const p = w.directOut[i];
        ubyte[4] observed;
        foreach (c; 0 .. 4)
            check(result.trySample(c,x,y,observed[c]),
                "read canonical output for every pixel");
        check(p.r==observed[0] && p.g==observed[1] &&
            p.b==observed[2] && p.a==observed[3],
            "runtime LUT/direct both match canonical output");
    }
}
private ulong checksum(Work* w) {
    ulong h = 1469598103934665603UL;
    const r = w.selected;
    foreach (y; 0 .. r.height)
    foreach (x; 0 .. r.width) {
        const p = w.tableOut[(r.y+y)*w.cfg.width+r.x+x];
        h = (h ^ p.r) * 1099511628211UL;
        h = (h ^ p.g) * 1099511628211UL;
        h = (h ^ p.b) * 1099511628211UL;
        h = (h ^ p.a) * 1099511628211UL;
    }
    return h;
}
private struct Timing {
    long us;
    size_t gc;
}
private Timing timePath(bool isLut, bool isFull, Work* w)
{
    StopWatch watch;
    const before = GC.stats().allocatedInCurrentThread;
    watch.start();
    foreach (_; 0 .. w.cfg.iterations) {
        if (isFull) {
            if (isLut) check(fullLoop!true(w), "LUT full path");
            else check(fullLoop!false(w), "color-d full path");
        } else {
            if (isLut) check(decodeLoop!true(w), "LUT decode");
            else check(decodeLoop!false(w), "color-d decode");
        }
    }
    watch.stop();
    const after = GC.stats().allocatedInCurrentThread;
    check(after >= before && after-before == 0,
        "zero current-thread GC allocation in measured path");
    return Timing(watch.peek.total!"usecs", after-before);
}
void main(string[] args) {
    const c = parse(args);
    Work work = setup(c);
    const channelDifferences = checkAll256(&work);
    verify(&work);
    const referenceHash = checksum(&work);
    // All setup, table preparation, and canonical oracle checks are
    // outside measured hot loops. Alternate order between rounds.
    writeln("pattern,layout,roi,opacity,width,height,pixels,round,iterations,",
        "direct_decode_us,lut_decode_us,direct_full_us,lut_full_us,",
        "thread_gc_bytes,canonical_checksum,runtime_lut_value_mismatches");
    foreach (round; 0 .. c.rounds) {
        Timing dDecode, lDecode, dFull, lFull;
        if (round % 2 == 0) {
            dDecode=timePath(false,false,&work);
            lDecode=timePath(true,false,&work);
            dFull=timePath(false,true,&work);
            lFull=timePath(true,true,&work);
        } else {
            lFull=timePath(true,true,&work);
            dFull=timePath(false,true,&work);
            lDecode=timePath(true,false,&work);
            dDecode=timePath(false,false,&work);
        }
        check(dDecode.gc + lDecode.gc + dFull.gc + lFull.gc == 0,
            "no GC byte deltas in all four measured paths");
        verify(&work);
        check(checksum(&work) == referenceHash,
            "stable checksum through alternating rounds");
        writeln(label(c.pattern), ",",
            c.layout == Layout.planar ? "planar" : "interleaved", ",",
            c.partial ? "partial" : "whole", ",", c.opacity, ",",
            c.width,",",c.height,",",work.selected.width*work.selected.height,
            ",",round,",",c.iterations,",",dDecode.us,",",lDecode.us,",",
            dFull.us,",",lFull.us,",",0,",",referenceHash,",",
            channelDifferences);
    }
    writeln("EXACT-DECODE-LUT PASS: 256/256 channels and full RGBA match color-d");
}
