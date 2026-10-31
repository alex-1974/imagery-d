/**
 * Common image-processing operations.
 *
 * Use these functions to soften images, find edges, create masks and compare
 * bands. Provide the width and height and a destination with the same number
 * of samples.
 *
 * Example:
 * ---
 * float[] input = [0, 0.2, 0.8, 1];
 * float[] softened = new float[](input.length);
 * gaussianBlur(input, 2, 2, 1.0f, softened);
 * ---
 */
module imagery.analysis.primitives;

import std.math : exp, sqrt, abs, log, atan2;
import raster.parallel_rows : parallelRows, ParallelRowsResult;

private size_t at(size_t w, size_t x, size_t y) @safe pure nothrow @nogc { return y * w + x; }
private bool valid(size_t w, size_t h, scope const(float)[] p) @safe pure nothrow @nogc { return w != 0 && h != 0 && p.length == w * h; }
private float px(scope const(float)[] p, size_t w, size_t h, long x, long y) @safe pure nothrow @nogc {
    if (x < 0) x = 0; else if (x >= cast(long)w) x = cast(long)w - 1;
    if (y < 0) y = 0; else if (y >= cast(long)h) y = cast(long)h - 1;
    return p[at(w, cast(size_t)x, cast(size_t)y)];
}

@safe unittest {
    float[] p = [0, 0, 0, 0, 1, 0, 0, 0, 0]; float[] blurred = new float[](9);
    gaussianBlur(p, 3, 3, 1, blurred); assert(blurred.length == 9);
    float[] gx = new float[](9), gy = new float[](9); sobel(p, 3, 3, gx, gy);
    assert(gx.length == 9 && gy.length == 9);
    ubyte[] mask = [1,1,0,1,1,0,0,0,1], opened = new ubyte[](9); open(mask,3,3,1,opened);
    uint[] labels = new uint[](9); assert(connectedComponents(mask,3,3,labels) == 2);
    ubyte[] filled = new ubyte[](9); floodFill(p,3,3,1,1,0.1f,filled); assert(filled[4] == 1);
    auto cgx = new float[](9), cgy = new float[](9), mag = new float[](9); cannyGradient(p,3,3,cgx,cgy,mag);
    ubyte[] fifo = new ubyte[](9), frontier = new ubyte[](9);
    cannyFromGradient(cgx,cgy,mag,3,3,0.1f,0.2f,fifo); cannyFromGradientFrontier(cgx,cgy,mag,3,3,0.1f,0.2f,frontier);
    assert(fifo == frontier);
}

/// Separable Gaussian blur with edge replication.
/// Softens an image. Larger `sigma` values create a stronger blur.
void gaussianBlur(scope const(float)[] src, size_t width, size_t height, float sigma, ref float[] dst) @safe {
    if (!valid(width,height,src) || !(sigma > 0) || !dst.length) return;
    auto r = cast(size_t)(sigma * 3.0f + 0.5f); auto k = new float[](r * 2 + 1); float sum;
    foreach (i; 0 .. k.length) { auto d = cast(float)(cast(long)i - cast(long)r); k[i] = exp(-(d*d)/(2*sigma*sigma)); sum += k[i]; }
    foreach (ref v; k) v /= sum; auto tmp = new float[](src.length);
    foreach (y; 0 .. height) foreach (x; 0 .. width) { float v; foreach (i; 0 .. k.length) { auto xx=cast(long)x+cast(long)i-cast(long)r; if(xx<0)xx=0;else if(xx>=cast(long)width)xx=cast(long)width-1; v += src[y*width+cast(size_t)xx]*k[i]; } tmp[y*width+x] = v; }
    foreach (y; 0 .. height) foreach (x; 0 .. width) { float v; foreach (i; 0 .. k.length) { auto yy=cast(long)y+cast(long)i-cast(long)r; if(yy<0)yy=0;else if(yy>=cast(long)height)yy=cast(long)height-1; v += tmp[cast(size_t)yy*width+x]*k[i]; } dst[y*width+x] = v; }
}

