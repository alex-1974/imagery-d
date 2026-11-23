/++ Internal separable, masked population moments and extrema. +/
module imagery.analysis.window_kernels;

import std.algorithm : min, max;
import std.math : isFinite, abs, sqrt;

@safe:

package struct WindowMoments
{
    double mean=0, m2=0;
    double roundoff=0;
    double low=double.infinity, high=-double.infinity;
    size_t count;

    void add(double value) nothrow @nogc
    {
        const delta=value-mean;
        mean+=delta / ++count;
        const term=delta*(value-mean);
        roundoff+=16*double.epsilon*(abs(m2)+abs(term));
        m2+=term;
    }
    void remove(double value) nothrow @nogc
    {
        if(count==1) { mean=0; m2=0; roundoff=0; count=0; return; }
        const delta=value-mean;
        mean-=delta / --count;
        const term=delta*(value-mean);
        roundoff+=16*double.epsilon*(abs(m2)+abs(term));
        m2=max(0.0,m2-term);
    }
    void join(WindowMoments row) nothrow @nogc
    {
        if(!row.count)return;
        if(!count) { mean=row.mean; m2=row.m2; roundoff=row.roundoff; count=row.count; return; }
        const total=count+row.count;
        const delta=row.mean-mean;
        const term=row.m2+delta*delta*(cast(double)count*row.count/total);
        roundoff+=row.roundoff+16*double.epsilon*(abs(m2)+abs(term));
        m2+=term;
        mean+=delta*(cast(double)row.count/total);
        count=total;
    }
    void subtract(WindowMoments row) nothrow @nogc
    {
        if(!row.count)return;
        if(count==row.count) { mean=0; m2=0; roundoff=0; count=0; return; }
        const remaining=count-row.count;
        const priorMean=mean+(mean-row.mean)*(cast(double)row.count/remaining);
        const delta=row.mean-priorMean;
        const term=row.m2+delta*delta*(cast(double)remaining*row.count/count);
        roundoff+=row.roundoff+16*double.epsilon*(abs(m2)+abs(term));
        m2=max(0.0,m2-term);
        mean=priorMean; count=remaining;
    }
}

private WindowMoments rebaseWindow(Read)(scope Read read,int x,int y,int radius)
{
    WindowMoments result;
    double anchor=0;
    foreach(dy;-radius..radius+1)foreach(dx;-radius..radius+1) {
        const p=read(x+dx,y+dy);
        if(!p.valid)continue;
        if(!result.count)anchor=p.value;
        result.add(p.value-anchor);
        result.low=min(result.low,p.value);result.high=max(result.high,p.value);
    }
    result.mean+=anchor;
    return result;
}

// A monotone queue keeps extrema without rescanning the window. A whole row
// is at most 256+62 samples. Each entry is inserted and removed at most once.
private struct ExtremaQueue
{
    size_t[512] indices;
    double[512] values;
    size_t first,last;
    void push(size_t index,double value,bool maximum) nothrow @nogc
    {
        while(last>first && (maximum ? values[last-1]<=value : values[last-1]>=value)) --last;
        indices[last]=index; values[last++]=value;
    }
    void expire(size_t index,size_t diameter) nothrow @nogc
    {
        if(index>=diameter && first<last && indices[first]<=index-diameter) ++first;
    }
    double front() const nothrow @nogc { return values[first]; }
}

