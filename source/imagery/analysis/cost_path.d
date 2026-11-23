/++ Incremental geometric paths over explicit image costs.
The owned plane API preserves float64 costs/distances and deterministic ties.
New seed sets reuse reserved window state through epoch reset. LazyCostPath
instead evaluates a stable cost functor only at touched global coordinates.
+/
module imagery.analysis.cost_path;

import std.math : isFinite,sqrt;
import raster.region : Region2D;
public import imagery.analysis.lazy_cost_path : LazyCostPath,PathSearchError;

@safe:

/// Eight neighbors use Euclidean diagonal step lengths; four use axes only.
enum PathConnectivity { four,eight }

package struct OwnedCostPlane
{
    const(double)[] values;
    size_t width;
    this(const(double)[] values,size_t width) nothrow @nogc {this.values=values;this.width=width;}
    double opCall(size_t x,size_t y) const nothrow @nogc {return values[y*width+x];}
}

/// Noncopyable serial search retaining an independent float64 cost copy.
/// prepare allocates; subsequent reset, advance and path queries allocate
/// nothing. .init is empty/exhausted, distance is infinity and pathTo is zero.
/// A normal reset is O(seeds), with a rare ushort epoch-wrap capacity clear.
/// The default full-grid search retains the original metric and tie rules.
/// Supply an initial window to reserve only its local state; a later reserve
/// can grow that capacity explicitly. Every window change starts a new epoch.
struct CostPath
{
    @disable this(this);
    private OwnedCostPlane owned;
    private LazyCostPath!OwnedCostPlane search;
    private size_t width,height;
    private PathConnectivity neighbors;
    private double xStep=1,yStep=1;

    /// Validate and own scalar costs, preserving previous state on failure.
    /// NaN/positive infinity block cells; negative costs are rejected. Large
    /// integer samples may lose precision in the explicit float64 conversion.
    /// Seeds are global row-major indices. Empty initialWindow means all pixels.
    void prepare(T)(scope const(T)[] cost,size_t w,size_t h,
        scope const(size_t)[] seeds,PathConnectivity neighbors=PathConnectivity.eight,
        double xStep=1,double yStep=1,Region2D initialWindow=Region2D.init)
    {
        if(!w||!h||w>size_t.max/h||cost.length!=w*h||!seeds.length||
            cast(uint)neighbors>PathConnectivity.max||!isFinite(xStep)||!isFinite(yStep)||
            xStep<=0||yStep<=0||!isFinite(xStep+yStep))throw new Exception("Invalid cost plane or step lengths");
        foreach(value;cost)if(value<0)throw new Exception("Negative cost");
        foreach(seed;seeds)if(seed>=cost.length||!isFinite(cast(double)cost[seed]))
            throw new Exception("Invalid or blocked seed");
        if(initialWindow.empty)initialWindow=Region2D(0,0,w,h);
        if(initialWindow.x>w||initialWindow.y>h||initialWindow.width>w-initialWindow.x||
            initialWindow.height>h-initialWindow.y||initialWindow.width>size_t.max/initialWindow.height)
            throw new Exception("Invalid search window");
        foreach(seed;seeds)if(seed%w<initialWindow.x||seed/w<initialWindow.y||
            seed%w-initialWindow.x>=initialWindow.width||seed/w-initialWindow.y>=initialWindow.height)
            throw new Exception("Seed outside search window");
        CostPath candidate;candidate.width=w;candidate.height=h;candidate.neighbors=neighbors;
        candidate.xStep=xStep;candidate.yStep=yStep;
        auto samples=new double[cost.length];foreach(i,value;cost)samples[i]=cast(double)value;
        candidate.owned=OwnedCostPlane(samples,w);
        candidate.search.prepare(candidate.owned,w,h,initialWindow.width*initialWindow.height,neighbors,xStep,yStep);
        if(candidate.search.reset(seeds,initialWindow)!=PathSearchError.none)throw new Exception("Invalid initial search");
        import std.algorithm.mutation : move;move(candidate,this);
    }

