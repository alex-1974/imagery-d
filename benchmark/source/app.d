module app;

import core.memory : GC;
import core.time : MonoTime;
import imagery.analysis.feature_regions;
import imagery.analysis.hessian_lines;
import imagery.analysis.structure_tensor;
import imagery.analysis.cost_path;
import raster.region : Region2D;
import std.algorithm : sort, min;
import std.conv : to;
import std.math : isFinite;
import std.stdio : writeln, writefln;

// Every cold invocation uses a fresh engine. Warm cache lookup is a separate
// workload and must not replace kernel execution in this baseline.
void main(string[] args)
{
    const size = args.length > 1 ? args[1].to!size_t : 1024;
    const repeats = args.length > 2 ? args[2].to!size_t : 3;
    const selected = args.length > 3 ? args[3] : "all";
    const rgb = args.length > 4 && args[4] == "rgb";
    if (!size || size > 4096 || !repeats || repeats > 100)
        throw new Exception("Usage: bench [size=1024 (1..4096)] [repeats=3] [feature=all] [scalar|rgb]");
    Source source;
    source.identity = "benchmark-v1";
    source.revision = "1";
    source.grid = "pixels";
    source.band = rgb ? "RGB" : "scalar";
    source.unit = "1";
    source.width = source.height = size;
    source.rgb = rgb;
    source.read = (Region2D region, scope Sample[] outValues) {
        foreach (i, ref sample; outValues)
        {
            const x = region.x + i % region.width, y = region.y + i / region.width;
            const v = cast(ubyte)((x * 37 + y * 17 + (x * y) % 97) & 255);
            sample = Sample(cast(float)v / 255, [v, cast(ubyte)(255-v), v], true);
        }
    };
    if(selected=="windows") { windowSweep(source,size,repeats); return; }
    if(selected=="hessian") { hessianSweep(size,repeats); return; }
    if(selected=="tensor") { tensorSweep(size,repeats); return; }
    if(selected=="cost-path") { costPathSweep(size,repeats); return; }
    if(selected=="paths") { pathSweep(source,size,repeats); return; }
    writefln("frontend=%d compiler=%s size=%d repeats=%d tile=256 input=%s",
        __VERSION__, __VENDOR__, size, repeats, rgb ? "rgb8" : "float32-values");
    writeln("feature,ns_per_pixel,gc_bytes_per_call,scratch_allocations,cache_payload_allocations,peak_tile_bytes,checksum");
    bool matched;
    foreach (feature; [Feature.gaussian, Feature.gradient, Feature.localNormalization,
        Feature.ridge, Feature.gabor, Feature.pathOpening, Feature.clahe, Feature.median])
    {
        if (selected != "all" && selected != feature.to!string) continue;
        if (feature == Feature.clahe && !rgb) continue;
        matched = true;
        long[] times;
        ulong bytes;
        MemoryMetrics metrics;
        double checksum = 0;
        foreach (run; 0 .. repeats + 1)
        {
            Engine engine;
            const before = GC.stats().allocatedInCurrentThread;
            const start = MonoTime.currTime;
            auto sink = (Region2D tile, scope const(Value)[] values, Provenance origin) {
                foreach (value; values)
                    if (value.valid) checksum += value.channels[0];
            };
            if (feature == Feature.clahe)
                equalizeLuminanceLocally(engine, source, Region2D(0, 0, size, size), 256, sink);
            else
                engine.run(source, Region2D(0, 0, size, size), feature, 256, sink);
            const elapsed = (MonoTime.currTime - start).total!"nsecs";
            const allocated = GC.stats().allocatedInCurrentThread - before;
            if (run) { times ~= elapsed; bytes += allocated; }
            metrics = engine.metrics;
        }
        times.sort;
        assert(isFinite(checksum));
        writefln("%s,%.3f,%d,%d,%d,%d,%.12g", feature,
            cast(double)times[$ / 2] / (size * size), bytes / repeats,
            metrics.scratchAllocations, metrics.cachePayloadAllocations, metrics.peakTileBytes, checksum);
    }
    if (!matched) throw new Exception("Unknown or unsupported feature/input combination");
}