/// Separable O((width+2r)*(height+2r)) work on well-conditioned data, with one
/// horizontal row record per expanded row and output column. Reader clamps
/// at the true source boundary. Scratch has width*(height+2r) records.
/// Shift by one finite sample before accumulating to avoid cancellation of
/// large common offsets. All storage is supplied by the request/worker.
/// Severe rolling cancellation can rebase individual windows with O(r²)
/// reference work. False selects the scalar fallback for an unsafe carrier.
package bool evaluateWindows(Read)(scope Read read, size_t width,size_t height,
    uint radius,scope WindowMoments[] rows,bool extrema=true)
{
    const fast=extrema?unitRunningMoments!true(read,width,height,radius,rows):
        unitRunningMoments!false(read,width,height,radius,rows);
    if(fast)return true;
    const r=cast(int)radius;
    const diameter=2*radius+1;
    double anchor=0;
    bool found;
    outer: foreach(y;-r..cast(int)height+r) foreach(x;-r..cast(int)width+r) {
        const p=read(x,y);
        if(p.valid && isFinite(p.value)) { anchor=p.value; found=true; break outer; }
    }
    if(!found) { rows[0..width*height]=WindowMoments.init; return true; }
    // Wide finite measurements can overflow a tile-centered carrier even
    // when a particular local window is constant. Let the complete scalar
    // reference handle such tiles rather than poisoning later rolling state.
    const limit=sqrt(double.max)/(4*diameter);
    foreach(y;-r..cast(int)height+r) foreach(x;-r..cast(int)width+r) {
        const p=read(x,y);
        if(p.valid && (!isFinite(p.value-anchor) || abs(p.value-anchor)>limit))return false;
    }
    foreach(y;0..height+2*radius)
    {
        WindowMoments rolling;
        ExtremaQueue lows,highs;
        foreach(t;0..width+2*radius)
        {
            if(t>=diameter) {
                const old=read(cast(int)(t-diameter)-r,cast(int)y-r);
                if(old.valid)rolling.remove(old.value-anchor);
            }
            lows.expire(t,diameter); highs.expire(t,diameter);
            const p=read(cast(int)t-r,cast(int)y-r);
            if(p.valid) {
                rolling.add(p.value-anchor);
                lows.push(t,p.value,false); highs.push(t,p.value,true);
            }
            if(t+1>=diameter) {
                auto cell=rolling;
                if(cell.count) { cell.low=lows.front; cell.high=highs.front; }
                rows[y*width+t+1-diameter]=cell;
            }
        }
    }
    foreach(x;0..width)
    {
        WindowMoments rolling;
        WindowMoments leaving;
        ExtremaQueue lows,highs;
        foreach(t;0..height+2*radius)
        {
            if(t>=diameter)rolling.subtract(leaving);
            lows.expire(t,diameter); highs.expire(t,diameter);
            const row=rows[t*width+x];
            rolling.join(row);
            if(row.count) { lows.push(t,row.low,false); highs.push(t,row.high,true); }
            if(t+1>=diameter) {
                auto cell=rolling;
                cell.mean+=anchor;
                if(cell.count) { cell.low=lows.front; cell.high=highs.front; }
                if(cell.count && cell.low==cell.high) {
                    cell.mean=cell.low;cell.m2=0;
                }
                else if(cell.count && cell.m2<=cell.roundoff*1e10) {
                    // Removing a high-contrast predecessor can lose nearly
                    // all significant bits of a low-variance window. Rebase
                    // only that window instead of publishing the residual.
                    cell=rebaseWindow(read,cast(int)x,cast(int)(t+1-diameter),r);
                }
                // Save the outgoing row before overwriting it. The next
                // iteration needs only that saved record; future incoming
                // rows and other columns have not been overwritten.
                leaving=rows[(t+1-diameter)*width+x];
                rows[(t+1-diameter)*width+x]=cell;
            }
        }
    }
    return true;
}

