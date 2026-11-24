/++ Bounded, transactional assembly of registered straight-sRGB RGBA8 sources.

 Opt-in direct import; registration and decoding remain caller responsibilities.
 See `docs/multiresolution-mosaic.md` for the sampling and budget contracts.
+/
module imagery.mosaic.multiresolution;

import color : LinearSRgbd, SRgb8, SRgb8Decoder, makeSRgb8Decoder, toSRgb, tryToSRgb8;
import color.alpha : Alpha, Premultiplied, premultiply, unpremultiply;
import core.stdc.stdlib : free, malloc;
import imagery.mosaic.decoded_tile_mosaic : RgbaAlphaAssociation;
import imagery.mosaic.validity_policy : QualityContributor, tryQualityWeights, validQualityContributor;
import imagery.pyramid.overview_selection : OverviewLevel, OverviewSelection,
    OverviewSelectionError, trySelectOverviewLevel;
import raster : OwnedByteResource, PlaneByteLayout, RasterLease, RasterView,
    RasterPlaneWindow, WritableRasterPlaneWindow, Region2D, tryAdoptMallocResource, tryImportOwnedRaster, withPlane;
import std.algorithm : min, max;
import std.algorithm.mutation : move;

/// Explicit filter. `.init` is not a sampling policy.
enum MosaicFilter : ubyte {
    /++ No explicit policy was supplied. +/
    unspecified,
    /++ Use the nearest source pixel without numeric interpolation. +/
    nearest,
    /++ Interpolate neighboring source pixels bilinearly. +/
    bilinear,
    /++ Integrate source pixel-cell coverage for downsampling. +/
    area }
/// `ready` requires exactly one successful callback; `missing` requires none.
enum MosaicTileStatus : ubyte {
    /++ No operation has completed; this is the default sentinel. +/
    notAttempted,
    /++ The source tile is available. +/
    ready,
    /++ The source tile is absent. +/
    missing,
    /++ The source tile read failed. +/
    failed }
/// Borrowed views expire on callback return. Empty validity means all valid.
alias MosaicTileConsumer = bool delegate(scope RasterView!ubyte rgba,
    scope RasterView!ubyte validity) @safe;
/// Tile coordinates are indices, not pixel origins. Providers bound their own
/// decode memory and release borrowed storage after the synchronous callback.
alias MosaicTileReader = MosaicTileStatus delegate(size_t levelIndex,
    size_t tileX, size_t tileY, scope MosaicTileConsumer consume) @safe;
/// Fill a row block in GLOBAL target coordinates, not ROI-local coordinates.
/// Factors describe the resampled sample; imagery-d subsequently excludes NoData.
/// The same global pixel must get the same factors across block/ROI partitions.
alias MosaicQualityReader = bool delegate(size_t levelIndex, Region2D targetBlock,
    scope QualityContributor[] factors) @safe;

/// One registered image pyramid over the common extent. At most 16 sources;
/// each axis <= 2^30, tile axes <= 256. Do not mutate inputs during a call.
struct MosaicSource
{
    /// Stable source identity, revision, common registration grid identity.
    string identity, revision, grid;
    /// Explicit caller policy identity and revision, including spatial recipes.
    string qualityPolicy, qualityRevision;
    /// Finest to coarsest; every level covers exactly the same extent.
    const(OverviewLevel)[] levels;
    /// Regular tile dimensions; edge tiles are clipped to the level bounds.
    size_t tileWidth, tileHeight;
    /// Only explicitly declared straight encoded-sRGB RGBA8 is admitted.
    RgbaAlphaAssociation association;
    /// Neutral or excluded constant factors, used when qualityRead is null.
    QualityContributor quality;
    /// Synchronous tile provider, with callback-scoped storage.
    MosaicTileReader read;
    /// Optional bounded row-block policy in global target coordinates.
    MosaicQualityReader qualityRead;
}

/// Output grid, ROI and explicit resource limits. No hidden worker threads.
struct MosaicRequest
{
    /// Full target grid over the common source extent; axes <= 2^30.
    size_t targetWidth, targetHeight;
    /// Nonempty region in that grid; output owners contain only this region.
    Region2D region;
    /// Area requires reduction or identity on BOTH selected-level axes.
    MosaicFilter filter;
    /// Exact logical output storage: five bytes per ROI pixel.
    size_t maxResultBytes;
    /// Engine-owned tile and row buffers; excludes provider memory/metadata.
    size_t maxWorkBytes;
    /// Limits on source taps and provider calls, including missing tiles.
    ulong maxSourceSamples, maxTileReads;
    /// Optional synchronous polling before reads, blocks, and publication.
    bool delegate() @safe cancelled;
}

/// Immutable facts copied into the owned frame; no callbacks or input views.
struct MosaicSourceProvenance
{
    /// Caller identity and policy facts at preflight.
    string identity, revision, grid, qualityPolicy, qualityRevision;
    /// Chosen index/adequacy and exact selected grid.
    OverviewSelection selection;
    /// Dimensions over the registered common extent.
    OverviewLevel level;
    /// Regular tile shape and constant quality declaration.
    size_t tileWidth, tileHeight;
    /// Effective constant factors (spatial policies are identified separately).
    QualityContributor quality;
    /// Whether a spatial quality callback participated.
    bool spatialQuality;
}

/// Owned straight encoded-sRGB RGBA8 plus separate binary validity.
/// Copying retains the raster-d owners; use serially (non-atomic lease counts).
/// `.init` is empty, never a completed frame. Source metadata is immutable.
struct MosaicFrame
{
    /// Four RGBA planes; alpha zero always has canonical zero RGB.
    RasterLease!ubyte rgba;
    /// One plane, 0 for NoData and 1 for valid (including transparent).
    RasterLease!ubyte validity;
    /// Global target grid and its materialized ROI.
    size_t targetWidth, targetHeight;
    /// ROI origin in the full target grid.
    Region2D region;
    /// Explicit filter used for all sources.
    MosaicFilter filter;
    /// Versioned pixel-center, linear-premultiplied conditional mixture recipe.
    string recipe;
    /// Per-source selection and caller policy metadata, copied before callbacks.
    immutable(MosaicSourceProvenance)[] sources;
}

