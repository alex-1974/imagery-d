/++ Region-readable feature sources on selected overview grids. +/
module imagery.analysis.feature_overviews;

import imagery.analysis.feature_regions : ImageResamplingMetadata, Source, Sample, sourceMetadata;
import imagery.pyramid.overview_selection : OverviewLevel, OverviewSelection,
    OverviewSelectionError, trySelectOverviewLevel;
import raster.region : Region2D;
import std.algorithm : min;
import std.conv : to;
import std.math : isFinite;

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

enum FeatureResampling { nearest, bilinearScalar }

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
/// Bilinear is available for scalar channels and requires valid contributors
/// with nonzero weights. The reader uses at most four source samples at once.
Source resampleFeatureSource(const Source input, size_t width, size_t height, size_t level,
    FeatureResampling policy)
{
    enum maxExtent = 1UL << 48;
    if (input.read is null || !input.width || !input.height || !width || !height ||
        input.width > maxExtent || input.height > maxExtent ||
        width > maxExtent || height > maxExtent ||
        (policy != FeatureResampling.nearest && policy != FeatureResampling.bilinearScalar) ||
        (input.rgb && policy == FeatureResampling.bilinearScalar))
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
