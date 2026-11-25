/++
Measure local noise and detail in a scalar image region. Call
`tryRegionQuality` with samples in declared units, then inspect the returned
status before reading the measurements. Choose scene-specific thresholds in
the application.
+/
module imagery.analysis.quality;

import std.algorithm : sort;
import std.math : abs, isFinite, sqrt, PI;

@safe:

/// Noise and detail measurements, independent of geographic scale.
/// `.init` has no samples and is not a successful measurement. A successful
/// measurement may legitimately have zero noise/energy/frequency.
struct RegionQuality
{
    /// Robust sigma from the MAD of a normalized separable second difference.
    /// This assumes locally white Gaussian noise; texture can raise the value.
    double noiseSigma;
    /// Mean squared central gradient, in squared input units per pixel².
    double gradientEnergy;
    /// sqrt(gradientEnergy / populationVariance)/(2*pi), cycles/pixel.
/// A detail-frequency indicator, not a physical sensor resolution estimate.
/// A single-frequency sinusoid retains this ratio under blur even though
/// its contrast and gradient energy decrease.
    double detailFrequency;
    /// Number of complete, finite 3x3 stencils included.
    size_t samples;
}

/// Sample count distinguishes empty state from a measured constant plane.
unittest
{
    RegionQuality result;
    assert(result.samples==0);
    float[25] constant=7;
    double[25] scratch;
    assert(tryRegionQuality(constant[],5,5,scratch[],result));
    assert(result.samples==9 && result.gradientEnergy==0);
}

/++
 Measure noise, gradient energy and detail frequency inside a scalar image.

  Use this to compare image quality in a declared scalar unit; thresholds and
  scene interpretation belong to the caller. Only complete finite 3x3 stencils
  are included. Noise sigma has input units, energy has squared input units per
  pixel squared, and detail frequency has cycles per pixel. Source and working
  memory must be disjoint. Working memory may be reordered even when the result
  is not replaced. The operation allocates no storage.

 Params:
  source = Read-only dense float32 scalar plane with exactly w*h samples.
  w = Image width in pixels.
  h = Image height in pixels.
  scratch = Caller-owned double working array of at least w*h elements, disjoint from source; overwritten and reordered.
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 True on success. False for invalid dimensions/storage or no usable
  interior; the previous output parameter remains unchanged.
+/
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

unittest
{
    float[81] input;
    foreach(i,ref value;input)value=cast(float)((i*17+i*i*31)%257)/16;
    double[81] scratch;
    RegionQuality reference,result;
    assert(tryRegionQuality(input[],9,9,scratch[],reference));
    foreach(factor;[1.0/1024,1024.0,-1.0]) {
        float[81] changed;
        foreach(i,value;input)changed[i]=cast(float)(factor*(value+128));
        assert(tryRegionQuality(changed[],9,9,scratch[],result));
        assert(abs(result.noiseSigma/abs(factor)-reference.noiseSigma)<1e-12);
        assert(abs(result.gradientEnergy/(factor*factor)-reference.gradientEnergy)<1e-12);
        assert(abs(result.detailFrequency-reference.detailFrequency)<1e-14);
    }
    input[40]=float.nan;
    assert(tryRegionQuality(input[],9,9,scratch[],result) && result.samples==40);
    const previous=result;
    input[]=float.infinity;
    assert(!tryRegionQuality(input[],9,9,scratch[],result) && result==previous);
}
