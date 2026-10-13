module app;

// Stage timings are separate diagnostic workloads; they are NOT additive.
// All compositing math is delegated to released color-d v0.2.0.
// No public API, scheduler, renderer or raster internals are introduced.
import core.memory : GC;
import core.stdc.stdlib : malloc;
import std.algorithm.searching : startsWith;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln;
import color :
    Alpha, LinearSRgbd, Premultiplied, SRgbd, SRgba8,
    premultiply, sourceOver, unpremultiply,
    toLinear, toSRgb, tryToSRgba8;
import imagery.presentation.composite :
    DecodedRgbaLayer, RgbaEncoding, RgbaAssociation,
    RgbaCompositeError, ResearchPreparedRgbaContext, tryPrepareRgbaContext,
    tryCompositeRgbaSourceOver, tryCompositeRgbaSourceOverPrepared;
import raster :
    RasterLease, RasterView, WritableRasterView,
    OwnedByteResource, PlaneByteLayout, Region2D,
    RasterCopyError, copyInto,
    tryAdoptMallocResource, tryImportOwnedRaster;

private alias PM = Premultiplied!LinearSRgbd;
private alias LS = Alpha!LinearSRgbd;
private enum double opacity = 0.37;
private enum Pattern : ubyte { mixed, opaque, transparent }
private enum Layout : ubyte { interleaved, planar }
private enum Stage : ubyte {
    checkedIO, decode, premultiply, over, encode, packedFull,
    fourPlaneFull, preparedFourPlaneFull, bufferedPackedFull,
    bufferedAllocatedFull
}
private enum size_t stageCount = 10;

