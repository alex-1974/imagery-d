/++
Find thin bright or dark lines in a scalar image. Call `hessianLineResponse`
with explicit scales in pixels, polarity and a `HessianLineVariant`. Reserve a
`HessianLineWorkspace` when processing repeated images or regions.

Notes:
Scale-normalized 2D Hessian line responses over finite scalar samples.
 The discrete Gaussian has support ceil(4*sigma), replicated source edges and
 a DC-corrected second derivative. Derivatives are multiplied by sigma².
 Sato uses the positive principal curvature; Frangi uses the 2D eigenvalue
 ratio and Hessian energy; Meijering mixes the two principal curvatures.
 Formula provenance: Sato et al. (1998), Frangi et al. (1998), Meijering et al.
 (2004). Unlike whole-image auto normalization, explicit gamma/responseScale
 permit the same contract on tiles, scientific measurements and full images.
+/
module imagery.analysis.hessian_lines;

import imagery.analysis.structure_tensor : kernel, pass, shifted,horizontalGaussian,eigenPair;
import std.algorithm : min,max;
import std.math : abs, atan2, ceil, exp, expm1, isFinite, PI, sqrt;

@safe:

/// Desired sign of normal curvature; both compares bright then dark responses.
enum LinePolarity {
    /++ Detect lines brighter than their surroundings. +/
    bright,
    /++ Detect lines darker than their surroundings. +/
    dark,
    /++ Detect both polarities; equal responses retain the first winner. +/
    both }
/// Formula family applied to the scale-normalized Hessian.
enum HessianLineVariant {
    /++ Use the Sato vessel/line response. +/
    sato,
    /++ Use the Frangi response with explicit beta and gamma. +/
    frangi,
    /++ Use the Meijering eigenvalue-mixing response. +/
    meijering }

/// Explicit, region-independent response parameters. .init is usable.
struct HessianLineParams
{
    /++
     Bright, dark or both line polarities; default is bright.
    +/
    LinePolarity polarity=LinePolarity.bright;
    /++
     Response formula; default is Sato.
    +/
    HessianLineVariant variant=HessianLineVariant.sato;
    /// Frangi blob sensitivity, finite and positive, dimensionless.
    double beta=0.5;
    /// Frangi structure sensitivity in the input sample's units, positive.
    double gamma=0.5;
    /// Meijering eigenvalue mixing in [-1,1]; default follows scikit-image 0.26.
    double alpha=1.0/3;
    /// Sato/Meijering divisor in input units. No per-region maximum is inferred.
    double responseScale=1;

    /++
     Validate this parameter value before allocating or evaluating image data.

     Throws:
     Exception if a field lies outside its documented range or selects an unknown enum value.
    +/
    void validate() const
    {
        if(cast(uint)polarity>LinePolarity.max || cast(uint)variant>HessianLineVariant.max ||
            !isFinite(beta) || beta<=0 || !isFinite(gamma) || gamma<=0 ||
            !isFinite(alpha) || alpha< -1 || alpha>1 || !isFinite(responseScale) || responseScale<=0)
            throw new Exception("Invalid Hessian line parameters");
    }
}

/// Prepare a multiscale line measurement with separate output and direction validity.
@safe unittest
{
    float[81] image=0;
    foreach(y;0..9) image[y*9+4]=1;
    double[2] sigmas=[1,2];
    HessianLineParams parameters;
    HessianLineWorkspace workspace;
    workspace.reserve(9,9,sigmas[]);
    float[81] strength,orientation,scale;
    ubyte[81] directionValid;
    hessianLineResponse(image[],9,9,sigmas[],parameters,workspace,
        strength[],orientation[],scale[],directionValid[]);
    assert(strength[40]>0 && directionValid[40]==1);
    assert(scale[40]==1 || scale[40]==2);
}


/++
 Validate a nonempty increasing list of pixel scales in [0.5,32]. Returns
   the source halo. All validation occurs before output or scratch writes.

 Params:
  sigmas = Nonempty strictly increasing Gaussian sigmas in pixels, each in [0.5,32].

 Returns:
 Required source halo in pixels, equal to ceil(4*largest sigma).

 Throws:
 Exception for Hessian scales are empty; Hessian scales must increase in [0.5,32].
