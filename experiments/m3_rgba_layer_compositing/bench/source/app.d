module app;

// Separate process-level diagnostic benchmark; not a correctness oracle.
// "relay" measures a checked 8-read/4-write raster access floor and deliberately
// performs different color work. It is NOT a semantically equivalent compositor.
import core.memory : GC;
import core.stdc.stdlib : malloc;
import std.algorithm.searching : startsWith;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln;
import imagery.presentation.composite :
    DecodedRgbaLayer, RgbaEncoding, RgbaAssociation, RgbaCompositeError,
    tryCompositeRgbaSourceOver;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease,
    RasterView, WritableRasterView, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;

private enum Layout : ubyte { planar, interleaved }
private enum Mode : ubyte { encodedStraight, linearPremultiplied }

private struct Config
{
    size_t width = 256;
    size_t height = 256;
    size_t rounds = 5;
    size_t iterations = 3;
    Layout layout = Layout.interleaved;
    Mode mode = Mode.encodedStraight;
}

private void require(bool success, string explanation)
{
    if (!success)
        throw new Exception("RGBA benchmark: " ~ explanation);
}

private Config parseArgs(string[] args)
{
    Config result;
    foreach (arg; args[1 .. $])
    {
        if (arg.startsWith("--width="))
            result.width = to!size_t(arg[8 .. $]);
        else if (arg.startsWith("--height="))
            result.height = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--rounds="))
            result.rounds = to!size_t(arg[9 .. $]);
        else if (arg.startsWith("--iterations="))
            result.iterations = to!size_t(arg[13 .. $]);
        else if (arg == "--layout=planar")
            result.layout = Layout.planar;
        else if (arg == "--layout=interleaved")
            result.layout = Layout.interleaved;
        else if (arg == "--mode=encoded")
            result.mode = Mode.encodedStraight;
        else if (arg == "--mode=linear-pm")
            result.mode = Mode.linearPremultiplied;
        else
            throw new Exception("Unknown argument " ~ arg);
    }
    require(result.width != 0 && result.height != 0 &&
        result.width <= size_t.max / result.height &&
        result.width * result.height <= size_t.max / 4,
        "valid dimensions and byte capacity");
    require(result.rounds != 0 && result.rounds <= 1000 &&
        result.iterations != 0 && result.iterations <= 10000,
        "valid repetitions");
    return result;
}

private RasterLease!ubyte makeImage(
    size_t w, size_t h, Layout layout, Mode mode, size_t layer,
    bool populate
)
{
    const size_t bytes = w * h * 4;
    auto raw = cast(ubyte*)malloc(bytes);
    require(raw !is null, "allocate independent RGBA backing");
    OwnedByteResource owned;
    require(tryAdoptMallocResource(raw, bytes, owned),
        "adopt independent backing");

    PlaneByteLayout[4] planes;
    foreach (c; 0 .. 4)
    {
        planes[c] = layout == Layout.planar
            ? PlaneByteLayout(c * w * h, cast(ptrdiff_t)w, 1)
            : PlaneByteLayout(c, cast(ptrdiff_t)(4 * w), 4);
    }
    RasterLease!ubyte result;
    require(tryImportOwnedRaster!ubyte(
        owned, planes[], Region2D(0, 0, w, h), result).ok,
        "import owned four-plane raster");

    if (populate)
    {
        bool writable;
        scope auto output = result.tryWritableView(writable);
        require(writable, "populate resident source");
        foreach (y; 0 .. h)
        foreach (x; 0 .. w)
        {
            const uint a = ((x + y + layer) % 7 == 0) ? 0 :
                ((x + 2 * y + layer) % 3 == 0 ? 128 : 255);
            uint[3] rgb = [
                cast(uint)((37 * x + 17 * y + 71 * layer + 13) % 256),
                cast(uint)((11 * x + 41 * y + 43 * layer + 29) % 256),
                cast(uint)((19 * x + 23 * y + 97 * layer + 53) % 256)
            ];
            if (mode == Mode.linearPremultiplied)
                foreach (ref c; rgb) c = (c * a + 127) / 255;
            require(output.trySetSample(0, x, y, cast(ubyte)rgb[0]) &&
                output.trySetSample(1, x, y, cast(ubyte)rgb[1]) &&
                output.trySetSample(2, x, y, cast(ubyte)rgb[2]) &&
                output.trySetSample(3, x, y, cast(ubyte)a),
                "populate source pixel");
        }
    }
    return result;
}

// Diagnostic "raster-access floor", not a color-mathematics equivalent.
// Same eight checked plane reads and four checked writes as the compositor.
private bool relay(
    scope RasterView!ubyte upper,
    scope RasterView!ubyte lower,
    scope WritableRasterView!ubyte destination
) @safe nothrow @nogc
{
    foreach (y; 0 .. upper.height)
    foreach (x; 0 .. upper.width)
    {
        ubyte[4] a;
        ubyte[4] b;
        foreach (c; 0 .. 4)
            if (!upper.trySample(c, x, y, a[c]))
                return false;
        foreach (c; 0 .. 4)
            if (!lower.trySample(c, x, y, b[c]))
                return false;
        foreach (c; 0 .. 4)
            if (!destination.trySetSample(c, x, y, a[c] ^ b[c]))
                return false;
    }
    return true;
}