/// Measurements include failed work; reset on entry independently of publication.
struct MosaicMetrics
{
    /// Exact owned output and scratch payloads (allocator metadata excluded).
    size_t resultBytes, workBytes, tileCacheBytes;
    /// Provider calls, cache hits and positive filter taps.
    ulong tileReads, cacheHits, sourceSamples;
    /// Actual source pixels copied into tile slots (including masked pixels).
    ulong copiedPixels;
    /// Output payload newly allocated by this call (zero for reusable workspace buffers).
    size_t allocatedOutputBytes;
    /// A private display backing was reused; owned publication never reuses aliases.
    bool reusedOutput;
}

/// Completed display metadata, containing no pixel owners. Safe to retain.
struct MosaicDisplayInfo
{
    /// Global target dimensions, ROI and explicit filter.
    size_t targetWidth,targetHeight;
    /++
 Requested logical image region represented by the display result.
+/
Region2D region;
    /++
 Explicit resampling filter used for the display.
+/
MosaicFilter filter;
    /// Sampling recipe and immutable source provenance.
    string recipe;
    /++
 Source provenance contributing to the display result.
+/
immutable(MosaicSourceProvenance)[] sources;
}
/// Complete-frame visitor. Pixel views expire on return; upload or explicitly
/// copy during the callback. No raster lease or pixel owner is supplied.
alias MosaicDisplayConsumer = bool delegate(scope RasterView!ubyte rgba,
    scope RasterView!ubyte validity,MosaicDisplayInfo info) @safe;

/// Reusable private display buffer. .init is ready; copying/reentry are disabled.
/// Serial calls only. Pixel owners never escape, so reuse does not infer
/// uniqueness from writable capability (raster-d explicitly does not promise it).
/// Source pixels are read anew; this caches allocation, not image content.
struct MosaicDisplayWorkspace
{
    private MosaicFrame buffer;
    private bool busy;
    @disable this(this);
/++
     Assemble and visit a complete frame. No callback runs on assembly failure.
               Persistent owned output uses tryAssembleMosaicOwned. A false/throwing
               consumer returns readFailure/callbackException; external consumer side
               effects are the caller's responsibility. Matching source metadata is
               reused. No @nogc/nothrow promise is made for the complete operation.

     Params:
      sources = Ordered source descriptors; owners/backings remain alive throughout the operation.
      request = Validated request dimensions, policies and resource limits.
      consumer = Synchronous visitor; copy or materialize borrowed data to retain it.
      metrics = Receives work/storage diagnostics; these can change on failure.

     Returns:
     The named operation status; none denotes success. Inspect the error before using outputs.
    +/
    MosaicError tryVisit(scope const MosaicSource[] sources,
        scope ref const MosaicRequest request,scope MosaicDisplayConsumer consumer,
        out MosaicMetrics metrics) @safe
    {
        if(busy || consumer is null)return MosaicError.invalidRequest;
        busy=true;
        // Keep the active owner local across foreign callbacks. Even resetting
        // the public workspace value cannot destroy these borrowed pixels.
        auto candidate=move(buffer);
        scope(exit){move(candidate,buffer);busy=false;}
        const error=assembleCandidate!true(sources,request,candidate,metrics);
        if(error!=MosaicError.none)return error;
        try
        {
            if(request.cancelled !is null && request.cancelled())return MosaicError.cancelled;
            scope auto rgba=candidate.rgba.view(),mask=candidate.validity.view();
            return consumer(rgba,mask,MosaicDisplayInfo(candidate.targetWidth,candidate.targetHeight,
                candidate.region,candidate.filter,candidate.recipe,candidate.sources)) ? MosaicError.none : MosaicError.readFailure;
        }
        catch(Exception){return MosaicError.callbackException;}
    }
}

/// Reuse private storage while borrowing each complete frame synchronously.
@safe unittest
{
    static assert(!__traits(compiles,{MosaicDisplayWorkspace a;auto b=a;}));
    MosaicSource source;source.identity="display";source.revision="1";source.grid="grid";
    source.qualityPolicy="neutral";source.qualityRevision="1";source.quality=QualityContributor(true);
    source.association=RgbaAlphaAssociation.straight;source.tileWidth=source.tileHeight=1;
    source.levels=[OverviewLevel(1,1)];
    source.read=(size_t level,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        return MosaicTileStatus.missing;};
    auto sources=[source];MosaicRequest request;
    request.targetWidth=request.targetHeight=1;request.region=Region2D(0,0,1,1);
    request.filter=MosaicFilter.nearest;request.maxResultBytes=5;request.maxWorkBytes=4096;
    request.maxSourceSamples=request.maxTileReads=2;
    MosaicDisplayWorkspace workspace;MosaicMetrics metrics;uint visits;
    MosaicDisplayConsumer consume=(scope RasterView!ubyte rgba,scope RasterView!ubyte mask,MosaicDisplayInfo info) @safe {
        ++visits;ubyte value=255;
        assert(mask.trySample(0,0,0,value)&&value==0&&info.region==request.region);
        MosaicMetrics nested;
        assert(workspace.tryVisit(sources,request,
            (scope RasterView!ubyte a,scope RasterView!ubyte b,MosaicDisplayInfo m) @safe {return true;},
            nested)==MosaicError.invalidRequest);
        return true;
    };
    assert(workspace.tryVisit(sources,request,consume,metrics)==MosaicError.none);
    assert(visits==1&&!metrics.reusedOutput&&metrics.allocatedOutputBytes==5);
    assert(workspace.tryVisit(sources,request,consume,metrics)==MosaicError.none);
    assert(visits==2&&metrics.reusedOutput&&metrics.allocatedOutputBytes==0);
    request.cancelled=(){return true;};
    assert(workspace.tryVisit(sources,request,consume,metrics)==MosaicError.cancelled&&visits==2);
    request.cancelled=null;request.maxWorkBytes=0;
    assert(workspace.tryVisit(sources,request,consume,metrics)==MosaicError.workExceedsBudget&&visits==2);
    request.maxWorkBytes=4096;
    assert(workspace.tryVisit(sources,request,
        (scope RasterView!ubyte a,scope RasterView!ubyte b,MosaicDisplayInfo m) @safe {return false;},
        metrics)==MosaicError.readFailure);
    assert(workspace.tryVisit(sources,request,
        delegate bool(scope RasterView!ubyte a,scope RasterView!ubyte b,MosaicDisplayInfo m) @safe {throw new Exception("consumer");},
        metrics)==MosaicError.callbackException);
    assert(workspace.tryVisit(sources,request,consume,metrics)==MosaicError.none&&visits==3);
    assert(workspace.tryVisit(sources,request,
        (scope RasterView!ubyte rgba,scope RasterView!ubyte mask,MosaicDisplayInfo info) @safe {
            workspace=MosaicDisplayWorkspace.init;
            ubyte value=255;return mask.trySample(0,0,0,value)&&value==0;
        },metrics)==MosaicError.none);
}

