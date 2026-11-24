module imagery.analysis.path_kernels;

import imagery.analysis.feature_parameters : PathMorphologyParams;
import imagery.analysis.feature_regions : Value, ValueTileOutput;
import std.algorithm : min, max, sort;
import std.math : signbit,isFinite;

@safe:

// Threshold decomposition of grayscale path morphology on a directed acyclic
// graph. Activating pixels in value order grows capped longest-path lengths;
// each forward/backward length increases at most L times. The queue never holds
// a node twice. O(N log N + N*L*(2*step+1)) time and O(N) reserved storage.
package struct ThresholdPathWorkspace
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
    ThresholdPathWorkspace scratch;scratch.reserve(77,35);
    assert(scratch.bytes==ThresholdPathWorkspace.requiredBytes(77,35));
}

// Grayscale dynamic programming, with max(8,2*length) scanlines retained per
// strip. Only one predecessor row per path length is live: update lengths in
// descending order. The horizontal orientation transposes the loaded support,
// so both orientations compute contiguous rows. Invalid samples are unreachable
// infinities, never numeric zero. Negative zero selects the scalar tie oracle.
package struct PathWorkspace
{
    static size_t stripHeight(uint length) nothrow @nogc {return max(8u,2*length);}
    double[] input,running,forward,best;
    float[] narrowInput,narrowRunning,narrowForward,narrowBest;
    ubyte[] byteSource,byteInput,byteRunning,byteForward,byteBest;
    size_t byteRuns;
    static size_t requiredBytes(size_t width,size_t height,PathMorphologyParams p,bool narrow=false) nothrow @nogc {
        const halo=(p.length-1)*max(1u,p.lateralStep),side=max(width,height);
        const samples=(width+2*halo)*(height+2*halo);
        const count=samples+p.length*(side+2*halo)+p.length*side*min(stripHeight(p.length),side)+side;
        return count*(narrow?float.sizeof:double.sizeof)+count+samples;
    }
    void reserve(size_t width,size_t height,PathMorphologyParams p,bool narrow=false) {
        const halo=(p.length-1)*max(1u,p.lateralStep),side=max(width,height);
        const n=(width+2*halo)*(height+2*halo),r=p.length*(side+2*halo);
        const f=p.length*side*min(stripHeight(p.length),side);
        PathWorkspace candidate;
        candidate.byteSource=new ubyte[n];candidate.byteInput=new ubyte[n];candidate.byteRunning=new ubyte[r];
        candidate.byteForward=new ubyte[f];candidate.byteBest=new ubyte[side];
        if(narrow) {
            candidate.narrowInput=new float[n];candidate.narrowRunning=new float[r];
            candidate.narrowForward=new float[f];candidate.narrowBest=new float[side];
        } else {
            candidate.input=new double[n];candidate.running=new double[r];
            candidate.forward=new double[f];candidate.best=new double[side];
        }
        this=candidate;
    }
    size_t bytes() const nothrow @nogc {
        return (input.length+running.length+forward.length+best.length)*double.sizeof+
            (narrowInput.length+narrowRunning.length+narrowForward.length+narrowBest.length)*float.sizeof+
            byteSource.length+byteInput.length+byteRunning.length+byteForward.length+byteBest.length;
    }
}

unittest {
    foreach(p;[PathMorphologyParams(7,1),PathMorphologyParams(31,2)])foreach(narrow;[false,true]) {
        PathWorkspace work;work.reserve(256,193,p,narrow);
        assert(work.bytes==PathWorkspace.requiredBytes(256,193,p,narrow));
    }
}

