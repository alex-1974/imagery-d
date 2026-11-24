/++ Prepared, window-bounded geometric shortest paths with lazy image costs.

The cost functor supplies stable nonnegative costs for one search epoch, using
global image coordinates. NaN and positive infinity block pixels. A changed
source revision, seed set or window starts a new epoch. No settled state is
silently preserved across a changed graph. Coordinates and steps are in pixels.
+/
module imagery.analysis.lazy_cost_path;

import imagery.analysis.cost_path : PathConnectivity, OwnedCostPlane;
import raster.region : Region2D;
import std.math : isFinite, sqrt;
import std.algorithm.mutation : move;

@safe:

/// .init is not success. Invalid reset coordinates preserve the prior search;
/// an invalid/blocked seed or a negative lazy observation invalidates the new
/// epoch, so distance/predecessor/path queries cannot publish partial answers.
enum PathSearchError : ubyte
{
    /++ Required preparation has not completed. +/
    notPrepared,
    /++ The operation completed successfully. +/
    none,
    /++ Request dimensions, parameters or callbacks violate the operation contract. +/
    invalidRequest,
    /++ A seed is blocked, outside the window or otherwise invalid. +/
    invalidSeed,
    /++ The lazy provider returned a negative cost. +/
    invalidCost
}

/// Noncopyable serial search over a caller-sized window capacity. CostFn is a
/// copyable value with double opCall(size_t x,size_t y) @safe nothrow @nogc.
/// Its samples must remain stable within an epoch; it must not reenter this
/// search. Costs are cached once per touched cell per epoch, including missing
/// cells. Ordinary reset is O(seeds); first setup and ushort epoch wrap clear
/// the reserved state once. prepare allocates, reset/advance/queries do not.
///
/// Heap positions encode settled state. Byte predecessor directions preserve
/// global size_t indices without a full predecessor-index array. On x86-64 the
/// lazy payload is 27 bytes per reserved window pixel, including cached costs;
/// allocator/GC headers, provider memory and caller paths are separate.
struct LazyCostPath(CostFn)
{
    @disable this(this);
    private enum absent = uint.max, settled = uint.max-1;
    private enum cachedCosts = !is(CostFn == OwnedCostPlane);
    private CostFn provider;
    private size_t imageWidth, imageHeight, heapLength;
    private Region2D domain;
    private double stepX,stepY,diagonal;
    private PathConnectivity connectivity;
    private double[] distances;
    static if(cachedCosts) private double[] costs;
    private uint[] heap,positions;
    private ushort[] stamps;
    private ubyte[] parents;
    private ushort epoch;
    private PathSearchError failure=PathSearchError.notPrepared;
    private bool prepared;
    private size_t touched,processed;
    private ulong evaluations;
    private bool cleared;

/++
     Reserve state only, without reading costs or starting a search. The
               global grid may exceed 2^32 pixels; local window capacity is at most
               uint.max-1. Invalid arguments/allocation failure preserve the old search.
               A successful reconfiguration invalidates its preceding query results.

     Params:
      source = Input data; its sample model, units and lifetime follow the operation contract above.
      width = Image or grid width in pixels.
      height = Image or grid height in pixels.
      maxWindowPixels = Maximum number of local search-window pixels to reserve.
      neighbors = Four- or eight-connected pixel neighborhood.
      xStep = Finite positive horizontal step length in caller-selected spatial units.
      yStep = Finite positive vertical step length in the same spatial unit as xStep.

