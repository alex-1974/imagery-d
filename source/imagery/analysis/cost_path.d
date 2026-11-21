/++ Incremental shortest paths over explicit nonnegative pixel costs.
 Edge cost is the arithmetic mean of endpoint costs times step length, as
 in geometric MCP. Coordinates and step lengths are in pixels. Positive
 infinity and NaN block a sample; negative finite costs are rejected.
 Prepare owns a copy of the cost plane and O(width*height) scratch. Subsequent
 search and path extraction allocate nothing. Instances require serial use.
+/
module imagery.analysis.cost_path;

import std.math : isFinite, sqrt;

@safe:

/// Eight neighbors use Euclidean diagonal step lengths; four use axes only.
enum PathConnectivity { four, eight }

/// Prepared state reused while the interactive target moves. Each advance
/// settles at most the caller's work budget, allowing cancellation between
/// calls without losing settled distances. Equal keys prefer the lower
/// row-major index. Equal relaxations preserve the first predecessor.
struct CostPath
{
    @disable this(this);
    private size_t width, height, heapLength;
    private double stepX, stepY, diagonal;
    private PathConnectivity connectivity;
    private double[] costs, distances;
    private size_t[] predecessors, heap, positions;
    private bool[] settled;
    private enum absent = size_t.max;

    /// Reset the search with one or more row-major seed indices. Input sample
    /// type may be float, double or an integer. Invalid arguments throw before
    /// replacing the previous prepared search. Seeds must be traversable.
    void prepare(T)(scope const(T)[] cost, size_t w, size_t h,
        scope const(size_t)[] seeds, PathConnectivity neighbors = PathConnectivity.eight,
        double xStep = 1, double yStep = 1)
    {
        if (!w || !h || w > size_t.max/h || cost.length != w*h || !seeds.length ||
            cast(uint)neighbors > PathConnectivity.max || !isFinite(xStep) ||
            !isFinite(yStep) || xStep <= 0 || yStep <= 0 || !isFinite(xStep+yStep))
            throw new Exception("Invalid cost plane or step lengths");
        foreach (value; cost)
            if (value < 0) throw new Exception("Negative cost");
        foreach (seed; seeds)
            if (seed >= cost.length || !isFinite(cast(double)cost[seed]))
                throw new Exception("Invalid or blocked seed");
        CostPath candidate;
        candidate.width=w; candidate.height=h;
        candidate.stepX=xStep; candidate.stepY=yStep; candidate.connectivity=neighbors;
        const scale=xStep>yStep?xStep:yStep;
        candidate.diagonal=scale*sqrt((xStep/scale)^^2+(yStep/scale)^^2);
        candidate.costs=new double[cost.length];
        candidate.distances=new double[cost.length];
        candidate.predecessors=new size_t[cost.length];
        candidate.heap=new size_t[cost.length];
        candidate.positions=new size_t[cost.length];
        candidate.settled=new bool[cost.length];
        candidate.distances[]=double.infinity;
        candidate.predecessors[]=absent; candidate.positions[]=absent;
        foreach (i, value; cost) candidate.costs[i]=cast(double)value;
        foreach (seed; seeds)
        {
            if (candidate.distances[seed] == 0) continue;
            candidate.distances[seed]=0; candidate.predecessors[seed]=seed;
            candidate.insert(seed);
        }
        import std.algorithm.mutation : move;
        move(candidate,this);
    }

    private bool less(size_t a, size_t b) const nothrow @nogc
    {
        return distances[a] < distances[b] || (distances[a] == distances[b] && a < b);
    }
    private void swapAt(size_t a, size_t b) nothrow @nogc
    {
        const t=heap[a]; heap[a]=heap[b]; heap[b]=t;
        positions[heap[a]]=a; positions[heap[b]]=b;
    }
    private void rise(size_t at) nothrow @nogc
    {
        while (at && less(heap[at],heap[(at-1)/2]))
        { const parent=(at-1)/2; swapAt(at,parent); at=parent; }
    }
    private void insert(size_t node) nothrow @nogc
    {
        positions[node]=heapLength; heap[heapLength++]=node; rise(heapLength-1);
    }
    private size_t pop() nothrow @nogc
    {
        const result=heap[0]; positions[result]=absent;
        if (--heapLength)
        {
            heap[0]=heap[heapLength]; positions[heap[0]]=0;
            size_t at;
            while (at < heapLength/2)
            {
                auto child=2*at+1;
                if (child+1<heapLength && less(heap[child+1],heap[child])) ++child;
                if (!less(heap[child],heap[at])) break;
                swapAt(at,child); at=child;
            }
        }
        return result;
    }

    /// Continue until target is settled, the queue empties, or maxSettled nodes
    /// have been processed. Returns whether target has a final finite distance.
    /// A false return can mean either more work or an unreachable target.
    bool advance(size_t target, size_t maxSettled = size_t.max) nothrow @nogc
    {
        if (target >= costs.length) return false;
        if (settled[target]) return true;
        size_t work;
        while (heapLength && work < maxSettled)
        {
            const node=pop(), x=node%width, y=node/width;
            settled[node]=true; ++work;
            foreach (dy; -1 .. 2) foreach (dx; -1 .. 2)
            {
                if ((!dx && !dy) || (connectivity==PathConnectivity.four && dx && dy) ||
                    (dx<0 && !x) || (dy<0 && !y) ||
                    (dx>0 && x==width-1) || (dy>0 && y==height-1)) continue;
                const nx=dx<0?x-1:dx>0?x+1:x, ny=dy<0?y-1:dy>0?y+1:y;
                const other=ny*width+nx;
                if (settled[other] || !isFinite(costs[other])) continue;
                const step=dx && dy ? diagonal : dx ? stepX : stepY;
                const distance=distances[node]+(costs[node]*0.5+costs[other]*0.5)*step;
                if (distance < distances[other])
                {
                    distances[other]=distance; predecessors[other]=node;
                    if (positions[other]==absent) insert(other); else rise(positions[other]);
                }
            }
            // Relax target neighbors too: later queries may continue from here.
            if (node==target) return true;
        }
        return false;
    }

    /// True when no unsettled reachable samples remain.
    bool exhausted() const nothrow @nogc { return heapLength == 0; }

    /// Final distance, or infinity for an unsettled/out-of-bounds target.
    double distanceTo(size_t target) const nothrow @nogc
    { return target<settled.length && settled[target] ? distances[target] : double.infinity; }

    /// Write seed-to-target row-major indices into caller storage. Returns
    /// required length; too-small buffers stay untouched. Zero means no path.
    size_t pathTo(size_t target, scope size_t[] output) const nothrow @nogc
    {
        if (target>=settled.length || !settled[target]) return 0;
        size_t length=1, node=target;
        while (predecessors[node]!=node) { ++length; node=predecessors[node]; }
        if (output.length<length) return length;
        node=target;
        foreach_reverse (i; 0 .. length)
        { output[i]=node; node=predecessors[node]; }
        return length;
    }
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
    assert(search.advance(2) && search.distanceTo(2)==2);
    costs[3..6]=double.infinity;
    search.prepare(costs[],3,3,seeds[],PathConnectivity.four);
    assert(!search.advance(8) && search.exhausted);
    assert(search.pathTo(8,path[])==0);
}
