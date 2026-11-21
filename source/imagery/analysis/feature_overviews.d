/++ Region-readable feature sources on selected overview grids. +/
module imagery.analysis.feature_overviews;

import imagery.analysis.feature_regions : ImageResamplingMetadata, Source, Sample, sourceMetadata;
import imagery.pyramid.overview_selection : OverviewLevel, OverviewSelection,
    OverviewSelectionError, trySelectOverviewLevel;
import raster.region : Region2D;
import std.algorithm : min;
import std.conv : to;
import std.math : isFinite, ceil;

@safe:

struct FeatureOverview
{
    Source source;
    /// Sampling distance in units of a finest-level pixel, by axis.
    double scaleX, scaleY;
    bool avoidsUndersampling;
}

/// Choose an already available grid covering the same logical extent.
FeatureOverview selectFeatureOverview(scope const Source[] levels,
    size_t targetWidth, size_t targetHeight)
{
    auto dimensions = new OverviewLevel[levels.length];
    foreach (i, level; levels)
        dimensions[i] = OverviewLevel(level.width, level.height);
    OverviewSelection selection;
    if (trySelectOverviewLevel(dimensions, targetWidth, targetHeight, selection) !=
        OverviewSelectionError.none || levels[selection.index].read is null)
        throw new Exception("Invalid overview grids");
    const level = levels[selection.index];
    sourceMetadata(level);
    return FeatureOverview(level, cast(double)levels[0].width / level.width,
        cast(double)levels[0].height / level.height, selection.avoidsUndersampling);
}

enum FeatureResampling { nearest, bilinearScalar, areaScalar }

private struct Axis
{
    size_t low, high;
    double fraction;
}

private Axis sourceAxis(size_t pixel, size_t targetSize, size_t sourceSize)
{
    import std.algorithm : clamp;
    const center = clamp((pixel + 0.5) * sourceSize / targetSize - 0.5,
        0.0, cast(double)(sourceSize - 1));
    const low = cast(size_t)center;
    return Axis(low, min(low + 1, sourceSize - 1), center - low);
}

/// Adapt a source to a same-extent grid. RGB uses nearest encoded samples.
/// Bilinear and area reduction require scalar channels and valid finite
/// contributors at every positive weight. Area reduction integrates pixel
/// cells over the destination footprint; enlarging either axis is rejected.
/// An invalid contributor invalidates the output (no implicit gap filling).
/// The reader retains at most four source samples, independent of source size.
Source resampleFeatureSource(const Source input, size_t width, size_t height, size_t level,
    FeatureResampling policy)
{
    enum maxExtent = 1UL << 48;
    if (input.read is null || !input.width || !input.height || !width || !height ||
        input.width > maxExtent || input.height > maxExtent ||
        width > maxExtent || height > maxExtent ||
        cast(uint)policy > FeatureResampling.max ||
        (input.rgb && policy != FeatureResampling.nearest) ||
        (policy == FeatureResampling.areaScalar && (width > input.width || height > input.height)))
        throw new Exception("Unsupported overview resampling request");

    Source output = input;
    output.width = width;
    output.height = height;
    output.metadata = sourceMetadata(input);
    const scaleX = cast(double)input.width / width;
    const scaleY = cast(double)input.height / height;
    auto spatial = &output.metadata.spatial;
    spatial.pixelSizeX *= scaleX;
    spatial.pixelSizeY *= scaleY;
    spatial.affine[1] *= scaleX;
    spatial.affine[4] *= scaleX;
    spatial.affine[2] *= scaleY;
    spatial.affine[5] *= scaleY;
    output.metadata.resampling = ImageResamplingMetadata(policy.to!string, input.grid,
        input.level, input.width, input.height);
    sourceMetadata(output);
    output.level = level;
    output.grid = "feature-resample-v1/" ~ input.grid.length.to!string ~ "/" ~ input.grid ~
        "/" ~ input.level.to!string ~ "/" ~ input.width.to!string ~ "x" ~ input.height.to!string ~
        "/" ~ width.to!string ~ "x" ~ height.to!string ~ "/" ~ policy.to!string;
    output.read = (Region2D region, scope Sample[] samples) {
        if (region.empty || region.x > width || region.y > height ||
            region.width > width - region.x || region.height > height - region.y ||
            samples.length / region.width != region.height || samples.length % region.width)
            throw new Exception("Invalid resampled source window");

        Sample[4] window;
        foreach (i, ref result; samples)
        {
            if (policy == FeatureResampling.areaScalar)
            {
                // Pixel cells occupy [x,x+1) in the parent grid. Use global
                // coordinates so separate ROI requests have identical weights.
                const left = (region.x + i % region.width) * scaleX;
                const top = (region.y + i / region.width) * scaleY;
                const right = min(cast(double)input.width, left + scaleX);
                const bottom = min(cast(double)input.height, top + scaleY);
                double sum = 0, weight = 0;
                bool valid = true;
                foreach (sy; cast(size_t)top .. cast(size_t)ceil(bottom))
                    foreach (sx; cast(size_t)left .. cast(size_t)ceil(right))
                    {
                        import std.algorithm : max;
                        const overlap = (min(right, sx + 1.0) - max(left, cast(double)sx)) *
                            (min(bottom, sy + 1.0) - max(top, cast(double)sy));
                        if (overlap <= 0) continue;
                        input.read(Region2D(sx, sy, 1, 1), window[0 .. 1]);
                        const cell = window[0];
                        valid = valid && cell.valid && isFinite(cell.scalar);
                        if (cell.valid && isFinite(cell.scalar)) sum += overlap * cell.scalar;
                        weight += overlap;
                    }
                result = Sample(weight > 0 ? sum / weight : 0, [0, 0, 0],
                    valid && weight > 0 && isFinite(sum));
                continue;
            }
            const x = sourceAxis(region.x + i % region.width, width, input.width);
            const y = sourceAxis(region.y + i / region.width, height, input.height);
            if (policy == FeatureResampling.nearest)
            {
                input.read(Region2D(x.fraction < 0.5 ? x.low : x.high,
                    y.fraction < 0.5 ? y.low : y.high, 1, 1), window[0 .. 1]);
                result = window[0];
                continue;
            }

            const cols = x.fraction == 0 ? 1 : x.high - x.low + 1;
            const rows = y.fraction == 0 ? 1 : y.high - y.low + 1;
            input.read(Region2D(x.low, y.low, cols, rows), window[0 .. cols * rows]);
            double value = 0;
            bool valid = true;
            foreach (row; 0 .. rows)
                foreach (col; 0 .. cols)
                {
                    const sample = window[row * cols + col];
                    valid = valid && sample.valid && isFinite(sample.scalar);
                    const wx = col == 0 ? 1 - x.fraction : x.fraction;
                    const wy = row == 0 ? 1 - y.fraction : y.fraction;
                    if (sample.valid)
                        value += wx * wy * sample.scalar;
                }
            result = Sample(value, [0, 0, 0], valid && isFinite(value));
        }
    };
    return output;
}