     Throws:
     Exception for Invalid cost search capacity or grid.
    +/
    void prepare(CostFn source,size_t width,size_t height,size_t maxWindowPixels,
        PathConnectivity neighbors=PathConnectivity.eight,double xStep=1,double yStep=1)
    {
        if(!width||!height||width>size_t.max/height||!maxWindowPixels||
            maxWindowPixels>width*height||maxWindowPixels>uint.max-1||
            maxWindowPixels>size_t.max/27||cast(uint)neighbors>PathConnectivity.max||
            !isFinite(xStep)||!isFinite(yStep)||xStep<=0||yStep<=0||!isFinite(xStep+yStep))
            throw new Exception("Invalid cost search capacity or grid");
        LazyCostPath candidate=typeof(this).init;
        candidate.provider=source;candidate.imageWidth=width;candidate.imageHeight=height;
        candidate.stepX=xStep;candidate.stepY=yStep;candidate.connectivity=neighbors;
        const scale=xStep>yStep?xStep:yStep;
        candidate.diagonal=scale*sqrt((xStep/scale)^^2+(yStep/scale)^^2);
        candidate.distances=new double[maxWindowPixels];
        static if(cachedCosts) candidate.costs=new double[maxWindowPixels];
        candidate.heap=new uint[maxWindowPixels];candidate.positions=new uint[maxWindowPixels];
        candidate.stamps=new ushort[maxWindowPixels];candidate.parents=new ubyte[maxWindowPixels];
        candidate.prepared=true;candidate.failure=PathSearchError.none;
        move(candidate,this);
    }

/++
     Start a new fixed-window search using global row-major seed indices.
               Empty windows mean the preceding window, or the whole grid initially.
               Coordinate/capacity errors preserve the preceding state. Source errors
               poison the new epoch. Normal reset never scans all reserved pixels;
               epochCleared reports the rare stamp-wrap clear explicitly.

     Params:
      seeds = Global row-major indices of usable seed cells.
      window = New fixed search rectangle; empty retains the preceding window.

     Returns:
     none when the new epoch starts; otherwise the named reset failure. See the preservation/poisoning rules above.
    +/
    PathSearchError reset(scope const(size_t)[] seeds,Region2D window=Region2D.init) nothrow @nogc
    {
        if(!prepared)return PathSearchError.notPrepared;
        if(window.empty)window=domain.empty?Region2D(0,0,imageWidth,imageHeight):domain;
        if(!seeds.length||window.empty||window.x>imageWidth||window.y>imageHeight||
            window.width>imageWidth-window.x||window.height>imageHeight-window.y||
            window.width>distances.length/window.height)
            return PathSearchError.invalidRequest;
        foreach(seed;seeds) {
            if(seed>=imageWidth*imageHeight)return PathSearchError.invalidRequest;
            const x=seed%imageWidth,y=seed/imageWidth;
            if(x<window.x||y<window.y||x-window.x>=window.width||y-window.y>=window.height)
                return PathSearchError.invalidRequest;
        }
        cleared=epoch==ushort.max;
        if(cleared){stamps[]=0;epoch=1;}else ++epoch;
        domain=window;heapLength=touched=processed=0;evaluations=0;failure=PathSearchError.none;
        foreach(seed;seeds) {
            const local=cast(uint)((seed/imageWidth-window.y)*window.width+seed%imageWidth-window.x);
            double cost;
            if(!touch(local,cost)) {
                if(failure==PathSearchError.none)failure=PathSearchError.invalidSeed;
                heapLength=0;return failure;
            }
            if(distances[local]==0)continue;
            distances[local]=0;parents[local]=4;insert(local);
        }
        return PathSearchError.none;
    }

