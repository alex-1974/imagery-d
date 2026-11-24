module api_defects;

import core.stdc.stdlib : malloc;
import std.math : abs, isFinite;
import std.stdio : writeln;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease,
    RasterPlaneWindow, Region2D, tryAdoptMallocResource, tryImportOwnedRaster,
    withPlane;
import imagery.analysis.execution : Roi, copyRoi;
import imagery.presentation.brightness_contrast : BrightnessContrast,
    BrightnessContrastError, tryBrightnessContrastOwned;

private void need(bool condition, string message)
{
    if (!condition) throw new Exception("Public API defect regression: " ~ message);
}

// These fixtures use the public owner/import API. They do not emulate raster
// ownership or access imagery's private implementation.
private RasterLease!T makeRaster(T)(size_t planes, bool interleaved,
    bool reverseRows, bool reverseSamples)
{
    enum size_t width = 8, height = 6;
    const channels = interleaved ? planes : 1;
    const rowBytes = (width * channels + 3) * T.sizeof;
    const planeBytes = rowBytes * height;
    const bytes = planeBytes * (interleaved ? 1 : planes);
    auto data = malloc(bytes);
    need(data !is null, "allocate fixture");
    OwnedByteResource owner;
    need(tryAdoptMallocResource(data, bytes, owner), "adopt fixture");
    auto layouts = new PlaneByteLayout[planes];
    foreach (c; 0 .. planes)
    {
        const step = channels * T.sizeof;
        const offset = (interleaved ? c * T.sizeof : c * planeBytes) +
            (reverseRows ? (height - 1) * rowBytes : 0) +
            (reverseSamples ? (width - 1) * step : 0);
        layouts[c] = PlaneByteLayout(offset,
            reverseRows ? -cast(ptrdiff_t)rowBytes : cast(ptrdiff_t)rowBytes,
            reverseSamples ? -cast(ptrdiff_t)step : cast(ptrdiff_t)step);
    }
    RasterLease!T result;
    need(tryImportOwnedRaster!T(owner, layouts[], Region2D(0, 0, width, height), result).ok,
        "import fixture layout");
    bool writable;
    scope auto output = result.tryWritableView(writable);
    need(writable, "fixture writable view");
    foreach (c; 0 .. planes) foreach (y; 0 .. height) foreach (x; 0 .. width)
    {
        const code = (c * 19 + y * 7 + x * 11) % 256;
        T value;
        static if (is(T == float) || is(T == double)) value = cast(T)(code / 255.0);
        else static if (is(T == ushort)) value = cast(T)(code * 257);
        else value = cast(T)code;
        need(output.trySetSample(c, x, y, value), "fill fixture");
    }
    static if (is(T == float) || is(T == double))
    {
        union Bits { T value; static if (is(T == float)) uint bits; else ulong bits; }
        Bits payload;
        static if (is(T == float)) payload.bits = 0x7fc12345;
        else payload.bits = 0x7ff8123456789abcUL;
        need(output.trySetSample(0, 2, 1, payload.value), "NaN payload");
        if (planes > 1)
        {
            need(output.trySetSample(1, 3, 2, -cast(T)0.0), "signed zero");
            need(output.trySetSample(1, 5, 4, T.infinity), "infinity");
        }
        if (planes > 3)
        {
            need(output.trySetSample(2, 4, 3, cast(T)1.5), "finite high sample");
            need(output.trySetSample(3, 3, 4, cast(T)-0.25), "finite negative sample");
        }
    }
    return result;
}

private bool sameBits(T)(T first, T second)
{
    static if (is(T == float) || is(T == double))
    {
        union Bits { T value; static if (is(T == float)) uint bits; else ulong bits; }
        Bits a, b; a.value = first; b.value = second;
        return a.bits == b.bits;
    }
    else return first == second;
}

