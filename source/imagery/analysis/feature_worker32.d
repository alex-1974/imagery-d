/++ Prepared scalar-image feature evaluation with float32 output planes.
 Input windows are borrowed from raster-d's scoped data-plane API. The caller
 supplies the complete halo, including its chosen source-edge extension.
 Default preparation reads/computes float64; source storage may be float32 or
 float64. prepareGaussian32 explicitly selects approximate float32 Gaussian
 arithmetic on clean normalized support. Conversion to float32 is explicit.
 This opt-in API does not change Engine's float64
 cache/output contract. RGB callers supply color-d-derived linear luminance.
+/
module imagery.analysis.feature_worker32;

public import imagery.analysis.feature_regions : Feature;
import imagery.analysis.feature_regions : Sample, Point, Value,
    describeTileKernel, evaluate, usesLocalMoments, fromLocalMoments;
public import imagery.analysis.feature_parameters;
import imagery.analysis.feature_contracts : fixedParameters;
import imagery.analysis.feature_structure : StructuralOptions, prepareGabor,
    GaborMember, squareMorphologyRadius, evaluateSquareMorphologyInto;
import imagery.analysis.window_kernels : WindowMoments, evaluateWindows;
import imagery.analysis.path_kernels : PathWorkspace, evaluatePathsInto;
import imagery.analysis.feature_output32 : PlaneOutput = Float32TileOutput;
import imagery.analysis.row_kernels : RowKernelScratch,basicRowFeature,structuralRowFeature;
import raster.data_plane : RasterPlaneWindow;
import raster.region : Region2D;
import std.algorithm : min, max;
import std.math : isFinite, sqrt, ceil;

@safe:

/// Declared numeric meaning; .init is the raw scalar domain. Luminance-only
/// families require linearLuminance. Gaussian32 requires a dimensionless domain.
enum FeaturePlaneDomain : ubyte {
    /// Raw measurements in caller-selected units; default strict arithmetic.
    scalar,
    /// Dimensionless linear luminance, required to remain in [0,1].
    linearLuminance,
    /// Dimensionless scalar normalized to characteristic scale 1. Nominal
    /// [0,1] values admit explicitly selected unit-domain arithmetic; outliers
    /// keep the complete strict fallback. This is not arbitrary raw units.
    normalizedScalar
}

/// Luminance-specific heuristics require an explicit luminance working domain.
unittest
{
    Float32FeatureWorker worker;
    worker.prepare(Feature.shadowCandidate,32,32,FeaturePlaneDomain.linearLuminance);
    assert(worker.halo==3);
}

/// `.init` is not success. Evaluation reports errors before changing published
/// buffers. Individual missing/unrepresentable samples use the result masks.
enum FeatureWorkerError : ubyte
{
    notAttempted, none, notPrepared, invalidRegion, invalidMask, invalidLuminance
}

/// An empty worker reports a detectable failure and initializes the out result.
unittest
{
    Float32FeatureWorker worker;
    RasterPlaneWindow!double empty;
    FeaturePlanes32 result;
    assert(worker.tryEvaluate(empty,Region2D(0,0,1,1),result)==FeatureWorkerError.notPrepared);
    assert(result.validity.length==0 && FeatureWorkerError.init!=FeatureWorkerError.none);
}

/// Borrowed SoA result, valid until the worker's next successful evaluation or
/// prepare. `.init` is empty, not success. Invalid sample channels are zero.
/// A finite double result whose float conversion is nonfinite has validity=0
/// and rangeFailure=1. Underflow to zero is normal float32 quantization;
/// orientationValid is cleared when strength rounds to zero. Ignore direction
/// whenever its mask is zero. Input must not alias these worker-owned buffers.
struct FeaturePlanes32
{
    /// Row-major output dimensions; channels are indexed y*width+x.
    size_t width, height;
    /// The descriptor's three numeric channels, separately stored as float32.
    const(float)[][3] channels;
    /// One for valid, representable samples; zero otherwise.
    const(ubyte)[] validity;
    /// One for a defined direction with nonzero float32 strength.
    const(ubyte)[] orientationValid;
    /// One for a valid mathematical result lost to float32 overflow.
    const(ubyte)[] rangeFailure;
    /// Input sample size, 4 or 8 bytes, for the selected working-plane type.
    size_t inputSampleBytes;
}