// The new min/max carrier is tested against the retained threshold DAG on
// lines, blobs, masks and rounding ties, for every requested support class.
@safe unittest
{
    import imagery.analysis.feature_regions : Point;
    import imagery.analysis.feature_output32 : Float32TileOutput;
    enum w=9,h=7,n=w*h;
    foreach(length;[1u,7u,15u,31u])foreach(step;[0u,1u,2u]) {
        const p=PathMorphologyParams(length,step),halo=(length-1)*max(1u,step);
        PathWorkspace work;work.reserve(w,h,p,true);
        ThresholdPathWorkspace reference;reference.reserve((w+2*halo)*(h+2*halo),n);
        float[n][3] channels;ubyte[n] valid,oriented,range;double[n] raw;
        float[][3] planes=[channels[0][],channels[1][],channels[2][]];
        auto output=Float32TileOutput(planes,valid[],oriented[],range[],raw[]);
        foreach(pattern;0..6)foreach(closing;[false,true]) {
            auto read=(int x,int y) @safe nothrow @nogc {
                x=max(0,min(w-1,x));y=max(0,min(h-1,y));
                const double v=pattern==0?(y==3?1:0):pattern==1?(x>=3&&x<=5&&y>=2&&y<=4?1:0):
                    pattern==2?cast(double)((x*7+y*13+x*y)%31)/31:
                    pattern==3?.5+double.epsilon*((x+y)%3):
                    pattern==4?.25:cast(float)((x*37+y*19+x*y)%256)/255.0f;
                return Point(v,pattern!=2||x!=4||y!=3);
            };
            Value[n] expected;
            assert(evaluateThresholdPathsInto(closing,w,h,read,p,reference,ValueTileOutput(expected[])));
            assert(evaluatePathsInto(closing,w,h,read,p,work,output));
            foreach(i,value;expected) {
                assert(valid[i]==value.valid&&range[i]==0&&oriented[i]==0);
                if(value.valid)assert(channels[0][i]==cast(float)value.channels[0]);
            }
        }
        if(length>1)foreach(value;[-0.0,1e300,1e-200]) {
            valid[]=77;
            assert(!evaluatePathsInto(false,w,h,(int x,int y) @safe nothrow @nogc {
                return Point(value,true);
            },p,work,output));
            foreach(v;valid)assert(v==77,"Narrow fallback must precede output publication");
        }
    }
}

@safe unittest
{
    Value[1] values;auto output=BytePathOutput!ValueTileOutput(ValueTileOutput(values[]));
    foreach(code;0..256) {
        output.setValue(0,Value([code,0,0],true,false));
        assert(values[0].channels[0]==cast(double)(cast(float)code/255.0f));
        assert(output.scalarAt(0)==code);
    }
}

pragma(inline,true)
private T choosePath(bool closing,T)(T a,T b) nothrow @nogc {
    static if(closing)return a<b?a:b;else return a>b?a:b;
}

private void pathRowStep(bool closing,uint step,T)(scope const(T)[] input,size_t wide,uint length,
    scope T[] running) nothrow @nogc
{
    static if(is(T==ubyte))enum T missing=closing?255:0;
    else enum missing=closing?T.infinity:-T.infinity;
    // Descending length preserves the predecessor state from the preceding
    // scanline while reusing the same running buffer.
    for(size_t k=length-1;k>0;--k) {
        auto next=running[k*wide..(k+1)*wide];
        const prior=running[(k-1)*wide..k*wide];
        static foreach(border;0..step) {
            foreach(x;[cast(size_t)border,wide-1-border]) {
                T best=missing;
                foreach(dx;-cast(int)step..cast(int)step+1) {
                    const at=cast(long)x+dx;
                    if(at>=0&&at<wide)best=choosePath!closing(best,prior[cast(size_t)at]);
                }
                next[x]=choosePath!(!closing)(input[x],best);
            }
        }
        const count=wide-2*step;
        auto target=next[step..wide-step];const source=input[step..wide-step];
        const center=prior[step..wide-step];
        static if(step>=1){const left=prior[step-1..step-1+count],right=prior[step+1..step+1+count];}
        static if(step==2){const farLeft=prior[0..count],farRight=prior[4..4+count];}
        foreach(i,ref v;target) {
            T best=center[i];
            static if(step>=1)best=choosePath!closing(choosePath!closing(best,left[i]),right[i]);
            static if(step==2)best=choosePath!closing(choosePath!closing(best,farLeft[i]),farRight[i]);
            v=choosePath!(!closing)(source[i],best);
        }
    }
    running[0..wide]=input[];
}

private void pathRow(bool closing,T)(scope const(T)[] input,size_t wide,uint length,uint step,
    scope T[] running) nothrow @nogc {
    if(step==0)pathRowStep!(closing,0)(input,wide,length,running);
    else if(step==1)pathRowStep!(closing,1)(input,wide,length,running);
    else pathRowStep!(closing,2)(input,wide,length,running);
}