/// Default is not success. Every failure preserves `published` and its aliases.
enum MosaicError : ubyte
{
    /++ No operation has completed; this is the default sentinel. +/
    notAttempted,
    /++ The operation completed successfully. +/
    none,
    /++ Source shape, identity or sample descriptor is invalid. +/
    invalidSource,
    /++ Request dimensions, parameters or callbacks violate the operation contract. +/
    invalidRequest,
    /++ The resampling filter is unspecified or unsupported. +/
    invalidFilter,
    /++ Source quality metadata violates the selection contract. +/
    invalidQuality,
    /++ Required retained output storage exceeds the caller’s budget. +/
    resultExceedsBudget,
    /++ Required working storage exceeds the caller’s budget. +/
    workExceedsBudget,
    /++ The configured input-sample work limit was exceeded. +/
    sampleBudgetExceeded,
    /++ The configured source-tile read limit was exceeded. +/
    tileBudgetExceeded,
    /++ A required source tile could not be read. +/
    readFailure,
    /++ A source or consumer callback threw an Exception. +/
    callbackException,
    /++ The caller requested cancellation before completion. +/
    cancelled,
    /++ Storage allocation or owned-raster construction failed. +/
    allocationFailure
}

private enum maxAxis = 1UL << 30;
private enum blockCapacity = 256;
private enum slotCount = 4;

// POD scratch only. The checked malloc slice cannot escape the private job;
// disabled copies prevent duplicate free. No pointer arithmetic reaches callers.
private struct Scratch(T)
{
    private T[] data;
    @disable this(this);
    bool allocate(size_t count) @trusted nothrow @nogc
    {
        static assert(__traits(isPOD, T));
        if (!count || count > cast(size_t)ptrdiff_t.max / T.sizeof) return false;
        auto p = cast(T*)malloc(count * T.sizeof);
        if (p is null) return false;
        data = p[0 .. count];
        data[] = T.init;
        return true;
    }
    T[] opSlice() return scope @safe nothrow @nogc { return data; }
    ~this() @trusted nothrow @nogc { free(data.ptr); }
}

// raster-d validates all layouts and owns the malloc obligation on success.
// On failure the unadopted allocation is freed here; no raw pixel access.
private bool allocateRaster(size_t width, size_t height, size_t planes,
    ref RasterLease!ubyte result) @trusted
{
    const bytes = width * height * planes; // checked by preflight
    auto p = malloc(bytes);
    if (p is null) return false;
    OwnedByteResource resource;
    if (!tryAdoptMallocResource(p, bytes, resource)) { free(p); return false; }
    PlaneByteLayout[4] layouts;
    foreach (c; 0 .. planes)
        layouts[c] = PlaneByteLayout(c, cast(ptrdiff_t)(width * planes), cast(ptrdiff_t)planes);
    return tryImportOwnedRaster!ubyte(resource, layouts[0 .. planes],
        Region2D(0, 0, width, height), result).ok;
}

private struct LinearSample
{
    double[4] channels = [0, 0, 0, 0];
    bool valid;
}

private struct CacheSlot
{
    bool occupied, missing;
    size_t source, x, y, startX, startY, width, height;
    ulong used;
}

private struct Job
{
    Scratch!ubyte tileBytes;
    CacheSlot[slotCount] slots;
    size_t slotBytes;
    Region2D footprint;
    ulong clock;
    SRgb8Decoder!double decode;