/// Empty results are detectable without guessing from a numeric channel.
unittest
{
    FeaturePlanes32 result;
    assert(result.width==0 && result.channels[0].length==0 && result.validity.length==0);
}

private struct Settings
{
    LocalStatisticsParams statistics;
    PathMorphologyParams paths;
    RidgeParams ridge;
    LineResponseParams line;
    GaborParams gabor;
    double shadowCeiling=.15;
    bool gaussian32;
}

private struct PlaneReader(T)
{
    const RasterPlaneWindow!T input;
    const(ubyte)[] finite;
    size_t left,top,stride;
    int x,y;
    this(return scope const RasterPlaneWindow!T input,return scope const(ubyte)[] finite,
        size_t left,size_t top,size_t stride,int x,int y) nothrow @nogc
    {
        this.input=input;this.finite=finite;this.left=left;this.top=top;
        this.stride=stride;this.x=x;this.y=y;
    }
    Point opCall(int dx,int dy) const scope nothrow @nogc
    {
        const sx=cast(size_t)(x+dx),sy=cast(size_t)(y+dy);
        if(!finite[sy*stride+sx])return Point.init;
        return Point(cast(double)input.load(left+sx,top+sy),true);
    }
}

/// Noncopyable, serial worker with explicitly prepared capacity. `.init` is
/// unprepared. prepare allocates once for a selected family and capacities
/// 1..256 per axis; successful evaluation is @nogc/nothrow and reuses scratch.
/// Inputs must stay stable during the call and must not alias worker outputs.
/// Supports tile features except encoded-RGB-only oklab/clipping/underexposure/
/// visibility and dedicated global/fitted/CLAHE operations. Other RGB-only
/// descriptors accept an explicitly prepared linear-luminance working plane.
struct Float32FeatureWorker
{
    @disable this(this);
    private bool ready;
    private Feature selected;
    private FeaturePlaneDomain domain;
    private size_t maxWidth,maxHeight,requiredHalo;
    private Settings settings;
    private StructuralOptions shapes;
    private string parameterText;
    private float[][3] planes;
    private ubyte[] valid,oriented,range,finite;
    private double[] pathValues;
    private WindowMoments[] moments;
    private Point[] morphologyRows,morphologyIntermediate;
    private PathWorkspace path;
    private RowKernelScratch rows;
    private int morphologyRadius;

    /// Prepare default parameters. Invalid settings throw Exception without
    /// replacing the preceding prepared state or its published buffers.
    void prepare(Feature feature,size_t width,size_t height,
        FeaturePlaneDomain inputDomain=FeaturePlaneDomain.scalar)
    { configure(feature,width,height,inputDomain,Settings.init); }

    /// Explicit approximate Gaussian 3x3: separable float32 on entirely valid
    /// normalized [0,1] support, absolute strength error <=3*float.epsilon
    /// against the strict float64 kernel. Requires dimensionless normalizedScalar
    /// or linearLuminance; raw-unit scalar is rejected at setup. Missing,
    /// signed-zero and wider normalized-scalar
    /// supports retain the complete strict fallback. The default prepare
    /// remains strict. inputDomain may additionally require linear luminance.
    /// Parameters record this distinct arithmetic policy. Setup/failure and
    /// borrowing rules are the same as prepare; evaluation stays @nogc/nothrow.
    void prepareGaussian32(size_t width,size_t height,
        FeaturePlaneDomain inputDomain=FeaturePlaneDomain.normalizedScalar)
    {
        if(inputDomain==FeaturePlaneDomain.scalar)
            throw new Exception("Gaussian32 requires an explicitly dimensionless working domain");
        Settings s;s.gaussian32=true;configure(Feature.gaussian,width,height,inputDomain,s);
    }

    /// A caller explicitly chooses float32 Gaussian arithmetic.
    @safe unittest
    {
        import imagery.analysis.feature_regions : describeTileFeature;
        import std.exception : assertThrown;
        Float32FeatureWorker worker;worker.prepareGaussian32(width:16,height:8);
        assert(worker.halo==1&&worker.parameters!=describeTileFeature(Feature.gaussian).parameters);
        assert(worker.scratchBytes<8*1024*1024);
        const prior=worker.parameters;
        assertThrown(worker.prepareGaussian32(8,8,FeaturePlaneDomain.scalar));
        assert(worker.parameters==prior);
    }

