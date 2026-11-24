module imagery.analysis.comparison_measure;

import imagery.analysis.feature_regions;
import imagery.analysis.feature_worker32;
import imagery.analysis.feature_output32;
import imagery.analysis.worker_measure : inputPlane;
import imagery.analysis.hessian_lines;
import imagery.analysis.structure_tensor;
import imagery.analysis.canny_worker;
import raster : RasterLease,RasterPlaneWindow,RasterView,withPlane,Region2D;
import core.memory : GC;
import core.time : MonoTime,dur;
import core.thread : Thread;
import core.sys.linux.sched : sched_getcpu;
import core.sys.posix.dlfcn : dlopen,dlsym,dlclose,RTLD_NOW;
import std.algorithm : min,max,startsWith,endsWith,canFind;
import std.conv : to;
import std.string : split,splitLines,strip,toStringz;
import std.file : readText,dirEntries,SpanMode,isFile;
import std.process : environment;
import std.digest.sha : SHA256;
import std.digest : toHexString;
import std.json : JSONValue;
import std.stdio : writeln;
import std.exception : enforce;

// Fixture and all consumer storage are prepared before timing. Every mode
// publishes all three channels and masks to the same frame; hash outside timer.
private class Work {
    Source source;
    size_t size,edge,serial;
    Feature feature;
    FeatureViewParams parameters;
    Float32FeatureWorker worker;
    RasterLease!double lease;
    RasterLease!float lease32;
    bool input32;
    bool viewOnly;
    size_t deliveredSamples;
    bool hessian;
    bool tensor;
    HessianLineWorkspace hessianScratch;
    TensorWorkspace tensorScratch;
    HessianLineParams hessianParameters;
    StructureTensorParams tensorParameters;
    float[] hessianInput;
    Float32TileOutput frame;
    Engine warm;
    CannyWorkspace control,canny;
    float[] controlInput,cannyInput;
    ubyte[] controlEdges,cannyEdges,nativeEdges,nativeSectors,nativeStaging;
    float[] nativeMagnitude,nativeThin;
    uint[] nativeStack;
    void* library;
    alias Native=extern(C) int function(const(float)*,size_t,size_t,float,float,ubyte*,float*,float*,ubyte*,ubyte*,uint*);
    Native native;
    string[] revisions;

