module imagery.analysis.path_kernels;

import imagery.analysis.feature_parameters : PathMorphologyParams;
import imagery.analysis.feature_regions : Value, ValueTileOutput;
import std.algorithm : min, max, sort;
import std.math : signbit;

@safe:

// Threshold decomposition of grayscale path morphology on a directed acyclic
// graph. Activating pixels in value order grows capped longest-path lengths;
// each forward/backward length increases at most L times. The queue never holds
// a node twice. O(N log N + N*L*(2*step+1)) time and O(N) reserved storage.
package struct PathWorkspace
{
    private struct Entry { double value; uint index; }
    private Entry[] order;
    private uint[] queue;
    private ubyte[] forward, backward, active, pending, published;

    // Exact array payload after a fresh reserve, excluding allocator overhead.
    static size_t requiredBytes(size_t samples,size_t area) nothrow @nogc
    {
        return samples*(Entry.sizeof+uint.sizeof+4*ubyte.sizeof)+area*ubyte.sizeof;
    }

    void reserve(size_t samples, size_t area)
    {
        if (samples > uint.max) throw new Exception("Path scratch exceeds index range");
        if (order.length < samples) {
            order=new Entry[samples];queue=new uint[samples];
            forward=new ubyte[samples];backward=new ubyte[samples];
            active=new ubyte[samples];pending=new ubyte[samples];
        }
        if (published.length < area) published=new ubyte[area];
    }

    size_t bytes() const nothrow @nogc
    {
        return order.length*Entry.sizeof+queue.length*uint.sizeof+
            forward.length+backward.length+active.length+pending.length+published.length;
    }
}

unittest
{
    PathWorkspace scratch;scratch.reserve(77,35);
    assert(scratch.bytes==PathWorkspace.requiredBytes(77,35));
}

// Reader is anchored at the output tile origin and clamps only at source edges.
// False requests the original scalar kernel, preserving signed-zero tie bits.
// That fallback is detected before any output publication.
package bool evaluatePaths(Read)(bool closing, size_t width, size_t height,
    scope Read read, PathMorphologyParams parameters, ref PathWorkspace scratch,
    scope Value[] output)
{
    return evaluatePathsInto(closing,width,height,read,parameters,scratch,ValueTileOutput(output));
}

