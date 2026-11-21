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
    uint radius,scope WindowMoments[] rows)
{
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
