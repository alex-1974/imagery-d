/++ Mask-aware color SLIC with caller-backed assignments and transactional labels.

Input colors are explicitly CIE Lab D50. RGB conversion belongs to color-d.
Local Lab/space clustering is followed by four-connected categorical cleanup
and deterministic graph-based merging of small adjacent regions. Independent
processing blocks share one analysis domain and yield the same final IDs.
+/
module imagery.analysis.color_slic;

import color : SRgb8, toLinear, toXyzD65, toCieLabD50;
import imagery.analysis.feature_components;
import imagery.analysis.feature_regions : Source, Sample;
import imagery.analysis.region_graph;
import raster.region : Region2D;
import std.algorithm : min,max;
import std.math : abs,isFinite;
import std.format : format;

@safe:

/// Explicit Lab/pixel distance policy, with fixed iteration count. Defaults
/// are spacing=16, compactness=10, ten iterations and 1/4-cell cleanup.
struct ColorSlicParams
{
    /// Grid spacing in pixels, 1..256; seeds are analysis-domain anchored.
    size_t spacing = 16;
    /// Lab-to-space weight m in dc² + (m/S)² ds²; finite [1e-6,1e6].
    double compactness = 10;
    /// Assignment/update passes, 1..100; empty centers retain their position.
    uint iterations = 10;
    /// Move seeds to lowest finite 3x3 Lab gradient, with row-major ties.
    bool perturbSeeds = true;
    /// Merge connected pieces smaller than factor*S²; [0,1], zero disables.
    double minimumSizeFactor = .25;
    /// Bound cleanup rounds; failure to reach a fixed point aborts publication.
    uint maxCleanupRounds = 32;
}

/// Explicit domain, capacities, work and result limits. .init is invalid.
struct ColorSlicRequest
{
    /// Fixed analysis extent, axes <= 2^30; IDs are not invariant under crops.
    Region2D extent;
    /// Clustering policy in declared Lab D50 coordinates.
    ColorSlicParams parameters;
    /// Row partitions, 1..256; not part of the mathematical result.
    size_t blockEdge = 128;
    /// Seed, provisional-component and unique adjacency capacities.
    uint maxCenters, maxLabels, maxEdges;
    /// Aggregate conservative live phase payload and immutable graph limits.
    size_t maxWorkBytes, maxResultBytes;
    /// Hard limit on distance evaluations, including rare orphan fallback.
    ulong maxDistanceEvaluations;
    /// Source facts. Color/algorithm recipes are supplied by this operation.
    ComponentProvenance provenance;
    /// Caller feature identities/units; empty is allowed only when samples are absent.
    string textureRecipe,edgeRecipe;
    /// Synchronous cancellation before row blocks, phases and publication.
    bool delegate() @safe cancelled;
}

/// Operational failures; .init is not success. D Errors propagate after abort.
enum ColorSlicError : ubyte
{
    notAttempted, none, invalidRequest, invalidSample, workExceedsBudget,
    distanceBudgetExceeded, centerLimit, cleanupLimit, componentFailure,
    graphFailure, callbackFailure, cancelled
}

/// Failed work is visible independently of publication; reset on entry.
struct ColorSlicMetrics
{
    /// Seed count, completed assignment passes and accepted cleanup rounds.
    size_t centers; uint iterations, cleanupRounds;
    /// Actual color-distance comparisons and pixels needing global fallback.
    ulong distanceEvaluations, fallbackPixels;
    /// Conservative live phase payload, excluding caller providers/stores/GC overhead.
    size_t workBytes;
    /// More specific phase errors when the top-level classification names one.
    ComponentError componentError;
    RegionGraphError graphError;
}

/// Completed segmentation metadata and immutable region graph. Labels remain
/// in the caller's committed store. Copies retain graph data, not label handles.
struct ColorSlicSegmentation
{
    /// Empty .init is invalid; graph validity determines completion.
    RegionGraph graph;
    /// Exact clustering and cleanup settings.
    ColorSlicParams parameters;
    /// Source/domain facts plus categorical four-connectivity policy.
    ComponentProvenance provenance;
    /// Versioned Lab D50/local-search/connectivity recipe.
    string recipe;
    /// True only for a completely committed segmentation.
    bool valid() const nothrow @nogc { return graph.valid; }
}