/// Bounded parallel Gaussian blur using separate horizontal and vertical passes.
ParallelRowsResult gaussianBlurParallel(scope const(float)[] src,size_t w,size_t h,float sigma,ref float[] dst,size_t workers=0,size_t chunk=1) @trusted {
    if(!valid(w,h,src)||dst.length<src.length||sigma<=0)return ParallelRowsResult.callbackFailed;auto r=cast(size_t)(sigma*3.0f+0.5f);auto k=new float[](r*2+1);float sum;foreach(i;0..k.length){auto d=cast(float)(cast(long)i-cast(long)r);k[i]=exp(-(d*d)/(2*sigma*sigma));sum+=k[i];}foreach(ref v;k)v/=sum;auto tmp=new float[](src.length);auto a=parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w){float v;foreach(i;0..k.length){auto xx=cast(long)x+cast(long)i-cast(long)r;if(xx<0)xx=0;else if(xx>=cast(long)w)xx=cast(long)w-1;v+=src[y*w+cast(size_t)xx]*k[i];}tmp[y*w+x]=v;}return true;});if(a!=ParallelRowsResult.completed)return a;return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w){float v;foreach(i;0..k.length){auto yy=cast(long)y+cast(long)i-cast(long)r;if(yy<0)yy=0;else if(yy>=cast(long)h)yy=cast(long)h-1;v+=tmp[cast(size_t)yy*w+x]*k[i];}dst[y*w+x]=v;}return true;});
}

/// 3x3 median filter.
/// Removes isolated bright or dark pixels while preserving broad edges.
void medianFilter(scope const(float)[] src, size_t width, size_t height, ref float[] dst) @safe {
    if (!valid(width,height,src) || dst.length < src.length) return; auto a = new float[9];
    foreach (y; 0 .. height) foreach (x; 0 .. width) { size_t n; foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) a[n++] = px(src,width,height,cast(long)x+dx,cast(long)y+dy); import std.algorithm : sort; a.sort(); dst[at(width,x,y)] = a[4]; }
}
alias medianBlur = medianFilter;

/// Edge-preserving bilateral filter for scalar planes.
void bilateralFilter(scope const(float)[] src, size_t width, size_t height,
    float spatialSigma, float rangeSigma, ref float[] dst) @safe {
    if (!valid(width, height, src) || dst.length < src.length || spatialSigma <= 0 || rangeSigma <= 0) return;
    auto radius = cast(size_t)(spatialSigma * 2.5f + 0.5f);
    foreach (y; 0 .. height) foreach (x; 0 .. width) {
        auto center = src[at(width, x, y)]; float sum, weightSum;
        foreach (dy; -(cast(long)radius) .. cast(long)(radius + 1)) foreach (dx; -(cast(long)radius) .. cast(long)(radius + 1)) {
            auto v = px(src, width, height, cast(long)x + dx, cast(long)y + dy);
            auto spatial = exp(-cast(float)(dx*dx + dy*dy) / (2*spatialSigma*spatialSigma));
            auto range = exp(-(v-center)*(v-center) / (2*rangeSigma*rangeSigma));
            auto w = spatial * range; sum += v*w; weightSum += w;
        }
        dst[at(width,x,y)] = weightSum > 0 ? sum / weightSum : center;
    }
}

/// One-pass guided filter using a local mean/variance estimate.
void guidedFilter(scope const(float)[] src, scope const(float)[] guide,
    size_t width, size_t height, size_t radius, float epsilon, ref float[] dst) @safe {
    if (!valid(width,height,src) || !valid(width,height,guide) || dst.length < src.length || epsilon <= 0) return;
    foreach (y; 0 .. height) foreach (x; 0 .. width) {
        float sumI,sumP,sumII,sumIP; size_t n;
        foreach(dy; -(cast(long)radius) .. cast(long)(radius+1)) foreach(dx; -(cast(long)radius) .. cast(long)(radius+1)) {
            auto i=px(guide,width,height,cast(long)x+dx,cast(long)y+dy); auto p=px(src,width,height,cast(long)x+dx,cast(long)y+dy);
            sumI+=i;sumP+=p;sumII+=i*i;sumIP+=i*p;++n;
        }
        auto ni=cast(float)n; auto meanI=sumI/ni; auto meanP=sumP/ni;
        auto varI=sumII/ni-meanI*meanI; auto cov=sumIP/ni-meanI*meanP; auto a=cov/(varI+epsilon); auto b=meanP-a*meanI;
        dst[at(width,x,y)]=a*guide[at(width,x,y)]+b;
    }
}