+/
size_t hessianLineHalo(scope const(double)[] sigmas)
{
    if(!sigmas.length)throw new Exception("Hessian scales are empty");
    double previous=0;
    foreach(s;sigmas) {
        if(!isFinite(s) || s<0.5 || s>32 || s<=previous)
            throw new Exception("Hessian scales must increase in [0.5,32]");
        previous=s;
    }
    return cast(size_t)ceil(4*previous);
}

/// Reusable double scratch. The one-argument reserve(samples) retains four full planes;
/// shape-aware reserve uses three bounded strip working buffers. .init has no storage.
struct HessianLineWorkspace
{
    private double[][4] planes;
    private size_t shapeWidth,shapeHeight,maximumRadius;
    private size_t rowBlock=128,columnBlock=128;
    /++
     Reserve reusable Float64 working storage for Hessian line evaluation.

               The one-argument form retains four full sample planes. Use the shape-aware
               overload for bounded strips. A successful reservation must cover the shape
               and scale envelope passed to hessianLineResponse.

     Params:
      samples = Maximum number of source pixels for the full-plane form.

     Throws:
     Exception if the requested capacity overflows; allocation failures may propagate.
    +/
    void reserve(size_t samples)
    {
        if(samples>size_t.max/(4*double.sizeof))throw new Exception("Hessian scratch overflow");
        foreach(ref plane;planes)if(plane.length<samples)plane=new double[samples];
        shapeWidth=shapeHeight=maximumRadius=0;rowBlock=128;columnBlock=128;
    }

/++
     Reserve three strip result values for this shape and scale envelope.
               stripRows/stripWidth are in 1..256. The halo-inclusive owned payload is
               at most 3 MiB; a fixed 6 KiB row result value is separate stack storage.
               Allocation completes before replacing the previous workspace.

     Params:
      width = Image or grid width in pixels.
      height = Image or grid height in pixels.
      sigmas = Nonempty strictly increasing Gaussian sigmas in pixels, each in [0.5,32].
      stripRows = Working block height in pixels, within the parameter type’s documented bound.
      stripWidth = Working block width in pixels, within the parameter type’s documented bound.

     Throws:
     Exception for Invalid Hessian strip reservation.
    +/
    void reserve(size_t width,size_t height,scope const(double)[] sigmas,
        size_t stripRows=128,size_t stripWidth=128)
    {
        const radius=hessianLineHalo(sigmas);
        if(!width||!height||width>size_t.max/height||!stripRows||stripRows>256||!stripWidth||stripWidth>256)
            throw new Exception("Invalid Hessian strip reservation");
        const count=min(width,stripWidth)*min(height,stripRows+2*radius);
        double[][4] candidate;
        foreach(i;0..3)candidate[i]=planes[i].length==count?planes[i]:new double[count];
        planes=candidate;shapeWidth=width;shapeHeight=height;maximumRadius=radius;
        rowBlock=stripRows;columnBlock=stripWidth;
    }

/++
     Owned array payload, excluding caller input/output and stack/metadata.

     Returns:
     Logical reserved payload bytes, excluding allocator overhead and caller/provider storage.
    +/
    size_t storageBytes() const nothrow @nogc
    {size_t result;foreach(p;planes)result+=p.length*double.sizeof;return result;}
}

/// Shape-aware reservation does not retain four whole-image planes.
@safe unittest
{
    double[3] scales=[1,2,4];HessianLineWorkspace workspace;
    workspace.reserve(1024,1024,scales[]);
    assert(workspace.storageBytes==3*128*160*double.sizeof);
    workspace.reserve(1024,1024,scales[],32,128);
    assert(workspace.storageBytes==3*128*64*double.sizeof);
}