    /// Prepare a variable local window for statistics/range/normalization/darkness.
    void prepare(Feature feature,size_t width,size_t height,LocalStatisticsParams parameters,
        FeaturePlaneDomain inputDomain=FeaturePlaneDomain.scalar)
    {
        parameters.validate();
        if(!isLocal(feature))throw new Exception("Feature does not use local parameters");
        Settings s;s.statistics=parameters;configure(feature,width,height,inputDomain,s);
    }

    /// Prepare variable path length and lateral step.
    void prepare(Feature feature,size_t width,size_t height,PathMorphologyParams parameters,
        FeaturePlaneDomain inputDomain=FeaturePlaneDomain.scalar)
    {
        parameters.validate();
        if(!isPath(feature))throw new Exception("Feature does not use path parameters");
        Settings s;s.paths=parameters;configure(feature,width,height,inputDomain,s);
    }

    /// Prepare across-line ridge radii.
    void prepare(Feature feature,size_t width,size_t height,RidgeParams parameters,
        FeaturePlaneDomain inputDomain=FeaturePlaneDomain.scalar)
    {
        parameters.validate();
        if(feature!=Feature.ridge)throw new Exception("Feature does not use ridge parameters");
        Settings s;s.ridge=parameters;configure(feature,width,height,inputDomain,s);
    }

    /// Prepare independent across-line and tangent support.
    void prepare(Feature feature,size_t width,size_t height,LineResponseParams parameters,
        FeaturePlaneDomain inputDomain=FeaturePlaneDomain.scalar)
    {
        parameters.validate();
        if(feature!=Feature.lineResponse)throw new Exception("Feature does not use line parameters");
        Settings s;s.line=parameters;configure(feature,width,height,inputDomain,s);
    }

    /// Prepare Gabor weights once, shared by every subsequent tile evaluation.
    void prepare(Feature feature,size_t width,size_t height,GaborParams parameters,
        FeaturePlaneDomain inputDomain=FeaturePlaneDomain.scalar)
    {
        parameters.validate();
        if(!isGabor(feature))throw new Exception("Feature does not use Gabor parameters");
        Settings s;s.gabor=parameters;configure(feature,width,height,inputDomain,s);
    }

    /// Prepare shadow window and dimensionless linear-luminance ceiling.
    void prepare(Feature feature,size_t width,size_t height,ShadowParams parameters,
        FeaturePlaneDomain inputDomain=FeaturePlaneDomain.linearLuminance)
    {
        parameters.validate();
        if(feature!=Feature.shadowCandidate)throw new Exception("Feature does not use shadow parameters");
        Settings s;s.statistics=parameters.window;s.shadowCeiling=parameters.luminanceCeiling;
        configure(feature,width,height,inputDomain,s);
    }

    /// Required input halo on each side of the output ROI, in working pixels.
    @property size_t halo() const nothrow @nogc { return requiredHalo; }
    /// Selected feature, meaningful after successful preparation.
    @property Feature feature() const nothrow @nogc { return selected; }
    /// Parameter identity matching the float64 engine; storage is explicitly
    /// float32 through this worker/result type. No source-data cache is owned.
    @property string parameters() const nothrow @nogc { return parameterText; }
    /// Retained output/mask/work-array payload, excluding metadata, worker and
    /// allocator overhead and the shared default Gabor table.
    @property size_t scratchBytes() const nothrow @nogc
    {
        size_t bytes=finite.length+valid.length+oriented.length+range.length+
            pathValues.length*double.sizeof+moments.length*WindowMoments.sizeof+
            (morphologyRows.length+morphologyIntermediate.length)*Point.sizeof+path.bytes+rows.bytes;
        foreach(p;planes)bytes+=p.length*float.sizeof;
        bytes+=shapes.gabor.length*GaborMember.sizeof;
        foreach(ref member;shapes.gabor)
            bytes+=(member.realWeights.length+member.imaginaryWeights.length)*double.sizeof;
        return bytes;
    }

    private static bool isLocal(Feature f) nothrow @nogc {
        return f==Feature.localStatistics || f==Feature.localNormalization ||
            f==Feature.dynamicRange || f==Feature.relativeDarkness || f==Feature.shadowCandidate;
    }
    private static bool isPath(Feature f) nothrow @nogc {return f==Feature.pathOpening || f==Feature.pathClosing;}
    private static bool isGabor(Feature f) nothrow @nogc {
        return f==Feature.gabor || (f>=Feature.gaborFine0 && f<=Feature.gaborCoarse135);
    }

