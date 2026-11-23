module planar_positive;

import imagery.analysis.feature_regions;
import imagery.analysis.cost_path;
import imagery.analysis.canny_worker;
import raster.region : Region2D;

struct Costs {
    double opCall(size_t x,size_t y) @safe nothrow @nogc {return 1;}
}

void positive(Source source,ref Engine engine) @safe
{
    engine.reserveCache(maxBytes: 1024*1024,maxEntries: 16);
    engine.reservePlanar(totalBytes: 2*1024*1024,dependencyBytes: 1024*1024,maxEntries:16);
    engine.runPlanar(source: source,region: Region2D(0,0,8,8),feature: Feature.gradient,edge: 8,
        sink: (Region2D tile,scope FeaturePlanes32 output,Provenance origin) @safe {});
    LazyCostPath!Costs search;
    search.prepare(source: Costs.init,width:100,height:100,maxWindowPixels:64);
    query(search);
}

void query(ref LazyCostPath!Costs search) @safe nothrow @nogc
{
    size_t[1] seeds=[101];size_t[64] path;
    const error=search.reset(seeds:seeds[],window:Region2D(1,1,8,8));
    const ready=search.advance(target:202,maxSettled:7);
    const cost=search.distanceTo(target:202);
    const count=search.pathTo(target:202,output:path[]);
}

void cannyQuery(ref CannyWorkspace worker,scope const(float)[] input,scope ubyte[] output) @safe nothrow @nogc
{
    const result=worker.tryRun(input:input,width:8,height:8,low:.1f,high:.3f,destination:output);
    const bytes=worker.storageBytes;
}
