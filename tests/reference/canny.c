/* MIT. Independent benchmark reference, not a production dependency.
 * Float Sobel in row-major stencil order, replicated boundary, inclusive
 * four-sector suppression, eight-connected global hysteresis. No smoothing.
 * Caller provides all scratch; no allocation occurs in the measured region.
 */
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <float.h>

int imagery_canny_reference(const float *src, size_t w, size_t h,
                            float low, float high, uint8_t *out,
                            float *mag, float *thin, uint8_t *direction,
                            uint8_t *edges, uint32_t *stack) {
    if (!w || !h || w > UINT32_MAX / h || !isfinite(low) ||
        !isfinite(high) || low < 0 || high < low) return 0;
    const size_t n = w*h;
    int bounded=1;
    for (size_t p=0; p<n; ++p) {
        if (!isfinite(src[p])) return 0;
        if (fabsf(src[p])>FLT_MAX/32) bounded=0;
    }
    static const int sx[9]={-1,0,1,-2,0,2,-1,0,1};
    static const int sy[9]={-1,-2,-1,0,0,0,1,2,1};
    for (size_t y=0; y<h; ++y) for (size_t x=0; x<w; ++x) {
        float dx=0, dy=0;
        if (bounded && x>0 && x+1<w) {
            const float *a=src+(y?y-1:0)*w, *b=src+y*w, *c=src+(y+1<h?y+1:y)*w;
            dx=-a[x-1]; dx+=a[x+1]; dx-=2*b[x-1]; dx+=2*b[x+1]; dx-=c[x-1]; dx+=c[x+1];
            dy=-a[x-1]; dy-=2*a[x]; dy-=a[x+1]; dy+=c[x-1]; dy+=2*c[x]; dy+=c[x+1];
        } else for (int j=0; j<3; ++j) {
            ptrdiff_t yy=(ptrdiff_t)y+j-1;
            if (yy<0) yy=0; else if ((size_t)yy>=h) yy=h-1;
            for (int i=0; i<3; ++i) {
                ptrdiff_t xx=(ptrdiff_t)x+i-1;
                if (xx<0) xx=0; else if ((size_t)xx>=w) xx=w-1;
                const float v=src[(size_t)yy*w+(size_t)xx];
                dx += v*sx[j*3+i]; dy += v*sy[j*3+i];
            }
        }
        const size_t p=y*w+x;
        mag[p]=sqrtf(dx*dx+dy*dy);
        const float ax=fabsf(dx), ay=fabsf(dy);
        direction[p]= ax>=ay*2.4142f ? 0 : ay>=ax*2.4142f ? 1 : dx*dy>=0 ? 2 : 3;
        thin[p]=NAN; edges[p]=0;
    }
    for (size_t y=1; y+1<h; ++y) for (size_t x=1; x+1<w; ++x) {
        const size_t p=y*w+x;
        const ptrdiff_t delta=direction[p]==0 ? 1 : direction[p]==1 ? (ptrdiff_t)w :
                              direction[p]==2 ? (ptrdiff_t)w+1 : (ptrdiff_t)w-1;
        if (mag[p]>=mag[p-delta] && mag[p]>=mag[p+delta]) thin[p]=mag[p];
    }
    /* Stack order differs deliberately from D's FIFO. Reachable sets agree. */
    size_t used=0;
    for (size_t p=0; p<n; ++p) if (thin[p]>=high) { edges[p]=1; stack[used++]=p; }
    while (used) {
        const size_t p=stack[--used], x=p%w, y=p/w;
        for (int j=-1; j<=1; ++j) for (int i=-1; i<=1; ++i) {
            const ptrdiff_t xx=(ptrdiff_t)x+i, yy=(ptrdiff_t)y+j;
            if (xx<0 || yy<0 || (size_t)xx>=w || (size_t)yy>=h) continue;
            const size_t q=(size_t)yy*w+(size_t)xx;
            if (!edges[q] && thin[q]>=low) { edges[q]=1; stack[used++]=q; }
        }
    }
    memcpy(out,edges,n);
    return 1;
}
