/++
 A deliberately small **usable DUB consumer** of research Levels: read a P6
 RGB image, apply selected-channel scalar Levels, write a new P6 RGB image.

 This is NOT imagery-d image I/O, not a supported library API, and not colour
 management. The caller explicitly elects to transform encoded RGB samples.
 Pixel ownership/layout remain raster-d responsibilities. Never overwrite input.
+/
module app;

import core.stdc.stdlib : malloc;
import std.conv : to;
import std.file : exists, getSize, read, write;
import std.format : format;
import std.stdio : writeln;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    Region2D, tryAdoptMallocResource, tryImportOwnedRaster;
import imagery.presentation.levels_research :
    ResearchLevels, ResearchLevelsError;
import imagery.presentation.levels_owned_research :
    tryLevelsOwnedResearch;

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

void main(string[] args)
{
    require(args.length == 8,
        "usage: levels-ppm INPUT.ppm NEW_OUTPUT.ppm " ~
        "INPUT_BLACK INPUT_WHITE GAMMA OUTPUT_BLACK OUTPUT_WHITE");

    const sourcePath = args[1], outputPath = args[2];
    require(sourcePath != outputPath && !exists(outputPath),
        "output must be a new file; never overwrite input or an existing file");
    require(getSize(sourcePath) <= 16_777_216,
        "demo refuses input larger than 16 MiB");

    const inputBytes = cast(const(ubyte)[])read(sourcePath);
    const image = parseP6(inputBytes);

    const settings = ResearchLevels(
        to!double(args[3]), to!double(args[4]), to!double(args[5]),
        to!double(args[6]), to!double(args[7]));

    auto source = makeInterleaved!ubyte(image.width, image.height, 3);
    bool sourceWritable;
    scope auto writer = source.tryWritableView(sourceWritable);
    require(sourceWritable, "source writable view");
    foreach (y; 0 .. image.height)
        foreach (x; 0 .. image.width)
            foreach (c; 0 .. 3)
                require(writer.trySetSample(
                    c, x, y, image.pixels[(y * image.width + x) * 3 + c]),
                    "source raster sample write");

    // The library-side owned-result probe builds a distinct raster-d lease.
    // It publishes that lease only when the full Levels operation succeeds.
    RasterLease!float destination;
    bool[3] selected = [true, true, true];

    const status = tryLevelsOwnedResearch!ubyte(
        source.view(), Region2D(0, 0, image.width, image.height),
        selected[], settings, RasterView!ubyte.init, false, destination);
    require(status == ResearchLevelsError.none, "invalid Levels request");

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
