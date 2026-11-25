/++
Filter scalar images, find edges and segment masks using caller-supplied
arrays. Allocate the destination arrays first, then call an operation with its
image width and height. Use `import imagery;` for the common names or this
module for advanced parallel and staged forms.
+/
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

/++
 Soften a dense scalar image with a separable Gaussian blur.

 Larger sigma smooths over a wider pixel neighborhood. Boundary pixels are
 replicated, and the discrete support radius is round(3*sigma). Supply a
 finite positive sigma with a representable kernel size. This convenience
 form allocates a kernel and a full temporary plane on each valid call.

 The destination is already allocated; it is not resized. Empty/mismatched
 shape, sigma that does not compare greater than zero, or a short destination
 returns without writing. Source dimensions must have a representable product.
 No mask or NoData policy is inferred.

 Params:
   src = Read-only input samples in row-major order; shape must match the supplied dimensions.
   width = Image or grid width in pixels.
   height = Image or grid height in pixels.
   sigma = Finite positive Gaussian standard deviation in pixels; the temporary kernel must fit addressable storage.
   dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
void gaussianBlur(scope const(float)[] src, size_t width, size_t height, float sigma, ref float[] dst) @safe {
    if (!valid(width,height,src) || !(sigma > 0) || dst.length < src.length) return;
    auto r = cast(size_t)(sigma * 3.0f + 0.5f); auto k = new float[](r * 2 + 1); float sum=0;
    foreach (i; 0 .. k.length) { auto d = cast(float)(cast(long)i - cast(long)r); k[i] = exp(-(d*d)/(2*sigma*sigma)); sum += k[i]; }
    foreach (ref v; k) v /= sum; auto tmp = new float[](src.length);
    foreach (y; 0 .. height) foreach (x; 0 .. width) { float v=0; foreach (i; 0 .. k.length) { auto xx=cast(long)x+cast(long)i-cast(long)r; if(xx<0)xx=0;else if(xx>=cast(long)width)xx=cast(long)width-1; v += src[y*width+cast(size_t)xx]*k[i]; } tmp[y*width+x] = v; }
    foreach (y; 0 .. height) foreach (x; 0 .. width) { float v=0; foreach (i; 0 .. k.length) { auto yy=cast(long)y+cast(long)i-cast(long)r; if(yy<0)yy=0;else if(yy>=cast(long)height)yy=cast(long)height-1; v += tmp[cast(size_t)yy*width+x]*k[i]; } dst[y*width+x] = v; }
}

/// Smooth a dense plane and leave a short destination unchanged.
@safe unittest
{
    import std.math : abs;
    float[9] source=1;
    float[] output=new float[9];
    gaussianBlur(source[],3,3,1,output);
    foreach(value;output) assert(abs(value-1)<1e-6f);
    float[] shortOutput=[42.0f];
    gaussianBlur(source[],3,3,1,shortOutput);
    assert(shortOutput[0]==42);
}


/++
 Bounded parallel Gaussian blur using separate horizontal and vertical passes.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  sigma = Finite positive Gaussian standard deviation in pixels; the temporary kernel must fit addressable storage.
  dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
  workers = Upper limit on row workers; zero delegates the choice to raster-d.
  chunk = Minimum row chunk per worker, at least one.

 Returns:
 Row-execution status; completed denotes a completed blur, callbackFailed includes invalid input validation.
+/
ParallelRowsResult gaussianBlurParallel(scope const(float)[] src,size_t w,size_t h,float sigma,ref float[] dst,size_t workers=0,size_t chunk=1) @trusted {
    if(!valid(w,h,src)||dst.length<src.length||sigma<=0)return ParallelRowsResult.callbackFailed;auto r=cast(size_t)(sigma*3.0f+0.5f);auto k=new float[](r*2+1);float sum=0;foreach(i;0..k.length){auto d=cast(float)(cast(long)i-cast(long)r);k[i]=exp(-(d*d)/(2*sigma*sigma));sum+=k[i];}foreach(ref v;k)v/=sum;auto tmp=new float[](src.length);auto a=parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w){float v=0;foreach(i;0..k.length){auto xx=cast(long)x+cast(long)i-cast(long)r;if(xx<0)xx=0;else if(xx>=cast(long)w)xx=cast(long)w-1;v+=src[y*w+cast(size_t)xx]*k[i];}tmp[y*w+x]=v;}return true;});if(a!=ParallelRowsResult.completed)return a;return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w){float v=0;foreach(i;0..k.length){auto yy=cast(long)y+cast(long)i-cast(long)r;if(yy<0)yy=0;else if(yy>=cast(long)h)yy=cast(long)h-1;v+=tmp[cast(size_t)yy*w+x]*k[i];}dst[y*w+x]=v;}return true;});
}

/++
 Remove isolated bright or dark pixels with a 3x3 scalar median.

 Boundary pixels are replicated. The destination must already hold at least
 the input sample count and must not overlap the input. Invalid nonempty-shape
 validation or a short destination returns without writing. This allocating
 convenience form uses temporary neighborhood storage.

 Params:
   src = Read-only input samples in row-major order; shape must match the supplied dimensions.
   width = Image or grid width in pixels.
   height = Image or grid height in pixels.
   dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
void medianBlur(scope const(float)[] src, size_t width, size_t height, ref float[] dst) @safe {
    if (!valid(width,height,src) || dst.length < src.length) return; auto a = new float[9];
    foreach (y; 0 .. height) foreach (x; 0 .. width) { size_t n; foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) a[n++] = px(src,width,height,cast(long)x+dx,cast(long)y+dy); import std.algorithm : sort; a.sort(); dst[at(width,x,y)] = a[4]; }
}

/// Remove an isolated bright impulse while preserving the input.
@safe unittest
{
    float[9] source=0; source[4]=1;
    float[] output=new float[9];
    medianBlur(source[],3,3,output);
    assert(output[4]==0 && source[4]==1);
}

/// Compatibility spelling retained for direct module users.
alias medianFilter = medianBlur;

/++
 Edge-preserving bilateral filter for scalar planes.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  width = Image or grid width in pixels.
  height = Image or grid height in pixels.
  spatialSigma = Finite positive spatial standard deviation in pixels.
  rangeSigma = Finite positive intensity standard deviation in input sample units.
  dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
