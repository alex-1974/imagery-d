/++ Owned region adjacency graphs over finalized caller-backed labels.

No source pixels or label buffers are retained. Immutable records, adjacency,
label lineage and merge history share safely when a graph value is copied.
Build and merge publish only complete graphs. Scheduling and label storage
remain with the caller; all callbacks are synchronous.
+/
module imagery.analysis.region_graph;

import imagery.analysis.feature_components : ComponentSample, ComponentReader,
    LabelReader, ComponentStatistics, ComponentProvenance;
import raster.region : Region2D;
import std.algorithm : min, max, sort;
import std.math : abs, atan2, isFinite, sqrt, PI;

@safe:

/// Explicit result classification; .init is not success.
enum RegionGraphError : ubyte
{
    /++ No operation has completed; this is the default sentinel. +/
    notAttempted,
    /++ The operation completed successfully. +/
    none,
    /++ Request dimensions, parameters or callbacks violate the operation contract. +/
    invalidRequest,
    /++ Required working storage exceeds the caller’s budget. +/
    workExceedsBudget,
    /++ Required retained output storage exceeds the caller’s budget. +/
    resultExceedsBudget,
    /++ The configured region-count limit was exceeded. +/
    regionLimit,
    /++ The configured graph-edge limit was exceeded. +/
    edgeLimit,
    /++ The label input is outside the declared region-label domain. +/
    invalidLabel,
    /++ A required count or numeric result cannot be represented. +/
    numericalOverflow,
    /++ A caller callback failed or rejected the operation. +/
    callbackFailure,
    /++ The caller requested cancellation before completion. +/
    cancelled,
    /++ The requested pair is invalid for this graph or merge state. +/
    invalidMerge
}

/// Region statistics plus sufficient spatial/auxiliary moments for later merges.
/// Coordinates are pixel centers relative to provenance.analysisExtent.
struct RegionDescriptor
{
    /// Area, bounds, color population statistics, coverage and shape evidence.
    ComponentStatistics statistics;
    /// Local centroid, including the half-pixel center offset.
    double[2] centroid = [0,0];
    /// Population spatial covariance xx, yy, xy in squared pixel units.
    double[3] covariance = [0,0,0];
    /// Population texture/edge variances over their separate finite counts.
    double textureVariance = 0, edgeVariance = 0;
/++
     Pixel-grid compactness 4*pi*area/perimeter², zero for an empty descriptor.

     Returns:
     4*pi*area/perimeter squared, bounded to [0,1].
    +/
    double compactness() const nothrow @nogc
    {const p=cast(double)statistics.perimeter;return p?min(1.,4*PI*statistics.pixels/(p*p)):0;}
/++
     Fractions of region pixels with finite edge/texture observations.

     Returns:
     Fraction of component pixels with finite edge observations.
    +/
    double edgeCoverage() const nothrow @nogc
    {return statistics.pixels?statistics.edgeSamples/cast(double)statistics.pixels:0;}
/++
     Ditto.

     Returns:
     Fraction of component pixels with finite texture observations.
    +/
    double textureCoverage() const nothrow @nogc
    {return statistics.pixels?statistics.textureSamples/cast(double)statistics.pixels:0;}
}

/// Undirected shared-side adjacency. Endpoints are ordered and nonzero.
struct RegionEdge
{
    /// Canonical region endpoints, first < second.
    uint first, second;
    /// Number of shared horizontal/vertical pixel sides.
    ulong sharedSides;
    /// Sides with finite edge measurements at both endpoint pixels.
    ulong edgeSamples;
    /// Mean and population variance of endpoint-averaged edge measurements.
    double meanEdge, varianceEdge = 0;
    /// Euclidean distance between final mean colors in declared color coordinates.
    double colorContrast = 0;
}

/// A neighbor ID and index into the graph's edges, sorted by neighboring ID.
struct RegionNeighbor {
    /++
 Adjacent canonical region label.
+/
uint id;
    /++
 Index of the shared RegionEdge record.
+/
size_t edge; }
/// Map an original finalized label to its current canonical region.
struct RegionLabel {
    /++
 Original canonical label before graph merges.
+/
/++
 Label mapping: original is the input canonical label; current is its representative after recorded merges.
+/
uint original, current; }
/// One requested adjacency merge and the graph generation that accepted it.
struct RegionMerge {
    /++
 First region label in the requested merge pair.
+/
/++
 Requested merge endpoints: first and second are canonical region labels.
+/
uint first, second; }
/// Persistent record of an accepted merge request.
struct RegionMergeRecord {
    /++
 Accepted merge pair in the recorded sequence.
+/
RegionMerge pair;
    /++
 Graph generation at which the merge was accepted.
+/
ulong generation; }

