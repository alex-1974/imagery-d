/++ Gaussian structure tensor over a finite dense scalar plane. Gaussian
 derivatives use sampled normalized kernels truncated at three sigma with
 source-edge replication. Orientation describes the dominant gradient normal
 modulo pi; add pi/2 for a line tangent. Scientific input units are preserved
 in gradient products. See scipy.ndimage.gaussian_filter for the derivative
 convention used by the independent differential probe.
+/
module imagery.analysis.structure_tensor;

import std.math : exp, ceil, isFinite, sqrt, atan2;
import std.algorithm : min,max;

@safe:

/// Scales in pixels. `.init` is a valid (1,2) scale pair. Gaussian support is
/// ceil(3*sigma) on each axis. An integration sigma of zero disables integration.
struct StructureTensorParams
{
    /// Finite positive gradient sigma, at most 32 source pixels.
    double gradientSigma=1;
    /// Finite integration sigma in [0,32] source pixels.
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

/// Support composes the two independent Gaussian stages.
unittest
{
    auto parameters=StructureTensorParams(1.25,2.5);
    parameters.validate();
    assert(parameters.halo()==12);
}

/// Reusable double scratch. Legacy reserve(samples) uses six full planes;
/// shape-aware reserve uses bounded gradient/product/integration carriers.
/// Growing storage is explicit through
/// reserve; repeated evaluation of equal/smaller planes allocates nothing.
/// `.init` has no reserved capacity. Copies share storage; use serially and do
/// not overlap scratch with input or output planes.
struct TensorWorkspace
{
    package double[][6] planes;
    private size_t shapeWidth,shapeHeight,gradientRadius,integrationRadius;
    private size_t rowBlock=32,columnBlock=128;
    /// Reserve O(samples) scratch, allocating only when capacity must grow.
    void reserve(size_t samples)
    {
        if (samples>size_t.max/(6*double.sizeof)) throw new Exception("Tensor scratch overflow");
        foreach(ref plane;planes) if(plane.length<samples) plane=new double[samples];
        shapeWidth=shapeHeight=gradientRadius=integrationRadius=0;rowBlock=32;columnBlock=128;
    }

    /// Reserve bounded strip/tile carriers for this shape and scale envelope.
    /// stripRows/stripWidth are in 1..256. Defaults bound the owned payload
    /// below 8 MiB even at maximum sigmas. Reject larger requested payloads
    /// before replacing storage. No allocation occurs during evaluation.
    void reserve(size_t width,size_t height,StructureTensorParams parameters,
        size_t stripRows=32,size_t stripWidth=128)
    {
        parameters.validate();
        if(!width||!height||width>size_t.max/height||!stripRows||stripRows>256||!stripWidth||stripWidth>256)
            throw new Exception("Invalid tensor strip reservation");
        const gr=cast(size_t)ceil(3*parameters.gradientSigma),sr=cast(size_t)ceil(3*parameters.integrationSigma);
        const bw=min(width,stripWidth),bh=min(height,stripRows);
        const gw=min(width,bw+2*sr),gh=min(height,bh+2*(gr+sr)),ph=min(height,bh+2*sr);
        const gradient=gw*gh,product=gw*ph,horizontal=bw*ph;
        size_t[6] needed=[max(gradient,horizontal),max(gradient,horizontal),product,product,product,horizontal];
        size_t total;foreach(n;needed)total+=n;
        if(total>8*1024*1024/double.sizeof)throw new Exception("Tensor strip payload exceeds 8 MiB");
        double[][6] candidate;
        foreach(i,ref plane;candidate)plane=planes[i].length==needed[i]?planes[i]:new double[needed[i]];
        planes=candidate;shapeWidth=width;shapeHeight=height;gradientRadius=gr;integrationRadius=sr;
        rowBlock=stripRows;columnBlock=stripWidth;
    }