    pragma(inline,true)
    private size_t globalIndex(size_t local) const nothrow @nogc
    {return domain.width==imageWidth?domain.y*imageWidth+local:
        (domain.y+local/domain.width)*imageWidth+domain.x+local%domain.width;}
    pragma(inline,true)
    private size_t localIndex(size_t global) const nothrow @nogc
    {
        if(!epoch||failure!=PathSearchError.none||global>=imageWidth*imageHeight)return size_t.max;
        if(domain.width==imageWidth) {
            const begin=domain.y*imageWidth;
            return global>=begin&&global-begin<domain.width*domain.height?global-begin:size_t.max;
        }
        const x=global%imageWidth,y=global/imageWidth;
        if(x<domain.x||y<domain.y||x-domain.x>=domain.width||y-domain.y>=domain.height)return size_t.max;
        return (y-domain.y)*domain.width+x-domain.x;
    }
    pragma(inline,true)
    private double costAt(uint local) nothrow @nogc
    {
        static if(cachedCosts)return costs[local];
        else return provider.values[globalIndex(local)];
    }
    pragma(inline,true)
    private bool touch(uint local,out double cost) nothrow @nogc
    {
        if(stamps[local]!=epoch) {
            stamps[local]=epoch;distances[local]=double.infinity;positions[local]=absent;parents[local]=4;++touched;
            static if(cachedCosts) {
                const global=globalIndex(local);++evaluations;
                costs[local]=provider(global%imageWidth,global/imageWidth);
            }
        }
        cost=costAt(local);
        static if(cachedCosts)if(cost<0){failure=PathSearchError.invalidCost;heapLength=0;return false;}
        return isFinite(cost);
    }
    private bool less(uint a,uint b) const nothrow @nogc
    {return distances[a]<distances[b]||(distances[a]==distances[b]&&a<b);}
    private void swapAt(size_t a,size_t b) nothrow @nogc
    {const t=heap[a];heap[a]=heap[b];heap[b]=t;positions[heap[a]]=cast(uint)a;positions[heap[b]]=cast(uint)b;}
    private void rise(size_t at) nothrow @nogc
    {while(at&&less(heap[at],heap[(at-1)/2])){const parent=(at-1)/2;swapAt(at,parent);at=parent;}}
    private void insert(uint node) nothrow @nogc
    {positions[node]=cast(uint)heapLength;heap[heapLength++]=node;rise(heapLength-1);}
    private uint pop() nothrow @nogc
    {
        const result=heap[0];positions[result]=settled;
        if(--heapLength) {
            heap[0]=heap[heapLength];positions[heap[0]]=0;
            size_t at;
            while(at<heapLength/2) {
                auto child=2*at+1;
                if(child+1<heapLength&&less(heap[child+1],heap[child]))++child;
                if(!less(heap[child],heap[at]))break;
                swapAt(at,child);at=child;
            }
        }
        return result;
    }

/++
     Settle at most maxSettled cells toward a global target. False means
               more work, unreachable/invalid target or a detected negative cost;
               inspect error/exhausted. A target outside the fixed window never expands
               the graph. Edge costs match CostPath's endpoint-mean geometric metric.

     Params:
      target = Target global index or destination rectangle as specified by this operation.
      maxSettled = Maximum cells to settle in this advance call; size_t.max means no work-count limit.

     Returns:
     True when the target is settled. False means pending work, an unavailable target, exhaustion or a reported search error; inspect exhausted/error as available.
    +/
    bool advance(size_t target,size_t maxSettled=size_t.max) nothrow @nogc
    {
        const local=localIndex(target);
        if(local==size_t.max)return false;
        if(stamps[local]==epoch&&positions[local]==settled)return true;
        size_t work;
        while(heapLength&&work<maxSettled) {
            const node=pop(),x=node%domain.width,y=node/domain.width;
            ++work;++processed;const cost=costAt(node);
            foreach(dy;-1..2)foreach(dx;-1..2) {
                if((!dx&&!dy)||(connectivity==PathConnectivity.four&&dx&&dy)||
                    (dx<0&&!x)||(dy<0&&!y)||(dx>0&&x==domain.width-1)||(dy>0&&y==domain.height-1))continue;
                const nx=dx<0?x-1:dx>0?x+1:x,ny=dy<0?y-1:dy>0?y+1:y;
                const other=cast(uint)(ny*domain.width+nx);
                if(stamps[other]==epoch&&positions[other]==settled)continue;
                double otherCost;
                if(!touch(other,otherCost)){if(failure!=PathSearchError.none)return false;continue;}
                const step=dx&&dy?diagonal:dx?stepX:stepY;
                const distance=distances[node]+(cost*.5+otherCost*.5)*step;
                if(distance<distances[other]) {
                    distances[other]=distance;parents[other]=cast(ubyte)((dy+1)*3+dx+1);
                    if(positions[other]==absent)insert(other);else rise(positions[other]);
                }
            }
            if(node==local)return true;
        }
        return false;
    }

/++
     Last source/reset error. An empty .init has notPrepared.

