module app;

import core.memory : GC;
import core.time : MonoTime;
import imagery.analysis.feature_regions;
import imagery.analysis.hessian_lines;
import imagery.analysis.structure_tensor;
import imagery.analysis.cost_path;
import imagery.analysis.quality;
import imagery.mosaic.validity_policy : QualityContributor,tryQualityWeights;
import imagery.analysis.primitives : canny,slic;
import color.rgb : SRgbd, toLinear;
import imagery.analysis.worker_measure : runWorker32Bench;
import imagery.analysis.resource_measure : runResourceBench;
import imagery.analysis.prepared_measure : runCannyWorkspaceBench,runEpochBench;
import imagery.analysis.scaling_measure : runScalingBench;
import std.parallelism : totalCPUs;
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
    if(selected=="worker32") { runWorker32Bench(size,repeats,args.length>5?args[5]:""); return; }
    if(selected=="resources") { runResourceBench(repeats); return; }
    if(selected=="prepared-canny") {runCannyWorkspaceBench(size,repeats);return;}
    if(selected=="epochs") {runEpochBench(size,repeats);return;}
    if(selected=="scaling") {runScalingBench(size,repeats,args.length>5?args[5].to!size_t:totalCPUs);return;}
    if(selected=="mixed") { mixedSweep(source,size,repeats); return; }
    if(selected=="quality") { qualitySweep(size,repeats); return; }
    if(selected=="quality-weights") { weightSweep(size,repeats); return; }
    if(selected=="canny") { cannySweep(size,repeats,rgb); return; }
    if(selected=="slic") { slicSweep(size,repeats); return; }
    writefln("frontend=%d compiler=%s size=%d repeats=%d tile=256 input=%s",
        __VERSION__, __VENDOR__, size, repeats, rgb ? "rgb8" : "float32-values");
    writeln("feature,ns_per_pixel,gc_bytes_per_call,scratch_allocations,cache_payload_allocations,peak_tile_bytes,checksum,source_ns_last,preparation_ns_last,kernel_ns_last,cache_ns_last,sink_ns_last");
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
        writefln("%s,%.3f,%d,%d,%d,%d,%.12g,%s,%s,%s,%s,%s", feature,
            cast(double)times[$ / 2] / (size * size), bytes / repeats,
            metrics.scratchAllocations, metrics.cachePayloadAllocations, metrics.peakTileBytes, checksum,
            metrics.sourceNanoseconds,metrics.preparationNanoseconds,metrics.kernelNanoseconds,
            metrics.cacheNanoseconds,metrics.sinkNanoseconds);
    }
    if (!matched) throw new Exception("Unknown or unsupported feature/input combination");
    if(selected=="all")cannySweep(size,repeats,rgb);
}

void weightSweep(size_t count,size_t repeats)
{
    enum calls=16384;
    writeln("contributors,regime,ns_per_call,gc_bytes_per_call,checksum");
    foreach(extreme;[false,true]) {
        const scale=extreme?1e250:1.0;
        auto contributors=new QualityContributor[count];auto weights=new double[count];
        foreach(i,ref c;contributors)c=QualityContributor(i==0 || i%7!=0,
            (.25+.05*(i%8))*(extreme?1e-250:1),(.2+.05*(i%11))*(extreme?1e-250:1),scale);
        long[] times;ulong allocated;double checksum=0;
        foreach(run;0..repeats+1) {
            bool success=true;
            const before=GC.stats().allocatedInCurrentThread;const start=MonoTime.currTime;
            foreach(i;0..calls) {
                contributors[i%count].preference=scale*(.5+cast(double)(i%17)/16);
                success&=tryQualityWeights(contributors,weights);
                checksum+=weights[i%count];
            }
            const elapsed=(MonoTime.currTime-start).total!"nsecs";
            const bytes=GC.stats().allocatedInCurrentThread-before;
            if(!success)throw new Exception("Quality-weight benchmark failed");
            if(run){times~=elapsed;allocated+=bytes;}
        }
        times.sort;
        writefln("%s,%s,%.3f,%s,%.12g",count,extreme?"range-fallback":"ordinary",
            cast(double)times[$/2]/calls,allocated/(repeats*calls),checksum);
    }
}

