module worker32_checks;

import imagery.analysis.feature_worker32;
import imagery.analysis.feature_regions;
import raster : RasterLease, OwnedByteResource, PlaneByteLayout, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster, RasterPlaneWindow, withPlane;
import core.stdc.stdlib : malloc;
import core.memory : GC;
import std.exception : enforce;
import std.algorithm : min,max;
import std.math : abs,isFinite;
import std.json : JSONValue;
import color.rgb : SRgbd,toLinear;

private struct WorkerMetrics
{
    size_t cases,samples,peakBytes;
    double maxError=0;
}

// Test-only raw allocation boundary. Every layout is validated by raster-d;
// its lease owns the malloc release obligation before callbacks begin.
private RasterLease!T owner(T)(scope const(T)[] values,size_t width,size_t height,
    bool reverseRows=false,bool reverseSamples=false,size_t sampleStep=1,size_t padding=0)
{
    enforce(values.length==width*height && width && height && sampleStep);
    const row=width*sampleStep+padding,amount=row*height;
    auto memory=cast(T*)malloc(amount*T.sizeof);enforce(memory !is null);
    memory[0..amount]=0;
    foreach(y;0..height)foreach(x;0..width)
        memory[(reverseRows?height-1-y:y)*row+(reverseSamples?width-1-x:x)*sampleStep]=values[y*width+x];
    OwnedByteResource resource;
    enforce(tryAdoptMallocResource(memory,amount*T.sizeof,resource));
    const start=((reverseRows?(height-1)*row:0)+(reverseSamples?(width-1)*sampleStep:0))*T.sizeof;
    PlaneByteLayout[1] layout=[PlaneByteLayout(start,
        (reverseRows?-cast(ptrdiff_t)row:cast(ptrdiff_t)row)*cast(ptrdiff_t)T.sizeof,
        (reverseSamples?-cast(ptrdiff_t)sampleStep:cast(ptrdiff_t)sampleStep)*cast(ptrdiff_t)T.sizeof)];
    RasterLease!T result;
    enforce(tryImportOwnedRaster!T(resource,layout[],Region2D(0,0,width,height),result).ok);
    return result;
}

private bool supported(Feature feature) @safe nothrow @nogc
{
    return feature!=Feature.oklab && feature!=Feature.clipping && feature!=Feature.underexposure &&
        feature!=Feature.visibility && feature!=Feature.distribution && feature!=Feature.normalizedLuminance &&
        feature!=Feature.exposureMatched && feature!=Feature.clahe;
}