    // Millions of cache-hit taps share invariant plans within one filter loop.
    // Keep this boundary inline so those loads/divisions can be optimized in
    // context; provider misses still use the scoped callback below.
    pragma(inline, true)
    MosaicError tap(scope const MosaicSource[] sources,
        scope const MosaicSourceProvenance[] plans, scope ref const MosaicRequest request,
        size_t source, size_t x, size_t y, ref MosaicMetrics metrics,
        ref LinearSample sample) @safe
    {
        sample = LinearSample.init;
        if (metrics.sourceSamples == request.maxSourceSamples) return MosaicError.sampleBudgetExceeded;
        ++metrics.sourceSamples;
        const tw = plans[source].tileWidth, th = plans[source].tileHeight;
        const tx = x / tw, ty = y / th;
        size_t index = slotCount;
        foreach (i, slot; slots)
            if (slot.occupied && slot.source == source && slot.x == tx && slot.y == ty &&
                (slot.missing || (x>=slot.startX && x-slot.startX<slot.width &&
                    y>=slot.startY && y-slot.startY<slot.height)))
            { index = i; ++metrics.cacheHits; break; }
        if (index == slotCount)
        {
            if (request.cancelled !is null && request.cancelled()) return MosaicError.cancelled;
            if (metrics.tileReads == request.maxTileReads) return MosaicError.tileBudgetExceeded;
            index = 0;
            foreach (i, slot; slots)
            {
                if (!slot.occupied) { index = i; break; }
                if (slot.used < slots[index].used) index = i;
            }
            auto bytes = tileBytes[][index * slotBytes .. (index + 1) * slotBytes];
            const width = min(tw, plans[source].level.width - tx * tw);
            const height = min(th, plans[source].level.height - ty * th);
            const startX = max(tx*tw, footprint.x), startY = max(ty*th, footprint.y);
            const copyWidth = min(tx*tw+width, footprint.x+footprint.width)-startX;
            const copyHeight = min(ty*th+height, footprint.y+footprint.height)-startY;
            assert(copyWidth && copyHeight); // tap is inside the block footprint
            const offsetX = startX-tx*tw, offsetY = startY-ty*th;
            size_t calls;
            bool copied;
            ++metrics.tileReads;
            const status = sources[source].read(plans[source].selection.index, tx, ty,
                (scope RasterView!ubyte rgba, scope RasterView!ubyte validity) @safe {
                    ++calls;
                    if (calls != 1 || rgba.planeCount != 4 || rgba.width != width || rgba.height != height ||
                        (validity.planeCount != 0 && (validity.planeCount != 1 ||
                        validity.width != width || validity.height != height))) return false;
                    if (validity.planeCount)
                    {
                        if (!withPlane(validity, 0, (scope ref const RasterPlaneWindow!ubyte plane) @safe {
                            foreach (yy; 0 .. copyHeight) {
                                scope const row = plane.row(offsetY+yy);
                                foreach (xx; 0 .. copyWidth) bytes[5*(yy*copyWidth+xx)+4] = cast(ubyte)(row.load(offsetX+xx)!=0);
                            }
                        })) return false;
                    }
                    else foreach (p; 0 .. copyWidth*copyHeight) bytes[5*p+4] = 1;
                    // Validate each affine plane once, retaining no borrowed window.
                    // Explicit dimensions above bound every load; NoData bytes are skipped.
                    foreach (c; 0 .. 4)
                        if (!withPlane(rgba, c, (scope ref const RasterPlaneWindow!ubyte plane) @safe {
                            foreach (yy; 0 .. copyHeight) {
                                scope const row = plane.row(offsetY+yy);
                                foreach (xx; 0 .. copyWidth) {
                                    const p = 5*(yy*copyWidth+xx);
                                    bytes[p+c] = bytes[p+4] ? row.load(offsetX+xx) : 0;
                                }
                            }
                        })) return false;
                    copied = true;
                    metrics.copiedPixels += copyWidth*copyHeight;
                    return true;
                });
            if (!((status == MosaicTileStatus.ready && calls == 1 && copied) ||
                  (status == MosaicTileStatus.missing && calls == 0))) return MosaicError.readFailure;
            slots[index] = CacheSlot(true, status == MosaicTileStatus.missing, source, tx, ty,
                startX, startY, copyWidth, copyHeight, 0);
        }
        slots[index].used = ++clock;
        if (slots[index].missing) return MosaicError.none;
        const p = index * slotBytes + 5 * ((y-slots[index].startY) * slots[index].width + x-slots[index].startX);
        auto bytes = tileBytes[];
        if (!bytes[p + 4]) return MosaicError.none;
        const a = bytes[p + 3] / 255.0;
        const linear = premultiply(Alpha!LinearSRgbd(
            LinearSRgbd(decode[bytes[p]], decode[bytes[p+1]], decode[bytes[p+2]]), a));
        sample = LinearSample([linear.color.r, linear.color.g, linear.color.b, linear.alpha], true);
        return MosaicError.none;
    }

    MosaicError resample(MosaicFilter filter)(scope const MosaicSource[] sources,
        scope const MosaicSourceProvenance[] plans, scope ref const MosaicRequest request,
        size_t source, size_t x, size_t y, ref MosaicMetrics metrics,
        ref LinearSample result) @safe
    {
        result = LinearSample.init;
        const sw = plans[source].level.width, sh = plans[source].level.height;
        static if (filter == MosaicFilter.nearest)
            return tap(sources, plans, request, source,
                cast(size_t)((2UL*x+1)*sw/(2UL*request.targetWidth)),
                cast(size_t)((2UL*y+1)*sh/(2UL*request.targetHeight)), metrics, result);
        size_t x0, x1, y0, y1;
        double fx = 0, fy = 0;
        static if (filter == MosaicFilter.bilinear)
        {
            axis(x, sw, request.targetWidth, x0, x1, fx);
            axis(y, sh, request.targetHeight, y0, y1, fy);
        }
        else
        {
            x0 = cast(size_t)(cast(ulong)x*sw/request.targetWidth);
            x1 = cast(size_t)(((cast(ulong)x+1)*sw-1)/request.targetWidth);
            y0 = cast(size_t)(cast(ulong)y*sh/request.targetHeight);
            y1 = cast(size_t)(((cast(ulong)y+1)*sh-1)/request.targetHeight);
        }
        // Preflight a possibly enormous area footprint without visiting it.
        const taps = cast(ulong)(x1-x0+1)*(y1-y0+1);
        if (taps > request.maxSourceSamples-metrics.sourceSamples) return MosaicError.sampleBudgetExceeded;
        result.valid = true;
        foreach (sy; y0 .. y1+1)
        {
            if (request.cancelled !is null && request.cancelled()) return MosaicError.cancelled;
            const wy = filter == MosaicFilter.bilinear ?
                (y0 == y1 ? 1.0 : sy == y0 ? 1-fy : fy) :
                overlap(y, sh, request.targetHeight, sy);
            foreach (sx; x0 .. x1+1)
            {
                const wx = filter == MosaicFilter.bilinear ?
                    (x0 == x1 ? 1.0 : sx == x0 ? 1-fx : fx) :
                    overlap(x, sw, request.targetWidth, sx);
                LinearSample value;
                const error = tap(sources, plans, request, source, sx, sy, metrics, value);
                if (error != MosaicError.none) return error;
                if (!value.valid) { result = LinearSample.init; return MosaicError.none; }
                foreach (c; 0 .. 4) result.channels[c] += wx*wy*value.channels[c];
            }
        }
        return MosaicError.none;
    }
}