private struct Config {
    size_t width = 96;
    size_t height = 64;
    size_t rounds = 3;
    size_t iterations = 2;
    bool partial;
    size_t roiSide; // 0: old whole/near-full ROI; otherwise offset square
    Pattern pattern = Pattern.mixed;
    Layout layout = Layout.interleaved;
}
private void require(bool ok, string message) {
    if (!ok) throw new Exception("M3 hotpath: " ~ message);
}
private Config config(string[] args) {
    Config cfg;
    foreach (arg; args[1 .. $]) {
        if (arg.startsWith("--width=")) cfg.width = to!size_t(arg[8 .. $]);
        else if (arg.startsWith("--height=")) cfg.height = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--rounds=")) cfg.rounds = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--iterations=")) cfg.iterations = to!size_t(arg[13 .. $]);
        else if (arg == "--partial") cfg.partial = true;
        else if (arg.startsWith("--roi-side=")) {
            cfg.roiSide = to!size_t(arg[11 .. $]);
            require(cfg.roiSide != 0, "explicit square ROI must be nonempty");
        }
        else if (arg == "--layout=planar") cfg.layout = Layout.planar;
        else if (arg == "--layout=interleaved") cfg.layout = Layout.interleaved;
        else if (arg == "--pattern=mixed") cfg.pattern = Pattern.mixed;
        else if (arg == "--pattern=opaque") cfg.pattern = Pattern.opaque;
        else if (arg == "--pattern=transparent") cfg.pattern = Pattern.transparent;
        else throw new Exception("Unknown benchmark option: " ~ arg);
    }
    require(cfg.width >= 24 && cfg.height >= 24 &&
        cfg.width <= cast(size_t)ptrdiff_t.max / 4 &&
        cfg.width <= size_t.max / cfg.height &&
        cfg.width * cfg.height <= cast(size_t)ptrdiff_t.max / 4,
        "valid resident dimensions");
    require(cfg.rounds > 0 && cfg.rounds <= 200 &&
        cfg.iterations > 0 && cfg.iterations <= 200,
        "valid measurement repetitions");
    require(cfg.roiSide == 0 || (!cfg.partial &&
        cfg.width >= 5 && cfg.height >= 7 &&
        cfg.roiSide <= cfg.width - 5 &&
        cfg.roiSide <= cfg.height - 7),
        "offset square ROI must fit and exclude partial mode");
    return cfg;
}
private Region2D region(Config c) @safe pure nothrow @nogc {
    if (c.roiSide != 0) return Region2D(5, 7, c.roiSide, c.roiSide);
    return c.partial
        ? Region2D(5, 7, c.width - 10, c.height - 14)
        : Region2D(0, 0, c.width, c.height);
}
private SRgba8 fixture(size_t layer, size_t x, size_t y, Pattern pattern)
@safe pure nothrow @nogc {
    ubyte a;
    final switch (pattern) {
        case Pattern.opaque: a = 255; break;
        case Pattern.transparent: a = 0; break;
        case Pattern.mixed:
            a = cast(ubyte)(((x + y + layer) % 7 == 0) ? 0 :
                (((x + 2 * y + layer) % 3 == 0) ? 128 : 255));
            break;
    }
    // Nonzero hidden straight RGB must survive *input* transport at alpha=0.
    return SRgba8(
        cast(ubyte)((37 * x + 17 * y + 71 * layer + 13) % 256),
        cast(ubyte)((11 * x + 41 * y + 43 * layer + 29) % 256),
        cast(ubyte)((19 * x + 23 * y + 97 * layer + 53) % 256), a);
}
private RasterLease!ubyte makeImage(
    size_t w, size_t h, Layout layout
) {
    const size_t bytes = w * h * 4;
    auto raw = cast(ubyte*)malloc(bytes);
    require(raw !is null, "allocate independent raster");
    OwnedByteResource owned;
    require(tryAdoptMallocResource(raw, bytes, owned), "adopt raster");
    PlaneByteLayout[4] planes;
    foreach (c; 0 .. 4) {
        planes[c] = layout == Layout.planar
            ? PlaneByteLayout(c * w * h, cast(ptrdiff_t)w, 1)
            : PlaneByteLayout(c, cast(ptrdiff_t)(w * 4), 4);
    }
    RasterLease!ubyte lease;
    require(tryImportOwnedRaster!ubyte(
        owned, planes[], Region2D(0, 0, w, h), lease).ok,
        "import four-plane layout");
    return lease;
}
private RasterLease!SRgba8 makePackedImage(size_t w, size_t h)
{
    require(w > 0 && h > 0 && h <= size_t.max/4 &&
        w <= size_t.max/(h*4) && w <= cast(size_t)ptrdiff_t.max/4,
        "bounded packed output scratch");
    const bytes = w*h*4;
    auto raw = cast(ubyte*)malloc(bytes);
    require(raw !is null, "allocate independent packed scratch");
    OwnedByteResource resource;
    require(tryAdoptMallocResource(raw, bytes, resource),
        "adopt packed scratch backing");
    PlaneByteLayout[1] plane =
        [PlaneByteLayout(0, cast(ptrdiff_t)(w*4), 4)];
    RasterLease!SRgba8 lease;
    require(tryImportOwnedRaster!SRgba8(resource, plane[],
        Region2D(0, 0, w, h), lease).ok,
        "import publicly owned packed scratch");
    return lease;
}
private void fill(
    ref RasterLease!ubyte lease, SRgba8[] pixels, size_t w, size_t h
) {
    bool ok;
    scope auto v = lease.tryWritableView(ok);
    require(ok, "writable input");
    foreach (y; 0 .. h)
    foreach (x; 0 .. w) {
        const p = pixels[y * w + x];
        require(v.trySetSample(0, x, y, p.r) &&
            v.trySetSample(1, x, y, p.g) &&
            v.trySetSample(2, x, y, p.b) &&
            v.trySetSample(3, x, y, p.a),
            "populate input samples");
    }
}
private PM opacityScaled(PM fg) @safe pure nothrow @nogc {
    return PM(LinearSRgbd(
        fg.color.r * opacity,
        fg.color.g * opacity,
        fg.color.b * opacity), fg.alpha * opacity);
}
private LS decodePixel(SRgba8 p) @safe nothrow @nogc {
    const straight = p.toAlphaSRgb!double();
    return LS(straight.color.toLinear(), straight.alpha);
}
private PM makePM(LS p) @safe pure nothrow @nogc {
    return premultiply(p);
}
private bool storePixel(PM result, out SRgba8 stored)
@safe nothrow @nogc {
    const straight = unpremultiply(result);
    return tryToSRgba8(
        Alpha!SRgbd(straight.color.toSRgb(), straight.alpha), stored);
}
private bool fullPixel(SRgba8 top, SRgba8 bottom, out SRgba8 result)
@safe nothrow @nogc {
    const fg = opacityScaled(makePM(decodePixel(top)));
    const bg = makePM(decodePixel(bottom));
    return storePixel(sourceOver(fg, bg), result);
}