// Only bounded [0,1] supports use sums of shifted values and their squares.
// Wide scientific domains retain the full centered Welford implementation.
// Ill-conditioned individual windows are recomputed with the centered oracle;
// an uncertain small/negative variance is never silently clamped to zero.
private bool unitRunningMoments(bool extrema,Read)(scope Read read,size_t width,size_t height,
    uint radius,scope WindowMoments[] rows)
{
    if(width>256)return false;
    const r=cast(int)radius,diameter=2*radius+1;
    double anchor=0;bool found;
    firstValid:foreach(y;-r..cast(int)height+r)foreach(x;-r..cast(int)width+r) {
        const point=read(x,y);
        if(!point.valid)continue;
        if(!isFinite(point.value)||point.value<0||point.value>1||
            (point.value==0&&1/point.value<0))return false;
        anchor=point.value;found=true;break firstValid;
    }
    if(!found){rows[0..width*height]=WindowMoments.init;return true;}
    foreach(y;0..height+2*radius) {
        double sum=0,squared=0;size_t count;
        static if(extrema)ExtremaQueue lows,highs;
        else {size_t equalValid=0;double lastValid=0;}
        foreach(t;0..width+2*radius) {
            if(t>=diameter) {
                const point=read(cast(int)(t-diameter)-r,cast(int)y-r);
                if(point.valid){const v=point.value-anchor;sum-=v;squared-=v*v;--count;}
            }
            const point=read(cast(int)t-r,cast(int)y-r);
            if(point.valid){
                if(!isFinite(point.value)||point.value<0||point.value>1||
                    (point.value==0&&1/point.value<0))return false;
                const v=point.value-anchor;sum+=v;squared+=v*v;++count;
                static if(!extrema) {
                    if(equalValid&&point.value==lastValid)++equalValid;
                    else {equalValid=1;lastValid=point.value;}
                }
            }
            static if(extrema) {
                lows.expire(t,diameter);highs.expire(t,diameter);
                if(point.valid){lows.push(t,point.value,false);highs.push(t,point.value,true);}
            }
            if(t+1>=diameter) {
                WindowMoments cell;cell.mean=sum;cell.m2=squared;cell.count=count;
                static if(extrema)if(count){cell.low=lows.front;cell.high=highs.front;}
                static if(!extrema)if(count&&equalValid>=count){cell.low=lastValid;cell.high=lastValid;}
                rows[y*width+t+1-diameter]=cell;
            }
        }
    }
    // Extrema are optional work, but never choose a different statistics
    // algorithm for a mixed request: single and shared/cached results agree.
    static if(extrema)foreach(x;0..width) {
        ExtremaQueue lows,highs;
        foreach(t;0..height+2*radius) {
            const cell=rows[t*width+x];lows.expire(t,diameter);highs.expire(t,diameter);
            if(cell.count){lows.push(t,cell.low,false);highs.push(t,cell.high,true);}
            if(t+1>=diameter) {
                auto destination=&rows[(t+1-diameter)*width+x];
                destination.low=lows.first<lows.last?lows.front:double.infinity;
                destination.high=highs.first<highs.last?highs.front:-double.infinity;
            }
        }
    }
    // Column pass runs across complete contiguous rows. These bounded stack
    // carriers (18 KiB plus 4 KiB constant certificates without extrema on
    // x86-64) have no heap/GC allocation.
    double[256] sums=0,squares=0;size_t[256] counts=0;
    WindowMoments[256] leaving;
    static if(!extrema){double[256] constantValues=0;size_t[256] constantCounts=0;}
    foreach(t;0..height+2*radius) {
        const incoming=rows[t*width..(t+1)*width];
        foreach(x;0..width) {
            if(t>=diameter){sums[x]-=leaving[x].mean;squares[x]-=leaving[x].m2;counts[x]-=leaving[x].count;}
            sums[x]+=incoming[x].mean;squares[x]+=incoming[x].m2;counts[x]+=incoming[x].count;
            static if(!extrema)if(incoming[x].count) {
                if(incoming[x].low==incoming[x].high) {
                    if(constantCounts[x]&&constantValues[x]==incoming[x].low)constantCounts[x]+=incoming[x].count;
                    else {constantCounts[x]=incoming[x].count;constantValues[x]=incoming[x].low;}
                } else constantCounts[x]=0;
            }
        }
        if(t+1<diameter)continue;
        const y=t+1-diameter;auto destination=rows[y*width..(y+1)*width];
        leaving[0..width]=destination[];
        foreach(x,ref cell;destination) {
            const low=cell.low,high=cell.high;
            cell=WindowMoments.init;cell.count=counts[x];
            if(!cell.count)continue;
            const mean=sums[x]/cell.count,correction=sums[x]*mean;
            cell.mean=anchor+mean;cell.m2=squares[x]-correction;
            const bound=32*double.epsilon*(abs(squares[x])+abs(correction))*(width+2*radius+t+1);
            cell.roundoff=bound;
            // Exact certificates count equal valid samples, including across
            // mask gaps. A plateau different from the tile anchor must not
            // pay O(r²) rebasing at every pixel. Uncertain nonconstant windows
            // still use the complete centered rebase.
            static if(extrema)const constant=low==high;
            else const constant=constantCounts[x]>=cell.count;
            if(constant) {
                static if(extrema)cell.mean=low;else cell.mean=constantValues[x];
                cell.m2=0;
            }
            else if(squares[x]==0 && sums[x]==0){cell.mean=anchor;cell.m2=0;}
            else if(cell.m2<=16*bound)cell=rebaseWindow(read,cast(int)x,cast(int)y,r);
            static if(extrema){cell.low=low;cell.high=high;}
        }
    }
    return true;
}

@safe unittest
{
    import imagery.analysis.feature_regions : Point;
    class Plateau {
        size_t calls;bool masked;
        Point opCall(int x,int y) scope @safe nothrow @nogc {
            ++calls;x=max(0,min(127,x));y=max(0,min(63,y));
            return Point(x<64?0:1,!masked||(x*3+y)%17!=0);
        }
    }
    enum width=128,height=64,radius=31;
    foreach(masked;[false,true]) {
        auto source=new Plateau;source.masked=masked;
        auto rows=new WindowMoments[width*(height+2*radius)];
        assert(evaluateWindows(source,width,height,radius,rows,false));
        foreach(y;0..height)foreach(x;[0,width-1]) {
            const cell=rows[y*width+x];assert(cell.count>0);
            assert(cell.mean==(x==0?0:1)&&cell.m2==0);
        }
        assert(source.calls<=4*(width+2*radius)*(height+2*radius),
            "Constant plateaus must not trigger per-window quadratic rebasing");
    }
}