    this(Source src,size_t side,string selected,bool input32=false) {
        this.input32=input32;
        source=src;size=side;edge=min(256UL,size);
        const parts=selected.split(":");
        const isCanny=parts[0]=="canny";
        hessian=parts[0]=="hessian";
        tensor=parts[0]=="tensor";
        const gaussian32=parts[0]=="gaussian32";
        feature=isCanny||hessian||tensor?Feature.gradient:gaussian32?Feature.gaussian:to!Feature(parts[0]);
        if(hessian&&parts.length>1)hessianParameters.variant=parts[1].to!HessianLineVariant;
        if(hessian&&parts.length>2)hessianParameters.polarity=parts[2].to!LinePolarity;
        if(tensor&&parts.length>2)tensorParameters=StructureTensorParams(parts[1].to!double,parts[2].to!double);
        if(parts.length>1&&!isCanny) {
            if(feature==Feature.localNormalization)parameters.statistics=LocalStatisticsParams(parts[1].to!uint,1);
            else parameters.paths=PathMorphologyParams(parts[1].to!uint,parts.length>2?parts[2].to!uint:1);
        }
        if(!isCanny&&!hessian&&!tensor) {
        if(gaussian32)worker.prepareGaussian32(edge,edge);
        else if(feature==Feature.localNormalization)worker.prepare(feature,edge,edge,parameters.statistics);
        else if(feature==Feature.pathOpening||feature==Feature.pathClosing)worker.prepare(feature,edge,edge,parameters.paths);
        else worker.prepare(feature,edge,edge);
        if(input32)lease32=inputPlane!float(size,worker.halo);else lease=inputPlane(size,worker.halo);
        // Both transports read the same precomputed raster. Fixture generation
        // is outside the clock even on the pre-readPlane baseline.
        if(!input32&&!source.rgb)source.read=(Region2D r,scope Sample[] output) @safe {
            auto parent=lease.view();bool ok;
            scope auto selected=parent.tryRoi(Region2D(r.x+worker.halo,r.y+worker.halo,r.width,r.height),ok);
            enforce(ok,"Invalid benchmark sample ROI");
            enforce(withPlane(selected,0,(scope ref const RasterPlaneWindow!double plane) @safe nothrow @nogc {
                foreach(y;0..r.height) {
                    auto row=plane.row(y);
                    foreach(x;0..r.width)output[y*r.width+x]=Sample(row.load(x),[0,0,0],true);
                }
            }));
        };
        // Keep the measurement overlay buildable on the pre-readPlane source.
        static if(__traits(hasMember,Source,"readPlane")) {
            if(!input32&&environment.get("IMAGERY_BORROW_SOURCE","1")=="1")
                source.readPlane=(Region2D r,scope ScalarPlaneConsumer!double consume) @safe {
                    auto parent=lease.view();bool ok;
                    scope auto selected=parent.tryRoi(Region2D(r.x+worker.halo,r.y+worker.halo,r.width,r.height),ok);
                    enforce(ok,"Invalid benchmark source ROI");
                    return withPlane(selected,0,(scope ref const RasterPlaneWindow!double plane) @safe nothrow @nogc {consume(plane);});
                };
        }
        foreach(ref c;frame.channels)c=new float[size*size];
        frame.valid=new ubyte[size*size];frame.oriented=new ubyte[size*size];frame.range=new ubyte[size*size];
        warm.reservePlanar(8*1024*1024,4*1024*1024,4);
        }
        if(hessian||tensor) {
            version(ImageryGaussianReference) {
                if(hessian)hessianScratch.reserve(size*size);else tensorScratch.reserve(size*size);
            } else {
                const rows=environment.get("IMAGERY_STRIP_ROWS",hessian?"128":"32").to!size_t;
                const columns=environment.get("IMAGERY_STRIP_WIDTH","128").to!size_t;
                double[3] scales=[1,2,4];
                static if(__traits(compiles,hessianScratch.reserve(size,size,scales[],rows,columns))) {
                    if(hessian)hessianScratch.reserve(size,size,scales[],rows,columns);
                    else tensorScratch.reserve(size,size,tensorParameters,rows,columns);
                } else {
                    if(hessian)hessianScratch.reserve(size*size);else tensorScratch.reserve(size*size);
                }
            }
            hessianInput=new float[size*size];
            foreach(y;0..size)foreach(x;0..size)
                hessianInput[y*size+x]=cast(float)((x*37+y*17+x*y%97)&255)/255;
            foreach(ref c;frame.channels)c=new float[size*size];
            frame.valid=new ubyte[size*size];frame.valid[]=1;
            frame.oriented=new ubyte[size*size];frame.range=new ubyte[size*size];
        }
        revisions=new string[4096];foreach(i,ref r;revisions)r="paired-"~i.to!string;
        control.prepare(64,64);controlInput=new float[64*64];controlEdges=new ubyte[64*64];
        foreach(i,ref v;controlInput)v=cast(float)(i*37%257)/256;
        if(isCanny) {
            const n=size*size;canny.prepare(size,size);
            cannyInput=new float[n];cannyEdges=new ubyte[n];
            foreach(y;0..size)foreach(x;0..size)cannyInput[y*size+x]=cast(float)((x*37+y*17+x*y%97)&255)/255;
            nativeEdges=new ubyte[n];nativeSectors=new ubyte[n];nativeStaging=new ubyte[n];
            nativeMagnitude=new float[n];nativeThin=new float[n];nativeStack=new uint[n];
            const path=environment.get("IMAGERY_CANNY_REFERENCE","");
            library=dlopen(path.toStringz,RTLD_NOW);enforce(library !is null,"Cannot load Canny C reference");
            native=cast(Native)dlsym(library,"imagery_canny_reference");enforce(native !is null);
        }
    }
    ~this(){if(library !is null)dlclose(library);}

