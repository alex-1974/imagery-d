module imagery.analysis.worker_measure;

import imagery.analysis.feature_worker32;
import imagery.analysis.feature_regions : Point,Value,Sample,evaluate,describeTileFeature;
import raster : RasterLease,OwnedByteResource,PlaneByteLayout,Region2D,
    tryAdoptMallocResource,tryImportOwnedRaster,RasterPlaneWindow,withPlane;
import core.stdc.stdlib : malloc;
import core.memory : GC;
import core.time : MonoTime;
import std.algorithm : min,max,sort;
import std.math : isFinite;
import std.stdio : writeln,writefln;

private alias Tap=Point delegate(int,int) @safe nothrow @nogc;

// Preserve the original delegate boundary as an independently compiled ABI
// call. Both paths use double working samples/arithmetic, explicit halos and
// source validity; publication is AoS float64 versus opt-in SoA float32.
pragma(inline,false)
Value delegatedReference(Feature feature,Sample center,scope Tap read) @safe nothrow @nogc
{
    return evaluate(feature,false,center,read);
}

private struct ReferenceReader
{
    Point[] points;
    size_t stride;
    int x,y;
    Point opCall(int dx,int dy) const @safe nothrow @nogc {
        return points[(y+dy)*stride+x+dx];
    }
}

private void referenceTile(scope ref const RasterPlaneWindow!double input,
    Region2D core,size_t halo,scope Point[] scratch,scope Value[] output,Feature feature) @safe nothrow @nogc
{
    const width=core.width+2*halo,height=core.height+2*halo;
    foreach(y;0..height) {
        const row=input.row(core.y-halo+y);
        foreach(x;0..width) {
            const value=row.load(core.x-halo+x);
            scratch[y*width+x]=Point(value,isFinite(value));
        }
    }
    ReferenceReader reader;reader.points=scratch[0..width*height];reader.stride=width;
    foreach(y;0..core.height)foreach(x;0..core.width) {
        reader.x=cast(int)(x+halo);reader.y=cast(int)(y+halo);
        const center=reader(0,0);
        output[y*core.width+x]=delegatedReference(feature,Sample(center.value,[0,0,0],center.valid),&reader.opCall);
    }
}

// Test/benchmark fixture ownership boundary; raster-d validates the descriptor
// and owns the malloc release obligation for the complete measurement.
private RasterLease!double inputPlane(size_t size,size_t halo)
{
    const side=size+2*halo,bytes=side*side*double.sizeof;
    auto memory=cast(double*)malloc(bytes);
    if(memory is null)throw new Exception("Benchmark fixture allocation failed");
    foreach(y;0..side)foreach(x;0..side) {
        const sx=max(0,min(cast(long)size-1,cast(long)x-cast(long)halo));
        const sy=max(0,min(cast(long)size-1,cast(long)y-cast(long)halo));
        const value=cast(ubyte)((sx*37+sy*17+(sx*sy)%97)&255);
        memory[y*side+x]=cast(float)value/255;
    }
    OwnedByteResource resource;
    if(!tryAdoptMallocResource(memory,bytes,resource))throw new Exception("Benchmark fixture adoption failed");
    PlaneByteLayout[1] layout=[PlaneByteLayout(0,side*double.sizeof,double.sizeof)];
    RasterLease!double lease;
    if(!tryImportOwnedRaster!double(resource,layout[],Region2D(0,0,side,side),lease).ok)
        throw new Exception("Benchmark fixture import failed");
    return lease;
}

void runWorker32Bench(size_t size,size_t repeats)
{
    enum edge=256;
    writeln("feature,publication,ns_per_pixel,gc_bytes_per_call,work_payload,checksum,prepare_ns,prepare_gc_bytes");
    foreach(feature;[Feature.gaussian,Feature.gradient,Feature.localNormalization,
        Feature.ridge,Feature.gabor,Feature.pathOpening,Feature.median]) {
        Float32FeatureWorker worker;worker.prepare(feature,edge,edge);
        const halo=worker.halo;
        auto lease=inputPlane(size,halo);auto view=lease.view();
        auto scratch=new Point[(edge+2*halo)^^2];
        auto values=new Value[edge*edge];
        foreach(prepared;[false,true]) {
            long[] setupTimes;ulong setupBytes;
            foreach(run;0..repeats+1) {
                const before=GC.stats().allocatedInCurrentThread;
                const start=MonoTime.currTime;
                if(prepared)worker.prepare(feature,edge,edge);
                else {
                    scratch=new Point[(edge+2*halo)^^2];
                    values=new Value[edge*edge];
                }
                const elapsed=(MonoTime.currTime-start).total!"nsecs";
                const bytes=GC.stats().allocatedInCurrentThread-before;
                if(run) {setupTimes~=elapsed;setupBytes+=bytes;}
            }
            setupTimes.sort;
            long[] timings;ulong allocated;double checksum=0;
            foreach(run;0..repeats+1) {
                long elapsed;
                bool succeeded=true;
                const before=GC.stats().allocatedInCurrentThread;
                const visited=withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
                    for(size_t y=0;y<size;y+=edge)for(size_t x=0;x<size;x+=edge) {
                        const w=min(edge,size-x),h=min(edge,size-y),count=w*h;
                        const core=Region2D(x+halo,y+halo,w,h);
                        FeaturePlanes32 result;
                        const start=MonoTime.currTime;
                        if(prepared)
                            succeeded&=worker.tryEvaluate(input,core,result)==FeatureWorkerError.none;
                        else referenceTile(input,core,halo,scratch,values,feature);
                        elapsed+=(MonoTime.currTime-start).total!"nsecs";
                        // Observe every output after the kernel timer. Reference
                        // values are quantized only here for a comparable digest.
                        foreach(i;0..count) {
                            if(prepared) {
                                checksum+=result.validity[i]+result.orientationValid[i]+result.rangeFailure[i];
                                foreach(c;0..3)checksum+=result.channels[c][i];
                            } else {
                                checksum+=values[i].valid+values[i].orientationValid;
                                foreach(c;0..3)checksum+=cast(float)values[i].channels[c];
                            }
                        }
                    }
                });
                const bytes=GC.stats().allocatedInCurrentThread-before;
                if(!visited || !succeeded)throw new Exception("Prepared worker benchmark failed");
                if(run) {timings~=elapsed;allocated+=bytes;}
            }
            timings.sort;
            const payload=prepared?worker.scratchBytes:scratch.length*Point.sizeof+values.length*Value.sizeof;
            writefln("%s,%s,%.3f,%s,%s,%.12g,%s,%s",feature,prepared?"prepared-float32-soa":"delegate-float64-aos",
                cast(double)timings[$/2]/(size*size),allocated/repeats,payload,checksum,
                setupTimes[$/2],setupBytes/repeats);
        }
    }
}
