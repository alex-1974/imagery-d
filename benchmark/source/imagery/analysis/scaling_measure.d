module imagery.analysis.scaling_measure;

import imagery.analysis.feature_regions;
import raster.region : Region2D;
import core.thread : Thread;
import core.sync.barrier : Barrier;
import core.memory : GC;
import core.time : MonoTime;
import std.algorithm : min,sort;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.conv : to;
import std.stdio : writeln,writefln;
import std.exception : enforce;

// Benchmark-only ownership model: each thread owns its Engine, Source closure,
// scratch and cache. Input is a pure coordinate formula. Output storage is
// allocated before starting threads and each tile has exactly one writer.
// No RasterLease/refcount or Engine instance crosses a worker boundary.
private class Worker {
    size_t id,workers,size,frames;
    Feature feature;
    Barrier barrier;
    float[][] channels;
    ubyte[][] masks;
    ulong[] bytes,computed;
    Throwable failure;
    void execute() {
        Engine engine;Source source;
        source.identity="isolated-scaling";source.grid="pixels";source.band="scalar";source.unit="1";
        source.width=source.height=size;
        source.read=(Region2D r,scope Sample[] values) @safe {
            foreach(i,ref sample;values) {
                const x=r.x+i%r.width,y=r.y+i/r.width;
                sample=Sample(cast(float)((x*37+y*17+x*y%97)&255)/255,[0,0,0],true);
            }
        };
        auto revisions=new string[frames];foreach(i,ref revision;revisions)revision="frame-"~i.to!string;
        try { engine.reservePlanar(4*1024*1024,2*1024*1024,4); }
        catch(Throwable error){failure=error;}
        enum edge=128;
        const columns=(size+edge-1)/edge,tiles=columns*columns;
        foreach(frame;0..frames) {
            barrier.wait();
            const before=GC.stats().allocatedInCurrentThread,initial=engine.metrics.featureEvaluations;
            if(failure is null)try {
                source.revision=revisions[frame];
                for(size_t tile=id;tile<tiles;tile+=workers) {
                    const x=tile%columns*edge,y=tile/columns*edge;
                    engine.runPlanar(source,Region2D(x,y,min(edge,size-x),min(edge,size-y)),feature,edge,
                        (Region2D r,scope FeaturePlanes32 values,Provenance origin) {
                            foreach(row;0..r.height) {
                                const offset=(r.y+row)*size+r.x,local=row*r.width;
                                foreach(c;0..3)channels[c][offset..offset+r.width]=values.channels[c][local..local+r.width];
                                masks[0][offset..offset+r.width]=values.validity[local..local+r.width];
                                masks[1][offset..offset+r.width]=values.orientationValid[local..local+r.width];
                                masks[2][offset..offset+r.width]=values.rangeFailure[local..local+r.width];
                            }
                        });
                }
            } catch(Throwable error){failure=error;}
            bytes[frame]=GC.stats().allocatedInCurrentThread-before;
            computed[frame]=engine.metrics.featureEvaluations-initial;
            barrier.wait();
        }
    }
}

void runScalingBench(size_t size,size_t repeats,size_t available)
{
    const tiles=((size+127)/128)^^2;
    enforce(available>0&&available<=tiles,"Need at least one independent tile per requested worker; enlarge size");
    writeln("operator,size,workers,ns_per_pixel,speedup,efficiency,gc_bytes,computed_tiles,digest");
    foreach(feature;[Feature.gaussian,Feature.gradient,Feature.median,Feature.ridge,Feature.gabor,Feature.localNormalization,Feature.pathOpening]) {
        string expected;double baseline;
        size_t previous;
        foreach(count;[1UL,min(2UL,available),min(4UL,available),available]) {
            if(count==previous)continue;previous=count;
            auto barrier=new Barrier(cast(uint)count+1);
            float[][] channels;ubyte[][] masks;
            foreach(c;0..3){channels~=new float[size*size];masks~=new ubyte[size*size];}
            auto states=new Worker[count];auto threads=new Thread[count];
            foreach(i;0..count) {
                auto worker=new Worker;states[i]=worker;
                worker.id=i;worker.workers=count;worker.size=size;worker.frames=repeats+4;worker.feature=feature;
                worker.barrier=barrier;worker.channels=channels;worker.masks=masks;
                worker.bytes=new ulong[repeats+4];worker.computed=new ulong[repeats+4];
                threads[i]=new Thread(&worker.execute);threads[i].start();
            }
            long[] times;ulong bytes,computed;
            foreach(frame;0..repeats+4) {
                const start=MonoTime.currTime;barrier.wait();barrier.wait();
                const elapsed=(MonoTime.currTime-start).total!"nsecs";
                if(frame>=4)times~=elapsed;
            }
            foreach(i;0..count) {
                threads[i].join();if(states[i].failure !is null)throw states[i].failure;
                foreach(frame;4..repeats+4){bytes+=states[i].bytes[frame];computed+=states[i].computed[frame];}
            }
            import std.digest.sha : SHA256;
            SHA256 hash;hash.start();
            foreach(plane;channels)hash.put(cast(const(ubyte)[])plane);
            foreach(plane;masks)hash.put(plane);
            const digest=hash.finish().toHexString;
            if(!expected.length)expected=digest.idup;else enforce(expected==digest[],"Multicore output bit patterns differ");
            enforce(bytes==0&&computed>0,"Actual per-worker warm computations must allocate zero GC bytes");
            times.sort;const ns=cast(double)times[$/2]/(size*size);
            if(count==1)baseline=ns;
            writefln("%s,%s,%s,%.3f,%.3f,%.3f,%s,%s,%s",feature,size,count,ns,baseline/ns,baseline/ns/count,bytes,computed,digest);
        }
    }
}