    void copy32(Region2D r,scope FeaturePlanes32 values) @safe nothrow @nogc {
        foreach(y;0..r.height) {
            const a=(r.y+y)*size+r.x,b=y*r.width;
            foreach(c;0..3)frame.channels[c][a..a+r.width]=values.channels[c][b..b+r.width];
            frame.valid[a..a+r.width]=values.validity[b..b+r.width];
            frame.oriented[a..a+r.width]=values.orientationValid[b..b+r.width];
            frame.range[a..a+r.width]=values.rangeFailure[b..b+r.width];
        }
    }
    private void evaluateWorker(T)(ref RasterView!T view,string mode) {
        bool ok=true;
            const h=worker.halo;
            enforce(withPlane(view,0,(scope ref const RasterPlaneWindow!T input) @safe nothrow @nogc {
                for(size_t y=0;y<size;y+=edge)for(size_t x=0;x<size;x+=edge) {
                    const w=min(edge,size-x),height=min(edge,size-y);FeaturePlanes32 result;
                    const start=MonoTime.currTime;
                    const status=worker.tryEvaluate(input,Region2D(x+h,y+h,w,height),result);
                    if(mode=="kernel")kernelNanoseconds+=(MonoTime.currTime-start).total!"nsecs";
                    if(status!=FeatureWorkerError.none){ok=false;return;}
                    copy32(Region2D(x,y,w,height),result);
                }
            })&&ok,"Comparison worker failed");
    }
    void evaluate(string mode,ref Engine engine) {
        Feature[1] selected=[feature];const region=Region2D(0,0,size,size);
        if(hessian||tensor) {
            double[3] sigmas=[1,2,4];
            const start=MonoTime.currTime;
            if(hessian)hessianLineResponse(hessianInput,size,size,sigmas[],hessianParameters,hessianScratch,
                frame.channels[0],frame.channels[1],frame.channels[2],frame.oriented);
            else structureTensor(hessianInput,size,size,tensorParameters,tensorScratch,
                frame.channels[0],frame.channels[1],frame.channels[2],frame.oriented);
            kernelNanoseconds+=(MonoTime.currTime-start).total!"nsecs";
        } else if(mode=="worker"||mode=="kernel") {
            if(input32){auto view=lease32.view();evaluateWorker(view,mode);}
            else {auto view=lease.view();evaluateWorker(view,mode);}
        } else if(mode=="cold64") {
            runFeatureView(engine,source,region,selected[],edge,parameters,
                (Region2D r,scope const(Value)[] values,Provenance p) {
                    deliveredSamples+=values.length;
                    if(!viewOnly)foreach(i,v;values)frame.setValue((r.y+i/r.width)*size+r.x+i%r.width,v);
                });
        } else if(mode=="canny-d") {
            enforce(canny.tryRun(cannyInput,size,size,.1f,.2f,cannyEdges)==CannyWorkerError.none);
        } else if(mode=="canny-c") {
            enforce(native(cannyInput.ptr,size,size,.1f,.2f,nativeEdges.ptr,nativeMagnitude.ptr,
                nativeThin.ptr,nativeSectors.ptr,nativeStaging.ptr,nativeStack.ptr)==1);
        } else engine.runPlanarView(source,region,selected[],edge,parameters,
            (Region2D r,scope FeaturePlanes32 values,Provenance p){
                deliveredSamples+=r.width*r.height;if(!viewOnly)copy32(r,values);
            });
    }
    long unchangedControl() {
        enforce(control.tryRun(controlInput,64,64,.1f,.2f,controlEdges)==CannyWorkerError.none);
        const start=MonoTime.currTime;
        enforce(control.tryRun(controlInput,64,64,.1f,.2f,controlEdges)==CannyWorkerError.none);
        return (MonoTime.currTime-start).total!"nsecs";
    }
    string digest(string mode) {
        SHA256 hash;hash.start();
        if(mode=="canny-c")hash.put(nativeEdges);
        else if(mode=="canny-d")hash.put(cannyEdges);
        else {
            foreach(c;frame.channels)hash.put(cast(const(ubyte)[])c);
            hash.put(frame.valid);hash.put(frame.oriented);hash.put(frame.range);
        }
        return hash.finish().toHexString.idup;
    }
    JSONValue measure(string selectedMode,bool observe=true,size_t iterations=1) {
        const onlyView=selectedMode.endsWith("-view");
        const mode=onlyView?selectedMode[0..$-5]:selectedMode;
        viewOnly=onlyView;scope(exit)viewOnly=false;
        source.revision=revisions[++serial%revisions.length];Engine cold;
        const controlBefore=unchangedControl();
        // Re-enter the same arithmetic workload before sampling frequency:
        // hashing/JSON can otherwise sample a different turbo state than SIMD.
        // Match the measured batch's work before sampling frequency. A single
        // short Canny/basic frame need not settle the same turbo state as a
        // >=150 ms batch. Cold preheat frames also use fresh instances.
        foreach(j;0..iterations) {
            source.revision=revisions[++serial%revisions.length];
            if(mode=="warm")evaluate(mode,warm);
            else {
                Engine preheatFrame;evaluate(mode,preheatFrame);
            }
        }
        kernelNanoseconds=0;
        source.revision=revisions[++serial%revisions.length];
        const before=telemetry();
        const initialMetrics=mode=="warm"?warm.metrics:MemoryMetrics.init;
        const initial=initialMetrics.featureEvaluations;
        const initialByteRuns=byteRuns();
        MemoryMetrics coldTotals;
        size_t coldPlanarPeak;
        deliveredSamples=0;
        const gc=GC.stats().allocatedInCurrentThread,start=MonoTime.currTime;
        foreach(i;0..iterations) {
            // The revision ring is far larger than the four cache slots;
            // repeated warm frames must be actual misses, even in a batch.
            if(i&&(mode=="warm"||mode=="cold64"||mode=="cold32"))
                source.revision=revisions[++serial%revisions.length];
            if(mode=="warm")evaluate(mode,warm);
            else if(mode=="cold64"||mode=="cold32") {
                Engine fresh;evaluate(mode,fresh);
                const m=fresh.metrics;
                static foreach(name;["sourceNanoseconds","preparationNanoseconds","kernelNanoseconds",
                    "cacheNanoseconds","sinkNanoseconds","featureEvaluations"])
                    __traits(getMember,coldTotals,name)+=__traits(getMember,m,name);
                coldTotals.peakTileBytes=max(coldTotals.peakTileBytes,m.peakTileBytes);
                static if(__traits(hasMember,MemoryMetrics,"borrowedPlaneTiles"))coldTotals.borrowedPlaneTiles+=m.borrowedPlaneTiles;
                coldTotals.peakCacheBytes=max(coldTotals.peakCacheBytes,m.peakCacheBytes);
                coldPlanarPeak=max(coldPlanarPeak,fresh.planarMetrics.peakBytes);
            } else evaluate(mode,cold);
        }
        const ns=(mode=="kernel"?kernelNanoseconds:(MonoTime.currTime-start).total!"nsecs")/cast(long)iterations,bytes=GC.stats().allocatedInCurrentThread-gc;
        const after=telemetry(),controlAfter=unchangedControl();
        const m=mode=="warm"?warm.metrics:coldTotals;
        const planarPeak=mode=="warm"?warm.planarMetrics.peakBytes:coldPlanarPeak;
        JSONValue r;r["mode"]=JSONValue(selectedMode);r["ns"]=JSONValue(ns);
        r["consumer"]=JSONValue(onlyView?"view-only":"complete-frame");
        r["delivered_samples"]=JSONValue(deliveredSamples);
        // A separate untimed full consumer validates the same fixture after
        // view-only work. Never hash an old frame or claim it was materialized
        // by the no-op callback. Use a fresh Engine to leave warm cache state.
        if(onlyView&&observe) {
            enforce(deliveredSamples==iterations*size*size,"View-only publication omitted samples");
            viewOnly=false;Engine validation;evaluate(mode,validation);viewOnly=true;
        }
        r["ns_per_pixel"]=JSONValue(cast(double)ns/(size*size));r["gc_bytes"]=JSONValue(bytes);
        r["iterations"]=JSONValue(iterations);
        r["digest"]=JSONValue(observe?digest(mode):"");
        r["frontend"]=JSONValue(__VERSION__);r["vendor"]=JSONValue(__VENDOR__);
        r["byte_path_tiles"]=JSONValue(byteRuns()-initialByteRuns);
        r["worker_payload_bytes"]=JSONValue(mode.startsWith("canny-")?canny.storageBytes:worker.scratchBytes);
        r["engine_tile_payload_bytes"]=JSONValue(m.peakTileBytes);
        r["cache_peak_sum_bytes"]=JSONValue(m.peakCacheBytes+planarPeak);
        r["caller_frame_bytes"]=JSONValue(mode.startsWith("canny-")?size*size:15*size*size);
        static if(__traits(hasMember,HessianLineWorkspace,"storageBytes"))
            r["standalone_payload_bytes"]=JSONValue(hessian?hessianScratch.storageBytes:tensor?tensorScratch.storageBytes:0);
        else r["standalone_payload_bytes"]=JSONValue((hessian?4:tensor?6:0)*size*size*double.sizeof);
        r["computed_tiles"]=JSONValue(m.featureEvaluations-initial);
        static if(__traits(hasMember,MemoryMetrics,"borrowedPlaneTiles"))
            r["borrowed_plane_tiles"]=JSONValue(m.borrowedPlaneTiles-initialMetrics.borrowedPlaneTiles);
        else r["borrowed_plane_tiles"]=JSONValue(0);
        r["control_before_ns"]=JSONValue(controlBefore);r["control_after_ns"]=JSONValue(controlAfter);
        SHA256 controlHash;controlHash.start();controlHash.put(controlEdges);
        r["control_digest"]=JSONValue(controlHash.finish().toHexString.idup);
        r["before"]=before;r["after"]=after;
        JSONValue phases;
        phases["source"]=JSONValue((m.sourceNanoseconds-initialMetrics.sourceNanoseconds)/iterations);
        phases["prepare"]=JSONValue((m.preparationNanoseconds-initialMetrics.preparationNanoseconds)/iterations);
        phases["kernel"]=JSONValue((m.kernelNanoseconds-initialMetrics.kernelNanoseconds)/iterations);
        phases["cache"]=JSONValue((m.cacheNanoseconds-initialMetrics.cacheNanoseconds)/iterations);
        phases["sink"]=JSONValue((m.sinkNanoseconds-initialMetrics.sinkNanoseconds)/iterations);r["phases_ns"]=phases;
        return r;
    }
    long kernelNanoseconds;
    private size_t byteRuns() const {
        static if(__traits(compiles,worker.bytePathRuns))return worker.bytePathRuns;
        else return 0;
    }
}

