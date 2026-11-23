/++ Internal prepared row kernels. Missing/wide-range samples retain the
scalar oracle; clean unit-domain tiles use bounded contiguous arithmetic.
All storage is private scratch, never a retained output owner.
+/
module imagery.analysis.row_kernels;

import imagery.analysis.feature_regions : Feature,Point,Value;
import imagery.analysis.feature_structure : StructuralOptions,kernels;
import std.math : isFinite,sqrt,atan2,PI;
import std.math : signbit;
import raster : RasterPlaneWindow,Region2D;
import std.algorithm : min,max;

@safe:

package bool basicRowFeature(Feature f) nothrow @nogc
{return f==Feature.gaussian||f==Feature.box||f==Feature.gradient||f==Feature.edgeEvidence||f==Feature.median;}
package bool structuralRowFeature(Feature f) nothrow @nogc
{return f==Feature.ridge||f==Feature.lineResponse||f==Feature.gabor||
    (f>=Feature.gaborFine0&&f<=Feature.gaborCoarse135);}

// The zero-one principle proves this min/max selection circuit on all finite
// ordered values. Tests exhaust all 512 binary neighborhoods independently.
pragma(inline,true)
private T median9(T)(T[9] v) nothrow @nogc
{
    enum pairs=[[1,2],[4,5],[7,8],[0,1],[3,4],[6,7],[1,2],[4,5],[7,8],
        [0,3],[5,8],[4,7],[3,6],[1,4],[2,5],[4,7],[4,2],[6,4],[4,2]];
    static foreach(pair;pairs) {{
        const a=v[pair[0]],b=v[pair[1]],lo=a<b?a:b;
        v[pair[1]]=a>b?a:b;v[pair[0]]=lo;
    }}
    return v[4];
}