private void copyCase(T)(bool interleaved, bool reverseRows, bool reverseSamples, size_t plane)
{
    auto owner = makeRaster!T(2, interleaved, reverseRows, reverseSamples);
    scope auto full = owner.view;
    bool cropped;
    scope auto input = full.tryRoi(Region2D(1, 1, 6, 4), cropped);
    need(cropped, "crop source view");
    enum size_t count = 16;
    auto destination = new T[count + 2];
    destination[] = cast(T)111;
    bool copied, invalidChanged;
    const visited = withPlane(input, plane,
        (scope ref const RasterPlaneWindow!T window) @safe nothrow @nogc {
            foreach (bad; [Roi(0, 0, 0, 1), Roi(size_t.max, 0, 1, 1),
                Roi(0, 0, size_t.max, size_t.max), Roi(5, 3, 2, 2)])
            {
                if (copyRoi(window, bad, destination)) invalidChanged = true;
                foreach (v; destination) if (v != cast(T)111) invalidChanged = true;
            }
            if (copyRoi(window, Roi(1, 0, 4, 4), destination[0 .. count - 1]))
                invalidChanged = true;
            foreach (v; destination) if (v != cast(T)111) invalidChanged = true;
            copied = copyRoi(window, Roi(1, 0, 4, 4), destination);
        });
    need(visited && copied && !invalidChanged, "validated safe ROI copy and rollback");
    foreach (y; 0 .. 4) foreach (x; 0 .. 4)
    {
        T expected;
        need(input.trySample(plane, 1 + x, y, expected), "copy reference sample");
        need(sameBits(destination[y * 4 + x], expected), "copy preserves sample bits");
    }
    need(destination[count] == cast(T)111 && destination[count + 1] == cast(T)111,
        "copy preserves tail");
    const RasterPlaneWindow!T empty;
    destination[] = cast(T)111;
    need(!copyRoi(empty, Roi(0, 0, 1, 1), destination), "reject default window");
    foreach (v; destination) need(v == cast(T)111, "default-window rollback");
}

private float[] snapshot(ref RasterLease!float result)
{
    scope auto view = result.view;
    auto values = new float[view.planeCount * view.width * view.height];
    foreach (c; 0 .. view.planeCount) foreach (y; 0 .. view.height) foreach (x; 0 .. view.width)
        need(view.trySample(c, x, y, values[(c * view.height + y) * view.width + x]), "snapshot result");
    return values;
}

private void requireSnapshot(ref RasterLease!float result, scope const(float)[] expected)
{
    scope auto view = result.view;
    need(view.planeCount == 4 && view.width == 6 && view.height == 4 && expected.length == 96,
        "retained result shape");
    foreach (c; 0 .. 4) foreach (y; 0 .. 4) foreach (x; 0 .. 6)
    {
        float value;
        need(view.trySample(c, x, y, value) &&
            sameBits(value, expected[(c * 4 + y) * 6 + x]), "retained complete result bits");
    }
}