// Subtract paired centers before multiplying the symmetric second derivative.
// This is equivalent to correcting the kernel's DC sum and exactly annihilates
// a constant source without a threshold depending on measurement units.
private void secondPass(T)(scope const(T)[] src,size_t w,size_t h,double sigma,
    scope const(double)[] smooth,int radius,bool vertical,scope double[] dst) nothrow @nogc
{
    double[129] weights;
    foreach(tap;1..radius+1)
        weights[tap]=((tap/sigma)^^2-1)/(sigma*sigma)*smooth[radius+tap];
    if(vertical) {
        foreach(y;0..h) {
            auto target=dst[y*w..(y+1)*w];target[]=0;
            const centers=src[y*w..(y+1)*w];
            foreach(tap;1..radius+1) {
                const py=shifted(y,tap,h),my=shifted(y,-tap,h);
                const weight=weights[tap];
                const plus=src[py*w..(py+1)*w],minus=src[my*w..(my+1)*w];
                foreach(x;0..w) {
                    const center=cast(double)centers[x];
                    target[x]+=((cast(double)plus[x]-center)+(cast(double)minus[x]-center))*weight;
                }
            }
        }
        return;
    }
    foreach(y;0..h)foreach(x;0..w) {
        const center=cast(double)src[y*w+x];
        double value=0;
        foreach(tap;1..radius+1) {
            const plus=vertical?shifted(y,tap,h)*w+x:y*w+shifted(x,tap,w);
            const minus=vertical?shifted(y,-tap,h)*w+x:y*w+shifted(x,-tap,w);
            value+=((cast(double)src[plus]-center)+(cast(double)src[minus]-center))*weights[tap];
        }
        dst[y*w+x]=value;
    }
}

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
            foreach(sigma;[.5,2.0,4.0]) {
                const g=kernel(sigma,4);
                secondPass(src,w,h,sigma,g.smooth[],g.radius,true,actual);
                secondPass(transposed,h,w,sigma,g.smooth[],g.radius,false,expected);
                foreach(y;0..h)foreach(x;0..w) {
                    const a=actual[y*w+x],b=expected[x*h+y];
                    assert(a==b&&(a!=0||signbit(a)==signbit(b)));
                }
            }
        }
    }
}

private double response(double positive,double negative,HessianLineParams p,
    out bool usePositive) nothrow @nogc
{
    usePositive=true;
    final switch(p.variant)
    {
        case HessianLineVariant.sato:
            return positive>0?positive/p.responseScale:0;
        case HessianLineVariant.frangi:
            const strongest=abs(positive)>=abs(negative)?positive:negative;
            const weakest=abs(positive)>=abs(negative)?negative:positive;
            if(strongest<=0)return 0;
            const ratio=abs(weakest)/strongest;
            const norm=sqrt(positive*positive+negative*negative);
            return exp(-0.5*(ratio/p.beta)^^2)*(-expm1(-0.5*(norm/p.gamma)^^2));
        case HessianLineVariant.meijering:
            const a=positive+p.alpha*negative, b=negative+p.alpha*positive;
            usePositive=abs(a)>=abs(b);
            const mixed=usePositive?a:b;
            return mixed>0?mixed/p.responseScale:0;
    }
}


private void publishHessian(double a,double b,double c,double middle,double gap,double sigma,
    HessianLineParams params,size_t i,scope float[] strength,scope float[] orientation,
    scope float[] scale,scope ubyte[] orientationValid) nothrow @nogc
{
    const first=params.polarity==LinePolarity.dark?1:-1;
    const signs=params.polarity==LinePolarity.both?2:1;
    foreach(choice;0..signs) {
        const sign=choice==0?first:-first;bool principal;
        const visible=cast(float)response(sign*middle+gap,sign*middle-gap,params,principal);
        if(visible<=0||visible<=strength[i])continue;
        strength[i]=visible;scale[i]=cast(float)sigma;
        const resolved=gap>32*double.epsilon*(abs(a)+abs(c)+2*abs(b));
        orientationValid[i]=cast(ubyte)resolved;
        double tangent=.5*atan2(2*sign*b,sign*(a-c))+(principal?PI/2:0);
        if(tangent<0)tangent+=PI;
        if(tangent>=PI)tangent-=PI;
        orientation[i]=resolved?cast(float)tangent:0;
    }
}

