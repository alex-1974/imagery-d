module imagery.analysis.resource_measure;

import imagery.analysis.feature_regions;
import imagery.analysis.feature_contracts : FeatureAccess;
import raster.region : Region2D;
import core.memory : GC;
import core.time : MonoTime;
import std.stdio : writeln,writefln;
import std.math : isFinite;
import std.conv : to;

// Small cache pressure deliberately forces actual recomputation after setup.
// A cache-hit-only loop cannot satisfy this deterministic allocation probe.
void runResourceBench(size_t repeats)
{
    Source source;source.identity="resource-probe";source.revision="1";source.grid="pixels";
    source.band="RGB";source.unit="1";source.width=source.height=64;source.rgb=true;
    source.read=(Region2D region,scope Sample[] samples) @safe {
        foreach(i,ref sample;samples) {
            const x=region.x+i%region.width,y=region.y+i/region.width;
            const v=cast(ubyte)((37*x+17*y+x*y%97)&255);
            sample=Sample(0,[v,cast(ubyte)(255-v),v],true);
        }
    };
    writeln("feature,mode,ns_per_pixel,gc_bytes,computed_tiles,source_reads,cache_hits,cache_reuses,scratch_reuses,peak_tile_bytes,peak_cache_bytes,checksum");
    size_t count;
    foreach(feature;__traits(allMembers,Feature)) {
        enum selected=__traits(getMember,Feature,feature);
        if(describeFeature(selected).access!=FeatureAccess.tile)continue;
        foreach(planar;[false,true]) {
        Engine engine;
        if(planar)engine.reservePlanar(128*1024,48*1024,8);else engine.reserveCache(64*1024,8);
        double checksum=0;
        Sink consume=(Region2D tile,scope const(Value)[] values,Provenance origin) @safe {
            foreach(v;values)if(v.valid)foreach(c;0..3)checksum+=v.channels[c];
        };
        PlanarSink consumePlanar=(Region2D tile,scope FeaturePlanes32 values,Provenance origin) @safe {
            foreach(i;0..values.width*values.height)if(values.validity[i])foreach(c;0..3)checksum+=values.channels[c][i];
        };
        void evaluate() {
            if(planar)engine.runPlanar(source,Region2D(0,0,64,64),selected,16,consumePlanar);
            else engine.run(source,Region2D(0,0,64,64),selected,16,consume);
        }
        // A larger support can use a larger processing tile than the request;
        // the explicit max edge remains 16 so there are at least 16 misses.
        evaluate();
        evaluate();
        const metrics=engine.metrics,hits=engine.hits,planarBefore=engine.planarMetrics;
        const before=GC.stats().allocatedInCurrentThread,started=MonoTime.currTime;
        foreach(run;0..repeats)evaluate();
        const elapsed=(MonoTime.currTime-started).total!"nsecs";
        const bytes=GC.stats().allocatedInCurrentThread-before,after=engine.metrics;
        const computed=after.featureEvaluations-metrics.featureEvaluations;
        if(!computed||!isFinite(checksum))throw new Exception("Resource probe did not compute finite output");
        writefln("%s,%s,%.3f,%s,%s,%s,%s,%s,%s,%s,%s,%.12g",feature,planar?"engine-planar-warm-miss":"engine-float64-warm-miss",
            cast(double)elapsed/(4096*repeats),bytes,computed,after.sourceTileReads-metrics.sourceTileReads,
            engine.hits-hits,planar?engine.planarMetrics.reuses-planarBefore.reuses:after.cachePayloadReuses-metrics.cachePayloadReuses,
            after.scratchReuses-metrics.scratchReuses,after.peakTileBytes,
            after.peakCacheBytes+(planar?engine.planarMetrics.peakBytes:0),checksum);
        ++count;
        if(bytes)throw new Exception("Warm Engine computed work allocated: "~feature~" ("~bytes.to!string~")");
        }
    }
    if(count!=98)throw new Exception("Incomplete tile catalogue resource probe");
    writeln("ENGINE_WARM_COMPUTED_ALLOCATION=PASS; 49 features x two precision modes, bounded caches, actual misses");
}