private struct Working {
    SRgba8[] top;
    SRgba8[] bottom;
    LS[] decodedTop;
    LS[] decodedBottom;
    PM[] premulTop;
    PM[] premulBottom;
    PM[] mixed;
    SRgba8[] stagedOutput;
    SRgba8[] fullOutput;
    RasterLease!ubyte upperLease;
    RasterLease!ubyte lowerLease;
    RasterLease!ubyte outputLease;
    RasterLease!ubyte stagingFourPlaneLease;
    RasterLease!SRgba8 stagingPackedLease;
    RasterLease!SRgba8 committedPackedLease;
    ResearchPreparedRgbaContext prepared;
    long prepareMicros;
    Config cfg;
    Region2D roi;
}
private Working create(Config cfg) {
    Working work;
    work.cfg = cfg;
    work.roi = region(cfg);
    const n = cfg.width * cfg.height;
    work.top = new SRgba8[n];
    work.bottom = new SRgba8[n];
    work.decodedTop = new LS[n];
    work.decodedBottom = new LS[n];
    work.premulTop = new PM[n];
    work.premulBottom = new PM[n];
    work.mixed = new PM[n];
    work.stagedOutput = new SRgba8[n];
    work.fullOutput = new SRgba8[n];

    foreach (y; 0 .. cfg.height)
    foreach (x; 0 .. cfg.width) {
        const i = y * cfg.width + x;
        work.top[i] = fixture(0, x, y, cfg.pattern);
        work.bottom[i] = fixture(1, x, y, cfg.pattern);
    }
    work.upperLease = makeImage(cfg.width, cfg.height, cfg.layout);
    work.lowerLease = makeImage(cfg.width, cfg.height, cfg.layout);
    work.outputLease = makeImage(work.roi.width, work.roi.height, cfg.layout);
    work.stagingFourPlaneLease =
        makeImage(work.roi.width, work.roi.height, cfg.layout);
    work.stagingPackedLease =
        makePackedImage(work.roi.width, work.roi.height);
    work.committedPackedLease =
        makePackedImage(work.roi.width, work.roi.height);
    fill(work.upperLease, work.top, cfg.width, cfg.height);
    fill(work.lowerLease, work.bottom, cfg.width, cfg.height);
    StopWatch preparedTimer;
    preparedTimer.start();
    require(tryPrepareRgbaContext(opacity, work.prepared)
        == RgbaCompositeError.none, "prepare exact runtime LUT and opacity");
    preparedTimer.stop();
    work.prepareMicros = preparedTimer.peek.total!"usecs";
    return work;
}