void bilateralFilter(scope const(float)[] src, size_t width, size_t height,
    float spatialSigma, float rangeSigma, ref float[] dst) @safe {
    if (!valid(width, height, src) || dst.length < src.length || spatialSigma <= 0 || rangeSigma <= 0) return;
    auto radius = cast(size_t)(spatialSigma * 2.5f + 0.5f);
    foreach (y; 0 .. height) foreach (x; 0 .. width) {
        auto center = src[at(width, x, y)]; float sum=0, weightSum=0;
        foreach (dy; -(cast(long)radius) .. cast(long)(radius + 1)) foreach (dx; -(cast(long)radius) .. cast(long)(radius + 1)) {
            auto v = px(src, width, height, cast(long)x + dx, cast(long)y + dy);
            auto spatial = exp(-cast(float)(dx*dx + dy*dy) / (2*spatialSigma*spatialSigma));
            auto range = exp(-(v-center)*(v-center) / (2*rangeSigma*rangeSigma));
            auto w = spatial * range; sum += v*w; weightSum += w;
        }
        dst[at(width,x,y)] = weightSum > 0 ? sum / weightSum : center;
    }
}

/++
 Smooth a scalar image with a local linear model of a guide plane.

 This one-pass approximation computes local mean, variance and covariance for
 each output pixel. It does not perform a second neighborhood average of the
 linear coefficients. Both planes share the same dense shape; boundaries are
 replicated. Supply a finite positive regularizer and disjoint output storage.

 Params:
   src = Read-only input samples in row-major order; shape must match the supplied dimensions.
   guide = Read-only guide plane with the same shape as src.
   width = Image or grid width in pixels.
   height = Image or grid height in pixels.
   radius = Neighborhood support radius in pixels.
   epsilon = Finite nonnegative regularizer or denominator threshold in the formula’s numeric domain.
   dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
void guidedFilter(scope const(float)[] src, scope const(float)[] guide,
    size_t width, size_t height, size_t radius, float epsilon, ref float[] dst) @safe {
    if (!valid(width,height,src) || !valid(width,height,guide) || dst.length < src.length || epsilon <= 0) return;
    foreach (y; 0 .. height) foreach (x; 0 .. width) {
        float sumI=0,sumP=0,sumII=0,sumIP=0; size_t n;
        foreach(dy; -(cast(long)radius) .. cast(long)(radius+1)) foreach(dx; -(cast(long)radius) .. cast(long)(radius+1)) {
            auto i=px(guide,width,height,cast(long)x+dx,cast(long)y+dy); auto p=px(src,width,height,cast(long)x+dx,cast(long)y+dy);
            sumI+=i;sumP+=p;sumII+=i*i;sumIP+=i*p;++n;
        }
        auto ni=cast(float)n; auto meanI=sumI/ni; auto meanP=sumP/ni;
        auto varI=sumII/ni-meanI*meanI; auto cov=sumIP/ni-meanI*meanP; auto a=cov/(varI+epsilon); auto b=meanP-a*meanI;
        dst[at(width,x,y)]=a*guide[at(width,x,y)]+b;
    }
}

/++
 Sobel horizontal/vertical gradients.
  Returns horizontal and vertical brightness changes for an image.
  The unnormalized 3x3 stencil gives gx=8 on a unit horizontal ramp.
  Source edges replicate. Supply finite scalar samples in declared units.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  width = Image or grid width in pixels.
  height = Image or grid height in pixels.
  gx = Horizontal derivative plane; destination for gradient computation, input for later Canny phases.
  gy = Vertical derivative plane; destination for gradient computation, input for later Canny phases.
+/
void sobel(scope const(float)[] src, size_t width, size_t height, ref float[] gx, ref float[] gy) @safe {
    if (!valid(width,height,src) || gx.length < src.length || gy.length < src.length) return;
    immutable int[3][3] kx = [[-1,0,1],[-2,0,2],[-1,0,1]]; immutable int[3][3] ky = [[-1,-2,-1],[0,0,0],[1,2,1]];
    foreach (y; 0 .. height) foreach (x; 0 .. width) { float ax=0, ay=0; foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) { auto v=px(src,width,height,cast(long)x+dx,cast(long)y+dy); ax += v*kx[dy+1][dx+1]; ay += v*ky[dy+1][dx+1]; } gx[at(width,x,y)]=ax; gy[at(width,x,y)]=ay; }
}

/// Measure the unnormalized Sobel derivative of a horizontal ramp.
@safe unittest
{
    float[9] source=[0,1,2,0,1,2,0,1,2];
    float[] gx=new float[9],gy=new float[9];
    sobel(source[],3,3,gx,gy);
    assert(gx[4]==8 && gy[4]==0);
}


/++
 Sobel gradients for 8-bit preview images. Outputs remain float so callers
  can feed them directly into the Canny stages.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  gx = Horizontal derivative plane; destination for gradient computation, input for later Canny phases.
  gy = Vertical derivative plane; destination for gradient computation, input for later Canny phases.
+/
void sobelUbyte(scope const(ubyte)[] src,size_t w,size_t h,ref float[] gx,ref float[] gy) @safe {
    if(w==0||h==0||src.length!=w*h||gx.length<src.length||gy.length<src.length)return; immutable int[3][3] kx=[[-1,0,1],[-2,0,2],[-1,0,1]]; immutable int[3][3] ky=[[-1,-2,-1],[0,0,0],[1,2,1]];
    foreach(y;0..h)foreach(x;0..w){int ax,ay;if(x>0&&y>0&&x+1<w&&y+1<h){auto p=y*w+x;ax=cast(int)src[p-w-1]*-1+cast(int)src[p-w+1]+cast(int)src[p-1]*-2+cast(int)src[p+1]*2+cast(int)src[p+w-1]*-1+cast(int)src[p+w+1];ay=cast(int)src[p-w-1]*-1+cast(int)src[p-w]*-2+cast(int)src[p-w+1]*-1+cast(int)src[p+w-1]+cast(int)src[p+w]*2+cast(int)src[p+w+1];}else foreach(dy;-1..2)foreach(dx;-1..2){auto v=cast(int)maskPx(src,w,h,cast(long)x+dx,cast(long)y+dy);ax+=v*kx[dy+1][dx+1];ay+=v*ky[dy+1][dx+1];}auto p=y*w+x;gx[p]=cast(float)ax;gy[p]=cast(float)ay;}
}

