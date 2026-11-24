/++ Prepared complete Canny on finite float32 scalar samples. No implicit
Gaussian is applied. Replicated Sobel edges, inclusive four-sector NMS and
global eight-connected hysteresis match imagery.analysis.primitives.canny.
+/
module imagery.analysis.canny_worker;

import std.math : abs,isFinite,sqrt;
import std.algorithm : min,max;
import std.algorithm.mutation : move;

@safe:

/// .init is not success. Every failure preserves the caller destination.
enum CannyWorkerError : ubyte {
    /++ Required preparation has not completed. +/
    notPrepared,
    /++ The operation completed successfully. +/
    none,
    /++ Request dimensions, parameters or callbacks violate the operation contract. +/
    invalidRequest,
    /++ An input observation violates the required numeric/sample domain. +/
    invalidSample,
    /++ The caller requested cancellation before completion. +/
    cancelled}

/// Noncopyable serial workspace. prepare allocates once; tryRun uses no GC or
/// native allocation. Only magnitude and suppressed strength need float planes;
/// direction sectors, private staged edges and a uint queue give 14 bytes per
/// reserved pixel, excluding allocator headers and caller input/destination.
/// Hysteresis is global; independent fixed-halo tiles are not equivalent.
struct CannyWorkspace
{
    @disable this(this);
    private size_t maxWidth,maxHeight;
    private float[] magnitude,thin;
    private ubyte[] sector,staging;
    private uint[] queue;

/++
     Reserve bounded full-domain capacity, at most uint.max pixels. Invalid
               extents/allocation failure preserve the previous prepared workspace.

     Params:
      width = Image or grid width in pixels.
      height = Image or grid height in pixels.

     Throws:
     Exception for Invalid Canny workspace capacity.
    +/
    void prepare(size_t width,size_t height)
    {
        if(!width||!height||width>size_t.max/height||width*height>uint.max||width*height>size_t.max/14)
            throw new Exception("Invalid Canny workspace capacity");
        const n=width*height;CannyWorkspace candidate;
        candidate.maxWidth=width;candidate.maxHeight=height;
        candidate.magnitude=new float[n];candidate.thin=new float[n];
        candidate.sector=new ubyte[n];candidate.staging=new ubyte[n];candidate.queue=new uint[n];
        move(candidate,this);
    }

/++
     Logical reserved array payload; zero for .init. Does not claim RSS.

     Returns:
     Logical reserved payload bytes, excluding allocator overhead and caller/provider storage.
    +/
    size_t storageBytes() const nothrow @nogc {return magnitude.length*14;}

    private void record(size_t i,float gx,float gy) nothrow @nogc
    {
        magnitude[i]=sqrt(gx*gx+gy*gy);
        const ax=abs(gx),ay=abs(gy);
        sector[i]=cast(ubyte)(ax>=ay*2.4142f?0:ay>=ax*2.4142f?1:gx*gy>=0?2:3);
    }
    private static float sample(scope const(float)[] input,size_t width,size_t height,long x,long y) nothrow @nogc
    {return input[cast(size_t)max(0L,min(cast(long)height-1,y))*width+cast(size_t)max(0L,min(cast(long)width-1,x))];}
    private void scalarSobel(scope const(float)[] input,size_t w,size_t h,size_t x,size_t y) nothrow @nogc
    {
        immutable int[3][3] kx=[[-1,0,1],[-2,0,2],[-1,0,1]],ky=[[-1,-2,-1],[0,0,0],[1,2,1]];
        float gx=0,gy=0;
        foreach(dy;-1..2)foreach(dx;-1..2) {
            const value=sample(input,w,h,cast(long)x+dx,cast(long)y+dy);
            gx+=value*kx[dy+1][dx+1];gy+=value*ky[dy+1][dx+1];
        }
        record(y*w+x,gx,gy);
    }

/++
     Complete one image into the first width*height destination bytes, after
               final cancellation. Extra destination bytes remain unchanged. Source
               length is exact; capacity is per axis. Thresholds are finite with
               0<=low<=high. Nonfinite source samples are rejected explicitly before
               publication. Cancellation is synchronous and cannot reenter/mutate this
               workspace. Inputs must remain stable for the complete call.

     Params:
      input = Input values or callback; the operation reads it as described above.
      width = Image or grid width in pixels.
      height = Image or grid height in pixels.
      low = Nonnegative weak-edge magnitude threshold, no greater than high.
      high = Strong-edge magnitude threshold, at least low.
      destination = Caller-owned output storage, or the destination pixel/raster for compositing.
      cancelled = Optional synchronous cancellation predicate; true requests cancellation.