private bool checkedAccess(
    scope RasterView!ubyte upper, scope RasterView!ubyte lower,
    Region2D roi, scope WritableRasterView!ubyte output
) @safe nothrow @nogc {
    // Control-plane workload: 8 checked reads + 4 checked writes per pixel.
    // Its XOR operation is deliberately NOT an equivalent color computation.
    foreach (y; 0 .. roi.height)
    foreach (x; 0 .. roi.width) {
        ubyte[4] top;
        ubyte[4] bottom;
        foreach (c; 0 .. 4) {
            if (!upper.trySample(c, roi.x + x, roi.y + y, top[c]) ||
                !lower.trySample(c, roi.x + x, roi.y + y, bottom[c]))
                return false;
        }
        foreach (c; 0 .. 4)
            if (!output.trySetSample(c, x, y, top[c] ^ bottom[c]))
                return false;
    }
    return true;
}
private bool fourPlane(Working* w) @safe nothrow @nogc {
    scope auto top = w.upperLease.view();
    scope auto bottom = w.lowerLease.view();
    bool writable;
    scope auto dest = w.outputLease.tryWritableView(writable);
    if (!writable) return false;
    return tryCompositeRgbaSourceOver(
        DecodedRgbaLayer(top, RgbaEncoding.encodedSRgb,
            RgbaAssociation.straight),
        DecodedRgbaLayer(bottom, RgbaEncoding.encodedSRgb,
            RgbaAssociation.straight),
        w.roi, opacity, dest) == RgbaCompositeError.none;
}
private bool preparedFourPlane(Working* w) @safe nothrow @nogc {
    scope auto top = w.upperLease.view();
    scope auto bottom = w.lowerLease.view();
    bool writable;
    scope auto dest = w.outputLease.tryWritableView(writable);
    if (!writable) return false;
    return tryCompositeRgbaSourceOverPrepared(
        w.prepared,
        DecodedRgbaLayer(top, RgbaEncoding.encodedSRgb,
            RgbaAssociation.straight),
        DecodedRgbaLayer(bottom, RgbaEncoding.encodedSRgb,
            RgbaAssociation.straight),
        w.roi, dest) == RgbaCompositeError.none;
}
// Buffered alternative: compute + repack + one public physical-copy
// preflight and commit. Scratch buffers are distinct, preallocated,
// caller-owned research leases; their creation is OUTSIDE timing.
// It changes the original input-vs-output overlap model to a snapshot
// potential, and is NOT a full checked multi-plane destination contract.
private bool bufferedPackedUsing(Working* w,
    ref RasterLease!ubyte stagingFourPlane,
    ref RasterLease!SRgba8 stagingPacked,
    ref RasterLease!SRgba8 committedPacked)