package struct RowKernelScratch
{
    double[] pixels,horizontal;
    float[] narrowPixels,gaussianRows;
    bool gaussian32;
    size_t capacityWidth,capacityHeight,capacityHalo;

    void reserve(size_t width,size_t height,size_t halo,size_t accumulatorPlanes=0,bool narrowMedian=false,bool gaussian32=false)
    {
        if(!width||!height||width>256||height>256||halo>128)
            throw new Exception("Invalid row kernel capacity");
        if(gaussian32&&(!narrowMedian||halo!=1))throw new Exception("Float32 Gaussian needs one normalized halo");
        const wide=width+2*halo,tall=height+2*halo;
        if(narrowMedian){narrowPixels=new float[wide*tall];pixels=null;}
        else {pixels=new double[wide*tall];narrowPixels=null;}
        horizontal=new double[width*accumulatorPlanes];
        this.gaussian32=gaussian32;gaussianRows=gaussian32?new float[width*(height+2)]:null;
        capacityWidth=width;capacityHeight=height;capacityHalo=halo;
    }
    size_t bytes() const nothrow @nogc {return (pixels.length+horizontal.length)*double.sizeof+(narrowPixels.length+gaussianRows.length)*float.sizeof;}
    static size_t requiredBytes(size_t width,size_t height,size_t halo,size_t accumulatorPlanes=0) nothrow @nogc
    {return ((width+2*halo)*(height+2*halo)+width*accumulatorPlanes)*double.sizeof;}

    // Validate all support before touching output. Wide-range arithmetic keeps
    // its original stable scalar reduction; negative zero keeps its tie bits.
    bool load(Read)(scope Read read,size_t width,size_t height,size_t halo) nothrow @nogc
    {
        const wide=width+2*halo,tall=height+2*halo;
        if(width>capacityWidth||height>capacityHeight||halo>capacityHalo)return false;
        bool clean=true;
        foreach(y;0..tall)foreach(x;0..wide) {
            const point=read(cast(int)x-cast(int)halo,cast(int)y-cast(int)halo);
            const v=point.value;
            clean&=point.valid&&isFinite(v)&&v>=0&&v<=1&&!(v==0&&1/v<0);
            if(narrowPixels.length)narrowPixels[y*wide+x]=cast(float)v;else pixels[y*wide+x]=v;
        }
        return clean;
    }

    // The provider window is borrowed, not retained. Pack each contiguous row
    // once, with clamping outside the lane loop. The integer bad-lane reduction
    // avoids building a validity plane for a fully valid unit-domain support.
    bool loadPlane(T)(scope ref const RasterPlaneWindow!T plane,Region2D tile,
        Region2D window,size_t sourceWidth,size_t sourceHeight,size_t halo) nothrow @nogc
    {
        if(tile.width>capacityWidth||tile.height>capacityHeight||halo>capacityHalo)return false;
        const wide=tile.width+2*halo,tall=tile.height+2*halo;
        const start=tile.x>halo?tile.x-halo:0;
        const end=tile.x+tile.width+min(halo,sourceWidth-tile.x-tile.width);
        const left=halo-min(tile.x,halo),count=end-start;
        uint dirty;
        foreach(y;0..tall) {
            const sy=y<halo?tile.y-min(tile.y,halo-y):tile.y+min(sourceHeight-1-tile.y,y-halo);
            const row=plane.row(sy-window.y);
            const sampleStart=start-window.x;
            auto target=pixels[y*wide..(y+1)*wide];
            foreach(x;0..count) {
                const value=cast(double)row.load(sampleStart+x);target[left+x]=value;
                dirty|=cast(uint)(!(value>=0&&value<=1))|cast(uint)(value==0&&signbit(value));
            }
            target[0..left]=target[left];target[left+count..$]=target[left+count-1];
        }
        return dirty==0;
    }

    bool basic(Read,Output)(Feature feature,size_t width,size_t height,scope Read read,
        ref Output output) nothrow @nogc
    {
        if(!basicRowFeature(feature)||!load(read,width,height,1))return false;
        return basicLoaded(feature,width,height,output);
    }
    // The prepared raster worker fills/validates this private plane during its
    // single source/mask pass; do not gather the same borrowed pixels twice.
    bool basicLoaded(Output)(Feature feature,size_t width,size_t height,ref Output output) nothrow @nogc
    {
        if(feature==Feature.gaussian)return gaussian32?gaussianUnit32(width,height,output):gaussian!false(width,height,output);
        if(feature==Feature.box)return gaussian!true(width,height,output);
        if(feature==Feature.median)return median(width,height,output);
        return gradient(width,height,feature==Feature.edgeEvidence,output);
    }

    bool structural(Read,Output)(Feature feature,size_t width,size_t height,scope Read read,
        scope const StructuralOptions options,ref Output output) nothrow @nogc
    {
        if(!structuralRowFeature(feature)||horizontal.length<4*width)return false;
        const bank=feature==Feature.gabor||(feature>=Feature.gaborFine0&&feature<=Feature.gaborCoarse135);
        size_t halo;
        const first=feature==Feature.gabor?0:bank?feature-Feature.gaborFine0:0;
        const end=feature==Feature.gabor?8:first+1;
        if(bank)halo=options.gabor.length?options.gabor[end-1].radius:kernels[end-1].radius;
        else halo=feature==Feature.ridge?options.ridge.lastRadius:options.line.across.lastRadius+options.line.alongRadius;
        if(!load(read,width,height,halo))return false;
        return structuralLoaded(feature,width,height,halo,options,output);
    }

    bool structuralLoaded(Output)(Feature feature,size_t width,size_t height,size_t halo,
        scope const StructuralOptions options,ref Output output) nothrow @nogc
    {
        const bank=feature==Feature.gabor||(feature>=Feature.gaborFine0&&feature<=Feature.gaborCoarse135);
        const first=feature==Feature.gabor?0:bank?feature-Feature.gaborFine0:0;
        const end=feature==Feature.gabor?8:first+1;
        output.initialize(width*height,true);
        const stride=width+2*halo;
        foreach(y;0..height) {
            auto target=output.row(y*width,width);
            auto realPart=horizontal[0..width],imaginary=horizontal[width..2*width],best=horizontal[2*width..3*width];
            best[]=0;
            if(bank) {
                const center=pixels[(y+halo)*stride+halo..(y+halo)*stride+halo+width];
                void accumulate(Kernel)(scope const ref Kernel kernel) nothrow @nogc {
                    realPart[]=0;imaginary[]=0;
                    const side=2*cast(size_t)kernel.radius+1;
                    foreach(ky;0..side) {
                        const left=(y+halo-kernel.radius+ky)*stride+halo-kernel.radius;
                        const row=pixels[left..left+width+side-1];
                        foreach(kx;0..side) {
                            const wr=kernel.realWeights[ky*side+kx],wi=kernel.imaginaryWeights[ky*side+kx];
                            const samples=row[kx..kx+width];
                            // Equal-length array expressions perform one bounds
                            // validation per tap, preserving each lane's order.
                            realPart[]+=(samples[]-center[])*wr;
                            imaginary[]+=(samples[]-center[])*wi;
                        }
                    }
                    foreach(x;0..width) {
                        const response=sqrt(realPart[x]*realPart[x]+imaginary[x]*imaginary[x]);
                        if(response>best[x]||end==first+1) {
                            best[x]=response;
                            target.setFiniteValue(x,Value([response,kernel.angle,kernel.scale],true,response>0));
                        }
                    }
                }
                if(options.gabor.length)foreach(ref kernel;options.gabor[first..end])accumulate(kernel);
                else foreach(ref kernel;kernels[first..end])accumulate(kernel);
            } else {
                immutable int[2][4] directions=[[1,0],[1,1],[0,1],[-1,1]];
                const across=feature==Feature.ridge?options.ridge:options.line.across;
                const extent=feature==Feature.ridge?0:cast(int)options.line.alongRadius;
                foreach(distance;cast(int)across.firstRadius..cast(int)across.lastRadius+1)
                    foreach(i,direction;directions) {
                        const dx=direction[0],dy=direction[1],nx=-dy*distance,ny=dx*distance;
                        realPart[]=double.infinity;
                        foreach(along;-extent..extent+1) {
                            const cx=cast(long)halo+dx*along,cy=cast(long)y+halo+dy*along;
                            const index=cast(size_t)(cy*stride+cx);
                            const minus=cast(size_t)((cy-ny)*stride+cx-nx),plus=cast(size_t)((cy+ny)*stride+cx+nx);
                            const c=pixels[index..index+width],a=pixels[plus..plus+width],b=pixels[minus..minus+width];
                            foreach(x;0..width)realPart[x]=min(realPart[x],c[x]-(.5*a[x]+.5*b[x]));
                        }
                        foreach(x;0..width)if(realPart[x]>best[x]) {
                            best[x]=realPart[x];target.setFiniteValue(x,Value([realPart[x],i*PI/4,distance],true,true));
                        }
                    }
            }
        }
        return true;
    }

    private bool gaussianUnit32(Output)(size_t width,size_t height,ref Output output) nothrow @nogc
    {
        const stride=width+2;
        foreach(y;0..height+2) {
            const row=narrowPixels[y*stride..(y+1)*stride];
            const a=row[0..width],b=row[1..width+1],c=row[2..width+2];
            auto target=gaussianRows[y*width..(y+1)*width];
            target[]=(a[]+c[])*.25f+b[]*.5f;
        }
        output.initialize(width*height,true);
        foreach(y;0..height) {
            const a=gaussianRows[y*width..(y+1)*width],b=gaussianRows[(y+1)*width..(y+2)*width],
                c=gaussianRows[(y+2)*width..(y+3)*width];
            auto target=output.row(y*width,width);
            foreach(x;0..width)target.setScalar(x,(a[x]+c[x])*.25f+b[x]*.5f);
        }
        return true;
    }

    private bool gaussian(bool box,Output)(size_t width,size_t height,ref Output output) nothrow @nogc
    {
        output.initialize(width*height,true);
        const stride=width+2;
        foreach(y;0..height) {
            auto target=output.row(y*width,width);
            const a=pixels[y*stride..(y+1)*stride],b=pixels[(y+1)*stride..(y+2)*stride],c=pixels[(y+2)*stride..(y+3)*stride];
            // Shift once per row. Every inner-loop slice has exactly width
            // samples, so safe indexing needs no x+offset overflow/bounds path.
            const a0=a[0..width],a1=a[1..width+1],a2=a[2..width+2];
            const b0=b[0..width],b1=b[1..width+1],b2=b[2..width+2];
            const c0=c[0..width],c1=c[1..width+1],c2=c[2..width+2];
            foreach(x;0..width) {
                // Unroll the original weighted online reduction, including its
                // rounding order. This also preserves float32 publication ties.
                double v=a0[x];
                static if(box) {
                    v+=.5*(a1[x]-v);v+=(1.0/3)*(a2[x]-v);
                    v+=.25*(b0[x]-v);v+=.2*(b1[x]-v);v+=(1.0/6)*(b2[x]-v);
                    v+=(1.0/7)*(c0[x]-v);v+=.125*(c1[x]-v);v+=(1.0/9)*(c2[x]-v);
                } else {
                    v+=(2.0/3)*(a1[x]-v);v+=.25*(a2[x]-v);
                    v+=(2.0/6)*(b0[x]-v);v+=.4*(b1[x]-v);v+=(2.0/12)*(b2[x]-v);
                    v+=(1.0/13)*(c0[x]-v);v+=(2.0/15)*(c1[x]-v);v+=(1.0/16)*(c2[x]-v);
                }
                target.setScalar(x,v);
            }
        }
        return true;
    }

    private bool median(Output)(size_t width,size_t height,ref Output output) nothrow @nogc
    {
        // Monotone float32 conversion commutes with an odd finite median:
        // float(median(double samples)) == median(float(samples)). This is an
        // exact final-output optimization, not a reduced-accuracy accumulation.
        if(narrowPixels.length)return medianRows(width,height,narrowPixels,output);
        return medianRows(width,height,pixels,output);
    }

    private bool medianRows(T,Output)(size_t width,size_t height,scope const(T)[] source,
        ref Output output) nothrow @nogc
    {
        output.initialize(width*height,true);
        const stride=width+2;
        foreach(y;0..height) {
            auto target=output.row(y*width,width);
            const a=source[y*stride..(y+1)*stride],b=source[(y+1)*stride..(y+2)*stride],c=source[(y+2)*stride..(y+3)*stride];
            // Shift once per row. Every inner-loop slice has exactly width
            // samples, so safe indexing needs no x+offset overflow/bounds path.
            const a0=a[0..width],a1=a[1..width+1],a2=a[2..width+2];
            const b0=b[0..width],b1=b[1..width+1],b2=b[2..width+2];
            const c0=c[0..width],c1=c[1..width+1],c2=c[2..width+2];
            foreach(x;0..width) {
                T[9] neighborhood=[a0[x],a1[x],a2[x],b0[x],b1[x],b2[x],c0[x],c1[x],c2[x]];
                const v=median9(neighborhood);
                target.setScalar(x,v);
            }
        }
        return true;
    }

    private bool gradient(Output)(size_t width,size_t height,bool evidence,ref Output output) nothrow @nogc
    {
        const stride=width+2;
        foreach(y;0..height) {
            auto target=output.row(y*width,width);
            const a=pixels[y*stride..(y+1)*stride],b=pixels[(y+1)*stride..(y+2)*stride],c=pixels[(y+2)*stride..(y+3)*stride];
            foreach(x;0..width) {
                const center=b[x+1];
                // Preserve the scalar oracle's centered term/reduction order.
                double gx=0,gy=0;
                gx-=(a[x]-center)*.125;gx+=(a[x+2]-center)*.125;
                gx-=(b[x]-center)*.25;gx+=(b[x+2]-center)*.25;
                gx-=(c[x]-center)*.125;gx+=(c[x+2]-center)*.125;
                gy-=(a[x]-center)*.125;gy-=(a[x+1]-center)*.25;gy-=(a[x+2]-center)*.125;
                gy+=(c[x]-center)*.125;gy+=(c[x+1]-center)*.25;gy+=(c[x+2]-center)*.125;
                const scale=max(gx<0?-gx:gx,gy<0?-gy:gy);
                Value v;v.valid=true;
                if(scale>0) {
                    const magnitude=scale*sqrt((gx/scale)^^2+(gy/scale)^^2);
                    if(evidence)v.channels[0]=min(1.0,magnitude/.125);
                    else {v.channels[0]=magnitude;v.channels[1]=atan2(gy,gx);v.orientationValid=true;}
                }
                target.setFiniteValue(x,v);
            }
        }
        return true;
    }
}

