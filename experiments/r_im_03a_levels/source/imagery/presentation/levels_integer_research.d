/++
 R-IM-03b — fixed-precision integer Levels, direct vs prepared LUT.
 Research-only, not a public image API and not colour-space conversion.
 No STAC, sensor or geospatial information is required.

 The caller owns source and destination raster-d leases. All test input
 and output buffers are disjoint. This implementation DOES NOT prevent
 physical aliasing and DOES NOT rollback after unexpected in-pass failure.
+/
module imagery.presentation.levels_integer_research;

import imagery.presentation.levels_research :
    ResearchLevels, ResearchLevelsError;
import raster : RasterView, WritableRasterView, Region2D;
import std.math : pow, sqrt;

version (LDC)
    import ldc.intrinsics : llvm_pow;

private enum size_t valueCount(T) =
    is(T == ubyte) ? cast(size_t)256 : cast(size_t)65536;

private enum double maxCode(T) =
    is(T == ubyte) ? 255.0 : 65535.0;

private bool finite(double x)
{
    return x >= -double.max && x <= double.max;
}

private bool valid(ResearchLevels p)
{
    return finite(p.inputBlack) && finite(p.inputWhite) &&
        finite(p.gamma) && finite(p.outputBlack) &&
        finite(p.outputWhite) &&
        p.inputBlack < p.inputWhite && p.gamma > 0.0 &&
        finite(p.inputWhite - p.inputBlack) &&
        finite(1.0 / p.gamma) &&
        p.outputBlack >= 0.0 && p.outputWhite <= 1.0 &&
        p.outputBlack <= p.outputWhite;
}

private bool contained(Region2D r, size_t w, size_t h)
{
    return r.width > 0 && r.height > 0 &&
        r.x <= w && r.y <= h &&
        r.width <= w - r.x && r.height <= h - r.y;
}

// An unclipped scalar in [0,1]; LUT stores this unquantized value.
// Computing the selection blend AFTER lookup prevents double rounding.
private double mapped(T, int METHOD = 0)(T code, ResearchLevels p)
if (is(T == ubyte) || is(T == ushort))
{
    const original = cast(double)code / maxCode!T;
    double t = (original - p.inputBlack) /
        (p.inputWhite - p.inputBlack);
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    // METHOD=0 Phobos (R-IM-03b baseline); METHOD=1 LLVM/libm pow on
    // LDC, Phobos fallback on DMD; METHOD=2 specialized gamma==2 sqrt.
    // No fast-math flag is requested; numerical differences are tested.
    double shaped;
    static if (METHOD == 1)
    {
        version (LDC)
            shaped = llvm_pow(t, 1.0 / p.gamma);
        else
            shaped = pow(t, 1.0 / p.gamma);
    }
    else static if (METHOD == 2)
        shaped = sqrt(t);
    else
        shaped = pow(t, 1.0 / p.gamma);
    return p.outputBlack +
        shaped * (p.outputWhite - p.outputBlack);
}

private T quantized(T)(double value)
if (is(T == ubyte) || is(T == ushort))
{
    // Deterministic positive-domain round-half-up after saturation.
    // Cast to uint is safe because input is in the bounded interval.
    if (value <= 0.0) return cast(T)0;
    if (value >= 1.0) return cast(T)maxCode!T;
    return cast(T)(cast(uint)(value * maxCode!T + 0.5));
}

/// A prepared immutable transform table (not a general colour LUT).
/// Size: 256 or 65536 * sizeof(double), independent of image size.
/// Input settings are frozen as part of prepared state.
struct ResearchLevelsTable(T)
if (is(T == ubyte) || is(T == ushort))
{
private:
    immutable(double)[] entries_;
    ResearchLevels settings_;

public:
    @property bool prepared() const
    {
        return entries_.length == valueCount!T;
    }

    @property size_t elementCount() const
    {
        return entries_.length;
    }

    @property ResearchLevels settings() const
    {
        return settings_;
    }

    // Internal accessor; indices are generated from typed unsigned codes.
    double at(T code) const
    {
        return entries_[cast(size_t)code];
    }

    static ResearchLevelsError prepare(
        ResearchLevels settings, ref ResearchLevelsTable!T target)
    {
        if (!valid(settings))
            return ResearchLevelsError.invalidParameters;

        // GC allocation is outside the hot pixel loop. On an allocation
        // exception no successful table publication is claimed.
        auto staging = new double[valueCount!T];
        foreach (i; 0 .. staging.length)
            staging[i] = mapped!T(cast(T)i, settings);

        // Immutable snapshot protects old table generations if a caller
        // prepares another table. This intentionally has a transient
        // second array, which benchmark and residency review must count.
        ResearchLevelsTable!T candidate;
        candidate.entries_ = staging.idup;
        candidate.settings_ = settings;
        target = candidate;
        return ResearchLevelsError.none;
    }
}

private ResearchLevelsError preflight(T)(
    scope RasterView!T input, Region2D roi,
    scope const(bool)[] affected, ResearchLevels settings,
    scope RasterView!ubyte selection, bool hasSelection,
    scope WritableRasterView!T output)