     Returns:
     The named operation status; none denotes success. Inspect the error before using outputs.
    +/
    PathSearchError error() const nothrow @nogc {return failure;}
/++
     True before reset, after poisoning, or when no reachable unsettled cell remains.

     Returns:
     True when no reachable unsettled search cell remains, including an empty/unprepared search.
    +/
    bool exhausted() const nothrow @nogc {return !epoch||failure!=PathSearchError.none||heapLength==0;}
/++
     Fixed window for this epoch; empty before its first reset.

     Returns:
     Current fixed global pixel search rectangle.
    +/
    Region2D window() const nothrow @nogc {return domain;}
/++
     Reserved local cells, independent of the global grid dimensions.

     Returns:
     Reserved local pixel capacity, independent of the full source extent.
    +/
    size_t reservedPixels() const nothrow @nogc {return distances.length;}
/++
     Logical array payload; excludes provider, caller path and GC headers.

     Returns:
     Logical reserved payload bytes, excluding allocator overhead and caller/provider storage.
    +/
    size_t storageBytes() const nothrow @nogc {
        static if(cachedCosts)enum bytesPerCell=27;else enum bytesPerCell=19;
        return distances.length*bytesPerCell;
    }
/++
     Cells first touched and cells settled since reset, including blocked touches.

     Returns:
     Number of local cells touched since the latest reset.
    +/
    size_t touchedCells() const nothrow @nogc {return touched;}
/++
     Work consumed by advance since reset.

     Returns:
     Number of cells settled since the latest reset.
    +/
    size_t settledCells() const nothrow @nogc {return processed;}
/++
     Actual provider calls since reset; lazy providers evaluate each touched cell once.

     Returns:
     Number of lazy cost-provider evaluations since the latest reset.
    +/
    ulong costEvaluations() const nothrow @nogc {return evaluations;}
/++
     True only when the last reset performed the rare full stamp-wrap clear.

     Returns:
     True when the latest reset required a full reserved-state epoch clear.
    +/
    bool epochCleared() const nothrow @nogc {return cleared;}
/++
     Final distance, infinity for all unknown/blocked/outside/poisoned queries.

     Params:
      target = Target global index or destination rectangle as specified by this operation.

     Returns:
     Final cost distance for a settled target, or positive infinity when unavailable.
    +/
    double distanceTo(size_t target) const nothrow @nogc {
        const local=localIndex(target);
        return local!=size_t.max&&stamps[local]==epoch&&positions[local]==settled?distances[local]:double.infinity;
    }
    private size_t predecessor(uint local) const nothrow @nogc {
        const code=parents[local];
        const x=local%domain.width,y=local/domain.width;
        const dx=cast(int)(code%3)-1,dy=cast(int)(code/3)-1;
        const px=dx<0?x+1:dx>0?x-1:x,py=dy<0?y+1:dy>0?y-1:y;
        return py*domain.width+px;
    }
/++
     Final global predecessor, size_t.max for an unknown result; a seed points to itself.

     Params:
      target = Target global index or destination rectangle as specified by this operation.

     Returns:
     Global predecessor index, size_t.max when unavailable; a seed points to itself.
    +/
    size_t predecessorOf(size_t target) const nothrow @nogc {
        const local=localIndex(target);
        return local!=size_t.max&&stamps[local]==epoch&&positions[local]==settled?globalIndex(predecessor(cast(uint)local)):size_t.max;
    }
/++
     Required seed-to-target path length, zero when unavailable. Too-small
               caller buffers remain unchanged; successful writes use global indices.