/// Convert a declared RGB8 Source to Lab D50 observations via color-d. Source
/// values must be finite exact codes 0..255, with validity supplied separately.
/// No alpha/NoData/color convention is inferred. Conversion is repeated on each
/// read; callers may supply prepared Lab rows to avoid repeated conversion.
ComponentReader colorSlicRgb(Source source)
{
    if(!source.rgb || !source.width || !source.height || source.read is null)
        throw new Exception("Color SLIC requires an RGB8 source");
    return (Region2D row,scope ComponentSample[] output) {
        if(row.height!=1 || row.width!=output.length || row.width>256 ||
            row.x>source.width || row.width>source.width-row.x || row.y>=source.height)
            throw new Exception("Invalid SLIC source row");
        Sample[256] samples;source.read(row,samples[0..output.length]);
        foreach(i,sample;samples[0..output.length])
        {
            output[i]=ComponentSample.init;output[i].valid=sample.valid;
            if(!sample.valid)continue;
            const codes=sample.rgb;
            const lab=SRgb8(codes[0],codes[1],codes[2]).toSRgb!double.toLinear.toXyzD65.toCieLabD50;
            output[i].state=ComponentSample.State.candidate;output[i].color=[lab.l,lab.a,lab.b];
        }
    };
}

private class Failure : Exception
{ColorSlicError reason;this(ColorSlicError reason){super("Color SLIC failed");this.reason=reason;}}
private void fail(ColorSlicError reason){throw new Failure(reason);}
private void poll(scope ref const ColorSlicRequest request)
{if(request.cancelled !is null && request.cancelled())fail(ColorSlicError.cancelled);}
private bool accepted(ComponentSample sample)
{
    if(sample.state>ComponentSample.State.seed)fail(ColorSlicError.invalidSample);
    if(!sample.valid || sample.state==ComponentSample.State.excluded)return false;
    foreach(value;sample.color)if(!isFinite(value)||abs(value)>1e6)fail(ColorSlicError.invalidSample);
    return true;
}
private struct Center
{
    double[3] color=[0,0,0]; double x=0,y=0; bool active;
}
private struct Sum { double[5] mean=[0,0,0,0,0];ulong count; }
private void observe(ref Sum sum,ComponentSample sample,size_t x,size_t y)
{
    ++sum.count;foreach(c;0..3)sum.mean[c]+=(sample.color[c]-sum.mean[c])/sum.count;
    sum.mean[3]+=(x+.5-sum.mean[3])/sum.count;sum.mean[4]+=(y+.5-sum.mean[4])/sum.count;
}
private size_t checkedAdd(size_t a,size_t b)
{if(a>size_t.max-b)fail(ColorSlicError.workExceedsBudget);return a+b;}
private size_t checkedBytes(size_t n,size_t item)
{if(n>size_t.max/item)fail(ColorSlicError.workExceedsBudget);return n*item;}

/// Conservative staging + two graph generations + bounded history payload.
/// Caller assignment/label stores and RGB/provider caches are separate.
size_t colorSlicWorkBytes(uint centers,uint labels,uint edges,uint rounds)
{
    auto result=checkedBytes(centers,Center.sizeof+Sum.sizeof+2*uint.sizeof);
    result=checkedAdd(result,componentScratchBytes(labels));
    result=checkedAdd(result,regionGraphWorkBytes(labels,edges));
    const graph=checkedAdd(checkedBytes(labels,RegionDescriptor.sizeof+RegionLabel.sizeof+size_t.sizeof),
        checkedBytes(edges,RegionEdge.sizeof+2*RegionNeighbor.sizeof));
    result=checkedAdd(result,checkedBytes(graph,3));
    result=checkedAdd(result,checkedBytes(checkedBytes(labels,rounds),3*RegionMergeRecord.sizeof));
    return checkedAdd(result,32768);
}

private double gradient(Region2D extent,ComponentReader input,size_t x,size_t y)
{
    double result=0;ComponentSample[1] a,b;
    foreach(axis;0..2)
    {
        const ax=axis?x:(x>extent.x?x-1:x),ay=axis?(y>extent.y?y-1:y):y;
        const bx=axis?x:min(x+1,extent.x+extent.width-1),by=axis?min(y+1,extent.y+extent.height-1):y;
        input(Region2D(ax,ay,1,1),a[]);input(Region2D(bx,by,1,1),b[]);
        if(!accepted(a[0])||!accepted(b[0]))return double.infinity;
        foreach(c;0..3){const d=a[0].color[c]-b[0].color[c];result+=d*d;}
    }
    return result;
}