/++
 Compute unnormalized 3x3 Sobel derivatives from bytes using bounded row workers. Output planes must be disjoint from the input and each other; completion joins all workers.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  gx = Horizontal derivative plane; destination for gradient computation, input for later Canny phases.
  gy = Vertical derivative plane; destination for gradient computation, input for later Canny phases.
  workers = Upper limit on row workers; zero delegates the choice to raster-d.
  chunk = Minimum row chunk per worker, at least one.

 Returns:
 Row-execution status; completed denotes finished derivatives.
+/
ParallelRowsResult sobelUbyteParallel(scope const(ubyte)[] src,size_t w,size_t h,ref float[] gx,ref float[] gy,size_t workers=0,size_t chunk=1) @trusted {
    if(w==0||h==0||src.length!=w*h||gx.length<src.length||gy.length<src.length)return ParallelRowsResult.callbackFailed;
    return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w){int ax,ay;auto p=y*w+x;if(x>0&&y>0&&x+1<w&&y+1<h){ax=cast(int)src[p-w-1]*-1+cast(int)src[p-w+1]+cast(int)src[p-1]*-2+cast(int)src[p+1]*2+cast(int)src[p+w-1]*-1+cast(int)src[p+w+1];ay=cast(int)src[p-w-1]*-1+cast(int)src[p-w]*-2+cast(int)src[p-w+1]*-1+cast(int)src[p+w-1]+cast(int)src[p+w]*2+cast(int)src[p+w+1];}else foreach(dy;-1..2)foreach(dx;-1..2){auto v=cast(int)maskPx(src,w,h,cast(long)x+dx,cast(long)y+dy);ax+=v*[[-1,0,1],[-2,0,2],[-1,0,1]][dy+1][dx+1];ay+=v*[[-1,-2,-1],[0,0,0],[1,2,1]][dy+1][dx+1];}gx[p]=cast(float)ax;gy[p]=cast(float)ay;}return true;});
}

/++
 Bounded parallel Sobel gradients.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  gx = Horizontal derivative plane; destination for gradient computation, input for later Canny phases.
  gy = Vertical derivative plane; destination for gradient computation, input for later Canny phases.
  workers = Upper limit on row workers; zero delegates the choice to raster-d.
  chunk = Minimum row chunk per worker, at least one.

 Returns:
 Row-execution status; completed denotes finished derivatives.
+/
ParallelRowsResult sobelParallel(scope const(float)[] src,size_t w,size_t h,ref float[] gx,ref float[] gy,size_t workers=0,size_t chunk=1) @trusted {
    if(!valid(w,h,src)||gx.length<src.length||gy.length<src.length)return ParallelRowsResult.callbackFailed;immutable int[3][3] kx=[[-1,0,1],[-2,0,2],[-1,0,1]];immutable int[3][3] ky=[[-1,-2,-1],[0,0,0],[1,2,1]];return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w){float ax=0,ay=0;foreach(dy;-1..2)foreach(dx;-1..2){auto v=px(src,w,h,cast(long)x+dx,cast(long)y+dy);ax+=v*kx[dy+1][dx+1];ay+=v*ky[dy+1][dx+1];}auto p=y*w+x;gx[p]=ax;gy[p]=ay;}return true;});
}

/++
 Laplacian response and Difference-of-Gaussians.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  width = Image or grid width in pixels.
  height = Image or grid height in pixels.
  dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
void laplacian(scope const(float)[] src, size_t width, size_t height, ref float[] dst) @safe { if (!valid(width,height,src)||dst.length<src.length)return; foreach(y;0..height)foreach(x;0..width) dst[at(width,x,y)]=px(src,width,height,x,y-1)+px(src,width,height,x-1,y)+px(src,width,height,x+1,y)+px(src,width,height,x,y+1)-4*px(src,width,height,x,y); }
/// Compatibility spelling retained for direct module users.
alias laplace = laplacian;
/++
 Subtract the second Gaussian-smoothed image from the first. Supply valid finite positive scales and a nonempty dense image; this allocating convenience form does not validate both scales before preparing its temporary images.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  width = Image or grid width in pixels.
  height = Image or grid height in pixels.
  sigma1 = Finite positive first Gaussian standard deviation in pixels.
  sigma2 = Finite positive second Gaussian standard deviation in pixels.
  dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
void differenceOfGaussians(scope const(float)[] src,size_t width,size_t height,float sigma1,float sigma2,ref float[] dst) @safe { auto a=new float[](src.length);auto b=new float[](src.length);gaussianBlur(src,width,height,sigma1,a);gaussianBlur(src,width,height,sigma2,b);if(dst.length<src.length)return;foreach(i;0..src.length)dst[i]=a[i]-b[i]; }

/++
 Gradient magnitude and direction, the first Canny pipeline stage.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  magnitude = Row-major gradient magnitude plane in input units per pixel.
  direction = Row-major gradient angles in radians.
+/
void gradientMagnitude(scope const(float)[] src,size_t w,size_t h,ref float[] magnitude,ref float[] direction) @safe { if(magnitude.length<src.length||direction.length<src.length)return;auto gx=new float[](src.length);auto gy=new float[](src.length);sobel(src,w,h,gx,gy);foreach(i;0..src.length){magnitude[i]=sqrt(gx[i]*gx[i]+gy[i]*gy[i]);direction[i]=atan2(gy[i],gx[i]);} }

/++
 First, parallelizable Canny phase: computes gradient components and
  magnitude. The result may be partitioned by row/tile with a one-pixel halo.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  gx = Horizontal derivative plane; destination for gradient computation, input for later Canny phases.
  gy = Vertical derivative plane; destination for gradient computation, input for later Canny phases.
  magnitude = Row-major gradient magnitude plane in input units per pixel.
+/
void cannyGradient(scope const(float)[] src, size_t w, size_t h,
    ref float[] gx, ref float[] gy, ref float[] magnitude) @safe {
    if (!valid(w,h,src) || gx.length < src.length || gy.length < src.length || magnitude.length < src.length) return;
    sobel(src,w,h,gx,gy); foreach(i;0..src.length) magnitude[i]=sqrt(gx[i]*gx[i]+gy[i]*gy[i]);
}

