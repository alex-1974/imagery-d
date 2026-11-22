module mixed_checks;

import imagery.analysis.feature_regions;
import raster.region : Region2D;
import std.algorithm : min,max;
import std.exception : enforce,assertThrown;
import std.json : JSONValue;
import std.math : nextUp;

@safe:

private class Reads {size_t count;}

private Source fixture(Reads reads,bool rgb)
{
    Source source;
    source.identity="mixed-view";source.revision="1";source.grid="pixels";
    source.band=rgb?"RGB":"scalar";source.unit=rgb?"1":"K";
    source.rgb=rgb;source.width=24;source.height=20;
    source.read=(Region2D r,scope Sample[] values) {
        ++reads.count;
        foreach(i,ref value;values) {
            const x=r.x+i%r.width,y=r.y+i/r.width;
            const v=cast(ubyte)(20+(17*x+13*y+x*y)%210);
            value=Sample(273+cast(double)v/32,[v,cast(ubyte)(255-v),v],!(x==4 && y==5));
        }
    };
    return source;
}

private void equal(Value actual,Value expected)
{
    enforce(actual.valid==expected.valid && actual.orientationValid==expected.orientationValid);
    if(actual.valid)enforce(actual.channels==expected.channels);
}

private void reference(ref Engine engine,Source source,Region2D region,Feature feature,
    size_t edge,FeatureViewParams p,scope Sink sink)
{
    switch(feature) {
        case Feature.localStatistics,Feature.localNormalization,Feature.dynamicRange:
            engine.run(source,region,feature,edge,p.statistics,sink);break;
        case Feature.pathOpening,Feature.pathClosing:
            engine.run(source,region,feature,edge,p.paths,sink);break;
        case Feature.ridge: engine.run(source,region,feature,edge,p.ridge,sink);break;
        case Feature.lineResponse: engine.run(source,region,feature,edge,p.line,sink);break;
        case Feature.gabor: engine.run(source,region,feature,edge,p.gabor,sink);break;
        case Feature.shadowCandidate:
            engine.run(source,region,feature,edge,ShadowParams(p.statistics,p.shadowLuminanceCeiling),sink);break;
        default: engine.run(source,region,feature,edge,sink);
    }
}