if (is(T == ubyte) || is(T == ushort))
{
    if (input.planeCount == 0 || input.width == 0 ||
        input.height == 0)
        return ResearchLevelsError.invalidSource;
    if (!contained(roi, input.width, input.height))
        return ResearchLevelsError.invalidRegion;
    if (affected.length != input.planeCount)
        return ResearchLevelsError.invalidChannelSelection;
    if (!valid(settings))
        return ResearchLevelsError.invalidParameters;
    if (hasSelection && (selection.planeCount != 1 ||
        selection.width != input.width ||
        selection.height != input.height))
        return ResearchLevelsError.invalidMask;
    if (output.planeCount != input.planeCount ||
        output.width != roi.width || output.height != roi.height)
        return ResearchLevelsError.invalidDestination;
    return ResearchLevelsError.none;
}

private ResearchLevelsError execute(T, int METHOD)(
    scope RasterView!T input, Region2D roi,
    scope const(bool)[] affected, ResearchLevels settings,
    scope RasterView!ubyte selection, bool hasSelection,
    scope WritableRasterView!T output,
    scope const(ResearchLevelsTable!T) table)
if (is(T == ubyte) || is(T == ushort))
{
    auto err = preflight!T(
        input, roi, affected, settings, selection, hasSelection, output);
    if (err != ResearchLevelsError.none)
        return err;
    static if (METHOD == 3)
        if (!table.prepared)
            return ResearchLevelsError.invalidParameters;
    static if (METHOD == 2)
        if (settings.gamma != 2.0)
            return ResearchLevelsError.invalidParameters;

    foreach (y; roi.y .. roi.y + roi.height)
    foreach (x; roi.x .. roi.x + roi.width)
    {
        double strength = 1.0;
        if (hasSelection)
        {
            ubyte m;
            if (!selection.trySample(0, x, y, m))
                return ResearchLevelsError.sampleFailure;
            strength = cast(double)m / 255.0;
        }
        foreach (channel; 0 .. input.planeCount)
        {
            T raw;
            if (!input.trySample(channel, x, y, raw))
                return ResearchLevelsError.sampleFailure;
            T result = raw;
            if (affected[channel] && strength != 0.0)
            {
                const source = cast(double)raw / maxCode!T;
                static if (METHOD == 3)
                    const adjusted = table.at(raw);
                else
                    const adjusted = mapped!(T, METHOD)(raw, settings);
                const outputValue = source +
                    strength * (adjusted - source);
                result = quantized!T(outputValue);
            }
            if (!output.trySetSample(
                    channel, x - roi.x, y - roi.y, result))
                return ResearchLevelsError.sampleFailure;
        }
    }
    return ResearchLevelsError.none;
}

/// Direct scalar pow per selected sample. No LUT allocation.
ResearchLevelsError tryLevelsIntegerDirectResearch(T)(
    scope RasterView!T input, Region2D roi,
    scope const(bool)[] affected, ResearchLevels settings,
    scope RasterView!ubyte selection, bool hasSelection,
    scope WritableRasterView!T output)
if (is(T == ubyte) || is(T == ushort))
{
    return execute!(T, 0)(
        input, roi, affected, settings, selection, hasSelection,
        output, ResearchLevelsTable!T.init);
}

/// Reuse already prepared table, preserving full pre-round mapping values.
/// No table rebuild or GC allocation on each point operation.
ResearchLevelsError tryLevelsIntegerLutResearch(T)(
    scope RasterView!T input, Region2D roi,
    scope const(bool)[] affected,
    scope const(ResearchLevelsTable!T) table,
    scope RasterView!ubyte selection, bool hasSelection,
    scope WritableRasterView!T output)
if (is(T == ubyte) || is(T == ushort))
{
    if (!table.prepared)
        return ResearchLevelsError.invalidParameters;
    return execute!(T, 3)(
        input, roi, affected, table.settings,
        selection, hasSelection, output, table);
}

/++
 LDC-only LLVM pow backend to probe TC-0006. DMD uses a Phobos
 fallback for source-level compatibility, never a claim of optimization.
 Semantics/ROI/output/opacity are shared with the original direct kernel.
+/
ResearchLevelsError tryLevelsIntegerLlvmPowResearch(T)(
    scope RasterView!T input, Region2D roi,
    scope const(bool)[] affected, ResearchLevels settings,
    scope RasterView!ubyte selection, bool hasSelection,
    scope WritableRasterView!T output)
if (is(T == ubyte) || is(T == ushort))
{
    return execute!(T, 1)(
        input, roi, affected, settings, selection, hasSelection,
        output, ResearchLevelsTable!T.init);
}

/++
 Fixed-gamma-2 alternative; rejects other gamma settings *before writing*.
 sqrt math is not silently substituted for a general pow transform.
+/
ResearchLevelsError tryLevelsIntegerSqrt2Research(T)(
    scope RasterView!T input, Region2D roi,
    scope const(bool)[] affected, ResearchLevels settings,
    scope RasterView!ubyte selection, bool hasSelection,
    scope WritableRasterView!T output)
if (is(T == ubyte) || is(T == ushort))
{
    return execute!(T, 2)(
        input, roi, affected, settings, selection, hasSelection,
        output, ResearchLevelsTable!T.init);
}