private bool dynamicPaths(bool closing,T,Read,Output)(size_t width,size_t height,scope Read read,
    PathMorphologyParams p,scope T[] input,scope T[] runningBuffer,scope T[] forward,scope T[] bestBuffer,scope Output output)
{
    static if(is(T==ubyte))enum T missing=closing?255:0;
    else enum missing=closing?T.infinity:-T.infinity;
    const halo=(p.length-1)*max(1u,p.lateralStep);
    const n=(width+2*halo)*(height+2*halo);
    assert(input.length>=n);
    // Validate before publishing anything, preserving the original signed-zero
    // fallback and allowing fully invalid supports to remain invalid.
    foreach(y;0..height+2*halo)foreach(x;0..width+2*halo) {
        const point=read(cast(int)x-cast(int)halo,cast(int)y-cast(int)halo);
        if(point.valid&&point.value==0&&signbit(point.value))return false;
        const converted=cast(T)point.value;
        static if(is(T==float))if(point.valid&&(!isFinite(converted)||(converted==0&&point.value!=0)))return false;
        input[y*(width+2*halo)+x]=point.valid?converted:missing;
    }
    output.initialize(width*height,false);
    foreach(vertical;[true,false]) {
        const minor=vertical?width:height,major=vertical?height:width;
        const wide=minor+2*halo;
        if(!vertical)foreach(y;0..major+2*halo)foreach(x;0..wide) {
            const point=read(cast(int)y-cast(int)halo,cast(int)x-cast(int)halo);
            input[y*wide+x]=point.valid?cast(T)point.value:missing;
        }
        auto running=runningBuffer[0..p.length*wide];
        for(size_t strip=0;strip<major;strip+=PathWorkspace.stripHeight(p.length)) {
            const count=min(PathWorkspace.stripHeight(p.length),major-strip);
            auto retained=forward[0..p.length*count*minor];
            running[]=missing;
            const first=halo+strip-(p.length-1),end=halo+strip+count;
            foreach(y;first..end) {
                pathRow!closing(input[y*wide..(y+1)*wide],wide,p.length,p.lateralStep,running);
                if(y>=halo+strip)foreach(k;0..p.length) {
                    const offset=((y-halo-strip)*p.length+k)*minor;
                    retained[offset..offset+minor]=running[k*wide+halo..k*wide+halo+minor];
                }
            }
            running[]=missing;
            for(size_t y=end+p.length-1;y-- > halo+strip;) {
                pathRow!closing(input[y*wide..(y+1)*wide],wide,p.length,p.lateralStep,running);
                if(y>=end)continue;
                const local=y-halo-strip;auto best=bestBuffer[0..minor];best[]=missing;
                foreach(k;0..p.length) {
                    const a=retained[(local*p.length+k)*minor..(local*p.length+k+1)*minor];
                    const b=running[(p.length-1-k)*wide+halo..(p.length-1-k)*wide+halo+minor];
                    foreach(i,ref value;best) {
                        static if(closing) {const v=a[i]>b[i]?a[i]:b[i];value=value<v?value:v;}
                        else {const v=a[i]<b[i]?a[i]:b[i];value=value>v?value:v;}
                    }
                }
                foreach(i,value;best)if(isFinite(cast(double)value)) {
                    const index=vertical?(strip+local)*width+i:i*width+strip+local;
                    if(!output.mathematicalValid(index) || (closing?value<output.scalarAt(index):value>output.scalarAt(index)))
                        output.setValue(index,Value([value,0,0],true,false));
                }
            }
        }
    }
    return true;
}

package bool evaluatePathsInto(Read,Output)(bool closing,size_t width,size_t height,
    scope Read read,PathMorphologyParams p,ref PathWorkspace scratch,scope Output output)
{
    if(p.length==1) {
        foreach(y;0..height)foreach(x;0..width) {
            const point=read(cast(int)x,cast(int)y);
            output.setValue(y*width+x,point.valid?Value([point.value,0,0],true,false):Value.init);
        }
        return true;
    }
    if(bytePaths(closing,width,height,read,p,scratch,output)){++scratch.byteRuns;return true;}
    // Finite monotone Float32 conversion commutes with this min/max lattice.
    // Overflow, underflow-to-zero and signed-zero supports retain the complete
    // double scalar oracle before output publication; dependencies stay double.
    if(scratch.narrowInput.length)
        return closing?dynamicPaths!(true,float)(width,height,read,p,scratch.narrowInput,scratch.narrowRunning,scratch.narrowForward,scratch.narrowBest,output):
            dynamicPaths!(false,float)(width,height,read,p,scratch.narrowInput,scratch.narrowRunning,scratch.narrowForward,scratch.narrowBest,output);
    return closing?dynamicPaths!(true,double)(width,height,read,p,scratch.input,scratch.running,scratch.forward,scratch.best,output):
        dynamicPaths!(false,double)(width,height,read,p,scratch.input,scratch.running,scratch.forward,scratch.best,output);
}