package bool evaluatePathsInto(Read,Output)(bool closing,size_t width,size_t height,
    scope Read read,PathMorphologyParams parameters,ref PathWorkspace scratch,scope Output output)
{
    const halo=(parameters.length-1)*max(1u,parameters.lateralStep);
    const wide=width+2*halo,tall=height+2*halo,n=wide*tall;
    if(parameters.length==1) {
        foreach(y;0..height)foreach(x;0..width) {
            const p=read(cast(int)x,cast(int)y);
            output.setValue(y*width+x,p.valid?Value([p.value,0,0],true,false):Value.init);
        }
        return true;
    }
    assert(scratch.order.length>=n && scratch.published.length>=width*height);
    auto order=scratch.order[0..n];
    size_t count;
    foreach(y;0..tall)foreach(x;0..wide) {
        const i=y*wide+x;
        const p=read(cast(int)x-cast(int)halo,cast(int)y-cast(int)halo);
        if(!p.valid)continue;
        // Equal nonzero finite doubles have identical bits. Signed zero is
        // the one finite tie where the original min/max ordering matters.
        if(p.value==0 && signbit(p.value))return false;
        order[count++]=PathWorkspace.Entry(p.value,cast(uint)i);
    }
    if(closing)
        sort!((a,b)=>a.value==b.value?a.index<b.index:a.value<b.value)(order[0..count]);
    else
        sort!((a,b)=>a.value==b.value?a.index<b.index:a.value>b.value)(order[0..count]);
    output.initialize(width*height,false);
    auto forward=scratch.forward[0..n],backward=scratch.backward[0..n];
    auto active=scratch.active[0..n],pending=scratch.pending[0..n];
    auto published=scratch.published[0..width*height];
    auto queue=scratch.queue[0..n];
    const length=parameters.length,step=cast(int)parameters.lateralStep;
    foreach(vertical;[false,true]) {
        forward[]=0;backward[]=0;active[]=0;pending[]=0;published[]=0;
        size_t head,tail,queued;
        void enqueue(uint node) nothrow @nogc {
            if(!active[node] || pending[node])return;
            pending[node]=1;queue[tail]=node;tail=(tail+1)%n;++queued;
        }
        foreach(entry;order[0..count]) {
            const node=entry.index;
            active[node]=1;enqueue(node);
            const threshold=entry.value;
            while(queued) {
                const current=queue[head];head=(head+1)%n;--queued;pending[current]=0;
                const x=cast(int)(current%wide),y=cast(int)(current/wide);
                uint before=1,after=1;
                foreach(lateral;-step..step+1) {
                    const px=vertical?x+lateral:x-1,py=vertical?y-1:y+lateral;
                    const sx=vertical?x+lateral:x+1,sy=vertical?y+1:y+lateral;
                    if(px>=0 && py>=0 && px<wide && py<tall)
                        before=max(before,1u+forward[py*wide+px]);
                    if(sx>=0 && sy>=0 && sx<wide && sy<tall)
                        after=max(after,1u+backward[sy*wide+sx]);
                }
                before=min(before,length);after=min(after,length);
                const changedBefore=before!=forward[current],changedAfter=after!=backward[current];
                forward[current]=cast(ubyte)before;backward[current]=cast(ubyte)after;
                if(x>=halo && y>=halo && x<halo+width && y<halo+height && before+after-1>=length) {
                    const i=(y-halo)*width+x-halo;
                    if(!published[i]) {
                        published[i]=1;
                        if(!output.mathematicalValid(i) || (closing?threshold<output.scalarAt(i):threshold>output.scalarAt(i)))
                            output.setValue(i,Value([threshold,0,0],true,false));
                    }
                }
                foreach(lateral;-step..step+1) {
                    const px=vertical?x+lateral:x-1,py=vertical?y-1:y+lateral;
                    const sx=vertical?x+lateral:x+1,sy=vertical?y+1:y+lateral;
                    if(changedAfter && px>=0 && py>=0 && px<wide && py<tall)
                        enqueue(cast(uint)(py*wide+px));
                    if(changedBefore && sx>=0 && sy>=0 && sx<wide && sy<tall)
                        enqueue(cast(uint)(sy*wide+sx));
                }
            }
        }
    }
    return true;
}

unittest
{
    import imagery.analysis.feature_regions : Feature, Point;
    import imagery.analysis.feature_structure : evaluateStructure;
    import core.memory : GC;
    enum w=5,h=4;
    auto read=(int x,int y) {
        x=max(0,min(w-1,x));y=max(0,min(h-1,y));
        return Point(cast(double)((x*7+y*13+x*y)%17)-8, x!=2 || y!=1);
    };
    foreach(length;[1u,3u,7u,13u,31u])foreach(step;[0u,1u,2u]) {
        const parameters=PathMorphologyParams(length,step);
        const halo=(length-1)*max(1u,step);
        PathWorkspace scratch;scratch.reserve((w+2*halo)*(h+2*halo),w*h);
        Value[w*h] output;
        foreach(closing;[false,true]) {
            const before=GC.stats().allocatedInCurrentThread;
            assert(evaluatePaths(closing,w,h,read,parameters,scratch,output[]));
            assert(GC.stats().allocatedInCurrentThread==before);
            foreach(y;0..h)foreach(x;0..w) {
                const result=evaluateStructure(closing?Feature.pathClosing:Feature.pathOpening,
                    (int dx,int dy)=>read(x+dx,y+dy),parameters);
                assert(output[y*w+x].valid==result.valid);
                if(result.valid) {
                    assert(output[y*w+x].channels==result.channels);
                    assert(closing?result.channels[0]>=read(x,y).value:result.channels[0]<=read(x,y).value);
                }
            }
            const original=output.dup;
            assert(evaluatePaths(closing,w,h,(int x,int y) {
                const p=read(x,y);return Point(2*p.value+17,p.valid);
            },parameters,scratch,output[]));
            foreach(i;0..w*h) {
                assert(output[i].valid==original[i].valid);
                if(output[i].valid)assert(output[i].channels[0]==2*original[i].channels[0]+17);
            }
        }
    }
}
