module region_program;
import imagery.analysis.feature_components;
import imagery.analysis.feature_regions : Source,Sample;
import imagery.analysis.color_slic;
import imagery.analysis.region_graph;
import raster.region : Region2D;
import std.json : JSONValue,JSONType;
import std.conv : to;
import std.exception : enforce;
import std.math : isFinite;
import core.time : MonoTime;
import core.memory : GC;

@safe:
private JSONValue number(double x){return isFinite(x)?JSONValue(x):JSONValue(null);}
private JSONValue numbers(scope const(double)[] values)
{JSONValue[] a;foreach(x;values)a~=number(x);return JSONValue(a);}
private ComponentStore ramStore(uint[] storage,Region2D extent)
{
    ComponentStore store;
    store.read=(Region2D row,scope uint[] values){
        const start=(row.y-extent.y)*extent.width+row.x-extent.x;
        values[]=storage[start..start+values.length];};
    store.write=(Region2D row,scope const(uint)[] values){
        const start=(row.y-extent.y)*extent.width+row.x-extent.x;
        storage[start..start+values.length]=values[];};
    return store;
}
private JSONValue graphJson(const RegionGraph graph)
{
    JSONValue result;JSONValue[] nodes,edges,mapping,history;
    foreach(node;graph.regions)
    {
        const s=node.statistics;JSONValue j;
        j["id"]=JSONValue(s.id);j["pixels"]=JSONValue(s.pixels);
        j["bounds"]=JSONValue([s.bounds.x,s.bounds.y,s.bounds.width,s.bounds.height]);
        j["mean"]=numbers(s.meanColor[]);j["variance"]=numbers(s.colorVariance[]);
        j["centroid"]=numbers(node.centroid[]);j["covariance"]=numbers(node.covariance[]);
        j["texture_count"]=JSONValue(s.textureSamples);j["edge_count"]=JSONValue(s.edgeSamples);
        j["texture"]=number(s.meanTexture);j["edge"]=number(s.meanEdge);
        j["texture_variance"]=number(node.textureVariance);j["edge_variance"]=number(node.edgeVariance);
        j["perimeter"]=JSONValue(s.perimeter);j["fill"]=number(s.fillRatio);
        j["orientation"]=number(s.orientation);j["oriented"]=JSONValue(s.orientationValid);
        uint[] neighbors;foreach(neighbor;graph.neighbors(s.id))
        {
            const edge=graph.edges[neighbor.edge];enforce(edge.first==s.id||edge.second==s.id);
            neighbors~=neighbor.id;
        }
        j["neighbors"]=JSONValue(neighbors);
        RegionDescriptor found;enforce(graph.tryRegion(s.id,found)&&found.statistics.id==s.id);
        nodes~=j;
    }
    foreach(edge;graph.edges)
    {
        JSONValue j;j["ids"]=JSONValue([edge.first,edge.second]);
        j["sides"]=JSONValue(edge.sharedSides);j["edge_count"]=JSONValue(edge.edgeSamples);
        j["edge"]=number(edge.meanEdge);j["variance"]=number(edge.varianceEdge);
        j["contrast"]=number(edge.colorContrast);edges~=j;
    }
    foreach(label;graph.labelMap)
    {uint current;enforce(graph.tryResolveLabel(label.original,current)&&current==label.current);
        mapping~=JSONValue([label.original,label.current]);}
    foreach(step;graph.mergeHistory)
        history~=JSONValue([cast(ulong)step.pair.first,step.pair.second,step.generation]);
    result["regions"]=JSONValue(nodes);result["edges"]=JSONValue(edges);
    result["map"]=JSONValue(mapping);result["history"]=JSONValue(history);
    result["generation"]=JSONValue(graph.provenance.generation);
    result["recipe"]=JSONValue(graph.provenance.segmentation);
    result["color_space"]=JSONValue(graph.provenance.colorSpace);
    enforce(graph.valid&&graph.provenance.source.identity=="region-program"&&
        graph.provenance.source.revision=="1"&&graph.provenance.source.grid=="pixel-grid");
    return result;
}