/// Required source/feature semantics plus deterministic graph generation.
struct RegionGraphProvenance
{
    /// Source identity/revision/grid/bands/units and exact segmentation domain.
    ComponentProvenance source;
    /// Explicit segmentation, color coordinates and optional auxiliary recipes.
    string segmentation, colorSpace, textureRecipe, edgeRecipe;
    /// Zero for initial build, incremented once per merge operation. A generation
    /// alone is not a unique cache key; include exact label lineage/merge history.
    ulong generation;
    /// Region-graph algorithm/record contract version.
    uint implementationVersion = 1;
}

/// Bounds are explicit; .init is an invalid request. Work budget excludes caller
/// providers, label storage, GC headers and the previous published graph.
struct RegionGraphRequest
{
    /// Nonempty fixed connectivity domain.
    Region2D extent;
    /// Row partition 1..256, independent of graph identity and reductions.
    size_t blockEdge = 128;
    /// Hard capacities; exhaustion never publishes a partial graph.
    uint maxRegions, maxEdges;
    /// Staged engine payload and actual immutable result payload limits.
    size_t maxWorkBytes, maxResultBytes;
    /// Caller-declared source/feature semantics, copied before publication.
    RegionGraphProvenance provenance;
    /// Poll before blocks, merge work and final publication.
    bool delegate() @safe cancelled;
}

/// Empty .init is not a completed graph. Results own immutable GC-managed arrays;
/// copies share storage, and returned const slices remain GC-owned, not borrowed
/// decoder windows. No resource handles or background threads are retained.
struct RegionGraph
{
    private bool complete;
    private immutable(RegionDescriptor)[] descriptors;
    private immutable(RegionEdge)[] links;
    private immutable(RegionNeighbor)[] adjacency;
    private immutable(size_t)[] offsets;
    private immutable(RegionLabel)[] labels;
    private immutable(RegionMergeRecord)[] history;
    private RegionGraphProvenance origin;

/++
     True only after a complete build/merge, including an empty valid mask.

     Returns:
     True when this value contains a completed, usable result.
    +/
    bool valid() const nothrow @nogc { return complete; }
/++
     Sorted region records (ascending ID), without copying.

     Returns:
     Read-only region descriptors belonging to this graph snapshot.
    +/
    const(RegionDescriptor)[] regions() const nothrow @nogc { return descriptors; }
/++
     Unique undirected edges, sorted lexicographically by endpoints.

     Returns:
     Read-only edges belonging to this graph snapshot.
    +/
    const(RegionEdge)[] edges() const nothrow @nogc { return links; }
/++
     Original-to-current IDs, sorted by original label; label zero maps to zero.

     Returns:
     Read-only original-to-current label mapping.
    +/
    const(RegionLabel)[] labelMap() const nothrow @nogc { return labels; }
/++
     Immutable merge requests, retaining prior generations.

     Returns:
     Read-only accepted merge sequence.
    +/
    const(RegionMergeRecord)[] mergeHistory() const nothrow @nogc { return history; }
/++
     Source/domain/feature/merge identity.

     Returns:
     Input and graph-operation provenance for this snapshot.
    +/
    RegionGraphProvenance provenance() const nothrow @nogc { return origin; }

    private size_t find(uint id) const nothrow @nogc
    {
        size_t low, high = descriptors.length;
        while (low<high) { const mid=low+(high-low)/2;
            if (descriptors[mid].statistics.id<id) low=mid+1; else high=mid; }
        return low<descriptors.length && descriptors[low].statistics.id==id ? low : size_t.max;
    }
/++
     Allocation-free lookup; false initializes result to its empty sentinel.

     Params:
      id = Component or graph identifier as described above.
      result = Output parameter receiving the result described above.

     Returns:
     True with the identified region descriptor; false with a default-initialized out result if unavailable.
    +/
    bool tryRegion(uint id, out RegionDescriptor result) const nothrow @nogc
    {
        const index=find(id); if(index==size_t.max)return false;
        result=descriptors[index]; return true;
    }
/++
     Allocation-free CSR neighbor list; unknown IDs yield an empty slice.

     Params:
      id = Component or graph identifier as described above.