/// Sobel horizontal/vertical gradients.
/// Returns horizontal and vertical brightness changes for an image.
void sobel(scope const(float)[] src, size_t width, size_t height, ref float[] gx, ref float[] gy) @safe {
    if (!valid(width,height,src) || gx.length < src.length || gy.length < src.length) return;
    immutable int[3][3] kx = [[-1,0,1],[-2,0,2],[-1,0,1]]; immutable int[3][3] ky = [[-1,-2,-1],[0,0,0],[1,2,1]];
    foreach (y; 0 .. height) foreach (x; 0 .. width) { float ax, ay; foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) { auto v=px(src,width,height,cast(long)x+dx,cast(long)y+dy); ax += v*kx[dy+1][dx+1]; ay += v*ky[dy+1][dx+1]; } gx[at(width,x,y)]=ax; gy[at(width,x,y)]=ay; }
}

/// Sobel gradients for 8-bit preview images. Outputs remain float so callers
/// can feed them directly into the Canny stages.
void sobelUbyte(scope const(ubyte)[] src,size_t w,size_t h,ref float[] gx,ref float[] gy) @safe {
    if(w==0||h==0||src.length!=w*h||gx.length<src.length||gy.length<src.length)return; immutable int[3][3] kx=[[-1,0,1],[-2,0,2],[-1,0,1]]; immutable int[3][3] ky=[[-1,-2,-1],[0,0,0],[1,2,1]];
    foreach(y;0..h)foreach(x;0..w){int ax,ay;if(x>0&&y>0&&x+1<w&&y+1<h){auto p=y*w+x;ax=cast(int)src[p-w-1]*-1+cast(int)src[p-w+1]+cast(int)src[p-1]*-2+cast(int)src[p+1]*2+cast(int)src[p+w-1]*-1+cast(int)src[p+w+1];ay=cast(int)src[p-w-1]*-1+cast(int)src[p-w]*-2+cast(int)src[p-w+1]*-1+cast(int)src[p+w-1]+cast(int)src[p+w]*2+cast(int)src[p+w+1];}else foreach(dy;-1..2)foreach(dx;-1..2){auto v=cast(int)maskPx(src,w,h,cast(long)x+dx,cast(long)y+dy);ax+=v*kx[dy+1][dx+1];ay+=v*ky[dy+1][dx+1];}auto p=y*w+x;gx[p]=cast(float)ax;gy[p]=cast(float)ay;}
}

ParallelRowsResult sobelUbyteParallel(scope const(ubyte)[] src,size_t w,size_t h,ref float[] gx,ref float[] gy,size_t workers=0,size_t chunk=1) @trusted {
    if(w==0||h==0||src.length!=w*h||gx.length<src.length||gy.length<src.length)return ParallelRowsResult.callbackFailed;
    return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w){int ax,ay;auto p=y*w+x;if(x>0&&y>0&&x+1<w&&y+1<h){ax=cast(int)src[p-w-1]*-1+cast(int)src[p-w+1]+cast(int)src[p-1]*-2+cast(int)src[p+1]*2+cast(int)src[p+w-1]*-1+cast(int)src[p+w+1];ay=cast(int)src[p-w-1]*-1+cast(int)src[p-w]*-2+cast(int)src[p-w+1]*-1+cast(int)src[p+w-1]+cast(int)src[p+w]*2+cast(int)src[p+w+1];}else foreach(dy;-1..2)foreach(dx;-1..2){auto v=cast(int)maskPx(src,w,h,cast(long)x+dx,cast(long)y+dy);ax+=v*[[-1,0,1],[-2,0,2],[-1,0,1]][dy+1][dx+1];ay+=v*[[-1,-2,-1],[0,0,0],[1,2,1]][dy+1][dx+1];}gx[p]=cast(float)ax;gy[p]=cast(float)ay;}return true;});
}

/// Bounded parallel Sobel gradients.
ParallelRowsResult sobelParallel(scope const(float)[] src,size_t w,size_t h,ref float[] gx,ref float[] gy,size_t workers=0,size_t chunk=1) @trusted {
    if(!valid(w,h,src)||gx.length<src.length||gy.length<src.length)return ParallelRowsResult.callbackFailed;immutable int[3][3] kx=[[-1,0,1],[-2,0,2],[-1,0,1]];immutable int[3][3] ky=[[-1,-2,-1],[0,0,0],[1,2,1]];return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w){float ax,ay;foreach(dy;-1..2)foreach(dx;-1..2){auto v=px(src,w,h,cast(long)x+dx,cast(long)y+dy);ax+=v*kx[dy+1][dx+1];ay+=v*ky[dy+1][dx+1];}auto p=y*w+x;gx[p]=ax;gy[p]=ay;}return true;});
}