/++
 Find thin bright or dark lines at explicit Gaussian scales.

  Use this for vessel-like or elongated image structures; scale is Gaussian
  sigma in pixels, not a universal line-width estimate. Choose Sato, Frangi or
  Meijering with params. The largest response wins; exact ties retain the first
  scale/polarity at output precision, with bright before dark. Zero response
  yields zero scale/angle and invalid orientation; isotropic positive responses
  also have invalid orientation. Mathematical tangent angles are normalized
  from zero inclusive to pi exclusive, then rounded to float32 radians.
  Replicate image edges. To process an interior ROI, supply the
  halo returned by hessianLineHalo and crop the result to the requested core.

  Float64 arithmetic produces float32 outputs. A finite working result can
  overflow float32; rescale large input units when needed. Source, output planes
  and working storage must not overlap. Parameter, shape, source-finiteness and
  reservation validation precede output writes. Evaluation allocates no storage.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  sigmas = Nonempty strictly increasing Gaussian sigmas in pixels, each in [0.5,32].
  params = Numerical settings; see the parameter type for units and ranges.
  scratch = Reusable working storage prepared for this shape and scale envelope; contents may be overwritten.
  strength = Preallocated row-major float32 line response, at least w*h entries.
  orientation = Preallocated row-major float32 axial angles in radians, meaningful only where orientationValid is one.
  scale = Preallocated row-major float32 winning Gaussian sigma in pixels.
  orientationValid = Preallocated one-byte-per-pixel direction mask; zero means direction is undefined.

 Throws:
 Exception for invalid parameters/scales, nonfinite input, insufficient
  output capacity or an incompatible working-storage reservation.
+/
void hessianLineResponse(scope const(float)[] src,size_t w,size_t h,
    scope const(double)[] sigmas,HessianLineParams params,ref HessianLineWorkspace scratch,
    scope float[] strength,scope float[] orientation,scope float[] scale,
    scope ubyte[] orientationValid)
{
    version(ImageryGaussianReference) {
        hessianLineReference(src,w,h,sigmas,params,scratch,strength,orientation,scale,orientationValid);return;
    }
    params.validate();const halo=hessianLineHalo(sigmas);
    if(!w||!h||w>size_t.max/h||src.length!=w*h||strength.length<w*h||
        orientation.length<w*h||scale.length<w*h||orientationValid.length<w*h)
        throw new Exception("Invalid Hessian plane shape or destination");
    foreach(v;src)if(!isFinite(v))throw new Exception("Nonfinite Hessian input");
    if(scratch.shapeWidth) {
        if(w>scratch.shapeWidth||h>scratch.shapeHeight||halo>scratch.maximumRadius)
            throw new Exception("Hessian shape/scales exceed strip reservation");
    } else foreach(p;scratch.planes)if(p.length<w*h)throw new Exception("Reserve Hessian workspace first");
    strength[0..w*h]=0;orientation[0..w*h]=0;scale[0..w*h]=0;orientationValid[0..w*h]=0;
    double[3*256] rowStorage;
    foreach(sigma;sigmas) {
        const g=kernel(sigma,4);const radius=cast(size_t)g.radius;
        double[129] secondWeights;
        foreach(tap;1..g.radius+1)
            secondWeights[tap]=((tap/sigma)^^2-1)/(sigma*sigma)*g.smooth[g.radius+tap];
        for(size_t y0=0;y0<h;y0+=scratch.rowBlock) {
            const rows=min(scratch.rowBlock,h-y0),first=y0-min(y0,radius);
            const last=y0+rows+min(radius,h-y0-rows),sourceRows=last-first;
            for(size_t x0=0;x0<w;x0+=scratch.columnBlock) {
                const width=min(scratch.columnBlock,w-x0),count=width*sourceRows;
                auto horizontalSecond=scratch.planes[0][0..count];
                auto horizontalSmooth=scratch.planes[1][0..count];
                auto horizontalDerivative=scratch.planes[2][0..count];
                foreach(y;first..last) {
                    const offset=(y-first)*width;
                    horizontalGaussian!(float,true,true)(src,w,y,x0,width,g,
                        horizontalSmooth[offset..offset+width],horizontalDerivative[offset..offset+width],
                        secondWeights[],horizontalSecond[offset..offset+width]);
                }
                auto xx=rowStorage[0..width],xy=rowStorage[256..256+width],yy=rowStorage[512..512+width];
                foreach(y;y0..y0+rows) {
                    xx[]=0;xy[]=0;yy[]=0;
                    foreach(tap;0..2*g.radius+1) {
                        const row=(shifted(y,tap-g.radius,h)-first)*width;
                        const input=horizontalSecond[row..row+width],weight=g.smooth[tap];
                        foreach(x;0..width)xx[x]+=input[x]*weight;
                    }
                    const center=(y-first)*width;
                    foreach(tap;1..g.radius+1) {
                        const plus=(shifted(y,tap,h)-first)*width,minus=(shifted(y,-tap,h)-first)*width;
                        const dw=g.derivative[g.radius+tap],sw=secondWeights[tap];
                        foreach(x;0..width) {
                            const c=horizontalSmooth[center+x];
                            yy[x]+=((horizontalSmooth[plus+x]-c)+(horizontalSmooth[minus+x]-c))*sw;
                            xy[x]+=(horizontalDerivative[plus+x]-horizontalDerivative[minus+x])*dw;
                        }
                    }
                    size_t x;
                    for(;x+1<width;x+=2) {
                        const a0=xx[x]*sigma*sigma,a1=xx[x+1]*sigma*sigma;
                        const b0=xy[x]*sigma*sigma,b1=xy[x+1]*sigma*sigma;
                        const c0=yy[x]*sigma*sigma,c1=yy[x+1]*sigma*sigma;
                        double m0,m1,g0,g1;eigenPair!true(a0,a1,b0,b1,c0,c1,m0,m1,g0,g1);
                        publishHessian(a0,b0,c0,m0,g0,sigma,params,y*w+x0+x,strength,orientation,scale,orientationValid);
                        publishHessian(a1,b1,c1,m1,g1,sigma,params,y*w+x0+x+1,strength,orientation,scale,orientationValid);
                    }
                    if(x<width) {
                        const a=xx[x]*sigma*sigma,b=xy[x]*sigma*sigma,c=yy[x]*sigma*sigma;
                        publishHessian(a,b,c,.5*(a+c),sqrt((.5*(a-c))^^2+b*b),sigma,params,
                            y*w+x0+x,strength,orientation,scale,orientationValid);
                    }
                }
            }
        }
    }
}