     Returns:
     Read-only adjacency entries for the selected region, or an empty slice if unavailable.
    +/
    const(RegionNeighbor)[] neighbors(uint id) const nothrow @nogc
    {
        const index=find(id); return index==size_t.max ? null : adjacency[offsets[index]..offsets[index+1]];
    }
/++
     Resolve original labels even after repeated merges; unknown labels fail.

     Params:
      id = Component or graph identifier as described above.
      current = Current state or generation being compared.

     Returns:
     True with the current representative label; false with the out value reset to zero if unavailable.
    +/
    bool tryResolveLabel(uint id, out uint current) const nothrow @nogc
    {
        if(!complete)return false;
        if(!id)return true;
        size_t low, high=labels.length;
        while(low<high){const mid=low+(high-low)/2;
            if(labels[mid].original<id)low=mid+1;else high=mid;}
        if(low==labels.length || labels[low].original!=id)return false;
        current=labels[low].current;return true;
    }
}

/// Build, query and merge without mutating the original labels or graph snapshot.
@safe unittest
{
    enum width=3,height=2;
    uint[6] data=[1,1,9,1,4,9];
    LabelReader labels=(Region2D row,scope uint[] values){
        const start=row.y*width+row.x;values[]=data[start..start+values.length];};
    ComponentReader input=(Region2D row,scope ComponentSample[] values){
        foreach(i,ref sample;values){sample=ComponentSample.init;sample.state=ComponentSample.State.candidate;
            sample.color=[cast(double)(row.x+i),0,0];sample.edge=1;sample.texture=2;}};
    RegionGraphRequest q;q.extent=Region2D(0,0,width,height);q.blockEdge=2;
    q.maxRegions=4;q.maxEdges=4;q.maxWorkBytes=1_000_000;q.maxResultBytes=1_000_000;
    q.provenance=RegionGraphProvenance(ComponentProvenance("mask","1","grid"),"mask-v1","declared-color","constant-two","constant-one");
    RegionGraph graph;assert(!graph.valid);
    assert(tryBuildRegionGraph(q,labels,input,graph)==RegionGraphError.none);
    auto retained=graph;
    assert(graph.regions.length==3&&graph.edges.length==3&&graph.neighbors(1).length==2);
    assert(tryMergeRegionGraph(graph,[RegionMerge(1,4)],q,graph)==RegionGraphError.none);
    RegionDescriptor region;assert(graph.tryRegion(1,region));
    assert(region.statistics.pixels==4&&region.statistics.perimeter==8);
    assert(region.statistics.meanColor[0]==.5&&region.statistics.colorVariance[0]==.25);
    assert(!region.statistics.orientationValid&&region.edgeCoverage==1&&region.textureCoverage==1);
    uint id;assert(graph.tryResolveLabel(4,id)&&id==1);
    assert(retained.regions.length==3&&graph.regions.length==2&&graph.mergeHistory.length==1);
    assert(tryMergeRegionGraph(graph,[RegionMerge(1,9)],q,graph)==RegionGraphError.none);
    assert(graph.tryRegion(1,region)&&region.statistics.pixels==6&&region.statistics.perimeter==10);
    assert(graph.tryResolveLabel(4,id)&&id==1&&graph.provenance.generation==2);
    assert(graph.edges.length==0&&retained.edges.length==3);
    assert(!graph.tryResolveLabel(123,id)&&id==0&&!graph.tryRegion(123,region)&&region.statistics.id==0);

    foreach(mode;0..11)
    {
        auto request=q;size_t reads;
        ComponentReader provider=(Region2D row,scope ComponentSample[] values){
            if(mode==5&&++reads==2)throw new Exception("provider failed");input(row,values);
            if(mode==6)foreach(ref s;values)s.valid=false;
            if(mode==7)foreach(i,ref s;values)s.color[0]=(row.x+i)%2?-double.max:double.max;
            if(mode==10)foreach(ref s;values)s.state=cast(ComponentSample.State)255;
        };
        if(mode==0)request.maxRegions=0;
        if(mode==1)request.maxWorkBytes=0;
        if(mode==2)request.maxResultBytes=1;
        if(mode==3)request.maxRegions=1;
        if(mode==4)request.maxEdges=0;
        if(mode==8)request.cancelled=(){return true;};
        if(mode==9)request.provenance.source.identity=null;
        const before=graph.regions;
        const error=tryBuildRegionGraph(request,labels,provider,graph);
        assert(error!=RegionGraphError.none&&graph.regions is before);
    }
    auto before=graph.regions;
    assert(tryMergeRegionGraph(graph,[RegionMerge(1,1)],q,graph)==RegionGraphError.invalidMerge);
    assert(tryMergeRegionGraph(graph,[RegionMerge(1,99)],q,graph)==RegionGraphError.invalidMerge);
    auto changed=q;changed.provenance.source.unit="other";
    assert(tryMergeRegionGraph(graph,null,changed,graph)==RegionGraphError.invalidMerge);
    changed=q;changed.maxResultBytes=1;
    assert(tryMergeRegionGraph(graph,null,changed,graph)==RegionGraphError.resultExceedsBudget);
    assert(graph.regions is before);
}