    /// Owned array payload only; caller planes, metadata and stack are separate.
    size_t storageBytes() const nothrow @nogc
    {size_t result;foreach(p;planes)result+=p.length*double.sizeof;return result;}
}

/// Reserve once before repeated evaluations.
unittest
{
    TensorWorkspace workspace;
    workspace.reserve(225);
    workspace.reserve(100); // smaller requests reuse the allocation
    workspace.reserve(1024,1024,StructureTensorParams(32,32));
    assert(workspace.storageBytes<8*1024*1024);
}

// Ordered horizontal Gaussian families over one source row. Curvature and
// derivative share the paired source loads; smoothing keeps -r..r order.
// Interior lanes have contiguous slices; only true source borders clamp.
package void horizontalGaussian(T,bool derivative=true,bool curvature=false)(
    scope const(T)[] source,size_t width,size_t y,size_t first,size_t count,
    scope const ref Gaussian g,scope double[] smooth,scope double[] gradient,
    scope const(double)[] secondWeights=null,scope double[] second=null) nothrow @nogc
{
    const r=cast(size_t)g.radius;
    smooth[0..count]=0;
    static if(derivative)gradient[0..count]=0;
    static if(curvature)second[0..count]=0;
    size_t lo=min(count,first<r?r-first:0),hi;
    if(width>r&&first<width-r)hi=min(count,width-r-first);
    hi=max(lo,hi);
    if(lo<hi) {
        auto outSmooth=smooth[lo..hi];
        foreach(tap;0..2*g.radius+1) {
            const start=y*width+first+lo+tap-r;
            const values=source[start..start+hi-lo];const weight=g.smooth[tap];
            foreach(x;0..values.length)outSmooth[x]+=cast(double)values[x]*weight;
        }
        static if(derivative||curvature) {
            auto outGradient=gradient[lo..hi];
            const centers=source[y*width+first+lo..y*width+first+hi];
            foreach(tap;1..g.radius+1) {
                const plus=source[y*width+first+lo+tap..y*width+first+hi+tap];
                const minus=source[y*width+first+lo-tap..y*width+first+hi-tap];
                const dw=g.derivative[g.radius+tap];
                static if(curvature) {
                    const sw=secondWeights[tap];auto outSecond=second[lo..hi];
                    foreach(x;0..plus.length) {
                        const p=cast(double)plus[x],m=cast(double)minus[x],c=cast(double)centers[x];
                        outGradient[x]+=(p-m)*dw;outSecond[x]+=((p-c)+(m-c))*sw;
                    }
                } else foreach(x;0..plus.length)outGradient[x]+=(cast(double)plus[x]-cast(double)minus[x])*dw;
            }
        }
    }
    if(lo||hi<count)foreach(x;0..count)if(x<lo||x>=hi) {
        const px=first+x;double sm=0,der=0,sec=0;
        foreach(tap;0..2*g.radius+1)sm+=cast(double)source[y*width+shifted(px,tap-g.radius,width)]*g.smooth[tap];
        static if(derivative||curvature)foreach(tap;1..g.radius+1) {
            const p=cast(double)source[y*width+shifted(px,tap,width)],m=cast(double)source[y*width+shifted(px,-tap,width)];
            der+=(p-m)*g.derivative[g.radius+tap];
            static if(curvature) {const c=cast(double)source[y*width+px];sec+=((p-c)+(m-c))*secondWeights[tap];}
        }
        smooth[x]=sm;static if(derivative)gradient[x]=der;static if(curvature)second[x]=sec;
    }
}

version(LDC) {
    import core.simd : double2;
    // Architecture-neutral LLVM vector sqrt; no target attribute, fast-math or
    // negative operand. DMD uses the scalar twin below.
    pragma(LDC_intrinsic,"llvm.sqrt.v2f64")
    private double2 packedRoot(double2 value) pure nothrow @nogc;
}

package void eigenPairScalar(bool hessian)(double a0,double a1,double b0,double b1,double c0,double c1,
    out double m0,out double m1,out double g0,out double g1) nothrow @nogc
{
    static if(hessian) {
        m0=.5*(a0+c0);m1=.5*(a1+c1);
        g0=sqrt((.5*(a0-c0))^^2+b0*b0);g1=sqrt((.5*(a1-c1))^^2+b1*b1);
    } else {
        m0=a0+c0;m1=a1+c1;
        g0=sqrt((a0-c0)^^2+4*b0*b0);g1=sqrt((a1-c1)^^2+4*b1*b1);
    }
}

package void eigenPair(bool hessian)(double a0,double a1,double b0,double b1,double c0,double c1,
    out double m0,out double m1,out double g0,out double g1) nothrow @nogc
{
    version(LDC) {
        double[2] aa=[a0,a1],bb=[b0,b1],cc=[c0,c1];
        auto a=cast(double2)aa,b=cast(double2)bb,c=cast(double2)cc;
        double2 middle,gap;
        static if(hessian) {
            middle=.5*(a+c);const difference=.5*(a-c);gap=packedRoot(difference*difference+b*b);
        } else {
            middle=a+c;const difference=a-c;gap=packedRoot(difference*difference+(4*b)*b);
        }
        m0=middle.array[0];m1=middle.array[1];g0=gap.array[0];g1=gap.array[1];
    } else eigenPairScalar!hessian(a0,a1,b0,b1,c0,c1,m0,m1,g0,g1);
}

@safe unittest
{
    import std.math : signbit;
    static foreach(hessian;[false,true])foreach(scale;[1e-100,1.0,1e100])foreach(i;0..257) {
        const a=scale*(i-128.0),b=scale*(i%7-3.0),c=scale*(i%13-6.0);
        double[4] scalar,packed;
        eigenPairScalar!hessian(a,c,b,-b,c,a,scalar[0],scalar[1],scalar[2],scalar[3]);
        eigenPair!hessian(a,c,b,-b,c,a,packed[0],packed[1],packed[2],packed[3]);
        foreach(k;0..4)assert(scalar[k]==packed[k]&&(scalar[k]!=0||signbit(scalar[k])==signbit(packed[k])));
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
        // A tiny positive sigma is a discrete impulse. Its off-center weights
        // underflow to zero; avoid 0/0 when sigma squared also underflows.
        result.derivative[i]=i==result.radius || result.smooth[i]==0 ? 0 :
            (i-result.radius)*result.smooth[i]/(sigma*sigma);
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
    if(vertical) {
        // A tap addresses one complete source row. Traverse its contiguous
        // lanes together; every pixel still accumulates taps in the original
        // order. Equal-length slices keep validation outside the inner loop.
        foreach(y;0..h) {
            auto target=dest[y*w..(y+1)*w];target[]=0;
            if(derivative) {
                foreach(tap;1..radius+1) {
                    const py=shifted(y,tap,h),my=shifted(y,-tap,h);
                    const weight=weights[radius+tap];
                    const plus=source[py*w..(py+1)*w],minus=source[my*w..(my+1)*w];
                    foreach(x;0..w)target[x]+=(cast(double)plus[x]-cast(double)minus[x])*weight;
                }
            } else foreach(tap;0..2*radius+1) {
                const sy=shifted(y,tap-radius,h);
                const weight=weights[tap];
                const row=source[sy*w..(sy+1)*w];
                foreach(x;0..w)target[x]+=cast(double)row[x]*weight;
            }
        }
        return;
    }
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

// The unchanged horizontal scalar pass is an independent transpose oracle
// for the vertical row traversal, including clamped narrow shapes and zeros.
@safe unittest
{
    import std.math : signbit;
    import std.meta : AliasSeq;
    static foreach(T;AliasSeq!(float,double)) {
        foreach(shape;[[19UL,7UL],[1UL,5UL],[5UL,1UL]])foreach(base;[0.0,1e12]) {
            const w=shape[0],h=shape[1];
            auto src=new T[w*h],transposed=new T[w*h];
            foreach(y;0..h)foreach(x;0..w) {
                const value=cast(T)(base+(cast(int)((x*37+y*17+x*y%97)&255)-127)*.125);
                src[y*w+x]=value;transposed[x*h+y]=value;
            }
            src[0]=transposed[0]=cast(T)-0.0;
            auto actual=new double[w*h],expected=new double[w*h];
            foreach(sigma;[0.0,.5,2.0,4.0])foreach(derivative;[false,true]) {
                const g=kernel(sigma);
                const weights=derivative?g.derivative[]:g.smooth[];
                pass(src,w,h,weights,g.radius,true,actual,derivative);
                pass(transposed,h,w,weights,g.radius,false,expected,derivative);
                foreach(y;0..h)foreach(x;0..w) {
                    const a=actual[y*w+x],b=expected[x*h+y];
                    assert(a==b&&(a!=0||signbit(a)==signbit(b)));
                }
            }
        }
    }
}


private void publishTensor(double xx,double xy,double yy,double trace,double delta,size_t i,
    scope float[] orientation,scope float[] coherence,scope float[] energy,
    scope ubyte[] orientationValid) nothrow @nogc
{
    energy[i]=cast(float)trace;
    coherence[i]=trace>0?cast(float)min(1.0,delta/trace):0;
    orientationValid[i]=cast(ubyte)(trace>0&&delta>32*double.epsilon*trace);
    orientation[i]=orientationValid[i]?cast(float)(.5*atan2(2*xy,xx-yy)):0;
}

/// Evaluate after explicit workspace reservation. Each output needs w*h
/// elements; all output planes and scratch must be disjoint. Reject malformed
/// shape, nonfinite inputs or insufficient scratch before writing output.
/// coherence is (lambdaMax-lambdaMin)/(lambdaMax+lambdaMin), or zero at zero
/// energy, bounded to [0,1]. Orientation is undefined when the eigenvalue gap
/// is at most 32*double.epsilon times the trace, including zero/isotropic tensors;
/// these have orientationValid=0 and orientation=0. Other angles are axial
/// radians in [-pi/2,pi/2]. All destinations remain unchanged on invalid input.
/// energy is the tensor trace. Outputs are explicitly rounded to float32.
/// Extreme finite inputs can overflow float32 energy; rescale the input if a
/// finite energy output is required. Tiny positive gradient sigmas whose
/// off-center weights underflow give zero discrete derivatives.
void structureTensor(scope const(float)[] source,size_t w,size_t h,
    StructureTensorParams params,ref TensorWorkspace scratch,
    scope float[] orientation,scope float[] coherence,scope float[] energy,
    scope ubyte[] orientationValid)
{
    version(ImageryGaussianReference) {
        tensorReference(source,w,h,params,scratch,orientation,coherence,energy,orientationValid);return;
    }
    params.validate();
    if(!w||!h||w>size_t.max/h||source.length!=w*h||orientation.length<w*h||
        coherence.length<w*h||energy.length<w*h||orientationValid.length<w*h)
        throw new Exception("Invalid tensor shape or destination");
    foreach(v;source)if(!isFinite(v))throw new Exception("Nonfinite tensor input");
    const g=kernel(params.gradientSigma),s=kernel(params.integrationSigma);
    const gr=cast(size_t)g.radius,sr=cast(size_t)s.radius;
    if(scratch.shapeWidth) {
        if(w>scratch.shapeWidth||h>scratch.shapeHeight||gr>scratch.gradientRadius||sr>scratch.integrationRadius)
            throw new Exception("Tensor shape/scales exceed strip reservation");
    } else foreach(p;scratch.planes)if(p.length<w*h)throw new Exception("Reserve tensor workspace first");
    double[2*448] gradientRows;
    for(size_t y0=0;y0<h;y0+=scratch.rowBlock) {
        const rows=min(scratch.rowBlock,h-y0),py=y0-min(y0,sr);
        const bottom=y0+rows+min(sr,h-y0-rows),ph=bottom-py;
        const gy=py-min(py,gr),gBottom=bottom+min(gr,h-bottom),gh=gBottom-gy;
        for(size_t x0=0;x0<w;x0+=scratch.columnBlock) {
            const width=min(scratch.columnBlock,w-x0),px=x0-min(x0,sr);
            const right=x0+width+min(sr,w-x0-width),pw=right-px;
            auto horizontalDerivative=scratch.planes[0][0..pw*gh];
            auto horizontalSmooth=scratch.planes[1][0..pw*gh];
            foreach(y;gy..gBottom) {
                const at=(y-gy)*pw;
                horizontalGaussian!(float,true)(source,w,y,px,pw,g,
                    horizontalSmooth[at..at+pw],horizontalDerivative[at..at+pw]);
            }
            auto xx=scratch.planes[2][0..pw*ph],xy=scratch.planes[3][0..pw*ph],yy=scratch.planes[4][0..pw*ph];
            auto gx=gradientRows[0..pw],dy=gradientRows[448..448+pw];
            foreach(y;py..bottom) {
                gx[]=0;dy[]=0;
                foreach(tap;0..2*g.radius+1) {
                    const row=(shifted(y,tap-g.radius,h)-gy)*pw,weight=g.smooth[tap];
                    const input=horizontalDerivative[row..row+pw];
                    foreach(x;0..pw)gx[x]+=input[x]*weight;
                }
                foreach(tap;1..g.radius+1) {
                    const plus=(shifted(y,tap,h)-gy)*pw,minus=(shifted(y,-tap,h)-gy)*pw;
                    const weight=g.derivative[g.radius+tap];
                    foreach(x;0..pw)dy[x]+=(horizontalSmooth[plus+x]-horizontalSmooth[minus+x])*weight;
                }
                const at=(y-py)*pw;
                foreach(x;0..pw) {xx[at+x]=gx[x]*gx[x];xy[at+x]=gx[x]*dy[x];yy[at+x]=dy[x]*dy[x];}
            }
            // Gradient carriers can now become the horizontally integrated
            // products. The products themselves remain disjoint until all
            // three horizontal families are complete.
            auto hx=scratch.planes[0][0..width*ph],hc=scratch.planes[1][0..width*ph],hy=scratch.planes[5][0..width*ph];
            foreach(y;0..ph) {
                const at=y*width;
                horizontalGaussian!(double,false)(xx,pw,y,x0-px,width,s,hx[at..at+width],null);
                horizontalGaussian!(double,false)(xy,pw,y,x0-px,width,s,hc[at..at+width],null);
                horizontalGaussian!(double,false)(yy,pw,y,x0-px,width,s,hy[at..at+width],null);
            }
            // Original products are dead; reuse their first rows for the final
            // fused vertical integrations without extra owned arrays.
            auto ax=xx[0..width],cross=xy[0..width],ay=yy[0..width];
            foreach(y;y0..y0+rows) {
                ax[]=0;cross[]=0;ay[]=0;
                foreach(tap;0..2*s.radius+1) {
                    const row=(shifted(y,tap-s.radius,h)-py)*width,weight=s.smooth[tap];
                    foreach(x;0..width) {ax[x]+=hx[row+x]*weight;cross[x]+=hc[row+x]*weight;ay[x]+=hy[row+x]*weight;}
                }
                size_t x;
                for(;x+1<width;x+=2) {
                    double m0,m1,d0,d1;
                    eigenPair!false(ax[x],ax[x+1],cross[x],cross[x+1],ay[x],ay[x+1],m0,m1,d0,d1);
                    publishTensor(ax[x],cross[x],ay[x],m0,d0,y*w+x0+x,orientation,coherence,energy,orientationValid);
                    publishTensor(ax[x+1],cross[x+1],ay[x+1],m1,d1,y*w+x0+x+1,orientation,coherence,energy,orientationValid);
                }
                if(x<width)publishTensor(ax[x],cross[x],ay[x],ax[x]+ay[x],
                    sqrt((ax[x]-ay[x])^^2+4*cross[x]*cross[x]),y*w+x0+x,orientation,coherence,energy,orientationValid);
            }
        }
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

// Preserve constant planes even at subnormal parameter and input scales.
unittest
{
    float[9] image=1;
    TensorWorkspace workspace;workspace.reserve(image.length);
    float[9] angle,coherence,energy;
    ubyte[9] valid;
    foreach(value;[1.0f,cast(float)1e-40])
        foreach(sigma;[1e-200,0.5,32.0]) {
            image[]=value;
            structureTensor(image[],3,3,StructureTensorParams(sigma,0),workspace,
                angle[],coherence[],energy[],valid[]);
            foreach(i;0..9)assert(angle[i]==0 && coherence[i]==0 && energy[i]==0 && valid[i]==0);
        }
}

version(unittest) private enum keepTensorReference=true;
else version(ImageryGaussianReference) private enum keepTensorReference=true;
else private enum keepTensorReference=false;
static if(keepTensorReference)
private void tensorReference(scope const(float)[] source,size_t w,size_t h,
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
        coherence[i]=trace>0?cast(float)min(1.0,delta/trace):0;
        orientationValid[i]=cast(ubyte)(trace>0 && delta>32*double.epsilon*trace);
        orientation[i]=orientationValid[i]?cast(float)(0.5*atan2(2*xy[i],xx[i]-yy[i])):0;
    }
}

@safe unittest
{
    import core.memory : GC;
    import std.math : signbit;
    import std.exception : assertThrown;
    foreach(shape;[[19UL,13UL],[1UL,5UL],[5UL,1UL],[1UL,1UL]])foreach(base;[0.0,1e12]) {
        const w=shape[0],h=shape[1],n=w*h;
        auto input=new float[n];
        foreach(i,ref v;input)v=cast(float)(base+(i*37+i/w*17)%256*(base==0?.03125:1048576.0));
        input[0]=-0.0f;
        TensorWorkspace reference;reference.reserve(n);
        float[][3] expected,actual;foreach(ref p;expected)p=new float[n];foreach(ref p;actual)p=new float[n];
        auto ev=new ubyte[n],av=new ubyte[n];
        foreach(params;[StructureTensorParams(.5,0),StructureTensorParams(.75,.5),StructureTensorParams(1.25,2.5),StructureTensorParams(32,32)]) {
            tensorReference(input,w,h,params,reference,expected[0],expected[1],expected[2],ev);
            foreach(block;[[3UL,5UL],[32UL,128UL]]) {
                TensorWorkspace work;work.reserve(w,h,params,block[0],block[1]);
                const before=GC.stats().allocatedInCurrentThread;
                structureTensor(input,w,h,params,work,actual[0],actual[1],actual[2],av);
                assert(GC.stats().allocatedInCurrentThread==before&&av==ev);
                foreach(c;0..3)foreach(i,v;actual[c])assert(v==expected[c][i]&&
                    (v!=0||signbit(v)==signbit(expected[c][i])));
            }
        }
        TensorWorkspace small;small.reserve(w,h,StructureTensorParams(.5,0));actual[2][]=17;
        assertThrown!Exception(structureTensor(input,w,h,StructureTensorParams(2,3),small,
            actual[0],actual[1],actual[2],av));
        foreach(v;actual[2])assert(v==17);
    }
}