/// Laplacian response and Difference-of-Gaussians.
void laplace(scope const(float)[] src, size_t width, size_t height, ref float[] dst) @safe { if (!valid(width,height,src)||dst.length<src.length)return; foreach(y;0..height)foreach(x;0..width) dst[at(width,x,y)]=px(src,width,height,x,y-1)+px(src,width,height,x-1,y)+px(src,width,height,x+1,y)+px(src,width,height,x,y+1)-4*px(src,width,height,x,y); }
alias laplacian = laplace;
void differenceOfGaussians(scope const(float)[] src,size_t width,size_t height,float sigma1,float sigma2,ref float[] dst) @safe { auto a=new float[](src.length);auto b=new float[](src.length);gaussianBlur(src,width,height,sigma1,a);gaussianBlur(src,width,height,sigma2,b);if(dst.length<src.length)return;foreach(i;0..src.length)dst[i]=a[i]-b[i]; }

/// Gradient magnitude and direction, the first Canny pipeline stage.
void gradientMagnitude(scope const(float)[] src,size_t w,size_t h,ref float[] magnitude,ref float[] direction) @safe { if(magnitude.length<src.length||direction.length<src.length)return;auto gx=new float[](src.length);auto gy=new float[](src.length);sobel(src,w,h,gx,gy);foreach(i;0..src.length){magnitude[i]=sqrt(gx[i]*gx[i]+gy[i]*gy[i]);direction[i]=atan2(gy[i],gx[i]);} }

/// First, parallelizable Canny phase: computes gradient components and
/// magnitude. The result may be partitioned by row/tile with a one-pixel halo.
void cannyGradient(scope const(float)[] src, size_t w, size_t h,
    ref float[] gx, ref float[] gy, ref float[] magnitude) @safe {
    if (!valid(w,h,src) || gx.length < src.length || gy.length < src.length || magnitude.length < src.length) return;
    sobel(src,w,h,gx,gy); foreach(i;0..src.length) magnitude[i]=sqrt(gx[i]*gx[i]+gy[i]*gy[i]);
}

/// Bounded parallel variant of cannyGradient. Workers write disjoint rows.
ParallelRowsResult cannyGradientParallel(scope const(float)[] src, size_t w, size_t h,
    ref float[] gx, ref float[] gy, ref float[] magnitude,
    size_t workerLimit = 0, size_t minimumChunk = 1) @trusted {
    if (!valid(w,h,src) || gx.length < src.length || gy.length < src.length || magnitude.length < src.length)
        return ParallelRowsResult.callbackFailed;
    immutable int[3][3] kx = [[-1,0,1],[-2,0,2],[-1,0,1]];
    immutable int[3][3] ky = [[-1,-2,-1],[0,0,0],[1,2,1]];
    return parallelRows(h, workerLimit, minimumChunk, (size_t first, size_t last) @safe nothrow {
        foreach (y; first .. last) foreach (x; 0 .. w) {
            float ax, ay; foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) {
                auto v=px(src,w,h,cast(long)x+dx,cast(long)y+dy); ax += v*kx[dy+1][dx+1]; ay += v*ky[dy+1][dx+1];
            }
            auto p=y*w+x; gx[p]=ax; gy[p]=ay; magnitude[p]=sqrt(ax*ax+ay*ay);
        }
        return true;
    });
}

/// Second, deterministic Canny phase from precomputed gradients/magnitude.
void cannyFromGradient(scope const(float)[] gx, scope const(float)[] gy,
    scope const(float)[] magnitude, size_t w, size_t h, float low, float high,
    ref ubyte[] edges) @safe {
    if (!valid(w,h,magnitude) || gx.length < magnitude.length || gy.length < magnitude.length || edges.length < magnitude.length || low < 0 || high < low) return;
    auto state=new ubyte[](magnitude.length); foreach(y;1..(h>1?h-1:1)) foreach(x;1..(w>1?w-1:1)){auto p=at(w,x,y),ax=abs(gx[p]),ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=magnitude[at(w,x-1,y)];b=magnitude[at(w,x+1,y)];}else if(ay>=ax*2.4142f){a=magnitude[at(w,x,y-1)];b=magnitude[at(w,x,y+1)];}else if(gx[p]*gy[p]>=0){a=magnitude[at(w,x-1,y-1)];b=magnitude[at(w,x+1,y+1)];}else{a=magnitude[at(w,x+1,y-1)];b=magnitude[at(w,x-1,y+1)];}if(magnitude[p]>=a&&magnitude[p]>=b)state[p]=magnitude[p]>=high?2:(magnitude[p]>=low?1:0);} edges[]=0;auto q=new size_t[](magnitude.length);size_t head,tail;foreach(i;0..state.length)if(state[i]==2){edges[i]=1;q[tail++]=i;}while(head<tail){auto p=q[head++],x=p%w,y=p/w;foreach(dy;-1..2)foreach(dx;-1..2){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(edges[n]==0&&state[n]>=1){edges[n]=1;q[tail++]=n;}}}} }