private void fixture(T)(bool rgb,ref WorkerMetrics metrics)
{
    enum w=17,h=13;
    auto original=new T[w*h];auto mask=new ubyte[w*h];auto colors=new ubyte[3][](w*h);
    foreach(i,ref v;original) {
        const x=i%w,y=i/w;
        colors[i]=[cast(ubyte)((x*31+y*17)%256),cast(ubyte)((x*13+y*29)%256),cast(ubyte)((x*7+y*43)%256)];
        if(rgb) {
            const c=SRgbd(colors[i][0]/255.0,colors[i][1]/255.0,colors[i][2]/255.0).toLinear;
            v=cast(T)(.2126*c.r+.7152*c.g+.0722*c.b);
        } else v=cast(T)(273+.125*x+.0625*y+((x*y)%7)/8.0);
        mask[i]=cast(ubyte)(x!=8 || y!=6);
    }
    if(!rgb)original[3*w+2]=T.nan;
    Source source;
    source.identity="worker-reference";source.revision="1";source.grid="pixels";
    source.band=rgb?"RGB":"temperature";source.unit=rgb?"1":"K";
    source.rgb=rgb;source.width=w;source.height=h;
    source.read=(Region2D r,scope Sample[] samples) {
        foreach(i,ref sample;samples) {
            const p=(r.y+i/r.width)*w+r.x+i%r.width;
            sample=Sample(cast(double)original[p],colors[p],mask[p]!=0);
        }
    };
    foreach(id;0..cast(int)Feature.max+1) {
        const feature=cast(Feature)id;
        if(!supported(feature) || (!rgb && describeTileFeature(feature).rgbOnly))continue;
        Float32FeatureWorker worker;
        worker.prepare(feature,w,h,rgb?FeaturePlaneDomain.linearLuminance:FeaturePlaneDomain.scalar);
        const halo=worker.halo,pw=w+2*halo,ph=h+2*halo;
        auto padded=new T[pw*ph];auto paddedMask=new ubyte[pw*ph];
        foreach(y;0..ph)foreach(x;0..pw) {
            const sx=max(0,min(w-1,cast(int)x-cast(int)halo));
            const sy=max(0,min(h-1,cast(int)y-cast(int)halo));
            padded[y*pw+x]=original[sy*w+sx];paddedMask[y*pw+x]=mask[sy*w+sx];
        }
        auto pixels=owner!T(padded,pw,ph,true,true,2,3);
        auto validity=owner!ubyte(paddedMask,pw,ph,false,true,3,5);
        auto view=pixels.view(),validView=validity.view();
        FeaturePlanes32 result;FeatureWorkerError status;
        const before=GC.stats().allocatedInCurrentThread;
        enforce(withPlane(view,0,(scope ref const RasterPlaneWindow!T input) @safe nothrow @nogc {
            withPlane(validView,0,(scope ref const RasterPlaneWindow!ubyte selected) @safe nothrow @nogc {
                status=worker.tryEvaluate(input,Region2D(halo,halo,w,h),result,selected);
            });
        }));
        enforce(status==FeatureWorkerError.none && GC.stats().allocatedInCurrentThread==before,"Prepared worker evaluation allocated");
        enforce(result.width==w && result.height==h && result.inputSampleBytes==T.sizeof);
        Engine reference;
        auto whole=new Value[w*h];
        reference.run(source,Region2D(0,0,w,h),feature,17,
            (Region2D r,scope const(Value)[] values,Provenance p) {
                whole[]=values;
                enforce(p.parameters==worker.parameters,"Worker parameter identity");
                foreach(i,v;values) {
                    enforce(result.validity[i]==v.valid && !result.rangeFailure[i],"Worker validity");
                    enforce(result.orientationValid[i]==cast(ubyte)(v.orientationValid && cast(float)v.channels[0]!=0),"Worker direction validity");
                    if(v.valid)foreach(c;0..3) {
                        const error=abs(cast(double)result.channels[c][i]-v.channels[c]);
                        metrics.maxError=max(metrics.maxError,error);
                        enforce(result.channels[c][i]==cast(float)v.channels[c],"Float32 worker reference conversion");
                    } else foreach(c;0..3)enforce(result.channels[c][i]==0);
                    ++metrics.samples;
                }
            });
        // Reuse one prepared worker for a differently sized interior tile.
        const roi=Region2D(halo+3,halo+2,7,5);
        const repeatBefore=GC.stats().allocatedInCurrentThread;
        enforce(withPlane(view,0,(scope ref const RasterPlaneWindow!T input) @safe nothrow @nogc {
            withPlane(validView,0,(scope ref const RasterPlaneWindow!ubyte selected) @safe nothrow @nogc {
                status=worker.tryEvaluate(input,roi,result,selected);
            });
        }));
        enforce(status==FeatureWorkerError.none && GC.stats().allocatedInCurrentThread==repeatBefore);
        foreach(i;0..35) {
            const previous=whole[(2+i/7)*w+3+i%7];
            enforce(result.validity[i]==previous.valid);
            if(previous.valid)foreach(c;0..3)
                enforce(result.channels[c][i]==cast(float)previous.channels[c],"Worker interior ROI conversion");
        }
        ++metrics.cases;metrics.peakBytes=max(metrics.peakBytes,worker.scratchBytes);
        enforce(worker.scratchBytes<=8*1024*1024);
    }
}