     Params:
      target = Target global index or destination rectangle as specified by this operation.
      output = Output parameter receiving the result described above.

     Returns:
     Required seed-to-target index count, or zero when no settled path exists. A short output buffer is left unchanged.
    +/
    size_t pathTo(size_t target,scope size_t[] output) const nothrow @nogc {
        auto node=localIndex(target);
        if(node==size_t.max||stamps[node]!=epoch||positions[node]!=settled)return 0;
        size_t length=1;
        for(auto at=node;parents[at]!=4;at=predecessor(cast(uint)at))++length;
        if(output.length<length)return length;
        foreach_reverse(i;0..length){output[i]=globalIndex(node);node=predecessor(cast(uint)node);}
        return length;
    }
}

/// Reserve once and reset a bounded corridor without scanning the full image.
unittest
{
    static struct Costs {double opCall(size_t x,size_t y) @safe nothrow @nogc {return x==5&&y<3?double.infinity:1;}}
    LazyCostPath!Costs search;search.prepare(Costs.init,10000,10000,64);
    size_t[1] seed=[10001];
    assert(search.reset(seed[],Region2D(1,1,8,8))==PathSearchError.none);
    assert(search.advance(20002)&&search.distanceTo(20002)==sqrt(2.0));
    const first=search.costEvaluations;
    assert(search.advance(20002)&&search.costEvaluations==first);
    size_t[8] path;
    assert(search.pathTo(20002,path[])==2&&path[0]==seed[0]&&path[1]==20002);
    assert(search.storageBytes==27*64&&search.costEvaluations==search.touchedCells);
    assert(search.reset(seed[])==PathSearchError.none&&!search.epochCleared);
    assert(search.touchedCells==1&&!isFinite(search.distanceTo(20002)));
}

@safe unittest
{
    static struct Costs {double opCall(size_t x,size_t y) @safe nothrow @nogc {return x==2&&y==2?-1:1;}}
    LazyCostPath!Costs search;assert(search.exhausted&&search.error==PathSearchError.notPrepared);
    search.prepare(Costs.init,8,8,64);size_t[1] seeds=[0];
    assert(search.reset(seeds[])==PathSearchError.none);
    assert(!search.advance(63)&&search.error==PathSearchError.invalidCost);
    assert(!isFinite(search.distanceTo(0))&&search.predecessorOf(0)==size_t.max);
    assert(search.reset(seeds[],Region2D(0,0,2,2))==PathSearchError.none);
    assert(search.advance(9));const old=search.distanceTo(9);
    assert(search.reset(seeds[],Region2D(1,1,2,2))==PathSearchError.invalidRequest);
    assert(search.distanceTo(9)==old);
    search.epoch=ushort.max;
    assert(search.reset(seeds[])==PathSearchError.none&&search.epochCleared);
    assert(!isFinite(search.distanceTo(9))&&search.advance(9));
}

// Expanding the graph can make an already settled path cheaper. It must not
// preserve that old answer as settled; ordinary reset supplies a new epoch.
@safe unittest
{
    static struct Costs {
        double opCall(size_t x,size_t y) @safe nothrow @nogc {return y==0?.1:1;}
    }
    LazyCostPath!Costs search;search.prepare(Costs.init,5,3,10,PathConnectivity.four);
    size_t[1] seeds=[5];
    assert(search.reset(seeds[],Region2D(0,1,5,1))==PathSearchError.none);
    assert(search.advance(9)&&search.distanceTo(9)==4);
    assert(search.reset(seeds[],Region2D(0,0,5,2))==PathSearchError.none);
    assert(!isFinite(search.distanceTo(9))&&search.advance(9));
    import std.math : abs;
    assert(abs(search.distanceTo(9)-1.5)<3e-15);
}