    private void configure(Feature f,size_t width,size_t height,FeaturePlaneDomain inputDomain,Settings s)
    {
        if(!width || !height || width>256 || height>256 || inputDomain>FeaturePlaneDomain.max ||
            cast(size_t)f>cast(size_t)Feature.max)
            throw new Exception("Invalid feature worker capacity or domain");
        if(f==Feature.oklab || f==Feature.clipping || f==Feature.underexposure || f==Feature.visibility ||
            f==Feature.distribution || f==Feature.normalizedLuminance || f==Feature.exposureMatched || f==Feature.clahe)
            throw new Exception("Feature needs its encoded-RGB or dedicated interface");
        const descriptor=describeTileKernel(f);
        if(descriptor.rgbOnly && inputDomain!=FeaturePlaneDomain.linearLuminance)
            throw new Exception("Feature requires a linear-luminance working plane");
        Float32FeatureWorker candidate;
        candidate.selected=f;candidate.domain=inputDomain;candidate.maxWidth=width;candidate.maxHeight=height;
        candidate.settings=s;candidate.shapes.ridge=s.ridge;candidate.shapes.line=s.line;
        size_t halo=descriptor.halo;
        if(isLocal(f))halo=s.statistics.radius;
        else if(isPath(f))halo=(s.paths.length-1)*max(1u,s.paths.lateralStep);
        else if(f==Feature.ridge)halo=s.ridge.lastRadius;
        else if(f==Feature.lineResponse)halo=s.line.across.lastRadius+s.line.alongRadius;
        else if(isGabor(f)) {
            const index=f==Feature.gabor?1:(f-Feature.gaborFine0)/4;
            halo=cast(size_t)ceil(s.gabor.wavelengths[index]*s.gabor.supportRatio);
            if(s.gabor!=GaborParams.init)candidate.shapes.gabor=prepareGabor(s.gabor);
        }
        candidate.requiredHalo=halo;
        const area=width*height,wide=width+2*halo,tall=height+2*halo;
        foreach(ref p;candidate.planes)p=new float[area];
        candidate.valid=new ubyte[area];candidate.oriented=new ubyte[area];candidate.range=new ubyte[area];
        candidate.finite=new ubyte[wide*tall];
        if(basicRowFeature(f))candidate.rows.reserve(width,height,1,0,f==Feature.median||s.gaussian32,s.gaussian32);
        else if(structuralRowFeature(f))candidate.rows.reserve(width,height,halo,4);
        if(isLocal(f))candidate.moments=new WindowMoments[(height+2*s.statistics.radius)*width];
        candidate.morphologyRadius=squareMorphologyRadius(f);
        if(candidate.morphologyRadius) {
            const r=candidate.morphologyRadius;
            candidate.morphologyRows=new Point[(width+2*r)*(height+4*r)];
            candidate.morphologyIntermediate=new Point[(width+2*r)*(height+2*r)];
        }
        if(isPath(f) && s.paths.length>1) {
            candidate.path.reserve(wide*tall,area);candidate.pathValues=new double[area];
        }
        candidate.parameterText=parameterIdentity(f,s);
        candidate.ready=true;
        import std.algorithm.mutation : move;
        move(candidate,this);
    }