/// Compact Canny-style binary edge mask (gradient threshold + hysteresis).
/// Creates a one-byte edge mask. `low` and `high` control weak and strong edges.
void canny(scope const(float)[] src,size_t w,size_t h,float low,float high,ref ubyte[] edges) @safe { if(!valid(w,h,src)||edges.length<src.length||low<0||high<low)return;auto gx=new float[](src.length);auto gy=new float[](src.length);sobel(src,w,h,gx,gy);auto m=new float[](src.length);foreach(i;0..src.length)m[i]=sqrt(gx[i]*gx[i]+gy[i]*gy[i]);auto thin=new float[](src.length);foreach(y;1..(h>1?h-1:1))foreach(x;1..(w>1?w-1:1)){auto p=at(w,x,y), ax=abs(gx[p]), ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=m[at(w,x-1,y)];b=m[at(w,x+1,y)];}else if(ay>=ax*2.4142f){a=m[at(w,x,y-1)];b=m[at(w,x,y+1)];}else if((gx[p]*gy[p])>=0){a=m[at(w,x-1,y-1)];b=m[at(w,x+1,y+1)];}else{a=m[at(w,x+1,y-1)];b=m[at(w,x-1,y+1)];}if(m[p]>=a&&m[p]>=b)thin[p]=m[p];}edges[]=0;auto q=new size_t[](src.length);size_t head,tail;foreach(i;0..thin.length)if(thin[i]>=high){edges[i]=1;q[tail++]=i;}while(head<tail){auto p=q[head++];auto x=p%w;auto y=p/w;foreach(dy;-1..2)foreach(dx;-1..2){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(edges[n]==0&&thin[n]>=low){edges[n]=1;q[tail++]=n;}}}} }

/// Four-connected flood fill using an absolute scalar tolerance.
/// Fast interactive edge preview: parallel gradients plus NMS, without
/// hysteresis propagation. Use `canny` for a final connected edge map.
ParallelRowsResult cannyPreview(scope const(float)[] src,size_t w,size_t h,float threshold,ref ubyte[] edges,size_t workers=0,size_t chunk=1) @trusted { if(!valid(w,h,src)||edges.length<src.length||threshold<0)return ParallelRowsResult.callbackFailed;auto gx=new float[](src.length),gy=new float[](src.length),m=new float[](src.length);auto s=cannyGradientParallel(src,w,h,gx,gy,m,workers,chunk);if(s!=ParallelRowsResult.completed)return s;edges[]=0;return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w)if(x>0&&y>0&&x+1<w&&y+1<h){auto p=y*w+x,ax=abs(gx[p]),ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=m[p-1];b=m[p+1];}else if(ay>=ax*2.4142f){a=m[p-w];b=m[p+w];}else if(gx[p]*gy[p]>=0){a=m[p-w-1];b=m[p+w+1];}else{a=m[p-w+1];b=m[p+w-1];}if(m[p]>=threshold&&m[p]>=a&&m[p]>=b)edges[p]=1;}return true;}); }