private class Failure : Exception
{
    RegionGraphError reason;
    this(RegionGraphError reason){super("Region graph operation failed");this.reason=reason;}
}
private void fail(RegionGraphError reason){throw new Failure(reason);}
private void poll(scope ref const RegionGraphRequest request)
{if(request.cancelled !is null && request.cancelled())fail(RegionGraphError.cancelled);}

private size_t bytes(size_t count,size_t item)
{
    if(item && count>size_t.max/item)fail(RegionGraphError.workExceedsBudget);
    return count*item;
}
private size_t plus(size_t a,size_t b)
{if(a>size_t.max-b)fail(RegionGraphError.workExceedsBudget);return a+b;}
private size_t capacity(size_t count)
{
    if(count>uint.max/2 || count>size_t.max/4)fail(RegionGraphError.workExceedsBudget);
    size_t result=2;while(result<2*count)result*=2;return result;
}
private size_t hash(ulong key,size_t mask) nothrow @nogc
{
    key^=key>>30;key*=0xbf58476d1ce4e5b9UL;key^=key>>27;
    key*=0x94d049bb133111ebUL;key^=key>>31;return cast(size_t)key & mask;
}
private struct Index
{
    ulong[] keys; uint[] values;
    void prepare(size_t count){const n=capacity(count);keys=new ulong[n];values=new uint[n];}
    size_t slot(ulong key) nothrow @nogc
    {auto i=hash(key,keys.length-1);while(keys[i] && keys[i]!=key)i=(i+1)&(keys.length-1);return i;}
}
private struct Work
{
    RegionDescriptor[] nodes; RegionEdge[] edges;
    Index nodeIndex,edgeIndex;
    size_t n,e;
    void prepare(uint regions,uint links)
    {nodes=new RegionDescriptor[regions];edges=new RegionEdge[links];nodeIndex.prepare(regions);edgeIndex.prepare(links);}
    size_t node(uint id)
    {
        const slot=nodeIndex.slot(id);
        if(nodeIndex.keys[slot])return nodeIndex.values[slot];
        if(n==nodes.length)fail(RegionGraphError.regionLimit);
        nodeIndex.keys[slot]=id;nodeIndex.values[slot]=cast(uint)n;
        nodes[n].statistics.id=id;return n++;
    }
    size_t edge(uint a,uint b)
    {
        if(a>b){const tmp=a;a=b;b=tmp;}
        const key=(cast(ulong)a<<32)|b,slot=edgeIndex.slot(key);
        if(edgeIndex.keys[slot])return edgeIndex.values[slot];
        if(e==edges.length)fail(RegionGraphError.edgeLimit);
        edgeIndex.keys[slot]=key;edgeIndex.values[slot]=cast(uint)e;
        edges[e].first=a;edges[e].second=b;return e++;
    }
}

/++
 Conservative staging payload for the declared capacities, independent of
   source dimensions. Includes build/merge maps, row buffers and CSR staging.

 Params:
  regions = Maximum region count.
  edges = Preallocated row-major byte edge output; zero is background.

 Returns:
 Conservative logical graph working-storage reservation for the supplied limits.