// Exact single-source nearest/identity filtering. Read each needed provider tile
// directly into the output block while its affine planes are borrowed. Sparse
// target-to-source mappings visit sampled tiles, never a huge bounding rectangle.
private MosaicError directBlock(scope const MosaicSource[] sources,
    scope const MosaicSourceProvenance[] plans,scope ref const MosaicRequest request,
    size_t left,size_t top,size_t width,size_t height,size_t stride,
    scope const(QualityContributor)[] factors,scope ubyte[] bytes,
    ref MosaicMetrics metrics) @safe
{
    size_t[256] xs;size_t[16] ys;
    foreach(x;0..width)xs[x]=cast(size_t)((2UL*(left+x)+1)*plans[0].level.width/(2UL*request.targetWidth));
    foreach(y;0..height)ys[y]=cast(size_t)((2UL*(top+y)+1)*plans[0].level.height/(2UL*request.targetHeight));
    bytes[]=0;
    const tw=plans[0].tileWidth,th=plans[0].tileHeight;
    for(size_t y0=0;y0<height;)
    {
        const ty=ys[y0]/th;size_t y1=y0+1;while(y1<height&&ys[y1]/th==ty)++y1;
        for(size_t x0=0;x0<width;)
        {
            const tx=xs[x0]/tw;size_t x1=x0+1;while(x1<width&&xs[x1]/tw==tx)++x1;
            bool needed;
            foreach(y;y0..y1)foreach(x;x0..x1)
            {
                const q=factors[y*stride+x];
                if(!q.valid||!q.coverage||!q.quality||!q.preference)continue;
                if(metrics.sourceSamples==request.maxSourceSamples)return MosaicError.sampleBudgetExceeded;
                ++metrics.sourceSamples;bytes[5*(y*stride+x)+4]=1;needed=true;
            }
            if(needed)
            {
                if(request.cancelled !is null && request.cancelled())return MosaicError.cancelled;
                if(metrics.tileReads==request.maxTileReads)return MosaicError.tileBudgetExceeded;
                ++metrics.tileReads;size_t calls;bool copied;
                const tileWidth=min(tw,plans[0].level.width-tx*tw),tileHeight=min(th,plans[0].level.height-ty*th);
                const status=sources[0].read(plans[0].selection.index,tx,ty,
                    (scope RasterView!ubyte rgba,scope RasterView!ubyte validity) @safe {
                        ++calls;
                        if(calls!=1||rgba.planeCount!=4||rgba.width!=tileWidth||rgba.height!=tileHeight||
                            (validity.planeCount && (validity.planeCount!=1||validity.width!=tileWidth||validity.height!=tileHeight)))return false;
                        if(validity.planeCount && !withPlane(validity,0,(scope ref const RasterPlaneWindow!ubyte plane) @safe {
                            foreach(y;y0..y1){scope const row=plane.row(ys[y]-ty*th);
                                foreach(x;x0..x1)if(bytes[5*(y*stride+x)+4])
                                    bytes[5*(y*stride+x)+4]=cast(ubyte)(row.load(xs[x]-tx*tw)!=0);}
                        }))return false;
                        static foreach(c;[3,0,1,2])
                        {
                            if(!withPlane(rgba,c,(scope ref const RasterPlaneWindow!ubyte plane) @safe {
                                foreach(y;y0..y1){scope const row=plane.row(ys[y]-ty*th);
                                    foreach(x;x0..x1){const p=5*(y*stride+x);
                                        if(bytes[p+4] && (c==3||bytes[p+3]))bytes[p+c]=row.load(xs[x]-tx*tw);}}
                            }))return false;
                        }
                        copied=true;return true;
                    });
                if(!((status==MosaicTileStatus.ready&&calls==1&&copied)||
                    (status==MosaicTileStatus.missing&&calls==0)))return MosaicError.readFailure;
                if(status==MosaicTileStatus.missing)
                    foreach(y;y0..y1)foreach(x;x0..x1)bytes[5*(y*stride+x)+4]=0;
            }
            x0=x1;
        }
        y0=y1;
    }
    return MosaicError.none;
}

// Exact integer coordinate arithmetic up to 2^30 per axis. Bilinear clamping
// and zero-fraction elimination prevent spurious dependencies on invalid taps.
private void axis(size_t x, size_t source, size_t target,
    out size_t low, out size_t high, out double fraction) @safe pure nothrow @nogc
{
    const denominator = 2UL*target;
    const numerator = cast(long)((2UL*x+1)*source) - cast(long)target;
    fraction = 0;
    if (numerator <= 0) { low = high = 0; return; }
    if (cast(ulong)numerator >= (source-1)*denominator) { low = high = source-1; return; }
    low = cast(size_t)(numerator/denominator);
    const remainder = numerator%denominator;
    high = low + (remainder != 0);
    fraction = cast(double)remainder/denominator;
}

private double overlap(size_t x, size_t source, size_t target, size_t sample)
    @safe pure nothrow @nogc
{
    return cast(double)(min((cast(ulong)x+1)*source, (cast(ulong)sample+1)*target) -
        max(cast(ulong)x*source, cast(ulong)sample*target))/source;
}

// Inclusive source bounds for a nonempty global target interval. The cache
// copies the intersection of this footprint and each provider tile, not rows
// that this work block cannot inspect. Sampling indices remain unchanged.
private void interval(MosaicFilter filter, size_t start, size_t count,
    size_t source, size_t target, out size_t low, out size_t high) @safe pure nothrow @nogc
{
    if (filter == MosaicFilter.nearest)
    {
        low = cast(size_t)((2UL*start+1)*source/(2UL*target));
        high = cast(size_t)((2UL*(start+count-1)+1)*source/(2UL*target));
    }
    else if (filter == MosaicFilter.bilinear)
    {
        size_t unused; double fraction;
        axis(start, source, target, low, unused, fraction);
        axis(start+count-1, source, target, unused, high, fraction);
    }
    else
    {
        low = cast(size_t)(cast(ulong)start*source/target);
        high = cast(size_t)((cast(ulong)(start+count)*source-1)/target);
    }
}