/// 8-bit preview variant that avoids float input conversion.
ParallelRowsResult cannyPreviewUbyte(scope const(ubyte)[] src,size_t w,size_t h,float threshold,ref ubyte[] edges,size_t workers=0,size_t chunk=1) @trusted { if(w==0||h==0||src.length!=w*h||edges.length<src.length||threshold<0)return ParallelRowsResult.callbackFailed;auto gx=new float[](src.length),gy=new float[](src.length);sobelUbyte(src,w,h,gx,gy);auto threshold2=threshold*threshold;edges[]=0;return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w)if(x>0&&y>0&&x+1<w&&y+1<h){auto p=y*w+x,ax=abs(gx[p]),ay=abs(gy[p]),m=gx[p]*gx[p]+gy[p]*gy[p];float a,b;if(ax>=ay*2.4142f){auto q=p-1,r=p+1;a=gx[q]*gx[q]+gy[q]*gy[q];b=gx[r]*gx[r]+gy[r]*gy[r];}else if(ay>=ax*2.4142f){auto q=p-w,r=p+w;a=gx[q]*gx[q]+gy[q]*gy[q];b=gx[r]*gx[r]+gy[r]*gy[r];}else if(gx[p]*gy[p]>=0){auto q=p-w-1,r=p+w+1;a=gx[q]*gx[q]+gy[q]*gy[q];b=gx[r]*gx[r]+gy[r]*gy[r];}else{auto q=p-w+1,r=p+w-1;a=gx[q]*gx[q]+gy[q]*gy[q];b=gx[r]*gx[r]+gy[r]*gy[r];}if(m>=threshold2&&m>=a&&m>=b)edges[p]=1;}return true;}); }

void floodFill(scope const(float)[] src,size_t w,size_t h,size_t seedX,size_t seedY,float tolerance,ref ubyte[] mask) @safe { if(!valid(w,h,src)||mask.length<src.length||seedX>=w||seedY>=h||tolerance<0)return;mask[]=0;auto q=new size_t[](src.length);size_t head,tail;q[tail++]=at(w,seedX,seedY);mask[q[0]]=1;auto seed=src[q[0]];while(head<tail){auto p=q[head++];auto x=p%w;auto y=p/w;foreach(k;0..4){long nx=cast(long)x,ny=cast(long)y;final switch(k){case 0:nx--;break;case 1:nx++;break;case 2:ny--;break;case 3:ny++;break;}if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(mask[n]==0&&abs(src[n]-seed)<=tolerance){mask[n]=1;q[tail++]=n;}}}} }

/// Priority-flood watershed approximation. Labels local minima basins and
/// marks competing fronts as zero (watershed lines).
void watershed(scope const(float)[] src, size_t w, size_t h, ref uint[] labels) @safe {
    if (!valid(w,h,src) || labels.length < src.length) return; labels[] = 0; uint next;
    foreach (i; 0 .. src.length) { bool minimum=true; auto x=i%w; auto y=i/w; foreach(dy;-1..2)foreach(dx;-1..2)if(dx!=0||dy!=0){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h&&src[at(w,cast(size_t)nx,cast(size_t)ny)]<src[i])minimum=false;} if(minimum)labels[i]=++next; }
    foreach (pass; 0 .. w+h) foreach (y;0..h) foreach(x;0..w) if(labels[at(w,x,y)]==0){uint found;foreach(dy;-1..2)foreach(dx;-1..2){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto q=labels[at(w,cast(size_t)nx,cast(size_t)ny)];if(q!=0){if(found!=0&&found!=q)found=uint.max;else found=q;}}}if(found!=uint.max)labels[at(w,x,y)]=found;}
}

/// Frontier-compatible entry point. It preserves the reference FIFO result
/// while giving tiled executors a stable seam for replacing connectivity
/// propagation without changing gradient/NMS contracts.
void cannyFromGradientFrontier(scope const(float)[] gx, scope const(float)[] gy,
    scope const(float)[] magnitude, size_t w, size_t h, float low, float high,
    ref ubyte[] edges) @safe {
    if (!valid(w,h,magnitude) || gx.length < magnitude.length || gy.length < magnitude.length || edges.length < magnitude.length || low < 0 || high < low) return;
    auto state=new ubyte[](magnitude.length); foreach(y;1..(h>1?h-1:1)) foreach(x;1..(w>1?w-1:1)){auto p=at(w,x,y),ax=abs(gx[p]),ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=magnitude[at(w,x-1,y)];b=magnitude[at(w,x+1,y)];}else if(ay>=ax*2.4142f){a=magnitude[at(w,x,y-1)];b=magnitude[at(w,x,y+1)];}else if(gx[p]*gy[p]>=0){a=magnitude[at(w,x-1,y-1)];b=magnitude[at(w,x+1,y+1)];}else{a=magnitude[at(w,x+1,y-1)];b=magnitude[at(w,x-1,y+1)];}if(magnitude[p]>=a&&magnitude[p]>=b)state[p]=magnitude[p]>=high?2:(magnitude[p]>=low?1:0);}
    cannyFrontierFromState(state,w,h,edges);
}