@safe nothrow @nogc {
    {
        scope auto top = w.upperLease.view();
        scope auto lower = w.lowerLease.view();
        bool writable;
        scope auto stageTarget =
            stagingFourPlane.tryWritableView(writable);
        if (!writable) return false;
        if (tryCompositeRgbaSourceOverPrepared(
            w.prepared,
            DecodedRgbaLayer(top, RgbaEncoding.encodedSRgb,
                RgbaAssociation.straight),
            DecodedRgbaLayer(lower, RgbaEncoding.encodedSRgb,
                RgbaAssociation.straight),
            w.roi, stageTarget) != RgbaCompositeError.none)
            return false;
    }
    {
        scope auto staged = stagingFourPlane.view();
        bool writable;
        scope auto packedStage =
            stagingPacked.tryWritableView(writable);
        if (!writable) return false;
        foreach (y; 0 .. w.roi.height)
        foreach (x; 0 .. w.roi.width) {
            ubyte r, g, b, a;
            if (!staged.trySample(0, x, y, r) ||
                !staged.trySample(1, x, y, g) ||
                !staged.trySample(2, x, y, b) ||
                !staged.trySample(3, x, y, a) ||
                !packedStage.trySetSample(0, x, y, SRgba8(r, g, b, a)))
                return false;
        }
    }
    {
        scope auto from = stagingPacked.view();
        bool writable;
        scope auto to = committedPacked.tryWritableView(writable);
        if (!writable) return false;
        RasterCopyError copyError;
        return copyInto(from, 0, to, 0, copyError) &&
            copyError == RasterCopyError.none;
    }
}
private bool bufferedPacked(Working* w) @safe nothrow @nogc {
    return bufferedPackedUsing(w, w.stagingFourPlaneLease,
        w.stagingPackedLease, w.committedPackedLease);
}
// A deliberately separate allocation-inclusive scratch treatment. Only
// caller-owned final target and prepared LUT are reused; two ROI-sized
// native-malloc scratch owners are constructed and destroyed per invocation.
// This is an experimental cost measure, not a production allocation API.
private bool bufferedAllocate(Working* w) {
    auto four = makeImage(w.roi.width, w.roi.height, w.cfg.layout);
    auto packed = makePackedImage(w.roi.width, w.roi.height);
    return bufferedPackedUsing(w, four, packed, w.committedPackedLease);
}
private bool stage(Working* w, Stage what) @safe nothrow @nogc {
    if (what == Stage.fourPlaneFull)
        return fourPlane(w);
    if (what == Stage.preparedFourPlaneFull)
        return preparedFourPlane(w);
    if (what == Stage.bufferedPackedFull)
        return bufferedPacked(w);
    if (what == Stage.bufferedAllocatedFull)
        return false; // timeStage creates fresh owners outside @nogc stage
    if (what == Stage.checkedIO) {
        scope auto top = w.upperLease.view();
        scope auto bottom = w.lowerLease.view();
        bool writable;
        scope auto dest = w.outputLease.tryWritableView(writable);
        return writable && checkedAccess(top, bottom, w.roi, dest);
    }
    const roi = w.roi;
    const width = w.cfg.width;
    foreach (y; 0 .. roi.height)
    foreach (x; 0 .. roi.width) {
        const i = (roi.y + y) * width + roi.x + x;
        final switch (what) {
            case Stage.checkedIO: break; // handled before the loop
            case Stage.fourPlaneFull: break; // handled before the loop
            case Stage.preparedFourPlaneFull: break; // handled before loop
            case Stage.bufferedPackedFull: break; // handled before loop
            case Stage.bufferedAllocatedFull: break; // handled by timeStage
            case Stage.decode:
                w.decodedTop[i] = decodePixel(w.top[i]);
                w.decodedBottom[i] = decodePixel(w.bottom[i]);
                break;
            case Stage.premultiply:
                w.premulTop[i] = makePM(w.decodedTop[i]);
                w.premulBottom[i] = makePM(w.decodedBottom[i]);
                break;
            case Stage.over:
                w.mixed[i] = sourceOver(
                    opacityScaled(w.premulTop[i]), w.premulBottom[i]);
                break;
            case Stage.encode:
                if (!storePixel(w.mixed[i], w.stagedOutput[i]))
                    return false;
                break;
            case Stage.packedFull:
                if (!fullPixel(w.top[i], w.bottom[i], w.fullOutput[i]))
                    return false;
                break;
        }
    }
    return true;
}
private void prepareAndVerify(Working* w) {
    // Isolated mathematical stages and full packed-array oracle.
    foreach (step; [Stage.decode, Stage.premultiply, Stage.over,
                    Stage.encode, Stage.packedFull])
        require(stage(w, step), "prepare mathematical oracle stages");

    // Verify the complete packed single-plane commit against the same
    // independent prepared/staged mathematical output on every round.
    require(stage(w, Stage.bufferedPackedFull),
        "buffered prepared color + packed public-copy commit");
    {
        scope auto completed = w.committedPackedLease.view();
        foreach (y; 0 .. w.roi.height)
        foreach (x; 0 .. w.roi.width) {
            const index = (w.roi.y+y)*w.cfg.width + w.roi.x+x;
            SRgba8 committed;
            require(completed.trySample(0, x, y, committed) &&
                committed == w.fullOutput[index],
                "buffered copy commit byte-exact to independent packed oracle");
        }
    }

    require(bufferedAllocate(w),
        "newly allocated two-scratch packed commit exactly matches reused");
    {
        scope auto completed = w.committedPackedLease.view();
        foreach (y; 0 .. w.roi.height)
        foreach (x; 0 .. w.roi.width) {
            const index = (w.roi.y+y)*w.cfg.width + w.roi.x+x;
            SRgba8 pixel;
            require(completed.trySample(0, x, y, pixel) &&
                pixel == w.fullOutput[index],
                "allocation-inclusive final commit matches canonical RGBA");
        }
    }

    // Both real four-plane execution variants independently compare
    // every output pixel against the same packed/color-d oracle.
    // This is a *differential* test, not an additive stage cost model.
    foreach (treatment; [Stage.fourPlaneFull, Stage.preparedFourPlaneFull]) {
        require(stage(w, treatment), "complete four-plane stage");
        {
            scope auto result = w.outputLease.view();
            foreach (y; 0 .. w.roi.height)
            foreach (x; 0 .. w.roi.width) {
                const i = (w.roi.y + y) * w.cfg.width + w.roi.x + x;
                const a = w.stagedOutput[i];
                const b = w.fullOutput[i];
                require(a == b, "staged and fused byte-exact output");
                ubyte[4] samples;
                foreach (c; 0 .. 4)
                    require(result.trySample(c, x, y, samples[c]),
                        "read full four-plane output");
                require(a.r == samples[0] && a.g == samples[1] &&
                    a.b == samples[2] && a.a == samples[3],
                    "both whole four-plane treatments match packed oracle");
            }
        }
    }
}
private ulong checksum(Working* w) {
    ulong hash = 1469598103934665603UL;
    foreach (y; 0 .. w.roi.height)
    foreach (x; 0 .. w.roi.width) {
        const i = (w.roi.y + y) * w.cfg.width + w.roi.x + x;
        const p = w.fullOutput[i];
        foreach (v; [p.r, p.g, p.b, p.a])
            hash = (hash ^ v) * 1099511628211UL;
    }
    return hash;
}
private struct Timed {
    long micros;
    size_t gcBytes;
}
private Timed timeStage(Working* w, Stage what, size_t iterations) {
    StopWatch timer;
    const before = GC.stats().allocatedInCurrentThread;
    timer.start();
    foreach (_; 0 .. iterations) {
        const success = what == Stage.bufferedAllocatedFull
            ? bufferedAllocate(w) : stage(w, what);
        require(success, "timed stage completed");
    }
    timer.stop();
    const after = GC.stats().allocatedInCurrentThread;
    require(after >= before && after - before == 0,
        "zero thread-local GC allocation in measured stage");
    return Timed(timer.peek.total!"usecs", after - before);
}
private string stageName(Stage s) @safe pure nothrow @nogc {
    final switch (s) {
        case Stage.checkedIO: return "checked_io";
        case Stage.decode: return "decode_2rgb";
        case Stage.premultiply: return "premultiply_2";
        case Stage.over: return "source_over";
        case Stage.encode: return "unpremul_encode_quantize";
        case Stage.packedFull: return "packed_full";
        case Stage.fourPlaneFull: return "fourplane_full";
        case Stage.preparedFourPlaneFull: return "prepared_fourplane_full";
        case Stage.bufferedPackedFull: return "buffered_packed_commit";
        case Stage.bufferedAllocatedFull: return "buffered_allocating_commit";
    }
}
private string patternName(Pattern p) @safe pure nothrow @nogc {
    final switch (p) {
        case Pattern.mixed: return "mixed";
        case Pattern.opaque: return "opaque";
        case Pattern.transparent: return "transparent";
    }
}
void main(string[] args) {
    const cfg = config(args);
    Working w = create(cfg);
    prepareAndVerify(&w);
    const initial = checksum(&w);

    writeln("pattern,layout,roi,width,height,pixels,round,iterations,",
        "stage,elapsed_us,thread_gc_bytes,canonical_checksum");
    foreach (round; 0 .. cfg.rounds) {
        // Rotate measurement sequence; no stage timing is added to another.
        foreach (step; 0 .. stageCount) {
            const s = cast(Stage)((step + round) % stageCount);
            const timing = timeStage(&w, s, cfg.iterations);
            writeln(patternName(cfg.pattern), ",",
                cfg.layout == Layout.planar ? "planar" : "interleaved", ",",
                cfg.roiSide != 0 ? "square" ~ to!string(cfg.roiSide) :
                    cfg.partial ? "partial" : "whole", ",",
                cfg.width, ",", cfg.height, ",",
                w.roi.width * w.roi.height, ",",
                round, ",", cfg.iterations, ",", stageName(s), ",",
                timing.micros, ",", timing.gcBytes, ",", initial);
        }
        prepareAndVerify(&w);
        require(checksum(&w) == initial,
            "per-round exact result checksum unchanged");
    }
    writeln("HOTPATH-STAGES PASS: all pixels match canonical RGBA, ",
        "all timed stages zero current-thread GC bytes, prepared_init_us=",
        w.prepareMicros);
}
