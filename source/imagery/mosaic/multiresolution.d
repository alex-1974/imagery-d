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
    RasterPlaneWindow, Region2D, tryAdoptMallocResource, tryImportOwnedRaster, withPlane;
import std.algorithm : min, max;

/// Explicit filter. `.init` is not a sampling policy.
enum MosaicFilter : ubyte { unspecified, nearest, bilinear, area }
/// `ready` requires exactly one successful callback; `missing` requires none.
enum MosaicTileStatus : ubyte { notAttempted, ready, missing, failed }
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
}

/// Default is not success. Every failure preserves `published` and its aliases.
enum MosaicError : ubyte
{
    notAttempted, none, invalidSource, invalidRequest, invalidFilter,
    invalidQuality, resultExceedsBudget, workExceedsBudget,
    sampleBudgetExceeded, tileBudgetExceeded, readFailure, callbackException,
    cancelled, allocationFailure
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

    MosaicError resample(scope const MosaicSource[] sources,
        scope const MosaicSourceProvenance[] plans, scope ref const MosaicRequest request,
        size_t source, size_t x, size_t y, ref MosaicMetrics metrics,
        ref LinearSample result) @safe
    {
        result = LinearSample.init;
        const sw = plans[source].level.width, sh = plans[source].level.height;
        if (request.filter == MosaicFilter.nearest)
            return tap(sources, plans, request, source,
                cast(size_t)((2UL*x+1)*sw/(2UL*request.targetWidth)),
                cast(size_t)((2UL*y+1)*sh/(2UL*request.targetHeight)), metrics, result);
        size_t x0, x1, y0, y1;
        double fx = 0, fy = 0;
        if (request.filter == MosaicFilter.bilinear)
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
            const wy = request.filter == MosaicFilter.bilinear ?
                (y0 == y1 ? 1.0 : sy == y0 ? 1-fy : fy) :
                overlap(y, sh, request.targetHeight, sy);
            foreach (sx; x0 .. x1+1)
            {
                const wx = request.filter == MosaicFilter.bilinear ?
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

/++ Materialize an ROI using selected overviews, four bounded tile slots and
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
+/
MosaicError tryAssembleMosaicOwned(scope const MosaicSource[] sources,
    scope ref const MosaicRequest request, ref MosaicFrame published,
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
    const block = min(r.width, blockCapacity), blockHeight = min(r.height, 16);
    const blockPixels = block*blockHeight, count = sources.length*blockPixels;
    metrics.tileCacheBytes = slotCount*tilePixels*5;
    metrics.workBytes = metrics.tileCacheBytes + count*LinearSample.sizeof +
        count*QualityContributor.sizeof + sources.length*(QualityContributor.sizeof+double.sizeof);
    if (metrics.workBytes>request.maxWorkBytes) return MosaicError.workExceedsBudget;
    Job job;
    job.slotBytes = tilePixels*5;
    Scratch!LinearSample samples;
    Scratch!QualityContributor factors, pixelFactors;
    Scratch!double weights;
    if (!job.tileBytes.allocate(metrics.tileCacheBytes) || !samples.allocate(count) ||
        !factors.allocate(count) || !pixelFactors.allocate(sources.length) || !weights.allocate(sources.length))
        return MosaicError.allocationFailure;
    MosaicFrame candidate;
    if (!allocateRaster(r.width, r.height, 4, candidate.rgba) ||
        !allocateRaster(r.width, r.height, 1, candidate.validity)) return MosaicError.allocationFailure;
    candidate.targetWidth = w; candidate.targetHeight = h; candidate.region = r; candidate.filter = request.filter;
    candidate.recipe = "registered-rgba8-linear-premultiplied-conditional-v1";
    candidate.sources = plans.idup;
    job.decode = makeSRgb8Decoder!double();
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
                        samples[][base+xx] = LinearSample.init;
                        if (!row[xx].valid || !row[xx].coverage || !row[xx].quality || !row[xx].preference) continue;
                        const error = job.resample(sources, plans, request, s, r.x+start+xx, r.y+top+yy,
                            metrics, samples[][base+xx]);
                        if (error != MosaicError.none) return error;
                    }
                }
            }
            foreach (yy; 0 .. height) foreach (xx; 0 .. length)
            {
                foreach (s; 0 .. sources.length)
                {
                    pixelFactors[][s] = factors[][s*blockPixels+yy*block+xx];
                    pixelFactors[][s].valid &= samples[][s*blockPixels+yy*block+xx].valid;
                }
                const valid = tryQualityWeights(pixelFactors[], weights[]);
                double[4] mixed = [0, 0, 0, 0];
                if (valid) foreach (s; 0 .. sources.length)
                    foreach (c; 0 .. 4) mixed[c] += weights[][s]*samples[][s*blockPixels+yy*block+xx].channels[c];
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
                foreach (c; 0 .. 4)
                    if (!output.trySetSample(c, start+xx, top+yy, bytes[c])) return MosaicError.readFailure;
                if (!mask.trySetSample(0, start+xx, top+yy, cast(ubyte)valid)) return MosaicError.readFailure;
            }
        }
        if (request.cancelled !is null && request.cancelled()) return MosaicError.cancelled;
    }
    catch (Exception) { return MosaicError.callbackException; }
    published = candidate;
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
