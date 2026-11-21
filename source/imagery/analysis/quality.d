/++ Region quality measurements. Threshold selection and scene interpretation
 belong to the consumer. Samples are a dense scalar plane in declared units.
+/
module imagery.analysis.quality;

import std.algorithm : sort;
import std.math : abs, isFinite, sqrt, PI;

@safe:

/// Noise and detail measurements, independent of geographic scale.
struct RegionQuality
{
    /// Robust sigma from the MAD of a normalized separable second difference.
    /// This assumes locally white Gaussian noise; texture can raise the value.
    double noiseSigma;
    /// Mean squared central gradient, in squared input units per pixel².
    double gradientEnergy;
    /// sqrt(gradientEnergy / populationVariance)/(2*pi), cycles/pixel.
    /// A detail-frequency indicator, not a physical sensor resolution estimate.
    double detailFrequency;
    /// Number of complete, finite 3x3 stencils included.
    size_t samples;
}

/// Measure the interior of a scalar region. Caller supplies at least w*h
/// doubles of scratch, which may be reordered. Nonfinite stencils are omitted.
/// Returns false for invalid dimensions/storage or no usable interior and
/// preserves published. No allocations occur. Source and scratch are disjoint.
bool tryRegionQuality(scope const(float)[] source, size_t w, size_t h,
    scope double[] scratch, ref RegionQuality published) nothrow @nogc
{
    if (w<3 || h<3 || w>size_t.max/h || source.length!=w*h || scratch.length<w*h)
        return false;
    size_t count;
    double mean=0, m2=0, energy=0;
    foreach (y; 1 .. h-1) foreach (x; 1 .. w-1)
    {
        const p=y*w+x;
        bool usable=true;
        double high=0;
        foreach (dy; -1 .. 2) foreach (dx; -1 .. 2)
        {
            const v=source[(y+dy)*w+x+dx];
            usable=usable && isFinite(v);
            high += v*(dx==0?-2:1)*(dy==0?-2:1)/6.0;
        }
        if (!usable) continue;
        scratch[count]=high;
        const delta=source[p]-mean;
        mean+=delta / ++count; m2+=delta*(source[p]-mean);
        const gx=(source[p+1]-cast(double)source[p-1])*0.5;
        const gy=(source[p+w]-cast(double)source[p-w])*0.5;
        energy+=gx*gx+gy*gy;
    }
    if (!count) return false;
    auto values=scratch[0..count];
    values.sort;
    const middle=count%2?values[count/2]:0.5*values[count/2-1]+0.5*values[count/2];
    foreach (ref v; values) v=abs(v-middle);
    values.sort;
    const mad=count%2?values[count/2]:0.5*values[count/2-1]+0.5*values[count/2];
    const gradient=energy/count;
    published=RegionQuality(mad/0.6744897501960817, gradient,
        m2>0?sqrt(gradient/(m2/count))/(2*PI):0,count);
    return true;
}

/// Constant planes have zero noise and detail; ramps have analytic energy.
unittest
{
    float[81] input=3;
    double[81] scratch;
    RegionQuality result;
    assert(tryRegionQuality(input[],9,9,scratch[],result));
    assert(result.noiseSigma==0 && result.gradientEnergy==0 && result.detailFrequency==0);
    foreach (i,ref v; input) v=cast(float)(i%9);
    assert(tryRegionQuality(input[],9,9,scratch[],result));
    assert(result.gradientEnergy==1 && result.noiseSigma<1e-12);
    auto old=result;
    assert(!tryRegionQuality(input[],2,2,scratch[],result) && result==old);
}