    private static string parameterIdentity(Feature f,Settings s)
    {
        import std.format : format;
        if(f==Feature.gaussian&&s.gaussian32)
            return "kernel=binomial-3x3;arithmetic=float32-separable;clean-support=finite-valid-unit;absolute-error=3*float32-epsilon;fallback=strict-float64;border=clamp";
        if(isLocal(f) && (s.statistics!=LocalStatisticsParams.init || (f==Feature.shadowCandidate && s.shadowCeiling!=.15)))
            return format!"radius=%s;minimum-valid=%s;variance=population;border=clamp;windows=centered-welford-monotone-v2"(
                s.statistics.radius,s.statistics.minimumValid)~
                (f==Feature.shadowCandidate?format!";luminance-ceiling=%.17g"(s.shadowCeiling):"");
        if(isPath(f) && s.paths!=PathMorphologyParams.init)
            return format!"element=axis-monotonic-path;length=%s;lateral-step=%s;border=clamp"(s.paths.length,s.paths.lateralStep);
        if(f==Feature.ridge && s.ridge!=RidgeParams.init)
            return format!"radii=%s..%s;angles-deg=0,45,90,135;along=1;across=opposite-radius;aggregate=max-positive;ties=first-radius-angle;border=clamp"(
                s.ridge.firstRadius,s.ridge.lastRadius);
        if(f==Feature.lineResponse && s.line!=LineResponseParams.init)
            return format!"radii=%s..%s;angles-deg=0,45,90,135;along=%s;across=opposite-radius;along-reduce=min;aggregate=max-positive;ties=first-radius-angle;border=clamp"(
                s.line.across.firstRadius,s.line.across.lastRadius,2*s.line.alongRadius+1);
        if(isGabor(f) && s.gabor!=GaborParams.init)
            return format!"wavelengths=%.17g,%.17g;angles-rad=%.17g,%.17g,%.17g,%.17g;sigma-ratio=%.17g;support-ratio=%.17g;aggregate=max;ties=first-wavelength-angle;border=clamp"(
                s.gabor.wavelengths[0],s.gabor.wavelengths[1],s.gabor.angles[0],s.gabor.angles[1],
                s.gabor.angles[2],s.gabor.angles[3],s.gabor.sigmaRatio,s.gabor.supportRatio);
        return fixedParameters(f);
    }

    /// Evaluate inside raster-d withPlane callbacks. core is relative to the
    /// borrowed window, with halo pixels already present on every side. Input
    /// may have signed row/sample strides. Optional mask has identical window
    /// dimensions and nonzero=valid. Nonfinite samples become unavailable.
    /// Finite linear-luminance samples outside [0,1] report invalidLuminance.
    /// On failure result is reset to .init (D out semantics), while preceding
    /// published buffers stay unchanged. Successful calls allocate nothing.
    FeatureWorkerError tryEvaluate(T)(scope ref const RasterPlaneWindow!T input,
        Region2D core,out FeaturePlanes32 result,
        scope const RasterPlaneWindow!ubyte mask=RasterPlaneWindow!ubyte.init) nothrow @nogc
    if(is(T==float) || is(T==double))
    {
        if(!ready)return FeatureWorkerError.notPrepared;
        if(core.empty || core.width>maxWidth || core.height>maxHeight ||
            core.x>input.width || core.y>input.height || core.width>input.width-core.x || core.height>input.height-core.y ||
            core.x<requiredHalo || core.y<requiredHalo ||
            input.width-core.x-core.width<requiredHalo || input.height-core.y-core.height<requiredHalo)
            return FeatureWorkerError.invalidRegion;
        if(mask.width || mask.height) {
            if(mask.width!=input.width || mask.height!=input.height)return FeatureWorkerError.invalidMask;
            return evaluateTile!(T,true)(input,core,result,mask);
        }
        return evaluateTile!(T,false)(input,core,result,mask);
    }

