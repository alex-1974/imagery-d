/++
 One-sample image-domain Levels precision harness. This is an ordinary,
 independently built DUB consumer, not part of the imagery-d library.
 It accepts decimal fixture values on stdin and reports the exact resulting
 float32 bit-pattern to the Python high-precision oracle driver.
+/
module app;

import core.stdc.stdlib : malloc;
import std.conv : to;
import std.stdio : stdin, writeln;
import std.string : split, strip;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import imagery : Levels, LevelsError, tryLevelsOwned;

private union Float32Bits
{
    float value;
    uint bits;
}

private void need(bool valid, string description)
{
    if (!valid)
        throw new Exception("M3 precision consumer: " ~ description);
}

private RasterLease!T oneSample(T)(T value)
{
    auto memory = malloc(T.sizeof);
    need(memory !is null, "malloc source");
    OwnedByteResource resource;
    need(tryAdoptMallocResource(memory, T.sizeof, resource),
        "adopt source");
    const PlaneByteLayout[1] planes =
        [PlaneByteLayout(0, cast(ptrdiff_t)T.sizeof,
                           cast(ptrdiff_t)T.sizeof)];
    RasterLease!T input;
    need(tryImportOwnedRaster!T(resource, planes[],
        Region2D(0, 0, 1, 1), input).ok, "import source");
    bool writable;
    {
        scope auto view = input.tryWritableView(writable);
        need(writable && view.trySetSample(0, 0, 0, value),
            "write input value");
    }
    return input;
}

private uint evaluate(T)(
    T value, Levels settings, bool affected, int maskWeight)
{
    auto input = oneSample!T(value);
    bool[1] channels = [affected];
    const roi = Region2D(0, 0, 1, 1);
    RasterLease!float output;
    LevelsError result;
    if (maskWeight >= 0)
    {
        auto mask = oneSample!ubyte(cast(ubyte)maskWeight);
        result = tryLevelsOwned!T(input.view(), roi, channels[],
            settings, mask.view(), float.sizeof, output);
    }
    else
        result = tryLevelsOwned!T(input.view(), roi, channels[],
            settings, float.sizeof, output);
    need(result == LevelsError.none, "one-sample status");
    scope auto view = output.view();
    float observed;
    need(view.trySample(0, 0, 0, observed), "read one-sample result");
    Float32Bits exact;
    exact.value = observed;
    return exact.bits;
}

void main()
{
    size_t count;
    foreach (line; stdin.byLine())
    {
        const fields = strip(line).split("\t");
        need(fields.length == 10, "expected ten TSV fields");
        const index = to!size_t(fields[0]);
        const kind = fields[1];
        const selected = to!int(fields[2]) != 0;
        const maskWeight = to!int(fields[3]);
        need(maskWeight == -1 || maskWeight == 0 ||
             maskWeight == 128 || maskWeight == 255, "mask weight");
        const levels = Levels(
            to!double(fields[5]), to!double(fields[6]),
            to!double(fields[7]), to!double(fields[8]),
            to!double(fields[9]));
        uint bits;
        switch (kind)
        {
            case "u8":
                bits = evaluate!ubyte(to!ubyte(fields[4]), levels,
                    selected, maskWeight);
                break;
            case "u16":
                bits = evaluate!ushort(to!ushort(fields[4]), levels,
                    selected, maskWeight);
                break;
            case "f32":
                bits = evaluate!float(to!float(fields[4]), levels,
                    selected, maskWeight);
                break;
            default:
                need(false, "unsupported fixture type");
        }
        writeln(index, "\t", bits);
        ++count;
    }
    need(count >= 100, "numeric fixture corpus unexpectedly small");
}