private void brightnessCase(T)(bool interleaved, bool reverseRows,
    bool reverseSamples, bool masked, uint selection)
{
    auto source = makeRaster!T(4, interleaved, reverseRows, reverseSamples);
    auto mask = makeRaster!ubyte(1, false, reverseRows, reverseSamples);
    bool writable;
    scope auto edit = mask.tryWritableView(writable);
    need(writable, "mask writer");
    foreach (y; 0 .. 6) foreach (x; 0 .. 8)
        need(edit.trySetSample(0, x, y, cast(ubyte)([0, 128, 255][(x + y) % 3])), "mask coverage");
    bool[4] affected;
    foreach (c, ref selected; affected) selected = (selection & (1u << c)) != 0;
    auto originalSamples = new T[4 * 8 * 6];
    foreach (c; 0 .. 4) foreach (y; 0 .. 6) foreach (x; 0 .. 8)
        need(source.view.trySample(c, x, y, originalSamples[(c * 6 + y) * 8 + x]), "snapshot source");
    const roi = Region2D(1, 1, 6, 4);
    enum size_t bytes = 6 * 4 * 4 * float.sizeof;
    RasterLease!float result;
    auto status = masked ?
        tryBrightnessContrastOwned(source.view, roi, affected[], BrightnessContrast(0.125, 0.5),
            mask.view, bytes, result) :
        tryBrightnessContrastOwned(source.view, roi, affected[], BrightnessContrast(0.125, 0.5),
            bytes, result);
    need(status == BrightnessContrastError.none, "brightness status");
    foreach (c; 0 .. 4) foreach (y; 0 .. roi.height) foreach (x; 0 .. roi.width)
    {
        const raw = originalSamples[(c * 6 + roi.y + y) * 8 + roi.x + x];
        T unchanged; float actual;
        need(source.view.trySample(c, roi.x + x, roi.y + y, unchanged) &&
            sameBits(unchanged, raw), "source remains unchanged");
        need(result.view.trySample(c, x, y, actual), "read adjusted");
        double original;
        static if (is(T == ubyte)) original = raw / 255.0;
        else static if (is(T == ushort)) original = raw / 65535.0;
        else original = raw;
        ubyte weight = 255;
        if (masked)
        {
            const expectedWeight = cast(ubyte)([0, 128, 255][(roi.x + x + roi.y + y) % 3]);
            need(mask.view.trySample(0, roi.x + x, roi.y + y, weight) && weight == expectedWeight,
                "coverage remains unchanged");
        }
        if (!affected[c] || weight == 0 || !isFinite(original))
        {
            static if (is(T == float))
                need(sameBits(actual, raw), "unselected/nonfinite/zero-mask float bits");
            else need(sameBits(actual, cast(float)original), "unselected normalized integer");
        }
        else
        {
            // Independent formula: affine map followed by clipping, then a
            // weighted blend. Two float epsilons allow final quantization and
            // the independently ordered blend, not arbitrary image error.
            auto adjusted = (original - 0.5) * 1.5 + 0.625;
            if (adjusted < 0) adjusted = 0;
            if (adjusted > 1) adjusted = 1;
            const alpha = weight / 255.0;
            const expected = (1 - alpha) * original + alpha * adjusted;
            need(abs(cast(double)actual - expected) <= 2 * float.epsilon,
                "selected mapping against independent formula");
        }
    }
    auto retained = snapshot(result);
    auto prior = result;
    status = tryBrightnessContrastOwned(source.view, roi, affected[],
        BrightnessContrast(0.125, 0.5), 0, result);
    need(status == BrightnessContrastError.resultExceedsBudget, "output budget failure");
    requireSnapshot(result, retained);
    status = tryBrightnessContrastOwned(source.view, roi, affected[0 .. 3],
        BrightnessContrast(0.125, 0.5), bytes, result);
    need(status == BrightnessContrastError.invalidChannelSelection, "invalid selection");
    requireSnapshot(result, retained);
    status = tryBrightnessContrastOwned(source.view, roi, affected[],
        BrightnessContrast(double.nan, 0), bytes, result);
    need(status == BrightnessContrastError.invalidParameters, "invalid settings even for all-unselected");
    requireSnapshot(result, retained);
    RasterLease!ubyte emptyMask;
    status = tryBrightnessContrastOwned(source.view, roi, affected[],
        BrightnessContrast(0.125, 0.5), emptyMask.view, bytes, result);
    need(status == BrightnessContrastError.invalidMask, "invalid mask");
    requireSnapshot(result, retained);
    requireSnapshot(prior, retained);
}

void runPublicApiDefectAudit()
{
    foreach (interleaved; [false, true])
    foreach (reverseRows; [false, true])
    foreach (reverseSamples; [false, true])
    {
        foreach (plane; 0 .. 2)
        {
            copyCase!ubyte(interleaved, reverseRows, reverseSamples, plane);
            copyCase!ushort(interleaved, reverseRows, reverseSamples, plane);
            copyCase!float(interleaved, reverseRows, reverseSamples, plane);
            copyCase!double(interleaved, reverseRows, reverseSamples, plane);
        }
        foreach (masked; [false, true]) foreach (selection; [0u, 5u, 10u, 15u])
        {
            brightnessCase!ubyte(interleaved, reverseRows, reverseSamples, masked, selection);
            brightnessCase!ushort(interleaved, reverseRows, reverseSamples, masked, selection);
            brightnessCase!float(interleaved, reverseRows, reverseSamples, masked, selection);
        }
    }
    writeln("PUBLIC_API_DEFECTS=PASS; 64 typed/strided ROI copies, 192 channel-selection/mask cases");
}
