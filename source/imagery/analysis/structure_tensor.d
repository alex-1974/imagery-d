/++ Gaussian structure tensor over a finite dense scalar plane. Gaussian
 derivatives use sampled normalized kernels truncated at three sigma with
 source-edge replication. Orientation describes the dominant gradient normal
 modulo pi; add pi/2 for a line tangent. Scientific input units are preserved
 in gradient products. See scipy.ndimage.gaussian_filter for the derivative
 convention used by the independent differential probe.
+/
module imagery.analysis.structure_tensor;

import std.math : exp, ceil, isFinite, sqrt, atan2;

@safe:

/// Scales in pixels. Gaussian support is ceil(3*sigma) on each axis.
struct StructureTensorParams
{
    double gradientSigma=1;
    double integrationSigma=2;
    /// Reject invalid or excessively large kernels before any output writes.
    void validate() const
    {
        if (!isFinite(gradientSigma) || gradientSigma<=0 || gradientSigma>32 ||
            !isFinite(integrationSigma) || integrationSigma<0 || integrationSigma>32)
            throw new Exception("Tensor sigmas require gradient in (0,32], integration in [0,32]");
    }
    /// Total source halo, including gradient and tensor integration support.
    size_t halo() const { validate(); return cast(size_t)ceil(3*gradientSigma)+cast(size_t)ceil(3*integrationSigma); }
}

/// Reusable six-plane double scratch. Growing storage is explicit through
/// reserve; repeated evaluation of equal/smaller planes allocates nothing.
struct TensorWorkspace
{
    package double[][6] planes;
    /// Reserve O(samples) scratch, allocating only when capacity must grow.
    void reserve(size_t samples)
    {
        if (samples>size_t.max/(6*double.sizeof)) throw new Exception("Tensor scratch overflow");
        foreach(ref plane;planes) if(plane.length<samples) plane=new double[samples];
    }
}

package struct Gaussian
{
    int radius;
    double[257] smooth, derivative;
}

package Gaussian kernel(double sigma, uint support=3)
{
    Gaussian result;
    if(sigma==0) { result.smooth[0]=1; return result; }
    result.radius=cast(int)ceil(support*sigma);
    double sum=0;
    foreach(i;0..2*result.radius+1) {
        const x=i-result.radius;
        result.smooth[i]=exp(-0.5*(x/sigma)^^2); sum+=result.smooth[i];
    }
    foreach(i;0..2*result.radius+1) {
        result.smooth[i]/=sum;
        result.derivative[i]=(i-result.radius)*result.smooth[i]/(sigma*sigma);
    }
    return result;
}

package size_t shifted(size_t i,int delta,size_t length) nothrow @nogc
{
    if(delta<0)return i<cast(size_t)(-delta)?0:i-cast(size_t)(-delta);
    return cast(size_t)delta>length-1-i?length-1:i+cast(size_t)delta;
}

package void pass(T)(scope const(T)[] source,size_t w,size_t h,
    scope const(double)[] weights,int radius,bool vertical,scope double[] dest,
    bool derivative=false) nothrow @nogc
{
    foreach(y;0..h)foreach(x;0..w) {
        double value=0;
        if(derivative) {
            foreach(tap;1..radius+1) {
                const plus=vertical?shifted(y,tap,h)*w+x:y*w+shifted(x,tap,w);
                const minus=vertical?shifted(y,-tap,h)*w+x:y*w+shifted(x,-tap,w);
                value+=(cast(double)source[plus]-source[minus])*weights[radius+tap];
            }
            dest[y*w+x]=value;
            continue;
        }
        foreach(tap;0..2*radius+1) {
            const sx=vertical?x:shifted(x,tap-radius,w);
            const sy=vertical?shifted(y,tap-radius,h):y;
            value+=source[sy*w+sx]*weights[tap];
        }
        dest[y*w+x]=value;
    }
}

/// Evaluate after explicit workspace reservation. Each output needs w*h
/// elements; all output planes and scratch must be disjoint. Reject malformed
/// shape, nonfinite inputs or insufficient scratch before writing output.
/// coherence is (lambdaMax-lambdaMin)/(lambdaMax+lambdaMin), or zero at zero
/// energy. Zero/ isotropic tensors have orientationValid=0 and orientation=0.
/// energy is the tensor trace. Outputs are explicitly rounded to float32.
void structureTensor(scope const(float)[] source,size_t w,size_t h,
    StructureTensorParams params,ref TensorWorkspace scratch,
    scope float[] orientation,scope float[] coherence,scope float[] energy,
    scope ubyte[] orientationValid)
{
    params.validate();
    if(!w || !h || w>size_t.max/h || source.length!=w*h ||
        orientation.length<w*h || coherence.length<w*h || energy.length<w*h || orientationValid.length<w*h)
        throw new Exception("Invalid tensor shape or destination");
    foreach(v;source)if(!isFinite(v))throw new Exception("Nonfinite tensor input");
    foreach(p;scratch.planes)if(p.length<w*h)throw new Exception("Reserve tensor workspace first");
    const g=kernel(params.gradientSigma), s=kernel(params.integrationSigma);
    auto tmp=scratch.planes[0][0..w*h], gx=scratch.planes[1][0..w*h], gy=scratch.planes[2][0..w*h];
    auto xx=scratch.planes[3][0..w*h], xy=scratch.planes[4][0..w*h], yy=scratch.planes[5][0..w*h];
    pass(source,w,h,g.derivative[],g.radius,false,tmp,true);
    pass(tmp,w,h,g.smooth[],g.radius,true,gx);
    pass(source,w,h,g.smooth[],g.radius,false,tmp);
    pass(tmp,w,h,g.derivative[],g.radius,true,gy,true);
    foreach(i;0..w*h) { xx[i]=gx[i]*gx[i]; xy[i]=gx[i]*gy[i]; yy[i]=gy[i]*gy[i]; }
    foreach(plane;[xx,xy,yy]) {
        pass(plane,w,h,s.smooth[],s.radius,false,tmp);
        pass(tmp,w,h,s.smooth[],s.radius,true,plane);
    }
    foreach(i;0..w*h) {
        const trace=xx[i]+yy[i];
        const delta=sqrt((xx[i]-yy[i])^^2+4*xy[i]*xy[i]);
        energy[i]=cast(float)trace;
        coherence[i]=trace>0?cast(float)(delta/trace):0;
        orientationValid[i]=cast(ubyte)(trace>0 && delta>0);
        orientation[i]=orientationValid[i]?cast(float)(0.5*atan2(2*xy[i],xx[i]-yy[i])):0;
    }
}

/// A horizontal scalar ramp has horizontal gradient orientation and unit coherence.
unittest
{
    float[225] image;
    foreach(i,ref v;image)v=cast(float)(i%15);
    TensorWorkspace workspace;workspace.reserve(image.length);
    float[225] angle,coherence,energy;
    ubyte[225] valid;
    structureTensor(image[],15,15,StructureTensorParams.init,workspace,angle[],coherence[],energy[],valid[]);
    assert(valid[112] && angle[112]==0 && coherence[112]>0.99999 && energy[112]>0);
}
