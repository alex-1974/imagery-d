/++ Scale-normalized 2D Hessian line responses over finite scalar samples.
 The discrete Gaussian has support ceil(4*sigma), replicated source edges and
 a DC-corrected second derivative. Derivatives are multiplied by sigma².
 Sato uses the positive principal curvature; Frangi uses the 2D eigenvalue
 ratio and Hessian energy; Meijering mixes the two principal curvatures.
 Formula provenance: Sato et al. (1998), Frangi et al. (1998), Meijering et al.
 (2004). Unlike whole-image auto normalization, explicit gamma/responseScale
 permit the same contract on tiles, scientific measurements and full images.
+/
module imagery.analysis.hessian_lines;

import imagery.analysis.structure_tensor : kernel, pass, shifted;
import std.math : abs, atan2, ceil, exp, expm1, isFinite, PI, sqrt;

@safe:

/// Desired sign of normal curvature; both compares bright then dark responses.
enum LinePolarity { bright, dark, both }
/// Formula family applied to the scale-normalized Hessian.
enum HessianLineVariant { sato, frangi, meijering }

/// Explicit, region-independent response parameters. .init is usable.
struct HessianLineParams
{
    LinePolarity polarity=LinePolarity.bright;
    HessianLineVariant variant=HessianLineVariant.sato;
    /// Frangi blob sensitivity, finite and positive, dimensionless.
    double beta=0.5;
    /// Frangi structure sensitivity in the input sample's units, positive.
    double gamma=0.5;
    /// Meijering eigenvalue mixing in [-1,1]; default follows scikit-image 0.26.
    double alpha=1.0/3;
    /// Sato/Meijering divisor in input units. No per-region maximum is inferred.
    double responseScale=1;

    void validate() const
    {
        if(cast(uint)polarity>LinePolarity.max || cast(uint)variant>HessianLineVariant.max ||
            !isFinite(beta) || beta<=0 || !isFinite(gamma) || gamma<=0 ||
            !isFinite(alpha) || alpha< -1 || alpha>1 || !isFinite(responseScale) || responseScale<=0)
            throw new Exception("Invalid Hessian line parameters");
    }
}

/// Validate a nonempty increasing list of pixel scales in [0.5,32]. Returns
/// the source halo. All validation occurs before output or scratch writes.
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

/// Four reusable double planes. .init has no storage; reserve before use.
struct HessianLineWorkspace
{
    private double[][4] planes;
    void reserve(size_t samples)
    {
        if(samples>size_t.max/(4*double.sizeof))throw new Exception("Hessian scratch overflow");
        foreach(ref plane;planes)if(plane.length<samples)plane=new double[samples];
    }
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

/// Write maximum response, tangent angle modulo pi, winning sigma, and
/// orientation validity into disjoint caller-owned float32/byte planes.
/// Outputs and scratch must be disjoint. Nonfinite input, malformed buffers,
/// invalid parameters or unreserved scratch throw before output writes.
/// Ties at output precision retain the first scale (and bright before dark). Zero response yields
/// zero scale/angle and invalid orientation. Isotropic positive responses also
/// have invalid orientation. Float32 response can overflow on extreme finite
/// samples; input rescaling is explicit. No evaluation allocation is performed.
/// To process an ROI, supply its source halo and publish only the ROI interior.
void hessianLineResponse(scope const(float)[] src,size_t w,size_t h,
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