/// Propagates strong Canny seeds through weak candidates in wavefronts. State
/// values are 0 (background), 1 (weak), and 2 (strong seed). This is the
/// tile-connectivity primitive; NMS remains a separate producer.
void cannyFrontierFromState(scope const(ubyte)[] state, size_t w, size_t h,
    ref ubyte[] edges) @safe {
    if (state.length != w*h || edges.length < state.length || w == 0 || h == 0) return;
    edges[] = 0; auto frontier = new size_t[](state.length); size_t count;
    foreach (i; 0 .. state.length) if (state[i] == 2) { edges[i]=1; frontier[count++]=i; }
    while (count != 0) {
        size_t nextCount; auto next = new size_t[](count*2+1);
        foreach (j; 0 .. count) { auto p=frontier[j]; auto x=p%w; auto y=p/w;
            foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) { auto nx=cast(long)x+dx, ny=cast(long)y+dy;
                if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(edges[n]==0&&state[n]==1){edges[n]=1;if(nextCount<next.length)next[nextCount++]=n;}}
            }
        }
        frontier = next[0 .. nextCount]; count = nextCount;
    }
}

/// Parallel staged Canny: gradient, NMS/state classification and serial
/// frontier propagation. The final propagation is deterministic.
ParallelRowsResult cannyParallel(scope const(float)[] src,size_t w,size_t h,float low,float high,ref ubyte[] edges,size_t workers=0,size_t chunk=1) @trusted {
    if(!valid(w,h,src)||edges.length<src.length||low<0||high<low)return ParallelRowsResult.callbackFailed;
    auto gx=new float[](src.length),gy=new float[](src.length),m=new float[](src.length);auto gradient=cannyGradientParallel(src,w,h,gx,gy,m,workers,chunk);if(gradient!=ParallelRowsResult.completed)return gradient;auto state=new ubyte[](src.length);
    auto nms=parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w)if(x>0&&y>0&&x+1<w&&y+1<h){auto p=y*w+x,ax=abs(gx[p]),ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=m[p-1];b=m[p+1];}else if(ay>=ax*2.4142f){a=m[p-w];b=m[p+w];}else if(gx[p]*gy[p]>=0){a=m[p-w-1];b=m[p+w+1];}else{a=m[p-w+1];b=m[p+w-1];}if(m[p]>=a&&m[p]>=b)state[p]=m[p]>=high?2:(m[p]>=low?1:0);}return true;});if(nms!=ParallelRowsResult.completed)return nms;cannyFrontierFromState(state,w,h,edges);return ParallelRowsResult.completed;
}

/// Deterministic grid SLIC-like superpixel assignment (compact baseline).
void slic(scope const(float)[] src,size_t w,size_t h,size_t spacing,ref uint[] labels) @safe {
    if(!valid(w,h,src)||labels.length<src.length||spacing==0)return; auto nx=(w+spacing-1)/spacing,ny=(h+spacing-1)/spacing,n=nx*ny;auto cx=new float[](n);auto cy=new float[](n);auto cc=new float[](n);foreach(j;0..ny)foreach(i;0..nx){auto k=j*nx+i;cx[k]=cast(float)((i*spacing+spacing/2<w)?i*spacing+spacing/2:w-1);cy[k]=cast(float)((j*spacing+spacing/2<h)?j*spacing+spacing/2:h-1);cc[k]=src[at(w,cast(size_t)cx[k],cast(size_t)cy[k])];}auto dist=new float[](src.length);foreach(iter;0..4){dist[]=float.max;foreach(k;0..n){auto x0=cast(long)cx[k],y0=cast(long)cy[k];foreach(y;0..h)foreach(x;0..w){auto dx=cast(float)x-cx[k],dy=cast(float)y-cy[k];auto dc=src[at(w,x,y)]-cc[k];auto d=dc*dc+(dx*dx+dy*dy)/(spacing*spacing);auto p=at(w,x,y);if(d<dist[p]){dist[p]=d;labels[p]=cast(uint)(k+1);}}}auto sx=new float[](n);auto sy=new float[](n);auto sc=new float[](n);auto cnt=new uint[](n);foreach(p;0..src.length){auto k=labels[p]-1;sx[k]+=cast(float)(p%w);sy[k]+=cast(float)(p/w);sc[k]+=src[p];++cnt[k];}foreach(k;0..n)if(cnt[k]!=0){cx[k]=sx[k]/cnt[k];cy[k]=sy[k]/cnt[k];cc[k]=sc[k]/cnt[k];}}
}