/++
 Bounded parallel variant of cannyGradient. Workers write disjoint rows.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  gx = Horizontal derivative plane; destination for gradient computation, input for later Canny phases.
  gy = Vertical derivative plane; destination for gradient computation, input for later Canny phases.
  magnitude = Row-major gradient magnitude plane in input units per pixel.
  workerLimit = Upper limit on row workers; zero delegates the choice to raster-d.
  minimumChunk = Minimum row chunk per worker, at least one.

 Returns:
 Row-execution status; completed denotes finished gradients and magnitude.
+/
ParallelRowsResult cannyGradientParallel(scope const(float)[] src, size_t w, size_t h,
    ref float[] gx, ref float[] gy, ref float[] magnitude,
    size_t workerLimit = 0, size_t minimumChunk = 1) @trusted {
    if (!valid(w,h,src) || gx.length < src.length || gy.length < src.length || magnitude.length < src.length)
        return ParallelRowsResult.callbackFailed;
    immutable int[3][3] kx = [[-1,0,1],[-2,0,2],[-1,0,1]];
    immutable int[3][3] ky = [[-1,-2,-1],[0,0,0],[1,2,1]];
    return parallelRows(h, workerLimit, minimumChunk, (size_t first, size_t last) @safe nothrow {
        foreach (y; first .. last) foreach (x; 0 .. w) {
            float ax=0, ay=0; foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) {
                auto v=px(src,w,h,cast(long)x+dx,cast(long)y+dy); ax += v*kx[dy+1][dx+1]; ay += v*ky[dy+1][dx+1];
            }
            auto p=y*w+x; gx[p]=ax; gy[p]=ay; magnitude[p]=sqrt(ax*ax+ay*ay);
        }
        return true;
    });
}

/++
 Second, deterministic Canny phase from precomputed gradients/magnitude.
  Uses inclusive two-neighbor nonmaximum suppression in four direction
  sectors and eight-connected weak-to-strong propagation. The outermost
  sample ring is suppressed. Full connectivity is global, not a fixed halo.

 Params:
  gx = Horizontal derivative plane; destination for gradient computation, input for later Canny phases.
  gy = Vertical derivative plane; destination for gradient computation, input for later Canny phases.
  magnitude = Row-major gradient magnitude plane in input units per pixel.
  w = Image width in pixels.
  h = Image height in pixels.
  low = Nonnegative weak-edge magnitude threshold, no greater than high.
  high = Strong-edge magnitude threshold, at least low.
  edges = Preallocated row-major byte edge output; zero is background.
+/
void cannyFromGradient(scope const(float)[] gx, scope const(float)[] gy,
    scope const(float)[] magnitude, size_t w, size_t h, float low, float high,
    ref ubyte[] edges) @safe {
    if (!valid(w,h,magnitude) || gx.length < magnitude.length || gy.length < magnitude.length || edges.length < magnitude.length || low < 0 || high < low) return;
    auto state=new ubyte[](magnitude.length); foreach(y;1..(h>1?h-1:1)) foreach(x;1..(w>1?w-1:1)){auto p=at(w,x,y),ax=abs(gx[p]),ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=magnitude[at(w,x-1,y)];b=magnitude[at(w,x+1,y)];}else if(ay>=ax*2.4142f){a=magnitude[at(w,x,y-1)];b=magnitude[at(w,x,y+1)];}else if(gx[p]*gy[p]>=0){a=magnitude[at(w,x-1,y-1)];b=magnitude[at(w,x+1,y+1)];}else{a=magnitude[at(w,x+1,y-1)];b=magnitude[at(w,x-1,y+1)];}if(magnitude[p]>=a&&magnitude[p]>=b)state[p]=magnitude[p]>=high?2:(magnitude[p]>=low?1:0);} edges[]=0;auto q=new size_t[](magnitude.length);size_t head,tail;foreach(i;0..state.length)if(state[i]==2){edges[i]=1;q[tail++]=i;}while(head<tail){auto p=q[head++],x=p%w,y=p/w;foreach(dy;-1..2)foreach(dx;-1..2){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(edges[n]==0&&state[n]>=1){edges[n]=1;q[tail++]=n;}}}} }

/++
 Compact Canny-style binary edge mask (gradient threshold + hysteresis).
  Creates a one-byte edge mask. `low` and `high` control weak and strong edges.
  Finite scalar input is required. No Gaussian smoothing is implicit;
  thresholds use unnormalized Sobel magnitude in source units. NMS is
  inclusive in four sectors; the outer sample ring is suppressed. Hysteresis
  is eight-connected across the complete supplied domain. Independent tiles
  require a separate global connectivity pass, not a fixed halo alone.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  low = Nonnegative weak-edge magnitude threshold, no greater than high.
  high = Strong-edge magnitude threshold, at least low.
  edges = Preallocated row-major byte edge output; zero is background.
+/
void canny(scope const(float)[] src,size_t w,size_t h,float low,float high,ref ubyte[] edges) @safe { if(!valid(w,h,src)||edges.length<src.length||low<0||high<low)return;auto gx=new float[](src.length);auto gy=new float[](src.length);sobel(src,w,h,gx,gy);auto m=new float[](src.length);foreach(i;0..src.length)m[i]=sqrt(gx[i]*gx[i]+gy[i]*gy[i]);auto thin=new float[](src.length);foreach(y;1..(h>1?h-1:1))foreach(x;1..(w>1?w-1:1)){auto p=at(w,x,y), ax=abs(gx[p]), ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=m[at(w,x-1,y)];b=m[at(w,x+1,y)];}else if(ay>=ax*2.4142f){a=m[at(w,x,y-1)];b=m[at(w,x,y+1)];}else if((gx[p]*gy[p])>=0){a=m[at(w,x-1,y-1)];b=m[at(w,x+1,y+1)];}else{a=m[at(w,x+1,y-1)];b=m[at(w,x-1,y+1)];}if(m[p]>=a&&m[p]>=b)thin[p]=m[p];}edges[]=0;auto q=new size_t[](src.length);size_t head,tail;foreach(i;0..thin.length)if(thin[i]>=high){edges[i]=1;q[tail++]=i;}while(head<tail){auto p=q[head++];auto x=p%w;auto y=p/w;foreach(dy;-1..2)foreach(dx;-1..2){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(edges[n]==0&&thin[n]>=low){edges[n]=1;q[tail++]=n;}}}} }

