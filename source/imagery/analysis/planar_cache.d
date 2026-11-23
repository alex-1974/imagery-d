/++ Private pooled float32 feature delivery storage. Raster ownership and
independent retained subscribers are outside this synchronous borrow cache.
+/
module imagery.analysis.planar_cache;

import imagery.analysis.feature_regions : TileIdentity,Value;
import imagery.analysis.feature_worker32 : FeaturePlanes32;
import std.math : isFinite;
import std.algorithm : max;

@safe:

/// Planar cache payload and work counters. Bytes are logical owned array/index
/// capacities, including inactive reserved index slots; source and GC headers
/// are separate. Pixel payload is 15 bytes per reserved tile pixel.
struct PlanarCacheMetrics
{
    /// Current index plus cached backing capacities and conservative key strings.
    size_t retainedBytes;
    /// Largest such retained payload since the latest reservation.
    size_t peakBytes;
    /// Fully charged fixed metadata reservation.
    size_t indexBytes;
    /// Actual pixel/mask buffer allocations and same-capacity reuses.
    size_t allocations,reuses;
    /// Completed cache hits and newly committed tiles.
    size_t hits,commits;
}

/// An unreserved cache has no retained payload, commits or hits.
@safe unittest
{
    PlanarCacheMetrics empty;
    assert(empty.retainedBytes==0&&empty.indexBytes==0&&empty.commits==0&&empty.hits==0);
}

package struct PlanarTileCache
{
    private struct Entry
    {
        TileIdentity key;
        float[] pixels;
        ubyte[] masks;
        size_t capacity;
        ulong age;
        bool active;
    }
    private Entry[] entries;
    private size_t limit;
    private ulong clock;
    PlanarCacheMetrics metrics;

    void reserve(size_t maxBytes,size_t maxEntries)
    {
        if(!maxBytes||maxBytes>16*1024*1024||!maxEntries||maxEntries>4096||
            maxEntries>=maxBytes/Entry.sizeof)throw new Exception("Invalid planar cache reservation");
        auto slots=new Entry[maxEntries];
        entries=slots;limit=maxBytes;clock=0;metrics=PlanarCacheMetrics.init;
        metrics.indexBytes=slots.length*Entry.sizeof;metrics.retainedBytes=metrics.peakBytes=metrics.indexBytes;
    }
    private size_t keyBytes(scope const TileIdentity key) const nothrow @nogc
    {
        return key.identity.length+key.revision.length+key.grid.length+key.band.length+key.unit.length+
            key.parameters.length+key.metadata.spatial.crs.length+key.metadata.spatial.pixelUnit.length+
            key.metadata.resampling.policy.length+key.metadata.resampling.parentGrid.length+
            key.metadata.product.provider.length+key.metadata.product.sensor.length+key.metadata.product.acquisitionTime.length;
    }
    private FeaturePlanes32 view(return scope const ref Entry e) const nothrow @nogc
    {
        FeaturePlanes32 result;result.width=e.key.tile.width;result.height=e.key.tile.height;
        const count=result.width*result.height;
        foreach(c;0..3)result.channels[c]=e.pixels[c*e.capacity..c*e.capacity+count];
        result.validity=e.masks[0..count];result.orientationValid=e.masks[e.capacity..e.capacity+count];
        result.rangeFailure=e.masks[2*e.capacity..2*e.capacity+count];result.inputSampleBytes=double.sizeof;
        return result;
    }
    bool find(scope const TileIdentity key,out FeaturePlanes32 output) nothrow @nogc
    {
        foreach(ref entry;entries)if(entry.active&&entry.key==key) {
            output=view(entry);++metrics.hits;return true;
        }
        return false;
    }
    private size_t oldest(size_t except=size_t.max) const nothrow @nogc
    {
        size_t slot=size_t.max;
        foreach(i,ref entry;entries)if(i!=except&&entry.active&&
            (slot==size_t.max||entry.age<entries[slot].age))slot=i;
        return slot;
    }
    void store(const TileIdentity key,scope const(Value)[] values,out FeaturePlanes32 output)
    {
        if(!entries.length||values.length!=key.tile.width*key.tile.height||values.length>size_t.max/15)
            throw new Exception("Invalid planar tile/cache");
        const fresh=15*values.length+keyBytes(key);
        if(fresh>limit-metrics.indexBytes)throw new Exception("Planar tile exceeds cache payload budget");
        size_t slot=size_t.max;
        if(metrics.retainedBytes<=limit-fresh)
            foreach(i,ref entry;entries)if(!entry.active){slot=i;break;}
        if(slot==size_t.max)slot=oldest();
        if(slot==size_t.max)throw new Exception("No planar cache slot");
        auto previous=entries[slot];
        const oldBytes=previous.active?15*previous.capacity+keyBytes(previous.key):0;
        const capacity=max(previous.capacity,values.length),charge=15*capacity+keyBytes(key);
        if(charge>limit-metrics.indexBytes)throw new Exception("Planar capacity exceeds cache budget");
        // Allocate candidate owners before changing the preceding live entry.
        float[] pixels=previous.pixels;ubyte[] masks=previous.masks;
        if(capacity>previous.capacity) {pixels=new float[3*capacity];masks=new ubyte[3*capacity];++metrics.allocations;}
        else ++metrics.reuses;
        while(metrics.retainedBytes-oldBytes>limit-charge) {
            const other=oldest(slot);
            if(other==size_t.max)throw new Exception("Insufficient planar cache capacity");
            metrics.retainedBytes-=15*entries[other].capacity+keyBytes(entries[other].key);
            entries[other]=Entry.init;
        }
        foreach(i,value;values) {
            float[3] converted;bool mathematical=value.valid,representable=value.valid;
            foreach(c;0..3){mathematical&=isFinite(value.channels[c]);converted[c]=cast(float)value.channels[c];representable&=isFinite(converted[c]);}
            representable&=mathematical;
            foreach(c;0..3)pixels[c*capacity+i]=representable?converted[c]:0;
            masks[i]=cast(ubyte)representable;
            masks[capacity+i]=cast(ubyte)(representable&&value.orientationValid&&converted[0]!=0);
            masks[2*capacity+i]=cast(ubyte)(mathematical&&!representable);
        }
        if(clock==ulong.max){foreach(ref entry;entries)entry.age=0;clock=0;}
        Entry candidate;candidate.key=key;candidate.pixels=pixels;candidate.masks=masks;
        candidate.capacity=capacity;candidate.age=++clock;candidate.active=true;entries[slot]=candidate;
        metrics.retainedBytes=metrics.retainedBytes-oldBytes+charge;metrics.peakBytes=max(metrics.peakBytes,metrics.retainedBytes);
        ++metrics.commits;output=view(entries[slot]);
    }
}