void windowSweep(Source source,size_t size,size_t repeats)
{
    writeln("window,ns_per_pixel,gc_bytes_per_call,peak_tile_bytes,checksum");
    foreach(radius;[1u,3u,7u,15u,31u])
    {
        long[] times;
        ulong allocated;
        size_t peak;
        double checksum=0;
        foreach(run;0..repeats+1) {
            Engine engine;
            const before=GC.stats().allocatedInCurrentThread;
            const start=MonoTime.currTime;
            engine.run(source,Region2D(0,0,size,size),Feature.localStatistics,256,
                LocalStatisticsParams(radius,((2*radius+1)^^2+1)/2),
                (Region2D r,scope const(Value)[] values,Provenance p) {
                    foreach(v;values)if(v.valid)checksum+=v.channels[0]+v.channels[1];
                });
            const elapsed=(MonoTime.currTime-start).total!"nsecs";
            const bytes=GC.stats().allocatedInCurrentThread-before;
            if(run) { times~=elapsed; allocated+=bytes; }
            peak=engine.metrics.peakTileBytes;
        }
        times.sort;
        writefln("%d,%.3f,%d,%d,%.12g",2*radius+1,
            cast(double)times[$/2]/(size*size),allocated/repeats,peak,checksum);
    }
}

void pathSweep(Source source,size_t size,size_t repeats)
{
    writeln("length,lateral_step,ns_per_pixel,gc_bytes_per_call,peak_tile_bytes,checksum");
    foreach(params;[PathMorphologyParams(7,1),PathMorphologyParams(15,1),
        PathMorphologyParams(31,0),PathMorphologyParams(31,1),PathMorphologyParams(31,2)]) {
        long[] times;ulong allocated;size_t peak;double checksum=0;
        foreach(run;0..repeats+1) {
            Engine engine;
            const before=GC.stats().allocatedInCurrentThread;
            const start=MonoTime.currTime;
            engine.run(source,Region2D(0,0,size,size),Feature.pathOpening,256,params,
                (Region2D r,scope const(Value)[] values,Provenance p) {
                    foreach(value;values)if(value.valid)checksum+=value.channels[0];
                });
            const elapsed=(MonoTime.currTime-start).total!"nsecs";
            const bytes=GC.stats().allocatedInCurrentThread-before;
            if(run) {times~=elapsed;allocated+=bytes;}
            peak=engine.metrics.peakTileBytes;
        }
        times.sort;
        writefln("%s,%s,%.3f,%s,%s,%.12g",params.length,params.lateralStep,
            cast(double)times[$/2]/(size*size),allocated/repeats,peak,checksum);
    }
}

void hessianSweep(size_t size,size_t repeats)
{
    auto input=new float[size*size];
    foreach(i,ref v;input)v=cast(float)((i*37+i/size*17)%256)/255;
    auto response=new float[input.length],angle=new float[input.length],scale=new float[input.length];
    auto valid=new ubyte[input.length];
    HessianLineWorkspace scratch;scratch.reserve(input.length);
    double[3] sigmas=[1,2,4];
    writeln("variant,ns_per_pixel,gc_bytes_per_call,checksum");
    foreach(variant;[HessianLineVariant.sato,HessianLineVariant.frangi,HessianLineVariant.meijering])
    {
        HessianLineParams params;params.variant=variant;
        long[] times;ulong allocated;double checksum=0;
        foreach(run;0..repeats+1) {
            const before=GC.stats().allocatedInCurrentThread;
            const start=MonoTime.currTime;
            hessianLineResponse(input,size,size,sigmas[],params,scratch,response,angle,scale,valid);
            const elapsed=(MonoTime.currTime-start).total!"nsecs";
            const bytes=GC.stats().allocatedInCurrentThread-before;
            foreach(v;response)checksum+=v;
            if(run) { times~=elapsed;allocated+=bytes; }
        }
        times.sort;
        writefln("%s,%.3f,%d,%.12g",variant,cast(double)times[$/2]/(size*size),allocated/repeats,checksum);
    }
}

