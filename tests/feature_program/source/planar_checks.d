module planar_checks;

import imagery.analysis.feature_regions;
import core.memory : GC;
import raster.region : Region2D;
import std.exception : enforce;
import std.json : JSONValue;
import std.math : isFinite;

private Source fixture(uint regime) @safe
{
    Source source;source.identity="planar-oracle";source.revision="regime";
    source.grid="pixels";source.width=37;source.height=31;source.band=regime<2?"RGB":"measurement";
    source.unit=regime<2?"1":"K";source.rgb=regime<2;
    source.read=(Region2D r,scope Sample[] values) @safe {
        foreach(i,ref v;values) {
            const x=r.x+i%r.width,y=r.y+i/r.width;
            const code=cast(ubyte)((x*37+y*19+x*y)%256);
            double value=cast(double)(cast(int)(x*7+y*3)%29-14);
            if(regime==2)value*=1e40;else if(regime==3)value*=1e-300;
            if(regime>=2&&(x*3+y*5)%31==0)value=double.nan;
            v=Sample(value,[code,cast(ubyte)(255-code),cast(ubyte)(code/2)],regime!=1||(x*3+y*5)%43!=0);
        }
    };
    return source;
}

private void compare(Value expected,scope FeaturePlanes32 actual,size_t i,ref size_t rangeFailures) @safe
{
    bool mathematical=expected.valid,representable=expected.valid;float[3] converted;
    foreach(c;0..3) {
        mathematical&=isFinite(expected.channels[c]);converted[c]=cast(float)expected.channels[c];
        representable&=isFinite(converted[c]);
    }
    representable&=mathematical;
    enforce(actual.validity[i]==representable,"Planar validity");
    enforce(actual.rangeFailure[i]==(mathematical&&!representable),"Planar representability");
    enforce(actual.orientationValid[i]==(representable&&expected.orientationValid&&converted[0]!=0),"Planar orientation/underflow");
    foreach(c;0..3)enforce(actual.channels[c][i]==(representable?converted[c]:0),"Exact final float32 rounding");
    rangeFailures+=actual.rangeFailure[i];
}

void checkPlanar(ref JSONValue result)
{
    checkFailures();
    size_t cases,pixels,rangeFailures;
    foreach(regime;0..4) {
        auto source=fixture(regime);
        foreach(featureName;__traits(allMembers,Feature)) {
            enum feature=__traits(getMember,Feature,featureName);
            const descriptor=describeFeature(feature);
            if(descriptor.access!=FeatureAccess.tile||(!source.rgb&&descriptor.rgbOnly))continue;
            Engine reference;auto expected=new Value[source.width*source.height];
            reference.run(source,Region2D(0,0,source.width,source.height),feature,17,
                (Region2D tile,scope const(Value)[] values,Provenance origin) @safe {
                    foreach(i,v;values)expected[(tile.y+i/tile.width)*source.width+tile.x+i%tile.width]=v;
                });
            foreach(edge;[7UL,32UL]) {
                Engine engine;const roi=Region2D(3,5,31,23);size_t visited;
                const expectedParameters=describePlanarFeature(feature).parameters;
                PlanarSink sink=(Region2D tile,scope FeaturePlanes32 actual,Provenance origin) @safe {
                    enforce(origin.extent==tile&&origin.gridWidth==source.width&&origin.unit==source.unit);
                    enforce(origin.parameters==expectedParameters);
                    foreach(i;0..actual.width*actual.height) {
                        const global=(tile.y+i/tile.width)*source.width+tile.x+i%tile.width;
                        compare(expected[global],actual,i,rangeFailures);++visited;
                    }
                };
                engine.runPlanar(source,roi,feature,edge,sink);
                enforce(visited==roi.width*roi.height);
                const reads=engine.metrics.sourceTileReads;visited=0;
                engine.runPlanar(source,roi,feature,edge,sink);
                enforce(visited==roi.width*roi.height&&engine.metrics.sourceTileReads==reads,"Planar exact cache replay");
                enforce(engine.metrics.peakTileBytes<=8*1024*1024);
                enforce(engine.metrics.liveCacheBytes+engine.planarMetrics.retainedBytes<=16*1024*1024);
                pixels+=2*visited;++cases;
            }
        }
    }
    // Shared full-precision dependencies must not be reconstructed from rounded
    // cached output. The large-offset scientific fixture amplifies that bug.
    auto source=fixture(2);const roi=Region2D(3,5,21,17);
    Feature[4] features=[Feature.localStatistics,Feature.localNormalization,Feature.gradient,Feature.dynamicRange];
    auto expected=new Value[features.length*source.width*source.height];Engine reference;
    runFeatureView(reference,source,Region2D(0,0,source.width,source.height),features[],13,
        (Region2D tile,scope const(Value)[] values,Provenance origin) @safe {
            size_t f;while(features[f]!=origin.feature)++f;
            foreach(i,v;values)expected[f*source.width*source.height+(tile.y+i/tile.width)*source.width+tile.x+i%tile.width]=v;
        });
    Engine mixed;size_t mixedPixels;
    mixed.runPlanarView(source,roi,features[],11,
        (Region2D tile,scope FeaturePlanes32 actual,Provenance origin) @safe {
            size_t f;while(features[f]!=origin.feature)++f;
            foreach(i;0..actual.width*actual.height) {
                compare(expected[f*source.width*source.height+(tile.y+i/tile.width)*source.width+tile.x+i%tile.width],actual,i,rangeFailures);
                ++mixedPixels;
            }
        });
    enforce(mixedPixels==roi.width*roi.height*features.length&&rangeFailures>0);
    result["planar_cases"]=JSONValue(cases);result["planar_pixels"]=JSONValue(pixels+mixedPixels);
    result["planar_range_failures"]=JSONValue(rangeFailures);
}