    /// Keep the raster borrow inside its synchronous callback; the result
    /// refers only to the worker's own output arrays.
    unittest
    {
        import raster : RasterView,withPlane;
        static bool processTile(scope ref const RasterView!double view,
            ref Float32FeatureWorker worker,Region2D core,
            out FeaturePlanes32 result,out FeatureWorkerError status) nothrow @nogc
        {
            status=FeatureWorkerError.notAttempted;
            return withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
                status=worker.tryEvaluate(input,core,result);
            });
        }
        RasterView!double empty;
        Float32FeatureWorker worker;
        FeaturePlanes32 result;FeatureWorkerError status;
        assert(!processTile(empty,worker,Region2D(0,0,1,1),result,status));
        assert(status==FeatureWorkerError.notAttempted && result.validity.length==0);
    }

    private FeatureWorkerError evaluateTile(T,bool masked)(scope ref const RasterPlaneWindow!T input,
        Region2D core,out FeaturePlanes32 result,scope const RasterPlaneWindow!ubyte mask) nothrow @nogc
    {
        const h=requiredHalo,wide=core.width+2*h,tall=core.height+2*h;
        const left=core.x-h,top=core.y-h,count=core.width*core.height;
        const rowFeature=basicRowFeature(selected)||structuralRowFeature(selected);
        bool cleanRows=rowFeature;
        if(rowFeature)finite[0..wide*tall]=1;
        foreach(y;0..tall) {
            const row=input.row(top+y);
            static if(masked)const validRow=mask.row(top+y);
            foreach(x;0..wide) {
                bool available=true;
                double value=0;
                static if(masked)available=validRow.load(left+x)!=0;
                if(available) {
                    value=cast(double)row.load(left+x);
                    available=isFinite(value);
                    if(available && domain==FeaturePlaneDomain.linearLuminance && (value<0 || value>1))
                        return FeatureWorkerError.invalidLuminance;
                }
                // Clean rows never consume the mask. Initialize its common
                // all-valid state in bulk; only missing samples need stores.
                if(!rowFeature||!available)finite[y*wide+x]=cast(ubyte)available;
                if(rowFeature) {
                    if(rows.narrowPixels.length)rows.narrowPixels[y*wide+x]=cast(float)value;
                    else rows.pixels[y*wide+x]=value;
                    cleanRows&=available&&value>=0&&value<=1&&!(value==0&&1/value<0);
                }
            }
        }
        auto destination=PlaneOutput(planes,valid,oriented,range,pathValues);
        const reader=PlaneReader!T(input,finite[0..wide*tall],left,top,wide,cast(int)h,cast(int)h);
        if(cleanRows&&basicRowFeature(selected)&&rows.basicLoaded(selected,core.width,core.height,destination)) {}
        else if(cleanRows&&structuralRowFeature(selected)&&rows.structuralLoaded(selected,core.width,core.height,h,shapes,destination)) {}
        else if(isLocal(selected)) {
            const optimized=evaluateWindows(reader,core.width,core.height,settings.statistics.radius,moments);
            foreach(y;0..core.height)foreach(x;0..core.width) {
                const i=y*core.width+x;
                const at=PlaneReader!T(input,finite[0..wide*tall],left,top,wide,cast(int)(h+x),cast(int)(h+y));
                const center=at(0,0);
                if(!optimized) {
                    destination.setValue(i,evaluate(selected,false,Sample(center.value,[0,0,0],center.valid),at,
                        settings.statistics,settings.paths,shapes,settings.shadowCeiling));
                    continue;
                }
                const moment=moments[i];
                if(!center.valid || moment.count<settings.statistics.minimumValid || !isFinite(moment.mean) || !isFinite(moment.m2)) {
                    destination.invalidate(i);continue;
                }
                const deviation=sqrt(max(0.0,moment.m2/moment.count));
                if(usesLocalMoments(selected))
                    destination.setValue(i,fromLocalMoments(selected,center.value,moment.mean,deviation,settings.shadowCeiling));
                else if(selected==Feature.dynamicRange) {
                    const value=moment.high-moment.low;
                    destination.setValue(i,Value([value,0,0],isFinite(value),false));
                } else destination.setValue(i,Value([moment.mean,deviation,0],true,false));
            }
        } else if(morphologyRadius)
            evaluateSquareMorphologyInto(selected,cast(int)core.width,cast(int)core.height,reader,
                morphologyRows,morphologyIntermediate,destination);
        else {
            bool complete;
            if(isPath(selected))
                complete=evaluatePathsInto(selected==Feature.pathClosing,core.width,core.height,
                    reader,settings.paths,path,destination);
            if(!complete)foreach(y;0..core.height)foreach(x;0..core.width) {
                const at=PlaneReader!T(input,finite[0..wide*tall],left,top,wide,cast(int)(h+x),cast(int)(h+y));
                const center=at(0,0);
                destination.setValue(y*core.width+x,evaluate(selected,false,
                    Sample(center.value,[0,0,0],center.valid),at,settings.statistics,settings.paths,shapes,settings.shadowCeiling));
            }
        }
        result.width=core.width;result.height=core.height;result.inputSampleBytes=T.sizeof;
        foreach(c;0..3)result.channels[c]=planes[c][0..count];
        result.validity=valid[0..count];result.orientationValid=oriented[0..count];result.rangeFailure=range[0..count];
        return FeatureWorkerError.none;
    }
}

/// Capacity and parameters are prepared before entering @nogc data callbacks.
unittest
{
    Float32FeatureWorker worker;
    worker.prepare(Feature.ridge,64,64,RidgeParams(2,7));
    assert(worker.halo==7 && worker.scratchBytes<8*1024*1024);
}