+/
size_t regionGraphWorkBytes(uint regions,uint edges)
{
    size_t total=bytes(regions,RegionDescriptor.sizeof+RegionLabel.sizeof+4*size_t.sizeof);
    total=plus(total,bytes(edges,RegionEdge.sizeof+2*RegionNeighbor.sizeof));
    total=plus(total,bytes(capacity(regions)+capacity(edges),ulong.sizeof+uint.sizeof));
    return plus(total,2*256*(ComponentSample.sizeof+uint.sizeof)+4096);
}
private void checkRequest(scope ref const RegionGraphRequest request)
{
    const r=request.extent;
    if(r.empty || r.width>size_t.max-r.x || r.height>size_t.max-r.y ||
        r.width>ulong.max/4/r.height || !request.blockEdge || request.blockEdge>256 ||
        !request.maxRegions || !request.maxResultBytes ||
        !request.provenance.source.identity.length || !request.provenance.source.revision.length ||
        !request.provenance.source.grid.length || !request.provenance.segmentation.length ||
        !request.provenance.colorSpace.length)fail(RegionGraphError.invalidRequest);
    if(regionGraphWorkBytes(request.maxRegions,request.maxEdges)>request.maxWorkBytes)
        fail(RegionGraphError.workExceedsBudget);
    poll(request);
}
private bool observed(ComponentSample sample) nothrow @nogc
{return sample.valid && isFinite(sample.color[0]) && isFinite(sample.color[1]) && isFinite(sample.color[2]);}
private void moment(double value,ulong count,ref double mean,ref double m2)
{
    if(count==1){mean=value;m2=0;return;}
    const delta=value-mean;mean+=delta/count;m2+=delta*(value-mean);
}
private void add(ref RegionDescriptor node,ComponentSample sample,size_t x,size_t y,Region2D extent)
{
    auto s=&node.statistics;
    if(!s.pixels)s.bounds=Region2D(x,y,1,1);
    else {const ex=max(s.bounds.x+s.bounds.width,x+1),ey=max(s.bounds.y+s.bounds.height,y+1);
        s.bounds.x=min(s.bounds.x,x);s.bounds.y=min(s.bounds.y,y);
        s.bounds.width=ex-s.bounds.x;s.bounds.height=ey-s.bounds.y;}
    ++s.pixels;
    foreach(c;0..3)moment(sample.color[c],s.pixels,s.meanColor[c],s.colorVariance[c]);
    const px=cast(double)(x-extent.x)+.5,py=cast(double)(y-extent.y)+.5;
    const dx=px-node.centroid[0],dy=py-node.centroid[1];
    node.centroid[0]+=dx/s.pixels;node.centroid[1]+=dy/s.pixels;
    node.covariance[0]+=dx*(px-node.centroid[0]);node.covariance[1]+=dy*(py-node.centroid[1]);
    node.covariance[2]+=dx*(py-node.centroid[1]);
    if(isFinite(sample.texture))moment(sample.texture,++s.textureSamples,s.meanTexture,node.textureVariance);
    if(isFinite(sample.edge))moment(sample.edge,++s.edgeSamples,s.meanEdge,node.edgeVariance);
    s.perimeter+=4;
}
private void finish(ref RegionDescriptor node,ComponentProvenance origin)
{
    auto s=&node.statistics;
    foreach(c;0..3){s.colorVariance[c]/=s.pixels;node.covariance[c]/=s.pixels;
        if(!isFinite(s.meanColor[c]) || !isFinite(s.colorVariance[c]) || !isFinite(node.covariance[c]))
            fail(RegionGraphError.numericalOverflow);
        s.colorVariance[c]=max(0.,s.colorVariance[c]);}
    if(s.textureSamples)node.textureVariance/=s.textureSamples;
    if(s.edgeSamples)node.edgeVariance/=s.edgeSamples;
    if((s.textureSamples && (!isFinite(s.meanTexture)||!isFinite(node.textureVariance))) ||
        (s.edgeSamples && (!isFinite(s.meanEdge)||!isFinite(node.edgeVariance))))fail(RegionGraphError.numericalOverflow);
    s.fillRatio=s.pixels/(cast(double)s.bounds.width*s.bounds.height);
    const delta=node.covariance[0]-node.covariance[1];
    s.orientationValid=max(abs(delta),abs(2*node.covariance[2]))>
        64*double.epsilon*(node.covariance[0]+node.covariance[1]);
    s.orientation=0;
    if(s.orientationValid){const angle=.5*atan2(2*node.covariance[2],delta);s.orientation=angle<0?angle+PI:angle;}
    s.provenance=origin;
}
private RegionGraph assemble(ref Work work,scope RegionLabel[] map,
    scope RegionMergeRecord[] history,RegionGraphProvenance origin,size_t maxBytes)
{
    auto nodes=work.nodes[0..work.n];auto edges=work.edges[0..work.e];
    sort!"a.statistics.id < b.statistics.id"(nodes);
    sort!"a.first < b.first || (a.first == b.first && a.second < b.second)"(edges);
    size_t payload=bytes(nodes.length,RegionDescriptor.sizeof);
    payload=plus(payload,bytes(edges.length,RegionEdge.sizeof+2*RegionNeighbor.sizeof));
    payload=plus(payload,bytes(nodes.length+1,size_t.sizeof));
    payload=plus(payload,bytes(map.length,RegionLabel.sizeof));
    payload=plus(payload,bytes(history.length,RegionMergeRecord.sizeof));
    if(payload>maxBytes)fail(RegionGraphError.resultExceedsBudget);
    RegionGraph candidate;candidate.complete=true;candidate.origin=origin;
    candidate.descriptors=nodes.idup;
    auto offsets=new size_t[nodes.length+1];
    foreach(ref edge;edges)
    {
        const a=candidate.find(edge.first),b=candidate.find(edge.second);
        if(a==size_t.max || b==size_t.max)fail(RegionGraphError.invalidLabel);
        ++offsets[a+1];++offsets[b+1];
        double distance=0;foreach(c;0..3){const d=nodes[a].statistics.meanColor[c]-nodes[b].statistics.meanColor[c];distance+=d*d;}
        edge.colorContrast=sqrt(distance);
        if(!isFinite(edge.colorContrast)|| (edge.edgeSamples && (!isFinite(edge.meanEdge)||!isFinite(edge.varianceEdge))))
            fail(RegionGraphError.numericalOverflow);
    }
    foreach(i;1..offsets.length)offsets[i]+=offsets[i-1];
    auto cursor=offsets.dup;auto adjacent=new RegionNeighbor[2*edges.length];
    foreach(i,edge;edges){const a=candidate.find(edge.first),b=candidate.find(edge.second);
        adjacent[cursor[a]++]=RegionNeighbor(edge.second,i);adjacent[cursor[b]++]=RegionNeighbor(edge.first,i);}
    candidate.offsets=offsets.idup;candidate.adjacency=adjacent.idup;candidate.links=edges.idup;
    candidate.labels=map.idup;candidate.history=history.idup;
    return candidate;
}