/++
 Four-connected flood fill using an absolute scalar tolerance.
   Fast interactive edge preview: parallel gradients plus NMS, without
   hysteresis propagation. Use `canny` for a final connected edge map.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  threshold = Nonnegative preview edge-magnitude threshold.
  edges = Preallocated row-major byte edge output; zero is background.
  workers = Upper limit on row workers; zero delegates the choice to raster-d.
  chunk = Minimum row chunk per worker, at least one.

 Returns:
 Row-execution status; completed denotes a finished non-hysteresis preview.
+/
ParallelRowsResult cannyPreview(scope const(float)[] src,size_t w,size_t h,float threshold,ref ubyte[] edges,size_t workers=0,size_t chunk=1) @trusted { if(!valid(w,h,src)||edges.length<src.length||threshold<0)return ParallelRowsResult.callbackFailed;auto gx=new float[](src.length),gy=new float[](src.length),m=new float[](src.length);auto s=cannyGradientParallel(src,w,h,gx,gy,m,workers,chunk);if(s!=ParallelRowsResult.completed)return s;edges[]=0;return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w)if(x>0&&y>0&&x+1<w&&y+1<h){auto p=y*w+x,ax=abs(gx[p]),ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=m[p-1];b=m[p+1];}else if(ay>=ax*2.4142f){a=m[p-w];b=m[p+w];}else if(gx[p]*gy[p]>=0){a=m[p-w-1];b=m[p+w+1];}else{a=m[p-w+1];b=m[p+w-1];}if(m[p]>=threshold&&m[p]>=a&&m[p]>=b)edges[p]=1;}return true;}); }

/++
 8-bit preview variant that avoids float input conversion.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  threshold = Nonnegative preview edge-magnitude threshold.
  edges = Preallocated row-major byte edge output; zero is background.
  workers = Upper limit on row workers; zero delegates the choice to raster-d.
  chunk = Minimum row chunk per worker, at least one.

 Returns:
 Row-execution status; completed denotes a finished byte-source preview.
+/
ParallelRowsResult cannyPreviewUbyte(scope const(ubyte)[] src,size_t w,size_t h,float threshold,ref ubyte[] edges,size_t workers=0,size_t chunk=1) @trusted { if(w==0||h==0||src.length!=w*h||edges.length<src.length||threshold<0)return ParallelRowsResult.callbackFailed;auto gx=new float[](src.length),gy=new float[](src.length);sobelUbyte(src,w,h,gx,gy);auto threshold2=threshold*threshold;edges[]=0;return parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w)if(x>0&&y>0&&x+1<w&&y+1<h){auto p=y*w+x,ax=abs(gx[p]),ay=abs(gy[p]),m=gx[p]*gx[p]+gy[p]*gy[p];float a,b;if(ax>=ay*2.4142f){auto q=p-1,r=p+1;a=gx[q]*gx[q]+gy[q]*gy[q];b=gx[r]*gx[r]+gy[r]*gy[r];}else if(ay>=ax*2.4142f){auto q=p-w,r=p+w;a=gx[q]*gx[q]+gy[q]*gy[q];b=gx[r]*gx[r]+gy[r]*gy[r];}else if(gx[p]*gy[p]>=0){auto q=p-w-1,r=p+w+1;a=gx[q]*gx[q]+gy[q]*gy[q];b=gx[r]*gx[r]+gy[r]*gy[r];}else{auto q=p-w+1,r=p+w-1;a=gx[q]*gx[q]+gy[q]*gy[q];b=gx[r]*gx[r]+gy[r]*gy[r];}if(m>=threshold2&&m>=a&&m>=b)edges[p]=1;}return true;}); }

/++
 Mark the four-connected region whose values differ from the seed by at most tolerance. On a valid request the destination is cleared, then included samples are marked one. Invalid shapes, short masks, out-of-bounds seeds or negative tolerance return without writing.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  seedX = Seed column in the source grid.
  seedY = Seed row in the source grid.
  tolerance = Nonnegative absolute difference from the seed in source scalar units.
  mask = Byte mask in the source grid; nonzero includes a sample, or mask/255 is mapping strength as described above.
+/
void floodFill(scope const(float)[] src,size_t w,size_t h,size_t seedX,size_t seedY,float tolerance,ref ubyte[] mask) @safe { if(!valid(w,h,src)||mask.length<src.length||seedX>=w||seedY>=h||tolerance<0)return;mask[]=0;auto q=new size_t[](src.length);size_t head,tail;q[tail++]=at(w,seedX,seedY);mask[q[0]]=1;auto seed=src[q[0]];while(head<tail){auto p=q[head++];auto x=p%w;auto y=p/w;foreach(k;0..4){long nx=cast(long)x,ny=cast(long)y;final switch(k){case 0:nx--;break;case 1:nx++;break;case 2:ny--;break;case 3:ny++;break;}if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(mask[n]==0&&abs(src[n]-seed)<=tolerance){mask[n]=1;q[tail++]=n;}}}} }

/// Fill only the four-connected values within the seed tolerance.
@safe unittest
{
    float[4] source=[0,0,9,9];
    ubyte[] included=new ubyte[4];
    floodFill(source[],2,2,0,0,0.1f,included);
    assert(included==[1,1,0,0]);
}


/++
 Approximate watershed regions by propagating labels from local minima.

 The implementation repeatedly scans the grid rather than using a priority
 queue. Competing fronts retain label zero. Use the resulting labels as an
 approximate partition, with zero also representing unresolved boundaries.

 Params:
   src = Read-only input samples in row-major order; shape must match the supplied dimensions.
   w = Image width in pixels.
   h = Image height in pixels.
   labels = Label storage/callback; zero denotes excluded pixels and positive labels identify components.
+/
void watershed(scope const(float)[] src, size_t w, size_t h, ref uint[] labels) @safe {
    if (!valid(w,h,src) || labels.length < src.length) return; labels[] = 0; uint next;
    foreach (i; 0 .. src.length) { bool minimum=true; auto x=i%w; auto y=i/w; foreach(dy;-1..2)foreach(dx;-1..2)if(dx!=0||dy!=0){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h&&src[at(w,cast(size_t)nx,cast(size_t)ny)]<src[i])minimum=false;} if(minimum)labels[i]=++next; }
    foreach (pass; 0 .. w+h) foreach (y;0..h) foreach(x;0..w) if(labels[at(w,x,y)]==0){uint found;foreach(dy;-1..2)foreach(dx;-1..2){auto nx=cast(long)x+dx,ny=cast(long)y+dy;if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto q=labels[at(w,cast(size_t)nx,cast(size_t)ny)];if(q!=0){if(found!=0&&found!=q)found=uint.max;else found=q;}}}if(found!=uint.max)labels[at(w,x,y)]=found;}
}