    /// Grow/reconfigure local capacity without copying source costs. Successful
    /// reserve invalidates the search; reset must follow. Failure preserves it.
    void reserve(size_t maxWindowPixels)
    {
        if(!width)throw new Exception("Prepare costs before reserving a window");
        search.prepare(owned,width,height,maxWindowPixels,neighbors,xStep,yStep);
    }
    /// Reset seeds and optionally the fixed window, preserving state on invalid
    /// coordinates or blocked seeds. Empty window means the preceding window.
    PathSearchError reset(scope const(size_t)[] seeds,Region2D window=Region2D.init) nothrow @nogc
    {
        if(!width)return PathSearchError.notPrepared;
        foreach(seed;seeds)if(seed>=owned.values.length||!isFinite(owned.values[seed]))return PathSearchError.invalidSeed;
        return search.reset(seeds,window);
    }
    /// Settle at most maxSettled cells. False means unfinished/unreachable or
    /// outside the fixed search window; inspect exhausted to distinguish work.
    bool advance(size_t target,size_t maxSettled=size_t.max) nothrow @nogc {return search.advance(target,maxSettled);}
    /// True when no reachable unsettled cells remain, including empty .init.
    bool exhausted() const nothrow @nogc {return search.exhausted;}
    /// Final distance; infinity for blocked, unsettled or out-of-window pixels.
    double distanceTo(size_t target) const nothrow @nogc {return search.distanceTo(target);}
    /// Settled global predecessor, size_t.max when unavailable; seeds point to themselves.
    size_t predecessorOf(size_t target) const nothrow @nogc {return search.predecessorOf(target);}
    /// Required global-index path length, zero when unavailable. Short buffers
    /// remain untouched; full buffers receive seed-to-target indices.
    size_t pathTo(size_t target,scope size_t[] output) const nothrow @nogc {return search.pathTo(target,output);}
    /// Current fixed window and reserved local pixel capacity.
    Region2D window() const nothrow @nogc {return search.window;}
    /// Local state capacity; independent of the owned source cost extent.
    size_t reservedPixels() const nothrow @nogc {return search.reservedPixels;}
    /// Logical owned costs + local state. Cost copy=8 bytes/global pixel and
    /// state=19 bytes/reserved pixel; excludes allocator/GC metadata/caller path.
    size_t storageBytes() const nothrow @nogc {return owned.values.length*double.sizeof+search.storageBytes;}
    /// Settled/touched work since reset; epochCleared marks the rare full clear.
    size_t touchedCells() const nothrow @nogc {return search.touchedCells;}
    /// Actual settled cells since reset.
    size_t settledCells() const nothrow @nogc {return search.settledCells;}
    /// Whether the preceding reset cleared all stamp storage on epoch wrap.
    bool epochCleared() const nothrow @nogc {return search.epochCleared;}
}

/// Searches extend across targets without allocating or restarting.
unittest
{
    import std.math : abs;
    CostPath search;
    double[9] costs=1;
    size_t[1] seeds=[0];
    search.prepare(costs[],3,3,seeds[]);
    assert(!search.advance(8,1));
    assert(search.advance(8));
    assert(abs(search.distanceTo(8)-2*sqrt(2.0))<1e-12);
    size_t[9] path;
    assert(search.pathTo(8,path[])==3 && path[0]==0 && path[2]==8);
    assert(search.predecessorOf(8)==4 && search.predecessorOf(0)==0);
    assert(search.predecessorOf(100)==size_t.max);
    assert(search.advance(2) && search.distanceTo(2)==2);
    costs[3..6]=double.infinity;
    search.prepare(costs[],3,3,seeds[],PathConnectivity.four);
    assert(!search.advance(8) && search.exhausted);
    assert(search.pathTo(8,path[])==0);
}