void tensorSweep(size_t size,size_t repeats)
{
    auto input=new float[size*size];
    foreach(i,ref v;input)v=cast(float)((i*37+i/size*17)%256)/255;
    auto angle=new float[input.length],coherence=new float[input.length],energy=new float[input.length];
    auto valid=new ubyte[input.length];
    TensorWorkspace scratch;scratch.reserve(input.length);
    writeln("gradient_sigma,integration_sigma,ns_per_pixel,gc_bytes_per_call,checksum");
    foreach(params;[StructureTensorParams(.5,0),StructureTensorParams(1,2),StructureTensorParams(2.75,4)]) {
        long[] times;ulong allocated;double checksum=0;
        foreach(run;0..repeats+1) {
            const before=GC.stats().allocatedInCurrentThread;
            const start=MonoTime.currTime;
            structureTensor(input,size,size,params,scratch,angle,coherence,energy,valid);
            const elapsed=(MonoTime.currTime-start).total!"nsecs";
            const bytes=GC.stats().allocatedInCurrentThread-before;
            foreach(i;0..input.length)checksum+=angle[i]+coherence[i]+energy[i]+valid[i];
            if(run) { times~=elapsed;allocated+=bytes; }
        }
        times.sort;
        writefln("%g,%g,%.3f,%d,%.12g",params.gradientSigma,params.integrationSigma,
            cast(double)times[$/2]/(size*size),allocated/repeats,checksum);
    }
}

void costPathSweep(size_t size,size_t repeats)
{
    auto input=new float[size*size];
    foreach(i,ref v;input)v=1+cast(float)((i*37+i/size*17)%256)/31;
    writeln("workload,domain_side,ns_per_pixel,ns_per_query,gc_bytes_per_call,checksum");
    foreach(interactive;[false,true]) {
        const side=interactive?min(size,128UL):size;
        auto domain=interactive?new float[side*side]:input;
        if(interactive)foreach(y;0..side)foreach(x;0..side)
            domain[y*side+x]=input[((size-side)/2+y)*size+(size-side)/2+x];
        size_t[1] seeds=[(side/2)*side+side/2];
        auto path=new size_t[domain.length];
        long[] times;ulong allocated;double checksum=0;
        enum queries=64;
        foreach(run;0..repeats+1) {
            CostPath search;search.prepare(domain,side,side,seeds[]);
            const before=GC.stats().allocatedInCurrentThread;
            const start=MonoTime.currTime;
            if(interactive) {
                foreach(query;0..queries) {
                    const x=min(side-1,side/2+(query%8)*min(side/32,8UL));
                    const y=min(side-1,side/2+(query/8)*min(side/32,8UL));
                    const target=y*side+x;
                    while(!search.advance(target,64) && !search.exhausted) {}
                    const length=search.pathTo(target,path);
                    checksum+=search.distanceTo(target)+length+path[0]+path[length-1]+path[length/2];
                }
            } else {
                // The public distance-map form incrementally queries all cells.
                foreach(i;0..domain.length)search.advance(i);
            }
            const elapsed=(MonoTime.currTime-start).total!"nsecs";
            const bytes=GC.stats().allocatedInCurrentThread-before;
            if(!interactive)foreach(i;0..domain.length)checksum+=search.distanceTo(i);
            if(run) { times~=elapsed;allocated+=bytes; }
        }
        times.sort;
        writefln("%s,%s,%.3f,%.3f,%d,%.12g",interactive?"interactive-64-targets":"full-distance-map",side,
            cast(double)times[$/2]/(side*side),interactive?cast(double)times[$/2]/queries:0,
            allocated/repeats,checksum);
    }
}