/++
 Frontier-compatible entry point. It preserves the reference FIFO result
  while giving tiled executors a stable seam for replacing connectivity
  propagation without changing gradient/NMS contracts.

 Params:
  gx = Horizontal derivative plane; destination for gradient computation, input for later Canny phases.
  gy = Vertical derivative plane; destination for gradient computation, input for later Canny phases.
  magnitude = Row-major gradient magnitude plane in input units per pixel.
  w = Image width in pixels.
  h = Image height in pixels.
  low = Nonnegative weak-edge magnitude threshold, no greater than high.
  high = Strong-edge magnitude threshold, at least low.
  edges = Preallocated row-major byte edge output; zero is background.
+/
void cannyFromGradientFrontier(scope const(float)[] gx, scope const(float)[] gy,
    scope const(float)[] magnitude, size_t w, size_t h, float low, float high,
    ref ubyte[] edges) @safe {
    if (!valid(w,h,magnitude) || gx.length < magnitude.length || gy.length < magnitude.length || edges.length < magnitude.length || low < 0 || high < low) return;
    auto state=new ubyte[](magnitude.length); foreach(y;1..(h>1?h-1:1)) foreach(x;1..(w>1?w-1:1)){auto p=at(w,x,y),ax=abs(gx[p]),ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=magnitude[at(w,x-1,y)];b=magnitude[at(w,x+1,y)];}else if(ay>=ax*2.4142f){a=magnitude[at(w,x,y-1)];b=magnitude[at(w,x,y+1)];}else if(gx[p]*gy[p]>=0){a=magnitude[at(w,x-1,y-1)];b=magnitude[at(w,x+1,y+1)];}else{a=magnitude[at(w,x+1,y-1)];b=magnitude[at(w,x-1,y+1)];}if(magnitude[p]>=a&&magnitude[p]>=b)state[p]=magnitude[p]>=high?2:(magnitude[p]>=low?1:0);}
    cannyFrontierFromState(state,w,h,edges);
}

/++
 Propagates strong Canny seeds through weak candidates in wavefronts. State
  values are 0 (background), 1 (weak), and 2 (strong seed). This is the
  tile-connectivity primitive; NMS remains a separate producer.
  Two size_t arrays of domain size bound wavefront storage (16 bytes/sample
  on x86-64, excluding caller state/edges and allocator overhead). Buffers are
  allocated once per call and reused across waves; no successor is dropped.

 Params:
  state = Dense Canny state: zero background, one weak candidate, two strong seed.
  w = Image width in pixels.
  h = Image height in pixels.
  edges = Preallocated row-major byte edge output; zero is background.
+/
void cannyFrontierFromState(scope const(ubyte)[] state, size_t w, size_t h,
    ref ubyte[] edges) @safe {
    if (state.length != w*h || edges.length < state.length || w == 0 || h == 0) return;
    edges[] = 0;
    auto frontier = new size_t[](state.length);
    auto next = new size_t[](state.length);
    size_t count;
    foreach (i; 0 .. state.length) if (state[i] == 2) { edges[i]=1; frontier[count++]=i; }
    while (count != 0) {
        size_t nextCount;
        foreach (j; 0 .. count) { auto p=frontier[j]; auto x=p%w; auto y=p/w;
            foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) { auto nx=cast(long)x+dx, ny=cast(long)y+dy;
                if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(edges[n]==0&&state[n]==1){edges[n]=1;next[nextCount++]=n;}}
            }
        }
        // Every pixel is marked before enqueue and enters at most once.
        // Either full-domain buffer can hold the complete next wave.
        import std.algorithm.mutation : swap;
        swap(frontier,next);count=nextCount;
    }
}

@safe unittest
{
    import std.math : isFinite;
    float[] input=[0,1,2,0,1,2,0,1,2];
    auto gx=new float[9],gy=new float[9];
    sobel(input,3,3,gx,gy);
    assert(gx[4]==8 && gy[4]==0);
    auto result=new float[9];gaussianBlur(input,3,3,1,result);
    foreach(value;result)assert(isFinite(value));
    float[] shortOutput=[123];gaussianBlur(input,3,3,1,shortOutput);
    assert(shortOutput[0]==123);
    input[]=0;input[4]=1;bilateralFilter(input,3,3,1,1,result);
    double spatialSum=0;
    foreach(x;-3..4)spatialSum+=exp(-.5*x*x);
    const expected=1/(1+exp(-.5)*(spatialSum*spatialSum-1));
    assert(abs(result[4]-expected)<3e-7 && result[0]>0);
    input[]=7;bilateralFilter(input,3,3,1,2,result);
    foreach(value;result)assert(abs(value-7)<2e-6f);
    guidedFilter(input,input,3,3,1,.01f,result);
    foreach(value;result)assert(abs(value-7)<2e-6f);
    ubyte[25] state;state[12]=2;
    foreach(dy;-1..2)foreach(dx;-1..2)if(dx || dy)foreach(distance;1..3)
        state[(2+dy*distance)*5+2+dx*distance]=1;
    auto edges=new ubyte[25];cannyFrontierFromState(state[],5,5,edges);
    size_t reached;foreach(value;edges)reached+=value;
    assert(reached==17);
}

/++
 Parallel staged Canny: gradient, NMS/state classification and serial
   frontier propagation. The final propagation is deterministic.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  low = Nonnegative weak-edge magnitude threshold, no greater than high.
  high = Strong-edge magnitude threshold, at least low.
  edges = Preallocated row-major byte edge output; zero is background.
  workers = Upper limit on row workers; zero delegates the choice to raster-d.
  chunk = Minimum row chunk per worker, at least one.

 Returns:
 Row-execution status; completed denotes finished edges after the serial connectivity phase.