     Returns:
     The named operation status; none denotes success. Inspect the error before using outputs.
    +/
    CannyWorkerError tryRun(scope const(float)[] input,size_t width,size_t height,
        float low,float high,scope ubyte[] destination,
        scope bool delegate() @safe nothrow @nogc cancelled=null) nothrow @nogc
    {
        if(!maxWidth)return CannyWorkerError.notPrepared;
        if(!width||!height||width>maxWidth||height>maxHeight||width>size_t.max/height||
            input.length!=width*height||destination.length<input.length||
            !isFinite(low)||!isFinite(high)||low<0||high<low)return CannyWorkerError.invalidRequest;
        const n=input.length;bool clean=true;
        foreach(y;0..height) {
            if(cancelled !is null&&cancelled())return CannyWorkerError.cancelled;
            foreach(value;input[y*width..(y+1)*width]) {
                if(!isFinite(value))return CannyWorkerError.invalidSample;
                clean&=abs(value)<=float.max/32;
            }
        }
        foreach(y;0..height) {
            if(cancelled !is null&&cancelled())return CannyWorkerError.cancelled;
            scalarSobel(input,width,height,0,y);
            if(width>1)scalarSobel(input,width,height,width-1,y);
            if(!clean) {
                foreach(x;1..width-1)scalarSobel(input,width,height,x,y);
                continue;
            }
            const a=input[(y?y-1:0)*width..$][0..width],b=input[y*width..$][0..width],
                c=input[(y+1<height?y+1:y)*width..$][0..width];
            foreach(x;1..width-1) {
                float gx=0,gy=0;
                gx-=a[x-1];gx+=a[x+1];gx-=2*b[x-1];gx+=2*b[x+1];gx-=c[x-1];gx+=c[x+1];
                gy-=a[x-1];gy-=2*a[x];gy-=a[x+1];gy+=c[x-1];gy+=2*c[x];gy+=c[x+1];
                record(y*width+x,gx,gy);
            }
        }
        // Suppressed/border samples are unavailable, not zero-strength maxima.
        // This distinction matters for inclusive zero thresholds.
        thin[0..n]=float.nan;staging[0..n]=0;
        foreach(y;1..(height>1?height-1:1)) {
            if(cancelled !is null&&cancelled())return CannyWorkerError.cancelled;
            foreach(x;1..(width>1?width-1:1)) {
                const i=y*width+x;float a,b;
                switch(sector[i]) {
                    case 0:a=magnitude[i-1];b=magnitude[i+1];break;
                    case 1:a=magnitude[i-width];b=magnitude[i+width];break;
                    case 2:a=magnitude[i-width-1];b=magnitude[i+width+1];break;
                    case 3:a=magnitude[i-width+1];b=magnitude[i+width-1];break;
                    default:assert(0,"Internal Canny sector must be in 0..3");
                }
                if(magnitude[i]>=a&&magnitude[i]>=b)thin[i]=magnitude[i];
            }
        }
        size_t head,tail;
        foreach(i;0..n)if(thin[i]>=high){staging[i]=1;queue[tail++]=cast(uint)i;}
        while(head<tail) {
            if((head&255)==0&&cancelled !is null&&cancelled())return CannyWorkerError.cancelled;
            const i=queue[head++],x=i%width,y=i/width;
            foreach(dy;-1..2)foreach(dx;-1..2) {
                const nx=cast(long)x+dx,ny=cast(long)y+dy;
                if(nx<0||ny<0||nx>=width||ny>=height)continue;
                const next=cast(size_t)ny*width+cast(size_t)nx;
                if(!staging[next]&&thin[next]>=low){staging[next]=1;queue[tail++]=cast(uint)next;}
            }
        }
        if(cancelled !is null&&cancelled())return CannyWorkerError.cancelled;
        destination[0..n]=staging[0..n];return CannyWorkerError.none;
    }
}

/// Repeated complete Canny reuses storage and publishes only completed bytes.
@safe unittest
{
    CannyWorkspace worker;float[25] image=0;ubyte[26] edges=99;
    assert(worker.tryRun(image[],5,5,.1f,.2f,edges[])==CannyWorkerError.notPrepared);
    worker.prepare(5,5);foreach(y;0..5)foreach(x;3..5)image[y*5+x]=1;
    assert(worker.tryRun(image[],5,5,.1f,.2f,edges[])==CannyWorkerError.none&&edges[25]==99);
    const prior=edges;
    assert(worker.tryRun(image[],5,5,-1,.2f,edges[])==CannyWorkerError.invalidRequest&&edges==prior);
    assert(worker.tryRun(image[],5,5,.1f,.2f,edges[],() @safe nothrow @nogc {return true;})==CannyWorkerError.cancelled&&edges==prior);
    size_t polls;
    assert(worker.tryRun(image[],5,5,.1f,.2f,edges[],() @safe nothrow @nogc {++polls;return false;})==CannyWorkerError.none);
    const complete=edges;size_t current;
    assert(worker.tryRun(image[],5,5,.1f,.2f,edges[],() @safe nothrow @nogc {return ++current==polls;})==CannyWorkerError.cancelled&&edges==complete);
    image[0]=float.nan;
    assert(worker.tryRun(image[],5,5,.1f,.2f,edges[])==CannyWorkerError.invalidSample&&edges==prior);
    assert(worker.storageBytes==25*14);
}