private void checkFailures() @safe
{
    import std.exception : assertThrown;
    auto source=fixture(0);const roi=Region2D(0,0,8,8);Engine engine;
    PlanarSink ignore=(Region2D r,scope FeaturePlanes32 values,Provenance p) @safe {};
    auto unidentified=source;unidentified.identity=null;
    assertThrown(engine.runPlanar(unidentified,roi,Feature.gaussian,8,ignore));
    assertThrown(engine.reservePlanar(1024,1024));
    assertThrown(engine.reserveCache(1,1));
    auto broken=source;broken.read=(Region2D r,scope Sample[] values) @safe {throw new Exception("provider failure");};
    assertThrown(engine.runPlanar(broken,roi,Feature.gaussian,8,ignore));
    // Both cache misses and hits must unwind serial guards after sink failure.
    PlanarSink fail=(Region2D r,scope FeaturePlanes32 values,Provenance p) @safe {throw new Exception("sink failure");};
    assertThrown(engine.runPlanar(source,roi,Feature.gaussian,8,fail));
    assertThrown(engine.runPlanar(source,roi,Feature.gaussian,8,fail));
    size_t reentryChecks;
    foreach(feature;[Feature.gaussian,Feature.gradient])
        engine.runPlanar(source,roi,feature,8,
            (Region2D r,scope FeaturePlanes32 values,Provenance p) @safe {
                assertThrown(engine.runPlanar(source,roi,feature,8,ignore));
                assertThrown(engine.run(source,roi,feature,8,
                    (Region2D t,scope const(Value)[] v,Provenance origin) @safe {}));
                assertThrown(engine.reserveCache());assertThrown(engine.reservePlanar());
                ++reentryChecks;
            });
    enforce(reentryChecks==2);
    engine.runPlanar(source,roi,Feature.gaussian,8,ignore);
    const reads=engine.metrics.sourceTileReads;
    source.revision="changed-revision";engine.runPlanar(source,roi,Feature.gaussian,8,ignore);
    enforce(engine.metrics.sourceTileReads>reads,"Changed revision must compute new work");
    engine.reserveCache(); // A precision-mode reconfiguration clears compact owners.
    enforce(engine.planarMetrics.retainedBytes==0);
    engine.runPlanar(source,roi,Feature.gaussian,8,ignore);
}