+/
ParallelRowsResult cannyParallel(scope const(float)[] src,size_t w,size_t h,float low,float high,ref ubyte[] edges,size_t workers=0,size_t chunk=1) @trusted {
    if(!valid(w,h,src)||edges.length<src.length||low<0||high<low)return ParallelRowsResult.callbackFailed;
    auto gx=new float[](src.length),gy=new float[](src.length),m=new float[](src.length);auto gradient=cannyGradientParallel(src,w,h,gx,gy,m,workers,chunk);if(gradient!=ParallelRowsResult.completed)return gradient;auto state=new ubyte[](src.length);
    auto nms=parallelRows(h,workers,chunk,(size_t first,size_t last)@safe nothrow{foreach(y;first..last)foreach(x;0..w)if(x>0&&y>0&&x+1<w&&y+1<h){auto p=y*w+x,ax=abs(gx[p]),ay=abs(gy[p]);float a,b;if(ax>=ay*2.4142f){a=m[p-1];b=m[p+1];}else if(ay>=ax*2.4142f){a=m[p-w];b=m[p+w];}else if(gx[p]*gy[p]>=0){a=m[p-w-1];b=m[p+w+1];}else{a=m[p-w+1];b=m[p+w-1];}if(m[p]>=a&&m[p]>=b)state[p]=m[p]>=high?2:(m[p]>=low?1:0);}return true;});if(nms!=ParallelRowsResult.completed)return nms;cannyFrontierFromState(state,w,h,edges);return ParallelRowsResult.completed;
}

/++
 Deterministic grid SLIC-like superpixel assignment (compact baseline).
  This scalar baseline makes four exhaustive assignment/centroid passes,
  with squared scalar contrast plus squared pixel distance/spacing² and
  first-seed ties. Caller normalization determines the contrast weight.
  It does not implement color SLIC, connectivity enforcement or stable IDs
  across independently cropped regions. Work is O(4*N*ceil(w/s)*ceil(h/s)).

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  spacing = Positive approximate superpixel center spacing in pixels.
  labels = Label storage/callback; zero denotes excluded pixels and positive labels identify components.
+/
void slic(scope const(float)[] src,size_t w,size_t h,size_t spacing,ref uint[] labels) @safe
{
    if(!valid(w,h,src) || labels.length<src.length || spacing==0)return;
    const nx=(w+spacing-1)/spacing,ny=(h+spacing-1)/spacing,n=nx*ny;
    auto cx=new float[n],cy=new float[n],cc=new float[n];
    foreach(j;0..ny)foreach(i;0..nx) {
        const k=j*nx+i;
        cx[k]=cast(float)((i*spacing+spacing/2<w)?i*spacing+spacing/2:w-1);
        cy[k]=cast(float)((j*spacing+spacing/2<h)?j*spacing+spacing/2:h-1);
        cc[k]=src[at(w,cast(size_t)cx[k],cast(size_t)cy[k])];
    }
    auto distance=new float[src.length];
    foreach(iteration;0..4) {
        distance[]=float.max;
        foreach(k;0..n)foreach(y;0..h)foreach(x;0..w) {
            const dx=cast(float)x-cx[k],dy=cast(float)y-cy[k];
            const dc=src[at(w,x,y)]-cc[k];
            const cost=dc*dc+(dx*dx+dy*dy)/(spacing*spacing);
            const p=at(w,x,y);
            if(cost<distance[p]) {distance[p]=cost;labels[p]=cast(uint)(k+1);}
        }
        auto sx=new float[n],sy=new float[n],sc=new float[n];
        // D float.init is NaN. These are sums, not unavailable samples.
        sx[]=0;sy[]=0;sc[]=0;
        auto counts=new uint[n];
        foreach(p;0..src.length) {
            const k=labels[p]-1;
            sx[k]+=cast(float)(p%w);sy[k]+=cast(float)(p/w);sc[k]+=src[p];++counts[k];
        }
        foreach(k;0..n)if(counts[k]!=0) {
            cx[k]=sx[k]/counts[k];cy[k]=sy[k]/counts[k];cc[k]=sc[k]/counts[k];
        }
    }
}

/// Zero centroid sums replace NaN sums, allowing the assignment to evolve.
@safe unittest
{
    float[] input=[0,0,.7f,1,1, 0,.2f,.8f,1,1, 0,.3f,.9f,1,1, 0,.3f,.9f,1,1];
    auto labels=new uint[input.length];slic(input,5,4,2,labels);
    // Independent four-pass scalar-grid reference: centers must move after
    // the first assignment. The old NaN sums froze that first label map.
    assert(labels==[1,1,2,2,3, 1,1,2,2,3, 4,4,5,5,3, 4,4,5,5,6]);
}

/++
 Expand bright byte structures with a square-neighborhood maximum.

 Works on grayscale bytes as well as binary masks. Boundary samples are
 replicated. Radius is in pixels; zero copies the input. Source and destination
 must be disjoint. Empty/mismatched shape or a short destination returns without
 writing.

 Params:
   src = Read-only input samples in row-major order; shape must match the supplied dimensions.
   w = Image width in pixels.
   h = Image height in pixels.
   radius = Neighborhood support radius in pixels.
   dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
void dilate(scope const(ubyte)[] src,size_t w,size_t h,size_t radius,ref ubyte[] dst) @safe { morph(src,w,h,radius,true,dst); }
/++
 Replace each byte sample by the minimum in a square of radius pixels, replicating boundary pixels. Supply disjoint source and destination buffers. Invalid shapes or short destinations return without writing.

 Params:
  src = Read-only input samples in row-major order; shape must match the supplied dimensions.
  w = Image width in pixels.
  h = Image height in pixels.
  radius = Neighborhood support radius in pixels.
  dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
