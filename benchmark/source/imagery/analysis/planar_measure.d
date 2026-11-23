module imagery.analysis.planar_measure;

import imagery.analysis.feature_regions;
import raster.region : Region2D;
import core.memory : GC;
import core.time : MonoTime;
import std.algorithm : sort;
import std.stdio : writeln,writefln;
import std.math : isFinite;
import std.exception : enforce;

void runPlanarBench(Source source,size_t size,size_t repeats)
{
    writeln("operator,mode,size,ns_per_pixel,gc_bytes,checksum,peak_tile_bytes,peak_cache_bytes");
    foreach(feature;[Feature.gaussian,Feature.gradient,Feature.median,Feature.ridge,Feature.gabor,
        Feature.localNormalization,Feature.pathOpening]) {
        double reference=0;
        foreach(planar;[false,true]) {
            long[] times;ulong allocated;double checksum=0;MemoryMetrics metrics;size_t cacheBytes;
            foreach(run;0..repeats+1) {
                Engine engine;
                const before=GC.stats().allocatedInCurrentThread,start=MonoTime.currTime;
                if(planar)engine.runPlanar(source,Region2D(0,0,size,size),feature,256,
                    (Region2D r,scope FeaturePlanes32 values,Provenance origin) {
                        foreach(i;0..r.width*r.height)if(values.validity[i])checksum+=values.channels[0][i];
                    });
                else engine.run(source,Region2D(0,0,size,size),feature,256,
                    (Region2D r,scope const(Value)[] values,Provenance origin) {
                        foreach(v;values)if(v.valid)checksum+=cast(float)v.channels[0];
                    });
                const elapsed=(MonoTime.currTime-start).total!"nsecs";
                const bytes=GC.stats().allocatedInCurrentThread-before;
                if(run){times~=elapsed;allocated+=bytes;}
                metrics=engine.metrics;cacheBytes=metrics.peakCacheBytes+engine.planarMetrics.peakBytes;
            }
            if(!planar)reference=checksum;else enforce(reference==checksum,"Direct planar strength projection differs");
            enforce(isFinite(checksum));times.sort;
            writefln("%s,%s,%s,%.3f,%s,%.12g,%s,%s",feature,planar?"engine-planar-cold":"engine-float64-cold",size,
                cast(double)times[$/2]/(size*size),allocated/repeats,checksum,metrics.peakTileBytes,cacheBytes);
        }
    }
}

void runCacheLayoutBench(Source source,size_t size)
{
    enforce(size<=256,"Cache layout probe needs one common output tile (size<=256)");
    writeln("operator,pixels,legacy_total_bytes,planar_dependency_bytes,planar_final_bytes,planar_total_bytes,whole_cache_ratio,final_pixel_payload_ratio,legacy_index_bytes,planar_index_bytes");
    foreach(feature;[Feature.gaussian,Feature.gradient,Feature.median,Feature.localNormalization]) {
        Engine legacy,planar;legacy.reserveCache(16*1024*1024,16);planar.reservePlanar(16*1024*1024,6*1024*1024,16);
        legacy.run(source,Region2D(0,0,size,size),feature,256,
            (Region2D r,scope const(Value)[] values,Provenance p) {});
        planar.runPlanar(source,Region2D(0,0,size,size),feature,256,
            (Region2D r,scope FeaturePlanes32 values,Provenance p) {});
        const oldBytes=legacy.metrics.liveCacheBytes,dependencies=planar.metrics.liveCacheBytes,finalBytes=planar.planarMetrics.retainedBytes;
        writefln("%s,%s,%s,%s,%s,%s,%.6f,%.6f,%s,%s",feature,size*size,oldBytes,dependencies,finalBytes,
            dependencies+finalBytes,cast(double)(dependencies+finalBytes)/oldBytes,15.0/Value.sizeof,
            legacy.metrics.cacheIndexBytes,planar.metrics.cacheIndexBytes+planar.planarMetrics.indexBytes);
    }
}