/// Fractional area reduction is invariant under ROI partitioning.
unittest
{
    import std.math : abs;
    Source input;
    input.identity = "area-test"; input.revision = "1";
    input.grid = "pixels"; input.band = "measurement"; input.unit = "K";
    input.width = 7; input.height = 5;
    input.read = (Region2D r, scope Sample[] samples) {
        foreach (i, ref s; samples)
            s = Sample(2.0 * (r.x + i % r.width) + 3.0 * (r.y + i / r.width), [0,0,0], true);
    };
    foreach (w; 1 .. 8) foreach (h; 1 .. 6)
    {
        auto output = resampleFeatureSource(input, w, h, 1, FeatureResampling.areaScalar);
        auto whole = new Sample[w*h];
        output.read(Region2D(0,0,w,h), whole);
        foreach (y; 0 .. h) foreach (x; 0 .. w)
        {
            Sample[1] part;
            output.read(Region2D(x,y,1,1), part);
            assert(part[0] == whole[y*w+x]);
            // Independent exact-integer overlap arithmetic: scale all X
            // coordinates by w and all Y coordinates by h.
            long numerator, denominator;
            foreach (sy; 0 .. 5) foreach (sx; 0 .. 7)
            {
                import std.algorithm : max;
                const wx = max(0L, min(cast(long)((x+1)*7), cast(long)((sx+1)*w)) -
                    max(cast(long)(x*7), cast(long)(sx*w)));
                const wy = max(0L, min(cast(long)((y+1)*5), cast(long)((sy+1)*h)) -
                    max(cast(long)(y*5), cast(long)(sy*h)));
                numerator += wx*wy*(2*sx+3*sy); denominator += wx*wy;
            }
            assert(whole[y*w+x].valid);
            assert(abs(whole[y*w+x].scalar - cast(double)numerator/denominator) < 1e-12);
        }
    }
    input.read = (Region2D r, scope Sample[] samples) {
        foreach (ref s; samples) s = Sample(1, [0,0,0], r.x != 3);
    };
    auto masked = resampleFeatureSource(input,1,1,1,FeatureResampling.areaScalar);
    Sample[1] result;
    masked.read(Region2D(0,0,1,1),result);
    assert(!result[0].valid);
}