private struct BytePathReader {
    const(ubyte)[] values;size_t stride,halo;
    import imagery.analysis.feature_regions : Point;
    this(const(ubyte)[] values,size_t stride,size_t halo) nothrow @nogc {
        this.values=values;this.stride=stride;this.halo=halo;
    }
    pragma(inline,true) Point opCall(int x,int y) const scope @safe nothrow @nogc {
        return Point(values[(cast(long)halo+y)*stride+cast(long)halo+x],true);
    }
}

private struct BytePathOutput(Output) {
    Output target;
    pragma(inline,true) void initialize(size_t n,bool valid) scope nothrow @nogc {target.initialize(n,valid);}
    pragma(inline,true) bool mathematicalValid(size_t i) const scope nothrow @nogc {return target.mathematicalValid(i);}
    pragma(inline,true) double scalarAt(size_t i) const scope nothrow @nogc {return cast(uint)(target.scalarAt(i)*255+.5);}
    pragma(inline,true) void setValue(size_t i,Value value) scope nothrow @nogc {
        value.channels[0]=cast(float)value.channels[0]/255.0f;target.setValue(i,value);
    }
}

private bool bytePaths(Read,Output)(bool closing,size_t width,size_t height,scope Read read,
    PathMorphologyParams p,ref PathWorkspace work,scope Output output)
{
    const halo=(p.length-1)*max(1u,p.lateralStep),wide=width+2*halo,tall=height+2*halo;
    foreach(y;0..tall)foreach(x;0..wide) {
        const point=read(cast(int)x-cast(int)halo,cast(int)y-cast(int)halo);
        if(!point.valid||!isFinite(point.value)||point.value<0||point.value>1||
            (point.value==0&&signbit(point.value)))return false;
        const code=cast(uint)(point.value*255+.5);
        // Exact source-value membership, never an approximate 8-bit cast.
        if(point.value!=cast(double)(cast(float)code/255.0f))return false;
        work.byteSource[y*wide+x]=cast(ubyte)code;
    }
    // Every supported sample is valid, so a complete straight path exists at
    // every core cell. Domain endpoints are neutral substitutes for unreachable
    // partial border states: they cannot beat a complete path. Masked, general
    // Float32 and scientific sources use the ordinary complete carriers.
    auto reader=BytePathReader(work.byteSource[0..wide*tall],wide,halo);
    auto destination=BytePathOutput!Output(output);
    return closing?dynamicPaths!(true,ubyte)(width,height,reader,p,work.byteInput,work.byteRunning,work.byteForward,work.byteBest,destination):
        dynamicPaths!(false,ubyte)(width,height,reader,p,work.byteInput,work.byteRunning,work.byteForward,work.byteBest,destination);
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

package bool evaluateThresholdPathsInto(Read,Output)(bool closing,size_t width,size_t height,
    scope Read read,PathMorphologyParams parameters,ref ThresholdPathWorkspace scratch,scope Output output)
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
        order[count++]=ThresholdPathWorkspace.Entry(p.value,cast(uint)i);
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
    foreach(length;[1u,3u,7u,13u,15u,31u])foreach(step;[0u,1u,2u]) {
        const parameters=PathMorphologyParams(length,step);
        const halo=(length-1)*max(1u,step);
        PathWorkspace scratch;scratch.reserve(w,h,parameters);
        ThresholdPathWorkspace reference;reference.reserve((w+2*halo)*(h+2*halo),w*h);
        Value[w*h] output;
        foreach(closing;[false,true]) {
            const before=GC.stats().allocatedInCurrentThread;
            assert(evaluatePaths(closing,w,h,read,parameters,scratch,output[]));
            assert(GC.stats().allocatedInCurrentThread==before);
            Value[w*h] old;
            assert(evaluateThresholdPathsInto(closing,w,h,read,parameters,reference,ValueTileOutput(old[])));
            assert(output==old);
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
