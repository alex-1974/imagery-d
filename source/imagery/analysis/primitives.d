/**
 * Small, allocation-explicit image-processing primitives.
 *
 * The functions in this module deliberately operate on dense scalar planes.
 * Raster-view adapters belong at the imagery/raster boundary; keeping the
 * kernels independent makes them useful for tiles, ROIs and partitioned
 * execution without imposing a storage layout.
 */
module imagery.analysis.primitives;

import std.math : exp, sqrt, abs, log, atan2;

private size_t at(size_t w, size_t x, size_t y) @safe pure nothrow @nogc { return y * w + x; }
private bool valid(size_t w, size_t h, scope const(float)[] p) @safe pure nothrow @nogc { return w != 0 && h != 0 && p.length == w * h; }
private float px(scope const(float)[] p, size_t w, size_t h, long x, long y) @safe pure nothrow @nogc {
    if (x < 0) x = 0; else if (x >= cast(long)w) x = cast(long)w - 1;
    if (y < 0) y = 0; else if (y >= cast(long)h) y = cast(long)h - 1;
    return p[at(w, cast(size_t)x, cast(size_t)y)];
}

/// Separable Gaussian blur with edge replication.
void gaussianBlur(scope const(float)[] src, size_t width, size_t height, float sigma, ref float[] dst) @safe {
    if (!valid(width,height,src) || !(sigma > 0) || !dst.length) return;
    auto r = cast(size_t)(sigma * 3.0f + 0.5f); auto k = new float[](r * 2 + 1); float sum;
    foreach (i; 0 .. k.length) { auto d = cast(float)(cast(long)i - cast(long)r); k[i] = exp(-(d*d)/(2*sigma*sigma)); sum += k[i]; }
    foreach (ref v; k) v /= sum; auto tmp = new float[](src.length);
    foreach (y; 0 .. height) foreach (x; 0 .. width) { float v; foreach (i; 0 .. k.length) v += px(src,width,height,cast(long)x+cast(long)i-cast(long)r,cast(long)y)*k[i]; tmp[at(width,x,y)] = v; }
    foreach (y; 0 .. height) foreach (x; 0 .. width) { float v; foreach (i; 0 .. k.length) v += px(tmp,width,height,cast(long)x,cast(long)y+cast(long)i-cast(long)r)*k[i]; dst[at(width,x,y)] = v; }
}

/// 3x3 median filter.
void medianFilter(scope const(float)[] src, size_t width, size_t height, ref float[] dst) @safe {
    if (!valid(width,height,src) || dst.length < src.length) return; auto a = new float[9];
    foreach (y; 0 .. height) foreach (x; 0 .. width) { size_t n; foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) a[n++] = px(src,width,height,cast(long)x+dx,cast(long)y+dy); import std.algorithm : sort; a.sort(); dst[at(width,x,y)] = a[4]; }
}

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
void sobel(scope const(float)[] src, size_t width, size_t height, ref float[] gx, ref float[] gy) @safe {
    if (!valid(width,height,src) || gx.length < src.length || gy.length < src.length) return;
    immutable int[3][3] kx = [[-1,0,1],[-2,0,2],[-1,0,1]]; immutable int[3][3] ky = [[-1,-2,-1],[0,0,0],[1,2,1]];
    foreach (y; 0 .. height) foreach (x; 0 .. width) { float ax, ay; foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) { auto v=px(src,width,height,cast(long)x+dx,cast(long)y+dy); ax += v*kx[dy+1][dx+1]; ay += v*ky[dy+1][dx+1]; } gx[at(width,x,y)]=ax; gy[at(width,x,y)]=ay; }
}

/// Laplacian response and Difference-of-Gaussians.
void laplace(scope const(float)[] src, size_t width, size_t height, ref float[] dst) @safe { if (!valid(width,height,src)||dst.length<src.length)return; foreach(y;0..height)foreach(x;0..width) dst[at(width,x,y)]=px(src,width,height,x,y-1)+px(src,width,height,x-1,y)+px(src,width,height,x+1,y)+px(src,width,height,x,y+1)-4*px(src,width,height,x,y); }
void differenceOfGaussians(scope const(float)[] src,size_t width,size_t height,float sigma1,float sigma2,ref float[] dst) @safe { auto a=new float[](src.length);auto b=new float[](src.length);gaussianBlur(src,width,height,sigma1,a);gaussianBlur(src,width,height,sigma2,b);if(dst.length<src.length)return;foreach(i;0..src.length)dst[i]=a[i]-b[i]; }

/// Gradient magnitude and direction, the first Canny pipeline stage.
void gradientMagnitude(scope const(float)[] src,size_t w,size_t h,ref float[] magnitude,ref float[] direction) @safe { if(magnitude.length<src.length||direction.length<src.length)return;auto gx=new float[](src.length);auto gy=new float[](src.length);sobel(src,w,h,gx,gy);foreach(i;0..src.length){magnitude[i]=sqrt(gx[i]*gx[i]+gy[i]*gy[i]);direction[i]=atan2(gy[i],gx[i]);} }

/// Compact Canny-style binary edge mask (gradient threshold + hysteresis).
void canny(scope const(float)[] src,size_t w,size_t h,float low,float high,ref ubyte[] edges) @safe { if(!valid(w,h,src)||edges.length<src.length||low<0||high<low)return;auto m=new float[](src.length);auto d=new float[](src.length);gradientMagnitude(src,w,h,m,d);edges[]=0;auto q=new size_t[](src.length);size_t head,tail;foreach(i;0..m.length)if(m[i]>=high){edges[i]=1;q[tail++]=i;}while(head<tail){auto p=q[head++];auto x=p%w;auto y=p/w;foreach(dy;-1..2)foreach(dx;-1..2){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(edges[n]==0&&m[n]>=low){edges[n]=1;q[tail++]=n;}}}} }