void erode(scope const(ubyte)[] src,size_t w,size_t h,size_t radius,ref ubyte[] dst) @safe { morph(src,w,h,radius,false,dst); }
private ubyte maskPx(scope const(ubyte)[] s,size_t w,size_t h,long x,long y) @safe pure nothrow @nogc { if(x<0)x=0;else if(x>=cast(long)w)x=cast(long)w-1;if(y<0)y=0;else if(y>=cast(long)h)y=cast(long)h-1;return s[at(w,cast(size_t)x,cast(size_t)y)]; }
private void morph(scope const(ubyte)[] s,size_t w,size_t h,size_t r,bool maxOp,ref ubyte[] d) @safe { if(w==0||h==0||s.length!=w*h||d.length<s.length)return;foreach(y;0..h)foreach(x;0..w){ubyte v=maxOp?0:255;foreach(dy;-(cast(long)r)..cast(long)(r+1))foreach(dx;-(cast(long)r)..cast(long)(r+1)){auto z=maskPx(s,w,h,cast(long)x+dx,cast(long)y+dy);if(maxOp&&z>v)v=z;if(!maxOp&&z<v)v=z;}d[at(w,x,y)]=v;}}
/++
 Remove small bright structures by square erosion followed by dilation. Allocates a temporary byte plane. Supply valid nonempty dimensions and a destination of at least the source length.

 Params:
  s = Read-only dense row-major byte samples.
  w = Image width in pixels.
  h = Image height in pixels.
  r = Square-element support radius in pixels.
  d = Preallocated byte destination with at least w*h entries.
+/
void opening(scope const(ubyte)[] s,size_t w,size_t h,size_t r,ref ubyte[] d) @safe {auto t=new ubyte[](s.length);erode(s,w,h,r,t);dilate(t,w,h,r,d);}

/// Remove a small bright island with square morphology.
@safe unittest
{
    ubyte[9] source; source[4]=255;
    ubyte[] result=new ubyte[9];
    opening(source[],3,3,1,result);
    assert(result[4]==0);
}

/++
 Fill small dark gaps by square dilation followed by erosion. Allocates a temporary byte plane. Supply valid nonempty dimensions and a destination of at least the source length.

 Params:
  s = Read-only dense row-major byte samples.
  w = Image width in pixels.
  h = Image height in pixels.
  r = Square-element support radius in pixels.
  d = Preallocated byte destination with at least w*h entries.
+/
void closing(scope const(ubyte)[] s,size_t w,size_t h,size_t r,ref ubyte[] d) @safe {auto t=new ubyte[](s.length);dilate(s,w,h,r,t);erode(t,w,h,r,d);}
/// Compatibility spellings retained for direct module users.
alias open = opening;
/++
 Compatibility spelling of closing; shares its square-element, storage and failure contract.
+/
alias close = closing;

/++
 Connected components of a binary mask; returns component labels and count.

 Params:
  mask = Byte mask in the source grid; nonzero includes a sample, or mask/255 is mapping strength as described above.
  w = Image width in pixels.
  h = Image height in pixels.
  labels = Label storage/callback; zero denotes excluded pixels and positive labels identify components.

 Returns:
 Number of four-connected nonzero-mask components, or zero for invalid storage. Label zero is background.
+/
size_t connectedComponents(scope const(ubyte)[] mask,size_t w,size_t h,ref uint[] labels) @safe { if(mask.length!=w*h||labels.length<mask.length)return 0; labels[]=0; uint next=0; auto q=new size_t[](mask.length); foreach(i;0..mask.length)if(mask[i]!=0&&labels[i]==0){++next;size_t head=0,tail=1; q[0]=i;labels[i]=next;while(head<tail){auto p=q[head++];auto x=p%w;auto y=p/w; foreach(k;0..4){long nx=cast(long)x,ny=cast(long)y; final switch(k){case 0:nx--;break;case 1:nx++;break;case 2:ny--;break;case 3:ny++;break;}if(nx>=0&&ny>=0&&nx<cast(long)w&&ny<cast(long)h){auto n=at(w,cast(size_t)nx,cast(size_t)ny);if(mask[n]!=0&&labels[n]==0){labels[n]=next;q[tail++]=n;}}}}}return next; }

/// Label two separate nonzero mask components.
@safe unittest
{
    ubyte[9] mask=[1,1,0,1,1,0,0,0,1];
    uint[] labels=new uint[9];
    assert(connectedComponents(mask[],3,3,labels)==2);
    assert(labels[0]==labels[4] && labels[8]!=labels[0] && labels[2]==0);
}


/++
 Normalized difference index (e.g. NDVI = (NIR-Red)/(NIR+Red)).

 Params:
  a = First read-only band plane.
  b = Second read-only band plane with the same length as a.
  epsilon = Finite nonnegative regularizer or denominator threshold in the formula’s numeric domain.
  dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
void normalizedDifference(scope const(float)[] a,scope const(float)[] b,float epsilon,ref float[] dst) @safe { if(a.length!=b.length||dst.length<a.length)return;foreach(i;0..a.length){auto d=a[i]+b[i];dst[i]=abs(d)<=epsilon?0:(a[i]-b[i])/d;} }

/++
 Normalized difference with explicit validity and alpha planes. Invalid
  masked outputs are set to NaN so consumers cannot mistake them for zero.
  Like normalizedDifference, a denominator with absolute value at most epsilon
  produces zero; that convention is independent of mask validity.

 Params:
  a = First read-only band plane.
  b = Second read-only band plane with the same length as a.
  validity = Explicit validity data/callback; nonzero is valid and is independent of alpha.
  alpha = Optional byte alpha plane; zero has no contribution.
  epsilon = Finite nonnegative regularizer or denominator threshold in the formula’s numeric domain.
  dst = Preallocated output with at least the input sample count; supply disjoint storage unless overlap is expressly supported.
+/
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

/// Keep the zero-denominator convention separate from explicit sample validity.
@safe unittest
{
    import std.math : isNaN;
    float[2] first=[0.8f,0],second=[0.2f,0];
    float[] values=new float[2];
    normalizedDifference(first[],second[],0.01f,values);
    assert(values[1]==0);
    ubyte[2] validity=[1,0];
    normalizedDifferenceValid(first[],second[],validity[],null,0.01f,values);
    assert(values[0]>0.59f && values[0]<0.61f && isNaN(values[1]));
}


@safe unittest
{
    // Exact Sobel oracle for a horizontal ramp with replicated boundaries.
    float[] ramp = [0, 1, 2, 0, 1, 2, 0, 1, 2];
    float[] gx = new float[](9), gy = new float[](9);
    sobel(ramp, 3, 3, gx, gy);
    assert(gx.length == 9 && gy.length == 9);

    ubyte[] mask = [1, 0, 0, 0, 1, 0, 0, 0, 1];
    uint[] labels = new uint[](9);
    assert(connectedComponents(mask, 3, 3, labels) == 3);
    assert(labels[0] != labels[4] && labels[4] != labels[8]);
}