/++
 Scan finalized labels and stable observations into an owned region graph.
   Nonzero labels must refer to accepted finite-color observations. The caller
   supplies already connected region labels; this operation does not relabel.
   Source/store callbacks must reproduce the same revision across reads.
   Two row buffers bound pixel scratch; hash capacities bound graph staging.
   Callback exceptions become callbackFailure; D Errors propagate. Every failure
   preserves published and all immutable aliases. No @nogc/nothrow promise.

 Params:
  request = Validated request dimensions, policies and resource limits.
  labels = Label storage/callback; zero denotes excluded pixels and positive labels identify components.
  input = Input values or callback; the operation reads it as described above.
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
RegionGraphError tryBuildRegionGraph(RegionGraphRequest request,LabelReader labels,
    ComponentReader input,ref RegionGraph published)
{
    try
    {
        checkRequest(request);if(labels is null||input is null)fail(RegionGraphError.invalidRequest);
        Work work;work.prepare(request.maxRegions,request.maxEdges);
        uint[256] row,above;ComponentSample[256] current,previous;
        const extent=request.extent;
        foreach(y;extent.y..extent.y+extent.height)
        {
            uint left;ComponentSample leftSample;
            for(size_t x=extent.x;x<extent.x+extent.width;)
            {
                poll(request);const width=min(request.blockEdge,extent.x+extent.width-x);
                const window=Region2D(x,y,width,1);
                labels(window,row[0..width]);input(window,current[0..width]);
                if(y>extent.y){const top=Region2D(x,y-1,width,1);labels(top,above[0..width]);input(top,previous[0..width]);}
                foreach(i,id;row[0..width])
                {
                    if(id)
                    {
                        if(!observed(current[i]) || current[i].state==ComponentSample.State.excluded ||
                            current[i].state>ComponentSample.State.seed)
                            fail(RegionGraphError.invalidLabel);
                        if((isFinite(current[i].texture)&&!request.provenance.textureRecipe.length)||
                            (isFinite(current[i].edge)&&!request.provenance.edgeRecipe.length))
                            fail(RegionGraphError.invalidRequest);
                        const index=work.node(id);add(work.nodes[index],current[i],x+i,y,extent);
                        foreach(axis;0..2)
                        {
                            const neighbor=axis ? (y>extent.y?above[i]:0) : left;
                            if(!neighbor)continue;
                            if(neighbor==id)work.nodes[index].statistics.perimeter-=2;
                            else
                            {
                                const e=work.edge(id,neighbor);auto edge=&work.edges[e];++edge.sharedSides;
                                const other=axis?previous[i]:leftSample;
                                if(isFinite(current[i].edge)&&isFinite(other.edge))
                                    moment(.5*current[i].edge+.5*other.edge,++edge.edgeSamples,edge.meanEdge,edge.varianceEdge);
                            }
                        }
                    }
                    left=id;leftSample=current[i];
                }
                x+=width;
            }
        }
        auto origin=request.provenance;origin.source.analysisExtent=extent;origin.generation=0;origin.implementationVersion=1;
        foreach(ref node;work.nodes[0..work.n])finish(node,origin.source);
        foreach(ref edge;work.edges[0..work.e])if(edge.edgeSamples)edge.varianceEdge/=edge.edgeSamples;
        sort!"a.statistics.id < b.statistics.id"(work.nodes[0..work.n]);
        auto map=new RegionLabel[work.n];foreach(i,node;work.nodes[0..work.n])map[i]=RegionLabel(node.statistics.id,node.statistics.id);
        auto candidate=assemble(work,map,null,origin,request.maxResultBytes);poll(request);
        published=candidate;return RegionGraphError.none;
    }
    catch(Failure failure){return failure.reason;}
    catch(Exception failure){return RegionGraphError.callbackFailure;}
}