/++
 Materialize an ROI using selected overviews, four bounded tile slots and
    linear-premultiplied resampling followed by explicit N-source quality weights.

    Inputs are registered to the same caller-declared extent/grid; this operation
    performs no reprojection. Nearest uses center ties to the right; bilinear uses
    center mapping and clamped edges; area integrates exact pixel-cell overlap.
    Any positive NoData tap excludes that source sample, with no hole filling.
    Quality factors are conditional relative weights, not geometric union opacity.
    Alpha is mixed separately from validity and output is canonical straight sRGB.

    Allocation is explicit: two owned rasters, bounded malloc scratch, and O(N)
    immutable provenance. Provider decode memory is the provider's responsibility.
    Complexity is O(positive filter taps + pixels * sources + decoded tile bytes).
    Callback Exceptions return callbackException; Errors propagate. Every returned
    failure, cancellation or thrown exception leaves `published` unchanged.
    `metrics` records attempted work, including failure. Cancellation is cooperative.
    Publication happens only after the final cancellation check. No callbacks,
    source views or provider leases are retained by the result.

 Params:
  sources = Ordered source descriptors; owners/backings remain alive throughout the operation.
  request = Validated request dimensions, policies and resource limits.
  published = Output parameter; the operation-specific success and failure-state rules above apply.
  metrics = Receives work/storage diagnostics; these can change on failure.

 Returns:
 The named operation status; none denotes success. Inspect the error before using outputs.
+/
MosaicError tryAssembleMosaicOwned(scope const MosaicSource[] sources,
    scope ref const MosaicRequest request, ref MosaicFrame published,
    out MosaicMetrics metrics) @safe
{
    MosaicFrame candidate;
    const error=assembleCandidate(sources,request,candidate,metrics);
    if(error==MosaicError.none)published=candidate;
    return error;
}

private MosaicError assembleCandidate(bool privateDisplayBuffer=false)(scope const MosaicSource[] sources,
    scope ref const MosaicRequest request,ref MosaicFrame candidate,
    out MosaicMetrics metrics) @safe
{
    if (!sources.length || sources.length > 16) return MosaicError.invalidSource;
    const w = request.targetWidth, h = request.targetHeight, r = request.region;
    if (!w || !h || w>maxAxis || h>maxAxis || !r.width || !r.height ||
        r.x>w || r.y>h || r.width>w-r.x || r.height>h-r.y ||
        !request.maxSourceSamples || !request.maxTileReads) return MosaicError.invalidRequest;
    if (request.filter<MosaicFilter.nearest || request.filter>MosaicFilter.area) return MosaicError.invalidFilter;
    MosaicSourceProvenance[16] storage;
    auto plans = storage[0 .. sources.length];
    size_t tilePixels;
    foreach (i, ref source; sources)
    {
        if (!source.identity.length || !source.revision.length || !source.grid.length ||
            source.grid != sources[0].grid || !source.qualityPolicy.length || !source.qualityRevision.length ||
            !source.tileWidth || !source.tileHeight || source.tileWidth>256 || source.tileHeight>256 ||
            source.association != RgbaAlphaAssociation.straight || source.read is null)
            return MosaicError.invalidSource;
        if (!validQualityContributor(source.quality)) return MosaicError.invalidQuality;
        OverviewSelection selected;
        if (trySelectOverviewLevel(source.levels, w, h, selected) != OverviewSelectionError.none)
            return MosaicError.invalidSource;
        foreach (level; source.levels)
            if (level.width>maxAxis || level.height>maxAxis) return MosaicError.invalidSource;
        const level = source.levels[selected.index];
        if (request.filter == MosaicFilter.area && (w>level.width || h>level.height))
            return MosaicError.invalidFilter;
        plans[i] = MosaicSourceProvenance(source.identity, source.revision, source.grid,
            source.qualityPolicy, source.qualityRevision, selected, level,
            source.tileWidth, source.tileHeight, source.quality, source.qualityRead !is null);
        tilePixels = max(tilePixels, source.tileWidth*source.tileHeight);
    }
    if (r.width > cast(size_t)ptrdiff_t.max / 5 / r.height) return MosaicError.resultExceedsBudget;
    metrics.resultBytes = r.width*r.height*5;
    if (metrics.resultBytes>request.maxResultBytes) return MosaicError.resultExceedsBudget;
    const direct=sources.length==1 && (request.filter==MosaicFilter.nearest ||
        (plans[0].level.width==w && plans[0].level.height==h));
    if(direct)return renderCandidate!(privateDisplayBuffer,true,MosaicFilter.unspecified)(sources,plans,request,tilePixels,candidate,metrics);
    final switch(request.filter)
    {
        case MosaicFilter.nearest:return renderCandidate!(privateDisplayBuffer,false,MosaicFilter.nearest)(sources,plans,request,tilePixels,candidate,metrics);
        case MosaicFilter.bilinear:return renderCandidate!(privateDisplayBuffer,false,MosaicFilter.bilinear)(sources,plans,request,tilePixels,candidate,metrics);
        case MosaicFilter.area:return renderCandidate!(privateDisplayBuffer,false,MosaicFilter.area)(sources,plans,request,tilePixels,candidate,metrics);
        case MosaicFilter.unspecified:return MosaicError.invalidFilter;
    }
}