private string optionalFile(string path) {try{return readText(path).strip.idup;}catch(Exception){return "";}}
private JSONValue telemetry() {
    JSONValue result;const cpu=sched_getcpu(),base="/sys/devices/system/cpu/cpu"~cpu.to!string;
    result["cpu"]=JSONValue(cpu);result["frequency_khz"]=JSONValue(optionalFile(base~"/cpufreq/scaling_cur_freq"));
    result["governor"]=JSONValue(optionalFile(base~"/cpufreq/scaling_governor"));
    result["siblings"]=JSONValue(optionalFile(base~"/topology/thread_siblings_list"));
    result["loadavg"]=JSONValue(optionalFile("/proc/loadavg"));
    string ticks;foreach(line;optionalFile("/proc/stat").splitLines)if(line.startsWith("cpu"))ticks~=line~"\n";
    result["cpu_ticks"]=JSONValue(ticks);
    JSONValue power,temperatures;
    foreach(path;["/sys/class/power_supply","/sys/class/thermal"])try {
        foreach(entry;dirEntries(path,SpanMode.shallow)) {
            if(path=="/sys/class/power_supply") {
                const online=optionalFile(entry.name~"/online");if(online.length)power[entry.name]=JSONValue(online);
            } else {const temp=optionalFile(entry.name~"/temp");if(temp.length)temperatures[entry.name]=JSONValue(temp);}
        }
    }catch(Exception){}
    result["power"]=power;result["temperatures_millic"]=temperatures;return result;
}

