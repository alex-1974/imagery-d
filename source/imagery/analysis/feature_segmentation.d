/++ Image adapters for cross-block components. +/
module imagery.analysis.feature_segmentation;

import imagery.analysis.feature_components : ComponentReader, ComponentSample;
import imagery.analysis.feature_regions : Engine, Feature, Source, Value, Provenance;
import raster.region : Region2D;
import std.algorithm : min;
import std.math : abs, isFinite, PI;

@safe:

private void validateWindow(const Source source, Region2D window, size_t length)
{
    if (window.empty || window.width > 258 || window.height != 1 ||
        length != window.width || window.x > source.width ||
        window.width > source.width - window.x || window.y >= source.height)
        throw new Exception("Invalid component-reader window");
}

/++
 Turn non-maximum-suppressed Sobel responses into weak and strong samples.
   Label with 8-connectivity and requireSeed=true for Canny hysteresis.

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  low = Nonnegative weak-edge magnitude threshold, no greater than high.
  high = Strong-edge magnitude threshold, at least low.

 Throws:
 Exception for Invalid Canny thresholds.
+/
ComponentReader cannyComponents(Source source, double low, double high)
{
    if (!(low > 0 && low <= high) || !isFinite(high))
        throw new Exception("Invalid Canny thresholds");
    auto engine = new Engine;
    return (Region2D window, scope ComponentSample[] samples) {
        validateWindow(source, window, samples.length);
        const left = cast(size_t)(window.x != 0);
        const top = cast(size_t)(window.y != 0);
        const width = left + window.width + (window.x + window.width < source.width ? 1 : 0);
        const height = top + 1 + (window.y + 1 < source.height ? 1 : 0);
        const support = Region2D(window.x - left, window.y - top, width, height);
        Value[260 * 3] gradients;
        engine.run(source, support, Feature.gradient, 32,
            (Region2D tile, scope const(Value)[] values, Provenance origin) {
                foreach (i, value; values)
                    gradients[(tile.y - support.y + i / tile.width) * width +
                        tile.x - support.x + i % tile.width] = value;
            });
        foreach (i, ref sample; samples)
        {
            sample = ComponentSample.init;
            const gx = i + left;
            const value = gradients[top * width + gx];
            sample.valid = value.valid;
            if (!value.valid || !value.orientationValid || value.channels[0] < low)
                continue;
            const angle = (value.channels[1] + PI) % PI;
            const direction = cast(size_t)(angle * 4 / PI + 0.5) % 4;
            immutable int[2][4] axes = [[1, 0], [1, 1], [0, 1], [-1, 1]];
            const axis = axes[direction];
            const compare = (int sign) {
                const x = cast(int)gx + axis[0] * sign;
                const y = cast(int)top + axis[1] * sign;
                if (x < 0 || x >= width || y < 0 || y >= height)
                    return false;
                const neighbor = gradients[y * width + x];
                sample.valid &= neighbor.valid;
                return neighbor.valid && (sign > 0 ? value.channels[0] >= neighbor.channels[0] :
                    value.channels[0] > neighbor.channels[0]);
            };
            const before = compare(-1);
            const after = compare(1);
            if (before && after)
            {
                sample.state = value.channels[0] >= high ?
                    ComponentSample.State.seed : ComponentSample.State.candidate;
                sample.edge = value.channels[0];
            }
        }
    };
}

/++
 Supply OKLab or scalar region candidates. The caller can mask candidates
  and mark seeds for region growing. A finite color-distance policy enables
  single-link region merging, optionally constrained to superpixel cells.

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  includeStatistics = True to include component color/texture/edge measurements.
+/
ComponentReader imageComponents(Source source, bool includeStatistics = false)
{
    auto engine = new Engine;
    return (Region2D window, scope ComponentSample[] samples) {
        validateWindow(source, window, samples.length);
        auto missing = ComponentSample.init;
        missing.valid = false;
        samples[] = missing;
        engine.run(source, window, source.rgb ? Feature.oklab : Feature.luminance, 32,
            (Region2D tile, scope const(Value)[] values, Provenance origin) {
                foreach (i, value; values)
                    if (value.valid)
                    {
                        auto sample = &samples[tile.x - window.x + i];
                        sample.valid = true;
                        sample.state = ComponentSample.State.candidate;
                        sample.color = value.channels;
                    }
            });
        if (!includeStatistics)
            return;
        foreach (feature; [Feature.localStatistics, Feature.gradient])
            engine.run(source, window, feature, 32,
                (Region2D tile, scope const(Value)[] values, Provenance origin) {
                    foreach (i, value; values)
                        if (value.valid)
                        {
                            auto sample = &samples[tile.x - window.x + i];
                            if (feature == Feature.gradient)
                                sample.edge = value.channels[0];
                            else
                                sample.texture = value.channels[1];
                        }
                });
    };
}

/// Adapt scalar image pixels into component candidates.
@safe unittest
{
    import imagery.analysis.feature_regions : Sample;
    Source source;
    source.width=2; source.height=1;
    source.read=(Region2D row,scope Sample[] values) {
        foreach(ref value;values) value=Sample(5,[0,0,0],true);
    };
    auto read=imageComponents(source);
    ComponentSample[2] observations;
    read(Region2D(0,0,2,1),observations[]);
    assert(observations[0].state==ComponentSample.State.candidate);
    assert(observations[0].color[0]==5 && observations[1].valid);
}