private void configured(P)(Feature feature,P parameters,bool rgb,ref WorkerMetrics metrics)
{
    enum w=23,h=19;
    auto values=new double[w*h];auto colors=new ubyte[3][](w*h);
    foreach(i,ref value;values) {
        const x=i%w,y=i/w;
        colors[i]=[cast(ubyte)((x*31+y*17)%256),cast(ubyte)((x*13+y*29)%256),cast(ubyte)((x*7+y*43)%256)];
        if(rgb) {
            const c=SRgbd(colors[i][0]/255.0,colors[i][1]/255.0,colors[i][2]/255.0).toLinear;
            value=.2126*c.r+.7152*c.g+.0722*c.b;
        } else value=((x*37+y*19+x*y)%61)/61.0;
    }
    Float32FeatureWorker worker;
    worker.prepare(feature,w,h,parameters,rgb?FeaturePlaneDomain.linearLuminance:FeaturePlaneDomain.scalar);
    const halo=worker.halo,pw=w+2*halo,ph=h+2*halo;
    auto padded=new double[pw*ph];
    foreach(y;0..ph)foreach(x;0..pw) {
        const sx=max(0,min(w-1,cast(int)x-cast(int)halo)),sy=max(0,min(h-1,cast(int)y-cast(int)halo));
        padded[y*pw+x]=values[sy*w+sx];
    }
    auto lease=owner!double(padded,pw,ph);auto view=lease.view();
    FeaturePlanes32 result;FeatureWorkerError status;
    const before=GC.stats().allocatedInCurrentThread;
    enforce(withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(halo,halo,w,h),result);
    }));
    enforce(status==FeatureWorkerError.none && GC.stats().allocatedInCurrentThread==before);
    Source source;
    source.identity="configured-worker";source.revision="1";source.grid="pixels";source.unit="1";
    source.band=rgb?"RGB":"scalar";source.rgb=rgb;source.width=w;source.height=h;
    source.read=(Region2D r,scope Sample[] samples) {
        foreach(i,ref sample;samples) {
            const p=(r.y+i/r.width)*w+r.x+i%r.width;
            sample=Sample(values[p],colors[p],true);
        }
    };
    Engine engine;
    engine.run(source,Region2D(0,0,w,h),feature,32,parameters,
        (Region2D r,scope const(Value)[] expected,Provenance origin) {
            enforce(worker.parameters==origin.parameters);
            foreach(i,v;expected) {
                enforce(result.validity[i]==v.valid && !result.rangeFailure[i]);
                if(v.valid)foreach(c;0..3) {
                    enforce(result.channels[c][i]==cast(float)v.channels[c],"Configured worker reference conversion");
                    metrics.maxError=max(metrics.maxError,abs(cast(double)result.channels[c][i]-v.channels[c]));
                }
                ++metrics.samples;
            }
        });
    ++metrics.cases;metrics.peakBytes=max(metrics.peakBytes,worker.scratchBytes);
}