void runComparisonBench(Source source,size_t size,size_t repeats,string selected,bool publication=false) {
    enforce(repeats<=100);auto work=new Work(source,size,selected);
    const canny=selected.split(":")[0]=="canny";
    const baseline=canny?"canny-c":"worker";
    const modes=canny?["canny-d"]:publication?
        ["cold64","cold32","warm","cold64-view","cold32-view","warm-view"]:["cold64","cold32","warm"];
    // One warm-up of every mode; actual Engine warm measurements use a new
    // revision every time and cannot become cache-hit-only replay.
    size_t[string] batches;
    foreach(mode;modes~[baseline]) {
        const pilot=work.measure(mode)["ns"].integer;
        batches[mode]=min(100UL,max(1UL,cast(size_t)((150_000_000+max(1L,pilot)-1)/max(1L,pilot))));
    }
    if(!canny)foreach(i;0..4)work.measure("warm",false);
    foreach(cycle;0..repeats) {
        foreach(mode;modes)foreach(position,current;[mode,baseline,baseline,mode]) {
            auto row=work.measure(current,true,batches[current]);
            row["operator"]=JSONValue(selected);row["size"]=JSONValue(size);row["cycle"]=JSONValue(cycle);
            row["pair"]=JSONValue(mode);row["position"]=JSONValue(position);
            writeln(row.toString);
        }
        // Bounded pause, outside all clocks, helps batches cool without
        // pretending the governor or desktop load is controlled.
        Thread.sleep(dur!"msecs"(100));
    }
}