/// A constant image has zero curvature for every scale and formula.
unittest
{
    float[49] source=17;
    float[49] strength,angle,scale;
    ubyte[49] valid;
    double[3] sigmas=[0.5,1.25,32];
    HessianLineWorkspace scratch;scratch.reserve(source.length);
    foreach(variant;[HessianLineVariant.sato,HessianLineVariant.frangi,HessianLineVariant.meijering]) {
        HessianLineParams params;params.variant=variant;
        hessianLineResponse(source[],7,7,sigmas[],params,scratch,
            strength[],angle[],scale[],valid[]);
        foreach(i;0..49)assert(strength[i]==0 && scale[i]==0 && !valid[i]);
    }
}

version(unittest) private enum keepHessianReference=true;
else version(ImageryGaussianReference) private enum keepHessianReference=true;
else private enum keepHessianReference=false;
static if(keepHessianReference)
private void hessianLineReference(scope const(float)[] src,size_t w,size_t h,
    scope const(double)[] sigmas,HessianLineParams params,ref HessianLineWorkspace scratch,
    scope float[] strength,scope float[] orientation,scope float[] scale,
    scope ubyte[] orientationValid)
{
    params.validate();hessianLineHalo(sigmas);
    if(!w || !h || w>size_t.max/h || src.length!=w*h ||
        strength.length<w*h || orientation.length<w*h || scale.length<w*h || orientationValid.length<w*h)
        throw new Exception("Invalid Hessian plane shape or destination");
    foreach(v;src)if(!isFinite(v))throw new Exception("Nonfinite Hessian input");
    foreach(p;scratch.planes)if(p.length<w*h)throw new Exception("Reserve Hessian workspace first");
    strength[0..w*h]=0;orientation[0..w*h]=0;scale[0..w*h]=0;orientationValid[0..w*h]=0;
    auto tmp=scratch.planes[0][0..w*h], xx=scratch.planes[1][0..w*h];
    auto xy=scratch.planes[2][0..w*h], yy=scratch.planes[3][0..w*h];
    foreach(sigma;sigmas)
    {
        const g=kernel(sigma,4);
        secondPass(src,w,h,sigma,g.smooth[],g.radius,false,tmp);
        pass(tmp,w,h,g.smooth[],g.radius,true,xx);
        pass(src,w,h,g.smooth[],g.radius,false,tmp);
        secondPass(tmp,w,h,sigma,g.smooth[],g.radius,true,yy);
        pass(src,w,h,g.derivative[],g.radius,false,tmp,true);
        pass(tmp,w,h,g.derivative[],g.radius,true,xy,true);
        foreach(i;0..w*h)
        {
            const a=xx[i]*sigma*sigma, b=xy[i]*sigma*sigma, c=yy[i]*sigma*sigma;
            const middle=0.5*(a+c), gap=sqrt((0.5*(a-c))^^2+b*b);
            const first=params.polarity==LinePolarity.dark?1:-1;
            const signs=params.polarity==LinePolarity.both?2:1;
            foreach(choice;0..signs)
            {
                const sign=choice==0?first:-first;
                bool principal;
                const candidate=response(sign*middle+gap,sign*middle-gap,params,principal);
                const visible=cast(float)candidate;
                if(visible<=0 || visible<=strength[i])continue;
                strength[i]=visible;scale[i]=cast(float)sigma;
                const resolved=gap>32*double.epsilon*(abs(a)+abs(c)+2*abs(b));
                orientationValid[i]=cast(ubyte)resolved;
                double tangent=0.5*atan2(2*sign*b,sign*(a-c))+(principal?PI/2:0);
                if(tangent<0)tangent+=PI;
                if(tangent>=PI)tangent-=PI;
                orientation[i]=resolved?cast(float)tangent:0;
            }
        }
    }
}