void mixedSweep(Source source,size_t size,size_t repeats)
{
    enum edge=128,slots=cast(size_t)Feature.max+1;
    Feature[] features=[Feature.localNormalization,Feature.pathOpening,Feature.ridge,
        Feature.lineResponse,Feature.gabor,Feature.gradient];
    if(source.rgb)features~=Feature.shadowCandidate;
    FeatureViewParams p;
    p.statistics=LocalStatisticsParams(5,20);p.paths=PathMorphologyParams(5,2);
    p.ridge=RidgeParams(2,5);p.line=LineResponseParams(RidgeParams(2,4),2);
    p.gabor.wavelengths=[1.5,3.5];p.gabor.sigmaRatio=.6;p.gabor.supportRatio=1.25;
    p.shadowLuminanceCeiling=.4;
    double[slots] reference=0;
    writefln("size=%s repeats=%s tile=%s input=%s outputs=%s",size,repeats,edge,source.rgb?"rgb8":"float32-values",features.length);
    writeln("mode,ns_per_pixel,gc_bytes_per_call,source_reads,scalar_preparations,scratch_allocations,peak_tile_bytes,checksum");
    foreach(batched;[false,true]) {
        long[] times;ulong allocated;MemoryMetrics metrics;double total=0;
        foreach(run;0..repeats+1) {
            Engine engine;double[slots] checksums=0;
            Sink sink=(Region2D r,scope const(Value)[] values,Provenance origin) {
                foreach(value;values) {
                    checksums[origin.feature]+=value.valid+value.orientationValid;
                    if(value.valid)foreach(channel;value.channels)checksums[origin.feature]+=channel;
                }
            };
            const before=GC.stats().allocatedInCurrentThread;
            const start=MonoTime.currTime;
            const region=Region2D(0,0,size,size);
            if(batched)runFeatureView(engine,source,region,features,edge,p,sink);
            else foreach(feature;features) {
                switch(feature) {
                    case Feature.localNormalization:engine.run(source,region,feature,edge,p.statistics,sink);break;
                    case Feature.pathOpening:engine.run(source,region,feature,edge,p.paths,sink);break;
                    case Feature.ridge:engine.run(source,region,feature,edge,p.ridge,sink);break;
                    case Feature.lineResponse:engine.run(source,region,feature,edge,p.line,sink);break;
                    case Feature.gabor:engine.run(source,region,feature,edge,p.gabor,sink);break;
                    case Feature.shadowCandidate:
                        engine.run(source,region,feature,edge,ShadowParams(p.statistics,p.shadowLuminanceCeiling),sink);break;
                    default:engine.run(source,region,feature,edge,sink);
                }
            }
            const elapsed=(MonoTime.currTime-start).total!"nsecs";
            const bytes=GC.stats().allocatedInCurrentThread-before;
            if(batched && checksums!=reference)throw new Exception("Mixed benchmark per-feature checksum mismatch");
            if(!batched)reference=checksums;
            if(run){times~=elapsed;allocated+=bytes;}
            metrics=engine.metrics;total=0;foreach(value;checksums)total+=value;
        }
        times.sort;
        writefln("%s,%.3f,%s,%s,%s,%s,%s,%.12g",batched?"mixed-shared-input":"separate-shared-engine",
            cast(double)times[$/2]/(size*size),allocated/repeats,metrics.sourceTileReads,
            metrics.scalarTilePreparations,metrics.scratchAllocations,metrics.peakTileBytes,total);
    }
}

void slicSweep(size_t size,size_t repeats)
{
    const spacing=size<8?1:size/8;
    auto input=new float[size*size];auto labels=new uint[input.length];
    foreach(i,ref value;input)value=cast(float)((i*37+i/size*17)%256)/255;
    long[] times;ulong allocated,checksum;
    foreach(run;0..repeats+1) {
        const before=GC.stats().allocatedInCurrentThread;
        const start=MonoTime.currTime;
        slic(input,size,size,spacing,labels);
        const elapsed=(MonoTime.currTime-start).total!"nsecs";
        const bytes=GC.stats().allocatedInCurrentThread-before;
        if(run){times~=elapsed;allocated+=bytes;}
        foreach(value;labels)checksum+=value;
    }
    times.sort;
    writeln("feature,spacing,clusters,ns_per_pixel,gc_bytes_per_call,checksum");
    writefln("scalarGridClustering,%s,%s,%.3f,%s,%s",spacing,((size+spacing-1)/spacing)^^2,
        cast(double)times[$/2]/input.length,allocated/repeats,checksum);
}

void cannySweep(size_t size,size_t repeats,bool rgb)
{
    auto input=new float[size*size];
    foreach(y;0..size)foreach(x;0..size) {
        const v=cast(ubyte)((x*37+y*17+(x*y)%97)&255);
        if(rgb) {
            const linear=SRgbd(v/255.0,(255-v)/255.0,v/255.0).toLinear;
            input[y*size+x]=cast(float)(.2126*linear.r+.7152*linear.g+.0722*linear.b);
        } else input[y*size+x]=cast(float)v/255;
    }
    auto edges=new ubyte[input.length];long[] times;ulong allocated;ulong checksum;
    foreach(run;0..repeats+1) {
        const before=GC.stats().allocatedInCurrentThread;
        const start=MonoTime.currTime;
        canny(input,size,size,.15f,.3f,edges);
        const elapsed=(MonoTime.currTime-start).total!"nsecs";
        const bytes=GC.stats().allocatedInCurrentThread-before;
        if(run) {times~=elapsed;allocated+=bytes;}
        foreach(value;edges)checksum+=value;
    }
    times.sort;
    writeln("feature,ns_per_pixel,gc_bytes_per_call,scratch_payload,checksum");
    writefln("canny,%.3f,%s,%s,%s",cast(double)times[$/2]/input.length,
        allocated/repeats,input.length*(4*float.sizeof+size_t.sizeof),checksum);
}

void qualitySweep(size_t size,size_t repeats)
{
    auto input=new float[size*size];
    foreach(i,ref value;input)value=cast(float)((i*37+i/size*17+(i%size)*(i/size))%256)/255;
    auto scratch=new double[input.length];
    long[] times;ulong allocated;double checksum=0;
    foreach(run;0..repeats+1) {
        RegionQuality result;
        const before=GC.stats().allocatedInCurrentThread;
        const start=MonoTime.currTime;
        const ok=tryRegionQuality(input,size,size,scratch,result);
        const elapsed=(MonoTime.currTime-start).total!"nsecs";
        const bytes=GC.stats().allocatedInCurrentThread-before;
        if(!ok)throw new Exception("Quality benchmark needs an interior");
        if(run) {times~=elapsed;allocated+=bytes;}
        checksum+=result.noiseSigma+result.gradientEnergy+result.detailFrequency+result.samples;
    }
    times.sort;
    writeln("feature,ns_per_pixel,gc_bytes_per_call,scratch_payload,checksum");
    writefln("regionQuality,%.3f,%s,%s,%.12g",cast(double)times[$/2]/input.length,
        allocated/repeats,scratch.length*double.sizeof,checksum);
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