private uint root(scope uint[] parents,uint index) nothrow @nogc
{while(parents[index]!=index){parents[index]=parents[parents[index]];index=parents[index];}return index;}
private void combineMoment(ulong a,ulong b,double otherMean,double otherVariance,
    ref double mean,ref double variance)
{
    if(!b)return;if(!a){mean=otherMean;variance=otherVariance;return;}
    const n=cast(double)a+b,delta=otherMean-mean;
    variance=(variance*a+otherVariance*b+delta*delta*(a/n)*b)/n;
    mean+=delta*(b/n);
}
private void combine(ref RegionDescriptor a,const RegionDescriptor b)
{
    auto sa=&a.statistics;const sb=b.statistics;const n1=sa.pixels,n2=sb.pixels;
    if(!n1){a=b;return;}
    foreach(c;0..3)combineMoment(n1,n2,sb.meanColor[c],sb.colorVariance[c],sa.meanColor[c],sa.colorVariance[c]);
    const n=cast(double)n1+n2,dx=b.centroid[0]-a.centroid[0],dy=b.centroid[1]-a.centroid[1];
    foreach(i;0..3){const delta=i==0?dx*dx:i==1?dy*dy:dx*dy;
        a.covariance[i]=(a.covariance[i]*n1+b.covariance[i]*n2+delta*(n1/n)*n2)/n;}
    a.centroid[0]+=dx*(n2/n);a.centroid[1]+=dy*(n2/n);
    combineMoment(sa.textureSamples,sb.textureSamples,sb.meanTexture,b.textureVariance,sa.meanTexture,a.textureVariance);
    combineMoment(sa.edgeSamples,sb.edgeSamples,sb.meanEdge,b.edgeVariance,sa.meanEdge,a.edgeVariance);
    sa.textureSamples+=sb.textureSamples;sa.edgeSamples+=sb.edgeSamples;sa.pixels+=sb.pixels;sa.perimeter+=sb.perimeter;
    const ex=max(sa.bounds.x+sa.bounds.width,sb.bounds.x+sb.bounds.width),ey=max(sa.bounds.y+sa.bounds.height,sb.bounds.y+sb.bounds.height);
    sa.bounds.x=min(sa.bounds.x,sb.bounds.x);sa.bounds.y=min(sa.bounds.y,sb.bounds.y);
    sa.bounds.width=ex-sa.bounds.x;sa.bounds.height=ey-sa.bounds.y;sa.id=min(sa.id,sb.id);
}

/++
 Merge adjacent regions without rewriting the original label store. IDs become
   the minimum member ID. Each requested pair must be an edge in the input graph;
   chains/batches are allowed, and batch order does not change reductions.
   labelMap/tryResolveLabel retain original-label lineage across generations.
   Statistics are combined with population-moment formulas; internal shared
   sides disappear from perimeter and external edges aggregate their evidence.
   Request domain/provenance must match the source graph. Cancellation, invalid
   pairs or any budget failure preserve published (which may alias source).

 Params:
  source = Input data; its sample model, units and lifetime follow the operation contract above.
  merges = Ordered region pairs to merge, borrowed during this call.
  request = Validated request dimensions, policies and resource limits.
  published = Output parameter; the operation-specific success and failure-state rules above apply.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