private size_t failuresAndRange()
{
    size_t peak;
    double[9*9] values;values[]=1;
    auto lease=owner!double(values[],9,9);auto view=lease.view();
    Float32FeatureWorker worker;
    FeaturePlanes32 result;FeatureWorkerError status;
    withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(1,1,7,7),result);
    });
    enforce(status==FeatureWorkerError.notPrepared && !result.validity.length);
    worker.prepare(Feature.gradient,7,7);
    withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(1,1,7,7),result);
    });
    enforce(status==FeatureWorkerError.none);
    const previous=result.channels[0].dup;
    const retained=result;
    withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(0,0,7,7),result);
    });
    enforce(status==FeatureWorkerError.invalidRegion && !result.validity.length && retained.channels[0]==previous);
    bool rejected;
    try {worker.prepare(Feature.ridge,7,7,RidgeParams(0,3));}catch(Exception){rejected=true;}
    enforce(rejected && worker.halo==1 && retained.channels[0]==previous);
    auto smallMask=owner!ubyte(new ubyte[4],2,2);auto maskView=smallMask.view();
    withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        withPlane(maskView,0,(scope ref const RasterPlaneWindow!ubyte mask) @safe nothrow @nogc {
            status=worker.tryEvaluate(input,Region2D(1,1,7,7),result,mask);
        });
    });
    enforce(status==FeatureWorkerError.invalidMask && !result.validity.length && retained.channels[0]==previous);

    // Overflow is a representability mask, not a fake finite feature value.
    foreach(i,ref value;values)value=(cast(double)(i%9)+i/9)*1e100;
    auto huge=owner!double(values[],9,9);auto hugeView=huge.view();
    withPlane(hugeView,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(1,1,7,7),result);
    });
    enforce(status==FeatureWorkerError.none);
    foreach(i;0..49)enforce(!result.validity[i] && result.rangeFailure[i] && !result.orientationValid[i]);
    foreach(i,ref value;values)value=(cast(double)(i%9)+i/9)*1e-50;
    auto tiny=owner!double(values[],9,9);auto tinyView=tiny.view();
    withPlane(tinyView,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(1,1,7,7),result);
    });
    enforce(status==FeatureWorkerError.none);
    foreach(i;0..49)enforce(result.validity[i] && !result.rangeFailure[i] && !result.orientationValid[i] && result.channels[0][i]==0);

    worker.prepare(Feature.gradient,7,7,FeaturePlaneDomain.linearLuminance);
    withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(1,1,7,7),result);
    });
    enforce(status==FeatureWorkerError.none);
    const good=result;const goodValues=result.channels[0].dup;
    const goodValid=result.validity.dup,goodRange=result.rangeFailure.dup;
    withPlane(hugeView,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(1,1,7,7),result);
    });
    enforce(status==FeatureWorkerError.invalidLuminance && !result.validity.length && good.channels[0]==goodValues &&
        good.validity==goodValid && good.rangeFailure==goodRange);

    // A nonrepresentable first direction must not be replaced by a weaker
    // representable direction; conversely a genuinely stronger finite winner
    // must be allowed to recover representability.
    worker.prepare(Feature.pathOpening,1,1,PathMorphologyParams(3,0));
    foreach(mode;0..2) {
        foreach(i,ref value;values)
            value=mode==0?(i/9==4?1e100:1):(i%9==4?1:-1e100);
        auto pathLease=owner!double(values[],9,9);auto pathView=pathLease.view();
        withPlane(pathView,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
            status=worker.tryEvaluate(input,Region2D(4,4,1,1),result);
        });
        enforce(status==FeatureWorkerError.none);
        if(mode==0)enforce(!result.validity[0] && result.rangeFailure[0]);
        else enforce(result.validity[0] && !result.rangeFailure[0] && result.channels[0][0]==1);
    }
    worker.prepare(Feature.topHat,1,1);
    values[]= -double.max;values[4*9+4]=double.max;
    auto mathematicalOverflow=owner!double(values[],9,9);auto mathView=mathematicalOverflow.view();
    withPlane(mathView,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(4,4,1,1),result);
    });
    enforce(status==FeatureWorkerError.none && !result.validity[0] && !result.rangeFailure[0]);

    foreach(feature;[Feature.localStatistics,Feature.pathOpening,Feature.openingProfile,Feature.gabor,Feature.lineResponse]) {
        Float32FeatureWorker maximum;
        if(feature==Feature.localStatistics)maximum.prepare(feature,256,256,LocalStatisticsParams(31,1));
        else if(feature==Feature.pathOpening)maximum.prepare(feature,256,256,PathMorphologyParams(31,2));
        else if(feature==Feature.lineResponse)maximum.prepare(feature,256,256,LineResponseParams(RidgeParams(1,31),31));
        else maximum.prepare(feature,256,256);
        enforce(maximum.scratchBytes<=8*1024*1024);
        peak=max(peak,maximum.scratchBytes);
    }
    return peak;
}