// Callgrind toggles collection on this one named region. Fixture preparation,
// telemetry, hashing and printing remain outside the instruction-count scope.
pragma(inline,false) extern(C) void imageryInstructionRegion(Work work) {
    work.evaluate("worker",work.warm);
}
void runInstructionBench(Source source,size_t size,string selected) {
    auto work=new Work(source,size,selected);work.measure("worker");
    imageryInstructionRegion(work);writeln(work.digest("worker"));
}
void runSingleBench(Source source,size_t size,string selected) {
    auto work=new Work(source,size,selected,true);
    // Fixed predeclared batching rule: short cells must span enough scheduler
    // ticks for the SMT-idle check. A separate untimed pilot selects 1..100
    // frames targeting >=150 ms of kernel work. No sample is removed by time.
    const pilot=work.measure("kernel")["ns"].integer;
    const iterations=min(100UL,max(1UL,cast(size_t)((150_000_000+max(1L,pilot)-1)/max(1L,pilot))));
    auto row=work.measure("kernel",true,iterations);
    row["input_storage"]=JSONValue("float32");
    row["operator"]=JSONValue(selected);row["size"]=JSONValue(size);writeln(row.toString);
}

// One cell for same-target before/after ABBA orchestration. The parent owns
// session pairing and hygiene; startup/setup remain outside clocks.
void runEngineSample(Source source,size_t size,string feature,string mode) {
    enforce(["cold64","cold32","warm","cold64-view","cold32-view","warm-view"].canFind(mode));
    auto work=new Work(source,size,feature);
    const pilot=work.measure(mode,false)["ns"].integer;
    const iterations=min(100UL,max(1UL,cast(size_t)((150_000_000+max(1L,pilot)-1)/max(1L,pilot))));
    auto row=work.measure(mode,true,iterations);
    row["operator"]=JSONValue(feature);row["size"]=JSONValue(size);writeln(row.toString);
}

pragma(inline,false) extern(C) void imageryEngineInstructionRegion(Work work,string mode,ref Engine engine)
{work.evaluate(mode,engine);}

void runEngineInstructionBench(Source source,size_t size,string feature,string selectedMode)
{
    const onlyView=selectedMode.endsWith("-view"),mode=onlyView?selectedMode[0..$-5]:selectedMode;
    enforce(["cold64","cold32","warm"].canFind(mode));
    auto work=new Work(source,size,feature);work.viewOnly=onlyView;Engine engine;
    if(mode=="warm") {
        engine.reservePlanar(8*1024*1024,4*1024*1024,4);
        foreach(i;0..4) {work.source.revision=work.revisions[++work.serial];work.evaluate(mode,engine);}
    }
    work.source.revision=work.revisions[++work.serial];
    const before=GC.stats().allocatedInCurrentThread,initial=engine.metrics.featureEvaluations;
    imageryEngineInstructionRegion(work,mode,engine);
    const allocated=GC.stats().allocatedInCurrentThread-before;
    JSONValue result;result["computed_tiles"]=JSONValue(engine.metrics.featureEvaluations-initial);
    result["gc_bytes"]=JSONValue(allocated);
    if(onlyView) {work.viewOnly=false;Engine validation;work.evaluate(mode,validation);}
    result["digest"]=JSONValue(work.digest(mode));result["mode"]=JSONValue(selectedMode);
    writeln(result.toString);
}