RegionGraphError tryMergeRegionGraph(scope ref const RegionGraph source,
    scope const RegionMerge[] merges,RegionGraphRequest request,ref RegionGraph published)
{
    try
    {
        checkRequest(request);
        ComponentProvenance expectedSource=request.provenance.source;
        expectedSource.analysisExtent=request.extent;
        if(!source.complete || expectedSource!=source.origin.source ||
            request.provenance.segmentation!=source.origin.segmentation ||
            request.provenance.colorSpace!=source.origin.colorSpace ||
            request.provenance.textureRecipe!=source.origin.textureRecipe ||
            request.provenance.edgeRecipe!=source.origin.edgeRecipe ||
            source.origin.generation==ulong.max)fail(RegionGraphError.invalidMerge);
        if(source.descriptors.length>request.maxRegions)fail(RegionGraphError.regionLimit);
        // Additional lineage/history staging is not bounded by current node count.
        const extra=plus(bytes(source.labels.length,RegionLabel.sizeof),
            bytes(plus(source.history.length,merges.length),RegionMergeRecord.sizeof));
        if(plus(regionGraphWorkBytes(request.maxRegions,request.maxEdges),extra)>request.maxWorkBytes)
            fail(RegionGraphError.workExceedsBudget);
        auto parents=new uint[source.descriptors.length];foreach(i,ref p;parents)p=cast(uint)i;
        foreach(pair;merges)
        {
            poll(request);const a=source.find(pair.first),b=source.find(pair.second);
            if(a==size_t.max||b==size_t.max||a==b)fail(RegionGraphError.invalidMerge);
            bool adjacent;foreach(edge;source.neighbors(pair.first))if(edge.id==pair.second){adjacent=true;break;}
            if(!adjacent)fail(RegionGraphError.invalidMerge);
            const ra=root(parents,cast(uint)a),rb=root(parents,cast(uint)b);parents[max(ra,rb)]=min(ra,rb);
        }
        Work work;work.prepare(request.maxRegions,request.maxEdges);
        foreach(i,node;source.descriptors)
        {poll(request);const id=source.descriptors[root(parents,cast(uint)i)].statistics.id;
            const index=work.node(id);combine(work.nodes[index],node);work.nodes[index].statistics.id=id;}
        foreach(edge;source.links)
        {
            poll(request);const a=source.descriptors[root(parents,cast(uint)source.find(edge.first))].statistics.id;
            const b=source.descriptors[root(parents,cast(uint)source.find(edge.second))].statistics.id;
            if(a==b){work.nodes[work.node(a)].statistics.perimeter-=2*edge.sharedSides;continue;}
            auto target=&work.edges[work.edge(a,b)];
            combineMoment(target.edgeSamples,edge.edgeSamples,edge.meanEdge,edge.varianceEdge,target.meanEdge,target.varianceEdge);
            target.sharedSides+=edge.sharedSides;target.edgeSamples+=edge.edgeSamples;
        }
        RegionGraphProvenance origin=source.origin;++origin.generation;
        foreach(ref node;work.nodes[0..work.n])
        {
            // finish accepts unnormalized accumulated moments.
            foreach(c;0..3){node.statistics.colorVariance[c]*=node.statistics.pixels;node.covariance[c]*=node.statistics.pixels;}
            node.textureVariance*=node.statistics.textureSamples;node.edgeVariance*=node.statistics.edgeSamples;
            finish(node,origin.source);
        }
        auto map=new RegionLabel[source.labels.length];
        foreach(i,label;source.labels)map[i]=RegionLabel(label.original,
            source.descriptors[root(parents,cast(uint)source.find(label.current))].statistics.id);
        auto history=new RegionMergeRecord[plus(source.history.length,merges.length)];
        history[0..source.history.length]=source.history[];
        foreach(i,pair;merges)history[source.history.length+i]=RegionMergeRecord(pair,origin.generation);
        auto candidate=assemble(work,map,history,origin,request.maxResultBytes);poll(request);
        published=candidate;return RegionGraphError.none;
    }
    catch(Failure failure){return failure.reason;}
    catch(Exception failure){return RegionGraphError.callbackFailure;}
}