// Exact legacy-scalar twin, independent of the fused pass layout and vector
// geometry. Validate every formula/polarity, odd/narrow shapes and tile edges.
@safe unittest
{
    import core.memory : GC;
    import std.math : signbit;
    import std.exception : assertThrown;
    foreach(shape;[[19UL,13UL],[1UL,5UL],[5UL,1UL],[1UL,1UL]])foreach(base;[0.0,1e12]) {
        const w=shape[0],h=shape[1],n=w*h;
        auto input=new float[n];
        foreach(i,ref v;input)v=cast(float)(base+(i*37+i/w*17)%256*(base==0?.03125:1048576.0));
        input[0]=-0.0f;double[3] scales=[.5,1.25,4];
        HessianLineWorkspace reference;reference.reserve(n);
        float[][3] expected,actual;foreach(ref p;expected)p=new float[n];foreach(ref p;actual)p=new float[n];
        auto ev=new ubyte[n],av=new ubyte[n];
        foreach(variant;[HessianLineVariant.sato,HessianLineVariant.frangi,HessianLineVariant.meijering])
            foreach(polarity;[LinePolarity.bright,LinePolarity.dark,LinePolarity.both]) {
            auto params=HessianLineParams(polarity,variant);
            hessianLineReference(input,w,h,scales[],params,reference,expected[0],expected[1],expected[2],ev);
            foreach(block;[[3UL,5UL],[32UL,128UL]]) {
                HessianLineWorkspace work;work.reserve(w,h,scales[],block[0],block[1]);
                const before=GC.stats().allocatedInCurrentThread;
                hessianLineResponse(input,w,h,scales[],params,work,actual[0],actual[1],actual[2],av);
                assert(GC.stats().allocatedInCurrentThread==before&&av==ev);
                foreach(c;0..3)foreach(i,v;actual[c])assert(v==expected[c][i]&&
                    (v!=0||signbit(v)==signbit(expected[c][i])));
            }
        }
        HessianLineWorkspace small;double[1] tiny=[.5];small.reserve(w,h,tiny[]);
        actual[0][]=17;
        assertThrown!Exception(hessianLineResponse(input,w,h,scales[],HessianLineParams.init,small,
            actual[0],actual[1],actual[2],av));
        foreach(v;actual[0])assert(v==17);
    }
}