/// Run full-domain SLIC and publish labels, validity and owned graph together.
/// assignmentStore is private caller/disk scratch and must not alias the final
/// transaction or source observations. Both stores must reproduce writes.
/// The source supplies explicit CIE Lab D50 samples (finite |coordinate|<=1e6).
/// Empty mask cells seed no center; orphan pixels use a budgeted global fallback.
/// Small connected pieces merge by longest shared boundary, then lowest mean
/// color contrast and ID, until stable or maxCleanupRounds is exhausted.
/// Final region/contact sinks, if requested, receive post-cleanup values only.
/// Every failure after valid commit/abort callbacks runs abort, preserves the
/// published segmentation and prior label aliases, and never invokes commit.
ColorSlicError tryColorSlic(ColorSlicRequest request,ComponentReader input,
    ComponentStore assignmentStore,ComponentTransaction transaction,
    ref ColorSlicSegmentation published,out ColorSlicMetrics metrics)
{
    if(transaction.commit is null || transaction.abort is null)return ColorSlicError.invalidRequest;
    bool committed;scope(exit)if(!committed)transaction.abort();
    try
    {
        const r=request.extent,p=request.parameters,s=p.spacing;
        if(r.empty||r.width>(1UL<<30)||r.height>(1UL<<30)||r.width>size_t.max-r.x||r.height>size_t.max-r.y||
            !s||s>256||!p.iterations||p.iterations>100||!isFinite(p.compactness)||p.compactness<1e-6||p.compactness>1e6||
            !isFinite(p.minimumSizeFactor)||p.minimumSizeFactor<0||p.minimumSizeFactor>1||!p.maxCleanupRounds||
            !request.maxCenters||!request.maxLabels||!request.blockEdge||request.blockEdge>256||
            !request.maxDistanceEvaluations||!request.maxResultBytes||input is null||
            assignmentStore.read is null||assignmentStore.write is null||transaction.store.read is null||transaction.store.write is null||
            !request.provenance.identity.length||!request.provenance.revision.length||!request.provenance.grid.length)
            fail(ColorSlicError.invalidRequest);
        const columns=(r.width+s-1)/s,rows=(r.height+s-1)/s;
        if(columns>request.maxCenters/rows)fail(ColorSlicError.centerLimit);
        try metrics.workBytes=colorSlicWorkBytes(request.maxCenters,request.maxLabels,request.maxEdges,p.maxCleanupRounds);
        catch(Exception failure){fail(ColorSlicError.workExceedsBudget);}
        if(metrics.workBytes>request.maxWorkBytes)fail(ColorSlicError.workExceedsBudget);
        poll(request);
        auto centers=new Center[columns*rows];auto sums=new Sum[centers.length];
        auto heads=new uint[centers.length];auto next=new uint[centers.length];
        ComponentSample[256] samples;uint[256] assigned;
        // Pick a valid seed nearest each nominal grid center, then perturb it.
        foreach(cy;0..rows)foreach(cx;0..columns)
        {
            poll(request);const left=cx*s,top=cy*s,width=min(s,r.width-left),height=min(s,r.height-top);
            const idealX=min(left+s/2,r.width-1),idealY=min(top+s/2,r.height-1);
            double best=double.infinity;size_t bx,by;ComponentSample chosen;
            foreach(y;top..top+height)
            {
                input(Region2D(r.x+left,r.y+y,width,1),samples[0..width]);
                foreach(i,sample;samples[0..width])if(accepted(sample))
                {const dx=cast(double)(left+i)-idealX,dy=cast(double)y-idealY,d=dx*dx+dy*dy;
                    if(d<best){best=d;bx=left+i;by=y;chosen=sample;}}
            }
            if(!isFinite(best))continue;
            if(p.perturbSeeds)
            {
                best=double.infinity;const centerX=bx,centerY=by;
                foreach(y;(centerY?centerY-1:0)..min(r.height,centerY+2))
                    foreach(x;(centerX?centerX-1:0)..min(r.width,centerX+2))
                    {
                        ComponentSample[1] point;input(Region2D(r.x+x,r.y+y,1,1),point[]);
                        if(!accepted(point[0]))continue;
                        const value=gradient(r,input,r.x+x,r.y+y);
                        if(value<best){best=value;bx=x;by=y;chosen=point[0];}
                    }
            }
            auto center=&centers[cy*columns+cx];center.active=true;center.x=bx+.5;center.y=by+.5;center.color=chosen.color;
            ++metrics.centers;
        }
        const scale=(p.compactness/s)^^2;
        foreach(iteration;0..p.iterations)
        {
            heads[]=0;sums[]=Sum.init;
            foreach(i,center;centers)if(center.active)
            {const cell=min(rows-1,cast(size_t)center.y/s)*columns+min(columns-1,cast(size_t)center.x/s);
                next[i]=heads[cell];heads[cell]=cast(uint)i+1;}
            foreach(y;0..r.height)for(size_t x=0;x<r.width;)
            {
                poll(request);const width=min(request.blockEdge,r.width-x);
                const window=Region2D(r.x+x,r.y+y,width,1);input(window,samples[0..width]);
                foreach(i,sample;samples[0..width])
                {
                    uint label;double best=double.infinity;
                    if(accepted(sample))
                    {
                        const px=x+i+.5,py=y+.5;
                        void compare(uint id,bool local)
                        {
                            const center=centers[id-1];const dx=px-center.x,dy=py-center.y;
                            // Online centroid rounding must not drop a center
                            // lying on the closed search-window boundary.
                            const tx=32*double.epsilon*max(cast(double)s,max(abs(px),abs(center.x)));
                            const ty=32*double.epsilon*max(cast(double)s,max(abs(py),abs(center.y)));
                            if(local && (abs(dx)>s+tx||abs(dy)>s+ty))return;
                            if(metrics.distanceEvaluations==request.maxDistanceEvaluations)fail(ColorSlicError.distanceBudgetExceeded);
                            ++metrics.distanceEvaluations;double distance=scale*(dx*dx+dy*dy);
                            foreach(c;0..3){const d=sample.color[c]-center.color[c];distance+=d*d;}
                            if(distance<best || (distance==best && id<label)){best=distance;label=id;}
                        }
                        const gx=(x+i)/s,gy=y/s;
                        foreach(yy;(gy?gy-1:0)..min(rows,gy+2))foreach(xx;(gx?gx-1:0)..min(columns,gx+2))
                            for(auto id=heads[yy*columns+xx];id;id=next[id-1])compare(id,true);
                        if(!label && metrics.centers)
                        {++metrics.fallbackPixels;foreach(c,center;centers)if(center.active)compare(cast(uint)c+1,false);}
                        if(!label)fail(ColorSlicError.invalidSample);
                        observe(sums[label-1],sample,x+i,y);
                    }
                    assigned[i]=label;
                }
                assignmentStore.write(window,assigned[0..width]);x+=width;
            }
            foreach(i,ref center;centers)if(sums[i].count)
            {center.color[]=sums[i].mean[0..3];center.x=sums[i].mean[3];center.y=sums[i].mean[4];}
            ++metrics.iterations;
        }
        ComponentReader categories=(Region2D row,scope ComponentSample[] output)
        {
            uint[256] labels;assignmentStore.read(row,labels[0..output.length]);input(row,output);
            foreach(i,ref sample;output)
            {if(labels[i]>centers.length)fail(ColorSlicError.invalidSample);
                sample.category=labels[i];sample.state=labels[i]?ComponentSample.State.candidate:ComponentSample.State.excluded;}
        };
        ComponentPolicy policy;policy.matchCategory=true;
        ComponentProvenance provenance=request.provenance;provenance.analysisExtent=r;provenance.policy=policy;
        provenance.implementationVersion=2;
        try labelComponents(r,categories,transaction.store,policy,request.maxLabels,request.blockEdge,
            null,null,transaction.validity,provenance,componentScratchBytes(request.maxLabels),request.cancelled);
        catch(ComponentFailure failure)
        {metrics.componentError=failure.reason;fail(failure.reason==ComponentError.cancelled?ColorSlicError.cancelled:ColorSlicError.componentFailure);}
        metrics.componentError=ComponentError.none;
        RegionGraphRequest gr;gr.extent=r;gr.blockEdge=request.blockEdge;gr.maxRegions=request.maxLabels;gr.maxEdges=request.maxEdges;
        gr.maxWorkBytes=request.maxWorkBytes;gr.maxResultBytes=request.maxResultBytes;gr.cancelled=request.cancelled;
        const recipe=format!"color-slic-lab-d50-local-v1;spacing=%s;compactness=%.17g;iterations=%s;perturb=%s;minimum-size=%.17g;cleanup-rounds=%s"(
            s,p.compactness,p.iterations,p.perturbSeeds,p.minimumSizeFactor,p.maxCleanupRounds);
        gr.provenance=RegionGraphProvenance(provenance,recipe,"CIE-Lab-D50",request.textureRecipe,request.edgeRecipe);
        RegionGraph graph;
        metrics.graphError=tryBuildRegionGraph(gr,transaction.store.read,input,graph);
        if(metrics.graphError!=RegionGraphError.none)fail(metrics.graphError==RegionGraphError.cancelled?ColorSlicError.cancelled:ColorSlicError.graphFailure);
        const minimum=p.minimumSizeFactor*s*s;
        while(minimum>0)
        {
            poll(request);RegionMerge[] merges;
            foreach(node;graph.regions)if(node.statistics.pixels<minimum)
            {
                uint selected;ulong sides;double contrast=double.infinity;
                foreach(neighbor;graph.neighbors(node.statistics.id))
                {const edge=graph.edges[neighbor.edge];
                    if(!selected||edge.sharedSides>sides||(edge.sharedSides==sides &&
                        (edge.colorContrast<contrast||(edge.colorContrast==contrast && neighbor.id<selected))))
                    {selected=neighbor.id;sides=edge.sharedSides;contrast=edge.colorContrast;}}
                if(selected)merges~=RegionMerge(node.statistics.id,selected);
            }
            if(!merges.length)break;
            if(metrics.cleanupRounds==p.maxCleanupRounds)fail(ColorSlicError.cleanupLimit);
            RegionGraph merged;metrics.graphError=tryMergeRegionGraph(graph,merges,gr,merged);
            if(metrics.graphError!=RegionGraphError.none)fail(metrics.graphError==RegionGraphError.cancelled?ColorSlicError.cancelled:ColorSlicError.graphFailure);
            graph=merged;++metrics.cleanupRounds;
        }
        // Materialize current canonical IDs; original-to-current lineage remains
        // in the graph, so old snapshots can still be interpreted explicitly.
        foreach(y;r.y..r.y+r.height)for(size_t x=r.x;x<r.x+r.width;)
        {
            poll(request);const width=min(request.blockEdge,r.x+r.width-x),window=Region2D(x,y,width,1);
            transaction.store.read(window,assigned[0..width]);
            foreach(ref label;assigned[0..width]){uint resolved;
                if(!graph.tryResolveLabel(label,resolved))fail(ColorSlicError.invalidSample);label=resolved;}
            transaction.store.write(window,assigned[0..width]);x+=width;
        }
        if(transaction.components !is null)foreach(node;graph.regions){poll(request);transaction.components(node.statistics);}
        if(transaction.contacts !is null)foreach(edge;graph.edges)
        {poll(request);foreach(i;0..edge.sharedSides)transaction.contacts(edge.first,edge.second);}
        poll(request);ColorSlicSegmentation candidate;
        candidate.graph=graph;candidate.parameters=p;candidate.provenance=provenance;candidate.recipe=recipe;
        transaction.commit();published=candidate;committed=true;return ColorSlicError.none;
    }
    catch(Failure failure){return failure.reason;}
    catch(Exception failure){return ColorSlicError.callbackFailure;}
}