/// Binary morphology with a square radius. Open = erode then dilate; close = reverse.
void dilate(scope const(ubyte)[] src,size_t w,size_t h,size_t radius,ref ubyte[] dst) @safe { morph(src,w,h,radius,true,dst); }
void erode(scope const(ubyte)[] src,size_t w,size_t h,size_t radius,ref ubyte[] dst) @safe { morph(src,w,h,radius,false,dst); }
private ubyte maskPx(scope const(ubyte)[] s,size_t w,size_t h,long x,long y) @safe pure nothrow @nogc { if(x<0)x=0;else if(x>=cast(long)w)x=cast(long)w-1;if(y<0)y=0;else if(y>=cast(long)h)y=cast(long)h-1;return s[at(w,cast(size_t)x,cast(size_t)y)]; }
private void morph(scope const(ubyte)[] s,size_t w,size_t h,size_t r,bool maxOp,ref ubyte[] d) @safe { if(w==0||h==0||s.length!=w*h||d.length<s.length)return;foreach(y;0..h)foreach(x;0..w){ubyte v=maxOp?0:255;foreach(dy;-(cast(long)r)..cast(long)(r+1))foreach(dx;-(cast(long)r)..cast(long)(r+1)){auto z=maskPx(s,w,h,cast(long)x+dx,cast(long)y+dy);if(maxOp&&z>v)v=z;if(!maxOp&&z<v)v=z;}d[at(w,x,y)]=v;}}
void open(scope const(ubyte)[] s,size_t w,size_t h,size_t r,ref ubyte[] d) @safe {auto t=new ubyte[](s.length);erode(s,w,h,r,t);dilate(t,w,h,r,d);}
void close(scope const(ubyte)[] s,size_t w,size_t h,size_t r,ref ubyte[] d) @safe {auto t=new ubyte[](s.length);dilate(s,w,h,r,t);erode(t,w,h,r,d);}
alias opening = open;
alias closing = close;

/// Connected components of a binary mask; returns component labels and count.
size_t connectedComponents(scope const(ubyte)[] mask,size_t w,size_t h,ref uint[] labels) @safe { if(mask.length!=w*h||labels.length<mask.length)return 0; labels[]=0; uint next=0; auto q=new size_t[](mask.length); foreach(i;0..mask.length)if(mask[i]!=0&&labels[i]==0){++next;size_t head=0,tail=1; q[0]=i;labels[i]=next;while(head<tail){auto p=q[head++];auto x=p%w;auto y=p/w; foreach(k;0..4){long nx=cast(long)x,ny=cast(long)y; final switch(k){case 0:nx--;break;case 1:nx++;break;case 2:ny--;break;case 3:ny++;break;}if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(mask[n]!=0&&labels[n]==0){labels[n]=next;q[tail++]=n;}}}}}return next; }

/// Normalized difference index (e.g. NDVI = (NIR-Red)/(NIR+Red)).
void normalizedDifference(scope const(float)[] a,scope const(float)[] b,float epsilon,ref float[] dst) @safe { if(a.length!=b.length||dst.length<a.length)return;foreach(i;0..a.length){auto d=a[i]+b[i];dst[i]=abs(d)<=epsilon?0:(a[i]-b[i])/d;} }

/// Normalized difference with explicit validity and alpha planes. Invalid
/// outputs are set to NaN so consumers cannot mistake them for zero.
void normalizedDifferenceValid(scope const(float)[] a, scope const(float)[] b,
    scope const(ubyte)[] validity, scope const(ubyte)[] alpha,
    float epsilon, ref float[] dst) @safe {
    if (a.length != b.length || dst.length < a.length) return;
    foreach (i; 0 .. a.length) {
        if ((validity.length != 0 && (validity.length <= i || validity[i] == 0)) ||
            (alpha.length != 0 && (alpha.length <= i || alpha[i] == 0))) { dst[i] = float.nan; continue; }
        auto d = a[i] + b[i]; dst[i] = abs(d) <= epsilon ? 0 : (a[i] - b[i]) / d;
    }
}