// Sampling/ownership capabilities are fixed before entering the hot worker.
// The general worker carries no per-pixel direct-display branch or byte buffer.
private MosaicError renderCandidate(bool privateDisplayBuffer,bool direct,MosaicFilter filter)(
    scope const MosaicSource[] sources,scope const MosaicSourceProvenance[] validatedPlans,
    scope ref const MosaicRequest request,size_t tilePixels,ref MosaicFrame candidate,
    ref MosaicMetrics metrics) @safe
{
    // Keep validated invariant plans local to the worker, separate from foreign
    // provider storage and writable pixel addresses.
    MosaicSourceProvenance[16] localPlans;
    auto plans=localPlans[0..validatedPlans.length];plans[]=validatedPlans[];
    const w=request.targetWidth,h=request.targetHeight,r=request.region;
    const block=min(r.width,blockCapacity),blockHeight=min(r.height,16);
    const blockPixels=block*blockHeight,count=sources.length*blockPixels;
    metrics.tileCacheBytes = direct ? 0 : slotCount*tilePixels*5;
    metrics.workBytes = metrics.tileCacheBytes + (direct?0:count*LinearSample.sizeof) +
        count*QualityContributor.sizeof + sources.length*(QualityContributor.sizeof+double.sizeof) + (direct?blockPixels*5:0) +
        (direct ? (256+16)*size_t.sizeof : 0);
    if (metrics.workBytes>request.maxWorkBytes) return MosaicError.workExceedsBudget;
    Job job;
    job.slotBytes = tilePixels*5;
    Scratch!LinearSample samples;
    Scratch!QualityContributor factors, pixelFactors;
    Scratch!double weights;
    Scratch!ubyte outputBytes;
    if ((!direct && (!job.tileBytes.allocate(metrics.tileCacheBytes) || !samples.allocate(count))) ||
        !factors.allocate(count) || !pixelFactors.allocate(sources.length) || !weights.allocate(sources.length) ||
        (direct && !outputBytes.allocate(blockPixels*5)))
        return MosaicError.allocationFailure;
    bool reusable;
    static if(privateDisplayBuffer)
    if(candidate.rgba.view().width==r.width&&candidate.rgba.view().height==r.height&&
        candidate.validity.view().width==r.width&&candidate.validity.view().height==r.height)
    {
        bool a,b;
        scope auto rgba=candidate.rgba.tryWritableView(a);
        scope auto mask=candidate.validity.tryWritableView(b);
        reusable=a&&b;
    }
    if(!reusable)
    {
        candidate=MosaicFrame.init;
        if (!allocateRaster(r.width, r.height, 4, candidate.rgba) ||
            !allocateRaster(r.width, r.height, 1, candidate.validity)) return MosaicError.allocationFailure;
        metrics.allocatedOutputBytes=metrics.resultBytes;
    }
    metrics.reusedOutput=reusable;
    candidate.targetWidth = w; candidate.targetHeight = h; candidate.region = r; candidate.filter = request.filter;
    candidate.recipe = "registered-rgba8-linear-premultiplied-conditional-v1";
    static if(privateDisplayBuffer)
    {if(candidate.sources!=plans)candidate.sources = plans.idup;}
    else candidate.sources=plans.idup;
    if(!direct)job.decode = makeSRgb8Decoder!double();
    bool writableRgba, writableMask;
    scope auto output = candidate.rgba.tryWritableView(writableRgba);
    scope auto mask = candidate.validity.tryWritableView(writableMask);
    if (!writableRgba || !writableMask) return MosaicError.allocationFailure;
    try
    {
        for (size_t top=0; top<r.height; top+=blockHeight)
        for (size_t start=0; start<r.width; start+=block)
        {
            if (request.cancelled !is null && request.cancelled()) return MosaicError.cancelled;
            const length = min(block, r.width-start);
            const height = min(blockHeight, r.height-top);
            foreach (s; 0 .. sources.length)
            {
                size_t x0,x1,y0,y1;
                interval(request.filter,r.x+start,length,plans[s].level.width,w,x0,x1);
                interval(request.filter,r.y+top,height,plans[s].level.height,h,y0,y1);
                job.footprint = Region2D(x0,y0,x1-x0+1,y1-y0+1);
                foreach (yy; 0 .. height)
                {
                    const base = s*blockPixels+yy*block;
                    auto row = factors[][base .. base+length];
                    row[] = plans[s].quality;
                    if (sources[s].qualityRead !is null && !sources[s].qualityRead(plans[s].selection.index,
                        Region2D(r.x+start, r.y+top+yy, length, 1), row)) return MosaicError.invalidQuality;
                    foreach (xx; 0 .. length)
                    {
                        if (!validQualityContributor(row[xx])) return MosaicError.invalidQuality;
                        static if(!direct)
                        {
                            samples[][base+xx] = LinearSample.init;
                            if (!row[xx].valid || !row[xx].coverage || !row[xx].quality || !row[xx].preference) continue;
                            const error = job.resample!filter(sources, plans, request, s, r.x+start+xx, r.y+top+yy,
                                metrics, samples[][base+xx]);
                            if (error != MosaicError.none) return error;
                        }
                    }
                }
            }
            if(direct)
            {
                const error=directBlock(sources,plans,request,r.x+start,r.y+top,length,height,block,
                    factors[],outputBytes[],metrics);
                if(error!=MosaicError.none)return error;
            }
            else foreach (yy; 0 .. height) foreach (xx; 0 .. length)
            {
                bool valid;
                double[4] mixed = [0, 0, 0, 0];
                if(sources.length==1)
                {
                    // One positive contributor normalizes to exactly one, even
                    // when its factor product would underflow. Rows were already
                    // schema-validated; alpha remains independent of validity.
                    const index=yy*block+xx,q=factors[][index];
                    valid=samples[][index].valid&&q.valid&&q.coverage>0&&q.quality>0&&q.preference>0;
                    if(valid)mixed=samples[][index].channels;
                }
                else
                {
                    foreach (s; 0 .. sources.length)
                    {
                        pixelFactors[][s] = factors[][s*blockPixels+yy*block+xx];
                        pixelFactors[][s].valid &= samples[][s*blockPixels+yy*block+xx].valid;
                    }
                    valid = tryQualityWeights(pixelFactors[], weights[]);
                    if (valid) foreach (s; 0 .. sources.length)
                        foreach (c; 0 .. 4) mixed[c] += weights[][s]*samples[][s*blockPixels+yy*block+xx].channels[c];
                }
                // Convex LDR arithmetic can round outside [0,alpha] by ulps.
                mixed[3] = min(1.0, max(0.0, mixed[3]));
                const alpha = cast(ubyte)(mixed[3]*255+0.5);
                SRgb8 encoded = SRgb8(0, 0, 0);
                if (alpha)
                {
                    foreach (c; 0 .. 3) mixed[c] = min(mixed[3], max(0.0, mixed[c]));
                    const straight = unpremultiply(Premultiplied!LinearSRgbd(
                        LinearSRgbd(mixed[0], mixed[1], mixed[2]), mixed[3]));
                    if (!tryToSRgb8(straight.color.toSRgb, encoded)) return MosaicError.readFailure;
                }
                const ubyte[4] bytes = [encoded.r, encoded.g, encoded.b, alpha];
                foreach(c;0..4)
                    if(!output.trySetSample(c,start+xx,top+yy,bytes[c]))return MosaicError.readFailure;
                if(!mask.trySetSample(0,start+xx,top+yy,cast(ubyte)valid))return MosaicError.readFailure;
            }
            // Validate each destination plane once per block. Stores remain
            // scoped raster-d operations; no writable pointer escapes.
            if(direct)foreach (c; 0 .. 5)
            {
                auto writeBlock = (scope ref WritableRasterPlaneWindow!ubyte plane) @safe nothrow @nogc {
                    foreach (yy; 0 .. height)
                    {
                        scope auto row = plane.row(top+yy);
                        foreach (xx; 0 .. length)
                            row.store(start+xx, outputBytes[][5*(yy*block+xx)+c]);
                    }
                };
                if (c<4 ? !withPlane(output,c,writeBlock) : !withPlane(mask,0,writeBlock))
                    return MosaicError.readFailure;
            }
        }
        if (request.cancelled !is null && request.cancelled()) return MosaicError.cancelled;
    }
    catch (Exception) { return MosaicError.callbackException; }
    return MosaicError.none;
}