private size_t checkFamilies(bool rgb)
{
    auto reads=new Reads;auto source=fixture(reads,rgb);
    const region=Region2D(3,2,17,15);enum edge=9,tiles=4;
    Feature[] selected=[Feature.localStatistics,Feature.localNormalization,Feature.dynamicRange,
        Feature.gradient,Feature.ridge,Feature.lineResponse,Feature.gabor,
        Feature.pathOpening,Feature.pathClosing,Feature.openingProfile];
    if(rgb)selected~=Feature.shadowCandidate;
    FeatureViewParams p;
    p.statistics=LocalStatisticsParams(5,20);p.paths=PathMorphologyParams(5,2);
    p.ridge=RidgeParams(2,5);p.line=LineResponseParams(RidgeParams(2,4),2);
    p.gabor.wavelengths=[1.5,3.5];p.gabor.sigmaRatio=.6;p.gabor.supportRatio=1.25;
    p.shadowLuminanceCeiling=.4;
    Value[][Feature] expected;string[Feature] identities;
    foreach(feature;selected) {
        expected[feature]=new Value[region.width*region.height];Engine single;
        reference(single,source,region,feature,edge,p,
            (Region2D r,scope const(Value)[] values,Provenance origin) {
                identities[feature]=origin.parameters;
                foreach(i,value;values)expected[feature][(r.y-region.y+i/r.width)*region.width+r.x-region.x+i%r.width]=value;
            });
    }
    Engine batch;size_t emitted;
    Sink verify=(Region2D r,scope const(Value)[] values,Provenance origin) {
        const tile=emitted/selected.length;
        const x=region.x+(tile%2)*edge,y=region.y+(tile/2)*edge;
        enforce(r==Region2D(x,y,min(edge,region.x+region.width-x),min(edge,region.y+region.height-y)));
        enforce(origin.feature==selected[emitted%selected.length] && origin.extent==r);
        enforce(origin.parameters==identities[origin.feature]);
        foreach(i,value;values)equal(value,expected[origin.feature][(r.y-region.y+i/r.width)*region.width+r.x-region.x+i%r.width]);
        ++emitted;
    };
    const before=reads.count;
    runFeatureView(batch,source,region,selected,edge,p,verify);
    enforce(emitted==tiles*selected.length && reads.count-before==tiles);
    enforce(batch.metrics.sourceTileReads==tiles && batch.metrics.scalarTilePreparations==tiles);
    const coldReads=reads.count;emitted=0;
    runFeatureView(batch,source,region,selected,edge,p,verify);
    enforce(emitted==tiles*selected.length && reads.count==coldReads);
    // Changing one family must not invalidate unrelated feature identities.
    auto changed=p;changed.ridge.lastRadius=6;
    const prior=batch.metrics;
    runFeatureView(batch,source,region,selected,edge,changed,
        (Region2D r,scope const(Value)[] values,Provenance origin) {
            if(origin.feature!=Feature.ridge) {
                enforce(origin.parameters==identities[origin.feature]);
                foreach(i,value;values)equal(value,expected[origin.feature][(r.y-region.y+i/r.width)*region.width+r.x-region.x+i%r.width]);
            } else enforce(origin.parameters!=identities[origin.feature]);
        });
    enforce(batch.metrics.featureEvaluations-prior.featureEvaluations==tiles);
    if(rgb) {
        auto shadow=p;shadow.shadowLuminanceCeiling=nextUp(p.shadowLuminanceCeiling);
        const earlier=batch.metrics;
        runFeatureView(batch,source,region,[Feature.shadowCandidate],edge,shadow,
            (Region2D r,scope const(Value)[] values,Provenance origin) {
                enforce(origin.parameters!=identities[Feature.shadowCandidate]);
            });
        enforce(batch.metrics.dependencyEvaluations==earlier.dependencyEvaluations);
        enforce(batch.metrics.dependencyCacheHits-earlier.dependencyCacheHits==tiles);
    }
    // A complete settings value validates even its currently unused families.
    auto invalid=p;invalid.gabor.sigmaRatio=double.nan;
    const readsBefore=reads.count,hitsBefore=batch.hits;size_t callbacks;
    assertThrown!Exception(runFeatureView(batch,source,region,[Feature.gradient],edge,invalid,
        (Region2D r,scope const(Value)[] values,Provenance origin){++callbacks;}));
    enforce(reads.count==readsBefore && batch.hits==hitsBefore && callbacks==0);
    // Explicit aggregate defaults use the legacy cache identity.
    Engine defaults;
    runFeatureView(defaults,source,region,selected,edge,
        (Region2D r,scope const(Value)[] values,Provenance origin){});
    const legacyReads=reads.count,legacyHits=defaults.hits;
    const FeatureViewParams initial;
    runFeatureView(defaults,source,region,selected,edge,initial,
        (Region2D r,scope const(Value)[] values,Provenance origin){});
    enforce(reads.count==legacyReads && defaults.hits-legacyHits==tiles*selected.length);
    enforce(batch.metrics.peakTileBytes<=8*1024*1024 && batch.metrics.peakCacheBytes<=16*1024*1024);
    return selected.length*region.width*region.height;
}

void checkMixedViews(ref JSONValue root)
{
    root["mixed_view_samples"]=JSONValue(checkFamilies(false)+checkFamilies(true));
    FeatureViewParams p;
    p.statistics=LocalStatisticsParams(31,200);
    p.line=LineResponseParams(RidgeParams(1,31),31);
    p.paths=PathMorphologyParams(31,2);
    p.gabor.wavelengths=[15.5,16];p.gabor.supportRatio=2;
    Source source;source.identity="max-mixed";source.revision="1";source.grid="pixels";
    source.band="scalar";source.unit="K";source.width=source.height=3;
    source.read=(Region2D r,scope Sample[] values) {foreach(ref v;values)v=Sample(273,[0,0,0],true);};
    Feature[5] families=[Feature.localStatistics,Feature.lineResponse,Feature.gabor,Feature.openingProfile,Feature.pathOpening];
    size_t peak;
    foreach(mask;1..32) {
        Feature[] selected;
        foreach(i,feature;families)if(mask & (1<<i))selected~=feature;
        Engine engine;size_t emitted;
        runFeatureView(engine,source,Region2D(1,1,1,1),selected,256,p,
            (Region2D r,scope const(Value)[] values,Provenance origin) {
                enforce(values.length==1 && values[0].valid && !values[0].orientationValid);
                const v=values[0];
                if(origin.feature==Feature.localStatistics)enforce(v.channels==[273.0,0,0]);
                else if(origin.feature==Feature.openingProfile)enforce(v.channels==[273.0,273,273]);
                else if(origin.feature==Feature.pathOpening)enforce(v.channels==[273.0,0,0]);
                else enforce(v.channels==[0.0,0,0]);
                ++emitted;
            });
        enforce(emitted==selected.length && engine.metrics.sourceTileReads==1);
        enforce(engine.metrics.peakTileBytes<=8*1024*1024);
        peak=max(peak,engine.metrics.peakTileBytes);
        if(mask==1)enforce(engine.metrics.scratchAllocations==4,"Unused custom Gabor settings must not prepare a bank");
    }
    root["mixed_view_combinations"]=JSONValue(31);
    root["mixed_view_peak_bytes"]=JSONValue(peak);
}
