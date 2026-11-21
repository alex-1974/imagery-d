module parameter_checks;
import imagery.analysis.feature_regions;
import raster.region : Region2D;
import std.math : abs;
import std.exception : enforce;

void checkParameters()
{
    Source source;
    source.width=11; source.height=9; source.identity="parameters"; source.revision="1";
    source.grid="pixels"; source.band="temperature"; source.unit="K";
    size_t reads;
    source.read=(Region2D r, scope Sample[] samples) {
        ++reads;
        foreach(i,ref s;samples) {
            const x=r.x+i%r.width, y=r.y+i/r.width;
            s=Sample(cast(double)((x*7+y*19)%37),[0,0,0],true);
        }
    };
    const region=Region2D(0,0,11,9);
    Engine engine;
    auto fixed=new Value[99];
    engine.run(source,region,Feature.localStatistics,256,
        (Region2D r, scope const(Value)[] values, Provenance p) { fixed[]=values; });
    const previous=reads;
    engine.run(source,region,Feature.localStatistics,256,LocalStatisticsParams.init,
        (Region2D r, scope const(Value)[] values, Provenance p) { enforce(values==fixed); });
    enforce(reads==previous && engine.hits==1);
    auto small=new Value[99];
    engine.run(source,region,Feature.localStatistics,256,LocalStatisticsParams(1,9),
        (Region2D r, scope const(Value)[] values, Provenance p) { small[]=values; enforce(p.parameters!=describeFeature(Feature.localStatistics).parameters); });
    enforce(reads>previous && small!=fixed);
    auto pieces=new Value[99];
    Engine tiled;
    tiled.run(source,region,Feature.localStatistics,3,LocalStatisticsParams(1,9),
        (Region2D r, scope const(Value)[] values, Provenance p) {
            foreach(i,v;values) pieces[(r.y+i/r.width)*11+r.x+i%r.width]=v;
        });
    foreach(i,p;pieces) {
        enforce(p.valid==small[i].valid);
        if(p.valid)foreach(c;0..3)enforce(abs(p.channels[c]-small[i].channels[c])<1e-12);
    }
    foreach(length;[1u,3u,7u,9u])foreach(step;[0u,1u,2u]) {
        PathMorphologyParams parameters=PathMorphologyParams(length,step);
        auto whole=new Value[99];
        Engine a,b;
        a.run(source,region,Feature.pathOpening,256,parameters,
            (Region2D r, scope const(Value)[] values, Provenance p) { whole[]=values; });
        b.run(source,region,Feature.pathOpening,3,parameters,
            (Region2D r, scope const(Value)[] values, Provenance p) {
                foreach(i,v;values) enforce(v==whole[(r.y+i/r.width)*11+r.x+i%r.width]);
            });
        if(length==1)foreach(i,v;whole)enforce(v.channels[0]==cast(double)(((i%11)*7+(i/11)*19)%37));
    }
    const before=reads;
    bool rejected;
    try { engine.run(source,region,Feature.localStatistics,3,LocalStatisticsParams(0,0),
        (Region2D,scope const(Value)[],Provenance){}); }
    catch(Exception) { rejected=true; }
    enforce(rejected && reads==before);
}