/// Four-connected flood fill using an absolute scalar tolerance.
void floodFill(scope const(float)[] src,size_t w,size_t h,size_t seedX,size_t seedY,float tolerance,ref ubyte[] mask) @safe { if(!valid(w,h,src)||mask.length<src.length||seedX>=w||seedY>=h||tolerance<0)return;mask[]=0;auto q=new size_t[](src.length);size_t head,tail;q[tail++]=at(w,seedX,seedY);mask[q[0]]=1;auto seed=src[q[0]];while(head<tail){auto p=q[head++];auto x=p%w;auto y=p/w;foreach(k;0..4){long nx=cast(long)x,ny=cast(long)y;final switch(k){case 0:nx--;break;case 1:nx++;break;case 2:ny--;break;case 3:ny++;break;}if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(mask[n]==0&&abs(src[n]-seed)<=tolerance){mask[n]=1;q[tail++]=n;}}}} }

/// Priority-flood watershed approximation. Labels local minima basins and
/// marks competing fronts as zero (watershed lines).
void watershed(scope const(float)[] src, size_t w, size_t h, ref uint[] labels) @safe {
    if (!valid(w,h,src) || labels.length < src.length) return; labels[] = 0; uint next;
    foreach (i; 0 .. src.length) { bool minimum=true; auto x=i%w; auto y=i/w; foreach(dy;-1..2)foreach(dx;-1..2)if(dx!=0||dy!=0){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h&&src[at(w,cast(size_t)nx,cast(size_t)ny)]<src[i])minimum=false;} if(minimum)labels[i]=++next; }
    foreach (pass; 0 .. w+h) foreach (y;0..h) foreach(x;0..w) if(labels[at(w,x,y)]==0){uint found;foreach(dy;-1..2)foreach(dx;-1..2){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto q=labels[at(w,cast(size_t)nx,cast(size_t)ny)];if(q!=0){if(found!=0&&found!=q)found=uint.max;else found=q;}}}if(found!=uint.max)labels[at(w,x,y)]=found;}
}

/// Deterministic grid SLIC-like superpixel assignment (compact baseline).
void slic(scope const(float)[] src,size_t w,size_t h,size_t spacing,ref uint[] labels) @safe {
    if(!valid(w,h,src)||labels.length<src.length||spacing==0)return; foreach(y;0..h)foreach(x;0..w){auto cx=x/spacing;auto cy=y/spacing;labels[at(w,x,y)]=cast(uint)(cy*((w+spacing-1)/spacing)+cx+1);}
}

/// Binary morphology with a square radius. Open = erode then dilate; close = reverse.
void dilate(scope const(ubyte)[] src,size_t w,size_t h,size_t radius,ref ubyte[] dst) @safe { morph(src,w,h,radius,true,dst); }
void erode(scope const(ubyte)[] src,size_t w,size_t h,size_t radius,ref ubyte[] dst) @safe { morph(src,w,h,radius,false,dst); }
private ubyte maskPx(scope const(ubyte)[] s,size_t w,size_t h,long x,long y) @safe pure nothrow @nogc { if(x<0)x=0;else if(x>=cast(long)w)x=cast(long)w-1;if(y<0)y=0;else if(y>=cast(long)h)y=cast(long)h-1;return s[at(w,cast(size_t)x,cast(size_t)y)]; }
private void morph(scope const(ubyte)[] s,size_t w,size_t h,size_t r,bool maxOp,ref ubyte[] d) @safe { if(w==0||h==0||s.length!=w*h||d.length<s.length)return;foreach(y;0..h)foreach(x;0..w){ubyte v=maxOp?0:255;foreach(dy;-(cast(long)r)..cast(long)(r+1))foreach(dx;-(cast(long)r)..cast(long)(r+1)){auto z=maskPx(s,w,h,cast(long)x+dx,cast(long)y+dy);if(maxOp&&z>v)v=z;if(!maxOp&&z<v)v=z;}d[at(w,x,y)]=v;}}
void open(scope const(ubyte)[] s,size_t w,size_t h,size_t r,ref ubyte[] d) @safe {auto t=new ubyte[](s.length);erode(s,w,h,r,t);dilate(t,w,h,r,d);}
void close(scope const(ubyte)[] s,size_t w,size_t h,size_t r,ref ubyte[] d) @safe {auto t=new ubyte[](s.length);dilate(s,w,h,r,t);erode(t,w,h,r,d);}

/// Connected components of a binary mask; returns component labels and count.
size_t connectedComponents(scope const(ubyte)[] mask,size_t w,size_t h,ref uint[] labels) @safe { if(mask.length!=w*h||labels.length<mask.length)return 0; labels[]=0; uint next=0; auto q=new size_t[](mask.length); foreach(i;0..mask.length)if(mask[i]!=0&&labels[i]==0){++next;size_t head=0,tail=1; q[0]=i;labels[i]=next;while(head<tail){auto p=q[head++];auto x=p%w;auto y=p/w; foreach(k;0..4){long nx=cast(long)x,ny=cast(long)y; final switch(k){case 0:nx--;break;case 1:nx++;break;case 2:ny--;break;case 3:ny++;break;}if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(mask[n]!=0&&labels[n]==0){labels[n]=next;q[tail++]=n;}}}}}return next; }

/// Normalized difference index (e.g. NDVI = (NIR-Red)/(NIR+Red)).
void normalizedDifference(scope const(float)[] a,scope const(float)[] b,float epsilon,ref float[] dst) @safe { if(a.length!=b.length||dst.length<a.length)return;foreach(i;0..a.length){auto d=a[i]+b[i];dst[i]=abs(d)<=epsilon?0:(a[i]-b[i])/d;} }