void checkWorker32(ref JSONValue root)
{
    double[9*9] values;
    foreach(i,ref value;values)value=cast(double)(i%9)+cast(double)(i/9);
    auto lease=owner!double(values[],9,9);
    auto view=lease.view();
    Float32FeatureWorker worker;worker.prepare(Feature.gradient,7,7);
    FeaturePlanes32 result;
    FeatureWorkerError status;
    const before=GC.stats().allocatedInCurrentThread;
    enforce(withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        status=worker.tryEvaluate(input,Region2D(1,1,7,7),result);
    }));
    enforce(status==FeatureWorkerError.none && result.validity[24] && result.orientationValid[24]);
    enforce(GC.stats().allocatedInCurrentThread==before);
    cleanMedianChecks();
    root["worker32_exact_median_samples"]=JSONValue(504);
    WorkerMetrics metrics;
    fixture!double(false,metrics);
    fixture!double(true,metrics);
    fixture!float(false,metrics);
    configured(Feature.localNormalization,LocalStatisticsParams(2,11),false,metrics);
    configured(Feature.pathOpening,PathMorphologyParams(11,2),false,metrics);
    configured(Feature.pathClosing,PathMorphologyParams(11,2),false,metrics);
    configured(Feature.ridge,RidgeParams(2,7),false,metrics);
    configured(Feature.lineResponse,LineResponseParams(RidgeParams(2,5),3),false,metrics);
    GaborParams gabor;gabor.wavelengths=[1.5,5.25];gabor.angles=[.1,.7,1.4,2.2];gabor.sigmaRatio=.7;gabor.supportRatio=1.5;
    configured(Feature.gabor,gabor,false,metrics);
    configured(Feature.shadowCandidate,ShadowParams(LocalStatisticsParams(2,11),.27),true,metrics);
    metrics.peakBytes=max(metrics.peakBytes,failuresAndRange());
    root["worker32_cases"]=JSONValue(metrics.cases);root["worker32_samples"]=JSONValue(metrics.samples);
    root["worker32_max_error"]=JSONValue(metrics.maxError);root["worker32_peak_bytes"]=JSONValue(metrics.peakBytes);
}

private void cleanMedianChecks()
{
    import std.algorithm : sort;
    import std.math : signbit;
    enum width=11,height=9;
    Float32FeatureWorker worker;worker.prepare(Feature.median,9,7);
    foreach(fixture;0..8) {
        auto samples=new double[width*height];
        foreach(i,ref value;samples)value=fixture==0?0:fixture==1?1:fixture==2?cast(double)(i*37%101)/101:
            fixture==3?.5+(cast(int)(i%9)-4)*0x1p-25:
            fixture==4?.5+0x1p-25+(cast(int)(i%3)-1)*double.epsilon:
            fixture==5?cast(double)(i%99)*0x1p-150:fixture==6?-0.0:cast(double)(i%17)*1e-300;
        auto lease=owner!double(samples,width,height);auto view=lease.view();
        FeaturePlanes32 actual;FeatureWorkerError status;
        const before=GC.stats().allocatedInCurrentThread;
        enforce(withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
            status=worker.tryEvaluate(input,Region2D(1,1,9,7),actual);
        }));
        enforce(status==FeatureWorkerError.none&&GC.stats().allocatedInCurrentThread==before);
        foreach(y;0..7)foreach(x;0..9) {
            double[9] sorted;size_t at;
            foreach(dy;0..3)foreach(dx;0..3)sorted[at++]=samples[(y+dy)*width+x+dx];
            sorted[].sort;const expected=cast(float)sorted[4],i=y*9+x;
            enforce(actual.validity[i]&&!actual.rangeFailure[i]&&!actual.orientationValid[i]);
            enforce(actual.channels[0][i]==expected&&
                (expected!=0||signbit(actual.channels[0][i])==signbit(expected)),"Median quantization commutation/signed zero");
            enforce(actual.channels[1][i]==0&&actual.channels[2][i]==0);
        }
    }
}
