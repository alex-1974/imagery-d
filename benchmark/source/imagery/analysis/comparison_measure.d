module imagery.analysis.comparison_measure;

import imagery.analysis.feature_regions;
import imagery.analysis.feature_worker32;
import imagery.analysis.feature_output32;
import imagery.analysis.worker_measure : inputPlane;
import imagery.analysis.hessian_lines;
import imagery.analysis.canny_worker;
import raster : RasterLease,RasterPlaneWindow,RasterView,withPlane,Region2D;
import core.memory : GC;
import core.time : MonoTime,dur;
import core.thread : Thread;
import core.sys.linux.sched : sched_getcpu;
import core.sys.posix.dlfcn : dlopen,dlsym,dlclose,RTLD_NOW;
import std.algorithm : min,startsWith;
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
    bool hessian;
    HessianLineWorkspace hessianScratch;
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
        const gaussian32=parts[0]=="gaussian32";
        feature=isCanny||hessian?Feature.gradient:gaussian32?Feature.gaussian:to!Feature(parts[0]);
        if(parts.length>1&&!isCanny) {
            if(feature==Feature.localNormalization)parameters.statistics=LocalStatisticsParams(parts[1].to!uint,1);
            else parameters.paths=PathMorphologyParams(parts[1].to!uint,parts.length>2?parts[2].to!uint:1);
        }
        if(!isCanny&&!hessian) {
        if(gaussian32)worker.prepareGaussian32(edge,edge);
        else if(feature==Feature.localNormalization)worker.prepare(feature,edge,edge,parameters.statistics);
        else if(feature==Feature.pathOpening||feature==Feature.pathClosing)worker.prepare(feature,edge,edge,parameters.paths);
        else worker.prepare(feature,edge,edge);
        if(input32)lease32=inputPlane!float(size,worker.halo);else lease=inputPlane(size,worker.halo);
        foreach(ref c;frame.channels)c=new float[size*size];
        frame.valid=new ubyte[size*size];frame.oriented=new ubyte[size*size];frame.range=new ubyte[size*size];
        warm.reservePlanar(8*1024*1024,4*1024*1024,4);
        }
        if(hessian) {
            hessianScratch.reserve(size*size);
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
        if(hessian) {
            double[3] sigmas=[1,2,4];
            const start=MonoTime.currTime;
            hessianLineResponse(hessianInput,size,size,sigmas[],HessianLineParams.init,hessianScratch,
                frame.channels[0],frame.channels[1],frame.channels[2],frame.oriented);
            kernelNanoseconds+=(MonoTime.currTime-start).total!"nsecs";
        } else if(mode=="worker"||mode=="kernel") {
            if(input32){auto view=lease32.view();evaluateWorker(view,mode);}
            else {auto view=lease.view();evaluateWorker(view,mode);}
        } else if(mode=="cold64") {
            runFeatureView(engine,source,region,selected[],edge,parameters,
                (Region2D r,scope const(Value)[] values,Provenance p) {
                    foreach(i,v;values)frame.setValue((r.y+i/r.width)*size+r.x+i%r.width,v);
                });
        } else if(mode=="canny-d") {
            enforce(canny.tryRun(cannyInput,size,size,.1f,.2f,cannyEdges)==CannyWorkerError.none);
        } else if(mode=="canny-c") {
            enforce(native(cannyInput.ptr,size,size,.1f,.2f,nativeEdges.ptr,nativeMagnitude.ptr,
                nativeThin.ptr,nativeSectors.ptr,nativeStaging.ptr,nativeStack.ptr)==1);
        } else engine.runPlanarView(source,region,selected[],edge,parameters,
            (Region2D r,scope FeaturePlanes32 values,Provenance p){copy32(r,values);});
    }
    long unchangedControl() {
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
    JSONValue measure(string mode,bool observe=true) {
        source.revision=revisions[++serial];Engine cold,preheat;
        const controlBefore=unchangedControl();
        // Re-enter the same arithmetic workload before sampling frequency:
        // hashing/JSON can otherwise sample a different turbo state than SIMD.
        // Every A and B gets this identical untimed one-frame warm-up.
        if(mode=="warm")evaluate(mode,warm);else evaluate(mode,preheat);
        kernelNanoseconds=0;
        source.revision=revisions[++serial];
        const before=telemetry();
        const initialMetrics=mode=="warm"?warm.metrics:MemoryMetrics.init;
        const initial=initialMetrics.featureEvaluations;
        const initialByteRuns=byteRuns();
        const gc=GC.stats().allocatedInCurrentThread,start=MonoTime.currTime;
        if(mode=="warm")evaluate(mode,warm);else evaluate(mode,cold);
        const ns=mode=="kernel"?kernelNanoseconds:(MonoTime.currTime-start).total!"nsecs",bytes=GC.stats().allocatedInCurrentThread-gc;
        const after=telemetry(),controlAfter=unchangedControl();
        const m=mode=="warm"?warm.metrics:cold.metrics;
        const planar=mode=="warm"?warm.planarMetrics:cold.planarMetrics;
        JSONValue r;r["mode"]=JSONValue(mode);r["ns"]=JSONValue(ns);
        r["ns_per_pixel"]=JSONValue(cast(double)ns/(size*size));r["gc_bytes"]=JSONValue(bytes);
        r["digest"]=JSONValue(observe?digest(mode):"");
        r["frontend"]=JSONValue(__VERSION__);r["vendor"]=JSONValue(__VENDOR__);
        r["byte_path_tiles"]=JSONValue(byteRuns()-initialByteRuns);
        r["worker_payload_bytes"]=JSONValue(mode.startsWith("canny-")?canny.storageBytes:worker.scratchBytes);
        r["engine_tile_payload_bytes"]=JSONValue(m.peakTileBytes);
        r["cache_peak_sum_bytes"]=JSONValue(m.peakCacheBytes+planar.peakBytes);
        r["caller_frame_bytes"]=JSONValue(mode.startsWith("canny-")?size*size:15*size*size);
        r["computed_tiles"]=JSONValue(m.featureEvaluations-initial);
        r["control_before_ns"]=JSONValue(controlBefore);r["control_after_ns"]=JSONValue(controlAfter);
        SHA256 controlHash;controlHash.start();controlHash.put(controlEdges);
        r["control_digest"]=JSONValue(controlHash.finish().toHexString.idup);
        r["before"]=before;r["after"]=after;
        JSONValue phases;
        phases["source"]=JSONValue(m.sourceNanoseconds-initialMetrics.sourceNanoseconds);
        phases["prepare"]=JSONValue(m.preparationNanoseconds-initialMetrics.preparationNanoseconds);
        phases["kernel"]=JSONValue(m.kernelNanoseconds-initialMetrics.kernelNanoseconds);
        phases["cache"]=JSONValue(m.cacheNanoseconds-initialMetrics.cacheNanoseconds);
        phases["sink"]=JSONValue(m.sinkNanoseconds-initialMetrics.sinkNanoseconds);r["phases_ns"]=phases;
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

void runComparisonBench(Source source,size_t size,size_t repeats,string selected) {
    enforce(repeats<=100);auto work=new Work(source,size,selected);
    const canny=selected.split(":")[0]=="canny";
    const baseline=canny?"canny-c":"worker";
    const modes=canny?["canny-d"]:["cold64","cold32","warm"];
    // One warm-up of every mode; actual Engine warm measurements use a new
    // revision every time and cannot become cache-hit-only replay.
    work.measure(baseline);foreach(mode;modes)work.measure(mode);
    if(!canny)foreach(i;0..4)work.measure("warm",false);
    foreach(cycle;0..repeats) {
        foreach(mode;modes)foreach(position,current;[mode,baseline,baseline,mode]) {
            auto row=work.measure(current);
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
    auto work=new Work(source,size,selected,true);auto row=work.measure("kernel");
    row["input_storage"]=JSONValue("float32");
    row["operator"]=JSONValue(selected);row["size"]=JSONValue(size);writeln(row.toString);
}