private struct TimedResult
{
    long micros;
    size_t gcBytes;
}

private TimedResult runPath(
    bool composite, Config cfg,
    scope DecodedRgbaLayer top, scope DecodedRgbaLayer bottom,
    scope WritableRasterView!ubyte destination
)
{
    StopWatch stopwatch;
    // Observe only hot calls; allocations for setup/timing/reporting are out.
    const before = GC.stats().allocatedInCurrentThread;
    stopwatch.start();
    foreach (_; 0 .. cfg.iterations)
    {
        if (composite)
            require(tryCompositeRgbaSourceOver(
                top, bottom, Region2D(0, 0, cfg.width, cfg.height),
                0.37, destination) == RgbaCompositeError.none,
                "repeated source-over operation");
        else
            require(relay(top.pixels, bottom.pixels, destination),
                "repeated access-only relay");
    }
    stopwatch.stop();
    const after = GC.stats().allocatedInCurrentThread;
    require(after >= before, "GC accounting monotonic");
    return TimedResult(stopwatch.peek.total!"usecs", after - before);
}

private ulong checksum(ref RasterLease!ubyte output, Config cfg)
{
    scope auto view = output.view();
    ulong h = 1469598103934665603UL;
    // Read across the output, so the timed computation is externally observed.
    foreach (y; 0 .. cfg.height)
    foreach (x; 0 .. cfg.width)
    foreach (c; 0 .. 4)
    {
        ubyte v;
        require(view.trySample(c, x, y, v), "read output checksum");
        h = (h ^ v) * 1099511628211UL;
    }
    return h;
}

void main(string[] args)
{
    const cfg = parseArgs(args);
    const char[] layout = cfg.layout == Layout.planar
        ? "planar" : "interleaved";
    const char[] mode = cfg.mode == Mode.encodedStraight
        ? "encoded-straight" : "linear-premultiplied";

    auto upperLease = makeImage(
        cfg.width, cfg.height, cfg.layout, cfg.mode, 0, true);
    auto lowerLease = makeImage(
        cfg.width, cfg.height, cfg.layout, cfg.mode, 1, true);
    auto targetLease = makeImage(
        cfg.width, cfg.height, cfg.layout, cfg.mode, 2, false);

    const association = cfg.mode == Mode.encodedStraight
        ? RgbaAssociation.straight : RgbaAssociation.premultiplied;
    const encoding = cfg.mode == Mode.encodedStraight
        ? RgbaEncoding.encodedSRgb : RgbaEncoding.linearSRgb;
    const top = DecodedRgbaLayer(
        upperLease.view(), encoding, association);
    const bottom = DecodedRgbaLayer(
        lowerLease.view(), encoding, association);
    bool writable;
    scope auto destination = targetLease.tryWritableView(writable);
    require(writable, "get writable output");

    // Semantics preflight before measuring and warm both paths.
    require(tryCompositeRgbaSourceOver(
        top, bottom, Region2D(0, 0, cfg.width, cfg.height),
        0.37, destination) == RgbaCompositeError.none,
        "preflight source-over");
    require(relay(top.pixels, bottom.pixels, destination),
        "preflight checked raster access");

    writeln("mode,layout,width,height,round,iterations,relay_us,composite_us,",
        "relay_gc_bytes,composite_gc_bytes,checksum");
    foreach (round; 0 .. cfg.rounds)
    {
        TimedResult relayTiming;
        TimedResult compositeTiming;
        // Alternate ordering to help expose temperature/frequency drift.
        if (round % 2 == 0)
        {
            relayTiming = runPath(false, cfg, top, bottom, destination);
            compositeTiming = runPath(true, cfg, top, bottom, destination);
        }
        else
        {
            compositeTiming = runPath(true, cfg, top, bottom, destination);
            relayTiming = runPath(false, cfg, top, bottom, destination);
        }
        require(relayTiming.gcBytes == 0 &&
            compositeTiming.gcBytes == 0,
            "no thread-local GC allocation in either measured kernel");

        // Final timed operation can be relay; explicitly publish composite
        // result before checksum, outside timed intervals.
        require(tryCompositeRgbaSourceOver(
            top, bottom, Region2D(0, 0, cfg.width, cfg.height),
            0.37, destination) == RgbaCompositeError.none,
            "restore composite output for checksum");
        const observed = checksum(targetLease, cfg);
        writeln(mode, ",", layout, ",", cfg.width, ",", cfg.height,
            ",", round, ",", cfg.iterations, ",",
            relayTiming.micros, ",", compositeTiming.micros, ",",
            relayTiming.gcBytes, ",", compositeTiming.gcBytes, ",",
            observed);
    }
}