@safe unittest
{
    import std.algorithm : sort;
    foreach(bits;0..512) {
        double[9] values;size_t ones;
        foreach(i,ref v;values){v=(bits>>i)&1;ones+=cast(size_t)v;}
        assert(median9(values)==(ones>=5));
    }
    // Final rounding is monotone even when many distinct double samples
    // collapse onto one float32 value, or tiny positives underflow to zero.
    uint state=0x17a46b39;
    foreach(fixture;0..4096) {
        double[9] samples;float[9] projected;
        foreach(i,ref value;samples) {
            state=1664525*state+1013904223;
            value=fixture%3==0?cast(double)state/uint.max:
                fixture%3==1?.5+(cast(int)(state%9)-4)*0x1p-25+(cast(int)(i%3)-1)*double.epsilon:
                cast(double)(state%99)*0x1p-150;
            projected[i]=cast(float)value;
        }
        samples[].sort;
        assert(median9(projected)==cast(float)samples[4]);
    }
}

// The retained per-pixel evaluator is independent of this row dispatch. Check
// complete double winner/angle/scale values, not just a shared strength oracle.
@safe unittest
{
    import imagery.analysis.feature_regions : ValueTileOutput,Sample,evaluate;
    import imagery.analysis.feature_parameters : LocalStatisticsParams,PathMorphologyParams,RidgeParams,LineResponseParams,GaborParams;
    import imagery.analysis.feature_structure : prepareGabor;
    import std.math : signbit;
    struct Reader {
        const(double)[] pixels;size_t stride;int x,y;
        Point opCall(int dx,int dy) const @safe nothrow @nogc {
            return Point(pixels[(y+dy)*stride+x+dx],true);
        }
    }
    enum width=9,height=7;
    foreach(custom;[false,true]) {
        StructuralOptions options;
        if(custom) {
            options.ridge=RidgeParams(2,31);options.line=LineResponseParams(RidgeParams(2,5),3);
            GaborParams p;p.wavelengths=[1.5,5.25];p.angles=[.1,.7,1.4,2.2];p.sigmaRatio=.7;p.supportRatio=1.5;
            options.gabor=prepareGabor(p);
        }
        foreach(feature;[Feature.gaussian,Feature.box,Feature.median,Feature.gradient,Feature.edgeEvidence,
            Feature.ridge,Feature.lineResponse,Feature.gabor,Feature.gaborFine0,Feature.gaborFine45,
            Feature.gaborFine90,Feature.gaborFine135,Feature.gaborCoarse0,Feature.gaborCoarse45,
            Feature.gaborCoarse90,Feature.gaborCoarse135]) {
            const bank=feature==Feature.gabor||(feature>=Feature.gaborFine0&&feature<=Feature.gaborCoarse135);
            const last=feature==Feature.gabor?7:bank?feature-Feature.gaborFine0:0;
            const halo=basicRowFeature(feature)?1:feature==Feature.ridge?options.ridge.lastRadius:
                feature==Feature.lineResponse?options.line.across.lastRadius+options.line.alongRadius:
                custom?options.gabor[last].radius:kernels[last].radius;
            const stride=width+2*halo,tall=height+2*halo;
            auto pixels=new double[stride*tall];auto result=new Value[width*height];
            RowKernelScratch rows;rows.reserve(width,height,halo,4);
            foreach(fixture;0..9) {
                foreach(i,ref v;pixels) {
                    const x=i%stride,y=i/stride;
                    v=fixture==0?0:fixture==1?1:fixture==2?cast(double)x/stride:
                        fixture==3?cast(double)y/tall:fixture==4?((x+y)%2?1:0):
                        fixture==5?cast(double)(i%17)*1e-300:
                        fixture==6?.5+(cast(int)(i%3)-1)*double.epsilon:
                        fixture==7?(x==halo+width/2&&y==halo+height/2?1:0):-0.0;
                }
                Reader reader;reader.pixels=pixels;reader.stride=stride;
                reader.x=reader.y=cast(int)halo;
                auto output=ValueTileOutput(result);
                const used=basicRowFeature(feature)?rows.basic(feature,width,height,reader,output):
                    rows.structural(feature,width,height,reader,options,output);
                assert(used==(fixture!=8),"Negative-zero support must retain scalar tie bits");
                if(!used)continue;
                foreach(y;0..height)foreach(x;0..width) {
                    reader.x=cast(int)(halo+x);reader.y=cast(int)(halo+y);
                    const center=reader(0,0);
                    const expected=evaluate(feature,false,Sample(center.value,[0,0,0],true),reader,
                        LocalStatisticsParams.init,PathMorphologyParams.init,options);
                    const actual=result[y*width+x];
                    assert(actual.valid==expected.valid&&actual.orientationValid==expected.orientationValid);
                    foreach(c;0..3)assert(actual.channels[c]==expected.channels[c]&&
                        (actual.channels[c]!=0||signbit(actual.channels[c])==signbit(expected.channels[c])),
                        "Row arithmetic/winner/tie differs from retained scalar evaluator");
                }
            }
        }
    }
}