JSONValue runProgram(JSONValue request,
    ComponentStore delegate(string,Region2D) diskFactory) @system
{
    const w=request["width"].integer.to!size_t,h=request["height"].integer.to!size_t;
    const ox=request["origin_x"].integer.to!size_t,oy=request["origin_y"].integer.to!size_t;
    enforce(w&&h&&w<=4096&&h<=4096);const extent=Region2D(ox,oy,w,h);
    auto samples=new ComponentSample[w*h];
    foreach(i,ref sample;samples)
    {
        const j=request["samples"].array[i];sample.state=cast(ComponentSample.State)j[0].integer;
        sample.valid=j[1].boolean;foreach(c;0..3)sample.color[c]=j[c+2].floating;
        sample.texture=j[5].type==JSONType.null_?double.nan:j[5].floating;
        sample.edge=j[6].type==JSONType.null_?double.nan:j[6].floating;
    }
    ComponentReader input=(Region2D row,scope ComponentSample[] values){
        enforce(row.height==1&&row.width==values.length&&values.length<=256);
        const start=(row.y-oy)*w+row.x-ox;values[]=samples[start..start+values.length];};
    if("rgb" in request.object && request["rgb"].boolean)
    {
        enforce(ox==0&&oy==0);Source source;
        source.identity="rgb-scene";source.revision="1";source.grid="pixel-grid";
        source.rgb=true;source.width=w;source.height=h;
        source.read=(Region2D row,scope Sample[] output){foreach(i,ref value;output){
            const s=samples[(row.y+i/row.width)*w+row.x+i%row.width];
            value=Sample(0,[cast(ubyte)s.color[0],cast(ubyte)s.color[1],cast(ubyte)s.color[2]],s.valid);}};
        input=colorSlicRgb(source);
    }
    ComponentProvenance source=ComponentProvenance("region-program","1","pixel-grid","Lab","1");
    auto storage=new uint[w*h];ComponentStore labels;
    if(request["disk"].boolean)labels=diskFactory(request["disk_path"].str,extent);
    else labels=ramStore(storage,extent);
    const block=request["block"].integer.to!size_t;
    RegionGraph graph;JSONValue result;JSONValue[] snapshots;
    const before=GC.stats.allocatedInCurrentThread;const started=MonoTime.currTime;
    if(request["program"].str=="slic")
    {
        auto assignData=new uint[w*h];auto assignments=request["disk"].boolean?
            diskFactory(request["disk_path"].str~"-assign",extent):ramStore(assignData,extent);
        ComponentTransaction transaction;transaction.store=labels;
        uint commits,aborts;transaction.commit=() nothrow {++commits;};transaction.abort=() nothrow {++aborts;};
        ColorSlicRequest q;q.extent=extent;q.blockEdge=block;q.provenance=source;
        q.textureRecipe="caller-texture";q.edgeRecipe="caller-edge";
        q.parameters.spacing=request["spacing"].integer.to!size_t;
        q.parameters.compactness=request["compactness"].floating;
        q.parameters.iterations=request["iterations"].integer.to!uint;
        q.parameters.minimumSizeFactor=request["minimum_size"].floating;
        q.parameters.perturbSeeds=request["perturb"].boolean;
        q.maxCenters=1024;q.maxLabels=1024;q.maxEdges=4096;
        q.maxWorkBytes=8*1024*1024;q.maxResultBytes=8*1024*1024;q.maxDistanceEvaluations=1_000_000_000;
        ColorSlicSegmentation published;ColorSlicMetrics metrics;
        const error=tryColorSlic(q,input,assignments,transaction,published,metrics);
        enforce(error==ColorSlicError.none,error.to!string~" / "~metrics.graphError.to!string~" / "~metrics.componentError.to!string);
        enforce(published.valid&&commits==1&&!aborts);graph=published.graph;
        result["centers"]=JSONValue(metrics.centers);result["comparisons"]=JSONValue(metrics.distanceEvaluations);
        result["fallbacks"]=JSONValue(metrics.fallbackPixels);result["cleanup_rounds"]=JSONValue(metrics.cleanupRounds);
        result["work_bytes"]=JSONValue(metrics.workBytes);
        if(request["disk"].boolean)foreach(y;0..h)
            assignments.read(Region2D(ox,oy+y,w,1),assignData[y*w..(y+1)*w]);
        result["assignments"]=JSONValue(assignData);
    }
    else
    {
        uint[] given;foreach(v;request["labels"].array)given~=v.integer.to!uint;
        foreach(y;0..h)labels.write(Region2D(ox,oy+y,w,1),given[y*w..(y+1)*w]);
        RegionGraphRequest q;q.extent=extent;q.blockEdge=block;q.maxRegions=1024;q.maxEdges=4096;
        q.maxWorkBytes=8*1024*1024;q.maxResultBytes=8*1024*1024;
        q.provenance=RegionGraphProvenance(source,"fixed-label-reference","CIE-Lab-D50","caller-texture","caller-edge");
        const buildStart=MonoTime.currTime;
        enforce(tryBuildRegionGraph(q,labels.read,input,graph)==RegionGraphError.none);
        result["build_ns"]=JSONValue((MonoTime.currTime-buildStart).total!"nsecs");
        long[] mergeTimes;
        snapshots~=graphJson(graph);
        foreach(batch;request["merges"].array)
        {
            RegionMerge[] merges;foreach(pair;batch.array)
                merges~=RegionMerge(pair[0].integer.to!uint,pair[1].integer.to!uint);
            auto retained=graph;const oldRegions=retained.regions.length;
            const mergeStart=MonoTime.currTime;
            enforce(tryMergeRegionGraph(graph,merges,q,graph)==RegionGraphError.none);
            mergeTimes~=(MonoTime.currTime-mergeStart).total!"nsecs";
            enforce(retained.regions.length==oldRegions);
            snapshots~=graphJson(graph);
        }
        result["snapshots"]=JSONValue(snapshots);
        result["merge_ns"]=JSONValue(mergeTimes);
        result["work_bytes"]=JSONValue(regionGraphWorkBytes(q.maxRegions,q.maxEdges));
    }
    result["elapsed_ns"]=JSONValue((MonoTime.currTime-started).total!"nsecs");
    result["gc_bytes"]=JSONValue(GC.stats.allocatedInCurrentThread-before);
    // Readback is outside the kernel clock; even file mode keeps a mirror for JSON.
    if(request["disk"].boolean)foreach(y;0..h)labels.read(Region2D(ox,oy+y,w,1),storage[y*w..(y+1)*w]);
    result["labels"]=JSONValue(storage);result["graph"]=graphJson(graph);
    auto crop=new uint[35];
    foreach(y;0..5)labels.read(Region2D(ox+1,oy+1+y,7,1),crop[y*7..(y+1)*7]);
    result["crop_labels"]=JSONValue(crop);
    JSONValue[] observations;
    foreach(y;0..h)
    {
        ComponentSample[256] row;enforce(w<=256);input(Region2D(ox,oy+y,w,1),row[0..w]);
        foreach(sample;row[0..w])observations~=JSONValue([number(sample.color[0]),number(sample.color[1]),number(sample.color[2])]);
    }
    result["observed_colors"]=JSONValue(observations);return result;
}