/// One complete segmentation, with separate caller staging and assignment scratch.
@safe unittest
{
    auto assignment=new uint[12],staging=new uint[12];
    uint[] publishedLabels=[99u];auto retained=publishedLabels;
    ComponentStore store(uint[] data)
    {
        ComponentStore result;
        result.read=(Region2D row,scope uint[] values){const start=row.y*4+row.x;values[]=data[start..start+values.length];};
        result.write=(Region2D row,scope const(uint)[] values){const start=row.y*4+row.x;data[start..start+values.length]=values[];};
        return result;
    }
    ComponentReader input=(Region2D row,scope ComponentSample[] values){foreach(i,ref s;values){
        s=ComponentSample.init;s.state=ComponentSample.State.candidate;s.color=[20.*(row.x+i),20.*row.y,0];}};
    ComponentTransaction transaction;transaction.store=store(staging);
    uint commits,aborts;transaction.commit=() nothrow {publishedLabels=staging;++commits;};transaction.abort=() nothrow {++aborts;};
    ColorSlicRequest q;q.extent=Region2D(0,0,4,3);q.parameters.spacing=2;q.parameters.iterations=2;
    q.parameters.minimumSizeFactor=0;q.parameters.perturbSeeds=false;
    q.maxCenters=16;q.maxLabels=32;q.maxEdges=64;q.maxWorkBytes=1_000_000;q.maxResultBytes=1_000_000;
    q.maxDistanceEvaluations=10000;q.provenance=ComponentProvenance("rgb","1","grid");
    ColorSlicSegmentation published;ColorSlicMetrics metrics;
    assert(!published.valid);
    assert(tryColorSlic(q,input,store(assignment),transaction,published,metrics)==ColorSlicError.none);
    assert(published.valid&&commits==1&&aborts==0&&retained==[99]&&publishedLabels.length==12);
    assert(metrics.centers==4&&metrics.iterations==2&&metrics.cleanupRounds==0);
    foreach(id;publishedLabels)assert(id!=0);
}

