/++
 A small standalone DUB consumer: read a P6 RGB image and either apply
 scalar Levels to a new P6 file or report RGB histogram/ROI statistics.

 This is NOT imagery-d image I/O and not a released API, and not colour
 management. The caller explicitly elects to transform encoded RGB samples.
 Pixel ownership/layout remain raster-d responsibilities. Never overwrite input.
+/
module app;

import core.stdc.stdlib : malloc;
import std.conv : to;
import std.file : exists, getSize, read, write;
import std.format : format;
import std.stdio : writeln;
import std.json : JSONValue;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import imagery : Levels, LevelsError, tryLevelsOwned,
    RgbHistogram256, RgbHistogramError, tryRgbHistogram256,
    tryRgbPercentileStretchLut;

private void require(bool ok, string why)
{
    if (!ok) throw new Exception("levels-ppm: " ~ why);
}

private bool whitespace(ubyte c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

// P6 ASCII header token reader. Binary payload begins EXACTLY after the
// single required maxval delimiter (or CRLF), even if first pixel == newline.
private string token(const(ubyte)[] bytes, ref size_t at)
{
    while (at < bytes.length)
    {
        if (whitespace(bytes[at]))
        {
            ++at;
            continue;
        }
        if (bytes[at] == '#')
        {
            while (at < bytes.length && bytes[at] != '\n')
                ++at;
            continue;
        }
        break;
    }
    const start = at;
    while (at < bytes.length && !whitespace(bytes[at]) &&
           bytes[at] != '#')
        ++at;
    require(at > start, "incomplete P6 header");
    return cast(string)bytes[start .. at].idup;
}

private struct Ppm
{
    size_t width;
    size_t height;
    const(ubyte)[] pixels;
}

private Ppm parseP6(const(ubyte)[] bytes)
{
    size_t at;
    require(token(bytes, at) == "P6", "only binary P6 PPM is supported");
    const width = to!size_t(token(bytes, at));
    const height = to!size_t(token(bytes, at));
    require(token(bytes, at) == "255", "only 8-bit P6 maxval 255");
    require(width > 0 && height > 0 && width <= 2048 && height <= 2048,
            "demo limited to 1..2048 pixels per dimension");
    const pixels = width * height;
    require(pixels <= 4_194_304, "demo pixel limit");

    require(at < bytes.length && whitespace(bytes[at]),
            "missing whitespace delimiter before P6 payload");
    if (bytes[at] == '\r' && at + 1 < bytes.length &&
        bytes[at + 1] == '\n')
        at += 2;
    else
        ++at;

    require(bytes.length - at == pixels * 3,
            "truncated or trailing P6 image data");
    return Ppm(width, height, bytes[at .. $]);
}

// This code belongs solely to the end-user app; it uses public raster-d
// owner/import APIs rather than defining an imagery-specific raster owner.
private RasterLease!T makeInterleaved(T)(
    size_t width, size_t height, size_t bands)
{
    const length = width * height * bands * T.sizeof;
    auto pointer = cast(T*)malloc(length);
    require(pointer !is null, "malloc image");

    OwnedByteResource owned;
    require(tryAdoptMallocResource(pointer, length, owned),
            "adopt image memory");

    auto planes = new PlaneByteLayout[](bands);
    foreach (c; 0 .. bands)
        planes[c] = PlaneByteLayout(c * T.sizeof,
            cast(ptrdiff_t)(width * bands * T.sizeof),
            cast(ptrdiff_t)(bands * T.sizeof));

    RasterLease!T image;
    require(tryImportOwnedRaster!T(
        owned, planes[], Region2D(0, 0, width, height), image).ok,
        "import typed raster");
    return image;
}

private ubyte encode(float value)
{
    const double v = cast(double)value;
    require(v == v, "unexpected NaN Levels result");
    if (v <= 0.0) return 0;
    if (v >= 1.0) return 255;
    return cast(ubyte)(v * 255.0 + 0.5);
}

private Ppm readP6(string path)
{
    require(getSize(path) <= 16_777_216,
        "demo refuses input larger than 16 MiB");
    return parseP6(cast(const(ubyte)[])read(path));
}

private RasterLease!ubyte importRgb(Ppm image)
{
    auto source = makeInterleaved!ubyte(image.width, image.height, 3);
    bool writable;
    scope auto writer = source.tryWritableView(writable);
    require(writable, "source writable view");
    foreach (y; 0 .. image.height)
    foreach (x; 0 .. image.width)
    foreach (c; 0 .. 3)
        require(writer.trySetSample(c, x, y,
            image.pixels[(y * image.width + x) * 3 + c]),
            "source raster sample write");
    return source;
}

// This is a consumer protocol, not a public imagery-d serialization API.
// Mask input is a headerless full-source-sized u8 plane, exactly W*H bytes.
private void histogramMain(string[] args)
{
    require(args.length == 7 || args.length == 8,
        "usage: levels-ppm --histogram INPUT.ppm X Y WIDTH HEIGHT [MASK.raw]");
    const image = readP6(args[2]);
    const roi = Region2D(to!size_t(args[3]), to!size_t(args[4]),
        to!size_t(args[5]), to!size_t(args[6]));
    auto source = importRgb(image);
    RgbHistogram256 record;
    RgbHistogramError status;
    if (args.length == 8)
    {
        require(getSize(args[7]) == image.width * image.height,
            "mask must contain exactly one byte per full-source pixel");
        const bytes = cast(const(ubyte)[])read(args[7]);
        require(bytes.length == image.width * image.height, "mask byte count");
        auto selection = makeInterleaved!ubyte(image.width, image.height, 1);
        bool writable;
        {
            scope auto writer = selection.tryWritableView(writable);
            require(writable, "mask writable view");
            foreach (y; 0 .. image.height)
            foreach (x; 0 .. image.width)
                require(writer.trySetSample(0, x, y,
                    bytes[y * image.width + x]), "mask sample write");
        }
        status = tryRgbHistogram256(source.view(), roi, selection.view(), record);
    }
    else
        status = tryRgbHistogram256(source.view(), roi, record);
    require(status == RgbHistogramError.none, "invalid RGB histogram request");

    JSONValue result;
    result["includedPixels"] = JSONValue(record.includedPixels);
    result["excludedPixels"] = JSONValue(record.excludedPixels);
    result["bins"] = JSONValue([JSONValue(record.bins[0][]),
        JSONValue(record.bins[1][]), JSONValue(record.bins[2][])]);
    result["minimum"] = JSONValue(record.minimum[]);
    result["maximum"] = JSONValue(record.maximum[]);
    result["mean"] = JSONValue(record.mean[]);
    writeln(result.toString()); // publish only the complete successful record
}

// Ordinary file consumer of the library's per-channel contrast LUT.
// Thresholds come from the full RGB image; every output pixel is mapped.
private void stretchMain(string[] args)
{
    require(args.length == 6,
        "usage: levels-ppm --stretch INPUT.ppm NEW_OUTPUT.ppm LOWER UPPER");
    const sourcePath = args[2], outputPath = args[3];
    require(sourcePath != outputPath && !exists(outputPath),
        "output must be a new file; never overwrite input or an existing file");
    const image = readP6(sourcePath);
    auto source = importRgb(image);
    RgbHistogram256 histogram;
    require(tryRgbHistogram256(source.view(),
        Region2D(0, 0, image.width, image.height), histogram) ==
        RgbHistogramError.none, "RGB histogram for contrast stretch");

    ubyte[256][3] lut;
    require(tryRgbPercentileStretchLut(histogram,
        to!uint(args[4]), to!uint(args[5]), lut),
        "invalid contrast percentiles");

    const header = format("P6\n%s %s\n255\n", image.width, image.height);
    auto result = new ubyte[](header.length + image.pixels.length);
    foreach (i; 0 .. header.length)
        result[i] = cast(ubyte)header[i];
    foreach (i, value; image.pixels)
        result[header.length + i] = lut[i % 3][value];
    write(outputPath, result);
    writeln("M3_RGB_STRETCH_PPM_COMPLETE,", image.width, ",",
        image.height, ",", outputPath);
}

void main(string[] args)
{
    if (args.length > 1 && args[1] == "--stretch")
    {
        stretchMain(args);
        return;
    }
    if (args.length > 1 && args[1] == "--histogram")
    {
        histogramMain(args);
        return;
    }

    require(args.length == 8,
        "usage: levels-ppm INPUT.ppm NEW_OUTPUT.ppm " ~
        "INPUT_BLACK INPUT_WHITE GAMMA OUTPUT_BLACK OUTPUT_WHITE");

    const sourcePath = args[1], outputPath = args[2];
    require(sourcePath != outputPath && !exists(outputPath),
        "output must be a new file; never overwrite input or an existing file");
    const image = readP6(sourcePath);

    const settings = Levels(
        to!double(args[3]), to!double(args[4]), to!double(args[5]),
        to!double(args[6]), to!double(args[7]));

    auto source = importRgb(image);

    // The library-side owned-result probe builds a distinct raster-d lease.
    // It publishes that lease only when the full Levels operation succeeds.
    RasterLease!float destination;
    bool[3] selected = [true, true, true];

    // P6 dimensions were checked above. Give the library exactly the
    // required normalized-float output payload budget, not an unbounded cap.
    const size_t resultPayloadBytes =
        image.width * image.height * 3 * float.sizeof;
    const status = tryLevelsOwned!ubyte(
        source.view(), Region2D(0, 0, image.width, image.height),
        selected[], settings, resultPayloadBytes, destination);
    require(status == LevelsError.none, "invalid Levels request");

    // Complete the entire output in memory before opening NEW_OUTPUT.
    const header = format("P6\n%s %s\n255\n", image.width, image.height);
    auto result = new ubyte[](header.length + image.width * image.height * 3);
    foreach (i; 0 .. header.length)
        result[i] = cast(ubyte)header[i];

    const samples = destination.view();
    foreach (y; 0 .. image.height)
        foreach (x; 0 .. image.width)
            foreach (c; 0 .. 3)
            {
                float adjusted;
                require(samples.trySample(c, x, y, adjusted),
                        "destination raster read");
                result[header.length + (y * image.width + x) * 3 + c] =
                    encode(adjusted);
            }

    write(outputPath, result);
    writeln("M3_LEVELS_PPM_COMPLETE,", image.width, ",", image.height,
            ",", outputPath);
}