/// Missing tiles publish explicit NoData, independently of transparent pixels.
@safe unittest
{
    MosaicSource source;
    source.identity="orthophoto"; source.revision="1"; source.grid="extent-1";
    source.qualityPolicy="explicit-neutral"; source.qualityRevision="1";
    source.levels=[OverviewLevel(1,1)]; source.tileWidth=source.tileHeight=1;
    source.association=RgbaAlphaAssociation.straight;
    source.quality=QualityContributor(true);
    source.read=(size_t level,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        return MosaicTileStatus.missing;
    };
    MosaicRequest request;
    request.targetWidth=request.targetHeight=1;
    request.region=Region2D(0,0,1,1); request.filter=MosaicFilter.nearest;
    request.maxResultBytes=5; request.maxWorkBytes=4096;
    request.maxSourceSamples=request.maxTileReads=1;
    MosaicFrame frame; MosaicMetrics metrics;
    assert(tryAssembleMosaicOwned([source],request,frame,metrics)==MosaicError.none);
    ubyte validity=255;
    assert(frame.validity.view().trySample(0,0,0,validity) && validity==0);
    assert(metrics.resultBytes==5 && metrics.tileReads==1);
}

// Invalid requests never call the provider or replace an existing frame.
@safe unittest
{
    MosaicFrame frame;
    MosaicRequest request;
    MosaicMetrics metrics;
    assert(tryAssembleMosaicOwned(null, request, frame, metrics) == MosaicError.invalidSource);
    assert(frame.rgba.view().planeCount == 0 && metrics.tileReads == 0);
}

@safe pure nothrow @nogc unittest
{
    size_t low, high; double fraction;
    axis(0, 7, 7, low, high, fraction);
    assert(low == 0 && high == 0 && fraction == 0);
    axis(1, 7, 7, low, high, fraction);
    assert(low == 1 && high == 1 && fraction == 0);
    axis(2, 7, 3, low, high, fraction);
    assert(low == 5 && high == 6 && fraction>0.333333333333 && fraction<0.333333333334);
    assert(overlap(0, 7, 3, 0) == 3.0/7);
    axis((1UL<<30)-1, 1UL<<30, 1UL<<30, low, high, fraction);
    assert(low == (1UL<<30)-1 && low == high && fraction == 0);
}

@safe unittest
{
    RasterLease!ubyte pixels;assert(allocateRaster(1,1,4,pixels));
    {
        bool ok;scope auto view=pixels.tryWritableView(ok);assert(ok);
        foreach(c,value;[cast(ubyte)17,26,98,255])assert(view.trySetSample(c,0,0,cast(ubyte)value));
    }
    MosaicSource source;source.identity="underflow";source.revision="1";source.grid="grid";
    source.qualityPolicy="positive-single";source.qualityRevision="1";
    source.quality=QualityContributor(true,1e-300,1e-300,1e300);
    source.association=RgbaAlphaAssociation.straight;source.levels=[OverviewLevel(1,1)];
    source.tileWidth=source.tileHeight=1;
    source.read=(size_t level,size_t x,size_t y,scope MosaicTileConsumer consume) @safe {
        scope auto view=pixels.view();
        return consume(view,RasterView!ubyte.init)?MosaicTileStatus.ready:MosaicTileStatus.failed;};
    MosaicRequest request;request.targetWidth=request.targetHeight=2;
    request.region=Region2D(0,0,2,2);request.filter=MosaicFilter.bilinear;
    request.maxResultBytes=20;request.maxWorkBytes=4096;request.maxSourceSamples=4;request.maxTileReads=4;
    MosaicFrame frame;MosaicMetrics metrics;
    assert(tryAssembleMosaicOwned([source],request,frame,metrics)==MosaicError.none);
    foreach(y;0..2)foreach(x;0..2){ubyte value;
        assert(frame.rgba.view().trySample(0,x,y,value)&&value==17);
        assert(frame.validity.view().trySample(0,x,y,value)&&value==1);}
}