// Catching D Errors is confined to this test; production @safe code propagates
// them while scope(exit) aborts the caller's staging transaction.
@system unittest
{
    foreach(mode;0..13)
    {
        auto assignment=new uint[12],staging=new uint[12];uint[] old=[99u];auto aliasOld=old;
        ComponentStore store(uint[] data,bool assignmentStore)
        {
            ComponentStore result;
            result.read=(Region2D row,scope uint[] values){const start=row.y*4+row.x;
                if(mode==6&&assignmentStore)throw new Exception("assignment read");values[]=data[start..start+values.length];};
            result.write=(Region2D row,scope const(uint)[] values){const start=row.y*4+row.x;
                if((mode==5&&assignmentStore)||(mode==7&&!assignmentStore))throw new Exception("store write");
                data[start..start+values.length]=values[];};return result;
        }
        ComponentReader input=(Region2D row,scope ComponentSample[] values){
            if(mode==10)throw new Exception("input failed");
            if(mode==11)throw new Error("provider Error");
            foreach(i,ref s;values){s=ComponentSample.init;s.state=ComponentSample.State.candidate;
                s.color=[20.*(row.x+i),20.*row.y,0];if(mode==12)s.color[0]=double.infinity;}};
        ComponentTransaction tx;tx.store=store(staging,false);uint commits,aborts;bool stop;
        tx.commit=() nothrow {old=staging;++commits;};tx.abort=() nothrow {++aborts;};
        tx.validity=(Region2D row,scope const(bool)[] v){if(mode==8)throw new Exception("validity");};
        tx.components=(ComponentStatistics s){if(mode==9)stop=true;};
        ColorSlicRequest q;q.extent=Region2D(0,0,4,3);q.parameters.spacing=2;q.parameters.iterations=2;
        q.parameters.minimumSizeFactor=0;q.parameters.perturbSeeds=false;
        q.maxCenters=16;q.maxLabels=32;q.maxEdges=64;q.maxWorkBytes=1_000_000;q.maxResultBytes=1_000_000;
        q.maxDistanceEvaluations=10000;q.provenance=ComponentProvenance("rgb","1","grid");
        q.cancelled=(){return stop;};
        if(mode==0)q.parameters.spacing=0;if(mode==1)q.maxWorkBytes=0;
        if(mode==2)q.maxDistanceEvaluations=1;if(mode==3)q.maxCenters=1;if(mode==4)q.maxLabels=1;
        ColorSlicSegmentation published;ColorSlicMetrics metrics;ColorSlicError error;
        bool threw;
        try error=tryColorSlic(q,input,store(assignment,true),tx,published,metrics);
        catch(Error failure){assert(mode==11);threw=true;}
        assert((error!=ColorSlicError.none||threw)&&!published.valid&&commits==0&&aborts==1);
        assert(old is aliasOld&&old==[99]);
        if(mode==1)assert(error==ColorSlicError.workExceedsBudget);
        if(mode==2)assert(error==ColorSlicError.distanceBudgetExceeded);
        if(mode==4)assert(error==ColorSlicError.componentFailure&&metrics.componentError==ComponentError.labelLimitExceeded);
        if(mode==9)assert(error==ColorSlicError.cancelled);
        if(mode==12)assert(error==ColorSlicError.invalidSample);
    }
}
