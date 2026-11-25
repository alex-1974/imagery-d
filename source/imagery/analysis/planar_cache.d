/++
Report allocation and reuse of the region engine's private planar cache. Read
`PlanarCacheMetrics` through the engine to distinguish buffer allocation,
reuse and cache hits. The cache does not account for independently retained
output owners.
+/
module imagery.analysis.planar_cache;

import imagery.analysis.feature_regions : TileIdentity,Value;
import imagery.analysis.feature_worker32 : FeaturePlanes32;
import std.math : isFinite;
import std.algorithm : max;
import std.array : minimallyInitializedArray;

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
    /// Number of pixel/mask buffer allocations.
    size_t allocations;
    /// Number of same-capacity pixel/mask buffer reuses.
    size_t reuses;
    /// Number of completed cache hits.
    size_t hits;
    /// Number of newly committed tiles.
    size_t commits;
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
        float[][3] planes;
        ubyte[] valid,oriented,range;
        bool exchanged;
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
        if(e.exchanged) {
            foreach(c;0..3)result.channels[c]=e.planes[c][0..count];
            result.validity=e.valid[0..count];result.orientationValid=e.oriented[0..count];result.rangeFailure=e.range[0..count];
        } else {
            foreach(c;0..3)result.channels[c]=e.pixels[c*e.capacity..c*e.capacity+count];
            result.validity=e.masks[0..count];result.orientationValid=e.masks[e.capacity..e.capacity+count];
            result.rangeFailure=e.masks[2*e.capacity..2*e.capacity+count];
        }
        result.inputSampleBytes=double.sizeof;
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
    private Entry beginWrite(const TileIdentity key,size_t count,out size_t slot)
    {
        if(!entries.length||count!=key.tile.width*key.tile.height||count>size_t.max/15)
            throw new Exception("Invalid planar tile/cache");
        const fresh=15*count+keyBytes(key);
        if(fresh>limit-metrics.indexBytes)throw new Exception("Planar tile exceeds cache payload budget");
        slot=size_t.max;
        if(metrics.retainedBytes<=limit-fresh)
            foreach(i,ref entry;entries)if(!entry.active){slot=i;break;}
        if(slot==size_t.max)slot=oldest();
        if(slot==size_t.max)throw new Exception("No planar cache slot");
        auto previous=entries[slot];
        const oldBytes=previous.active?15*previous.capacity+keyBytes(previous.key):0;
        const capacity=max(previous.capacity,count),charge=15*capacity+keyBytes(key);
        if(charge>limit-metrics.indexBytes)throw new Exception("Planar capacity exceeds cache budget");
        // Allocate candidate owners before changing the preceding live entry.
        float[] pixels=previous.pixels;ubyte[] masks=previous.masks;
        if(capacity>previous.capacity||pixels.length<3*capacity||masks.length<3*capacity) {pixels=new float[3*capacity];masks=new ubyte[3*capacity];++metrics.allocations;}
        else ++metrics.reuses;
        while(metrics.retainedBytes-oldBytes>limit-charge) {
            const other=oldest(slot);
            if(other==size_t.max)throw new Exception("Insufficient planar cache capacity");
            metrics.retainedBytes-=15*entries[other].capacity+keyBytes(entries[other].key);
            entries[other]=Entry.init;
        }
        Entry candidate;candidate.pixels=pixels;candidate.masks=masks;candidate.capacity=capacity;
        return candidate;
    }
    private void finishWrite(const TileIdentity key,size_t slot,Entry candidate,out FeaturePlanes32 output)
    {
        const oldBytes=entries[slot].active?15*entries[slot].capacity+keyBytes(entries[slot].key):0;
        const charge=15*candidate.capacity+keyBytes(key);
        if(clock==ulong.max){foreach(ref entry;entries)entry.age=0;clock=0;}
        candidate.key=key;candidate.age=++clock;candidate.active=true;entries[slot]=candidate;
        metrics.retainedBytes=metrics.retainedBytes-oldBytes+charge;
        metrics.peakBytes=max(metrics.peakBytes,metrics.retainedBytes);++metrics.commits;
        output=view(entries[slot]);
    }
    void store(const TileIdentity key,scope const(Value)[] values,out FeaturePlanes32 output)
    {
        size_t slot;auto candidate=beginWrite(key,values.length,slot);
        auto pixels=candidate.pixels;auto masks=candidate.masks;const capacity=candidate.capacity;
        foreach(i,value;values) {
            float[3] converted;bool mathematical=value.valid,representable=value.valid;
            foreach(c;0..3){mathematical&=isFinite(value.channels[c]);converted[c]=cast(float)value.channels[c];representable&=isFinite(converted[c]);}
            representable&=mathematical;
            foreach(c;0..3)pixels[c*capacity+i]=representable?converted[c]:0;
            masks[i]=cast(ubyte)representable;
            masks[capacity+i]=cast(ubyte)(representable&&value.orientationValid&&converted[0]!=0);
            masks[2*capacity+i]=cast(ubyte)(mathematical&&!representable);
        }
        finishWrite(key,slot,candidate,output);
    }
    // Direct final publication has already applied the shared numeric/mask
    // policy. Copy every channel/mask without re-creating Value records.
    void storePlanes(const TileIdentity key,scope FeaturePlanes32 values,out FeaturePlanes32 output)
    {
        if(!values.width||!values.height||values.width!=key.tile.width||values.height!=key.tile.height||values.width>size_t.max/values.height)
            throw new Exception("Invalid planar result extent");
        const count=values.width*values.height;
        foreach(c;0..3)if(values.channels[c].length!=count)throw new Exception("Invalid planar channel");
        if(values.validity.length!=count||values.orientationValid.length!=count||values.rangeFailure.length!=count)
            throw new Exception("Invalid planar masks");
        size_t slot;auto candidate=beginWrite(key,count,slot);const capacity=candidate.capacity;
        foreach(c;0..3)candidate.pixels[c*capacity..c*capacity+count]=values.channels[c];
        candidate.masks[0..count]=values.validity;
        candidate.masks[capacity..capacity+count]=values.orientationValid;
        candidate.masks[2*capacity..2*capacity+count]=values.rangeFailure;
        finishWrite(key,slot,candidate,output);
    }

    // Transfer complete private producer arrays into one cache entry. Return
    // an equally sized evicted/spare backing to the producer instead of
    // copying pixels. Only Engine-owned arrays may enter this internal API.
    // All validation/allocation precedes the nonthrowing ownership commit.
    // Returned spare contents are unspecified: the producer initializes the
    // complete active extent before rendering/publication. Avoid redundant
    // NaN/zero fills here; Float32TileOutput.initialize performs that write.
    void exchange(const TileIdentity key,ref float[][3] planes,ref ubyte[] valid,
        ref ubyte[] oriented,ref ubyte[] range,out FeaturePlanes32 output)
    {
        if(!key.tile.width||!key.tile.height||key.tile.width>size_t.max/key.tile.height)
            throw new Exception("Invalid planar exchange extent");
        const capacity=planes[0].length,count=key.tile.width*key.tile.height;
        if(!entries.length||!capacity||!count||count>capacity||capacity>size_t.max/15||
            planes[1].length!=capacity||planes[2].length!=capacity||
            valid.length!=capacity||oriented.length!=capacity||range.length!=capacity)
            throw new Exception("Invalid complete planar producer buffers");
        const charge=15*capacity+keyBytes(key);
        if(charge>limit-metrics.indexBytes)throw new Exception("Planar producer exceeds cache budget");
        size_t slot=size_t.max;
        if(metrics.retainedBytes<=limit-charge)
            foreach(i,ref entry;entries)if(!entry.active){slot=i;break;}
        if(slot==size_t.max)slot=oldest();
        if(slot==size_t.max)throw new Exception("No planar exchange slot");
        auto previous=entries[slot];
        float[][3] sparePlanes;ubyte[] spareValid,spareOriented,spareRange;
        if(previous.active&&previous.capacity==capacity) {
            if(previous.exchanged) {
                sparePlanes=previous.planes;spareValid=previous.valid;
                spareOriented=previous.oriented;spareRange=previous.range;
            } else {
                foreach(c;0..3)sparePlanes[c]=previous.pixels[c*capacity..(c+1)*capacity];
                spareValid=previous.masks[0..capacity];spareOriented=previous.masks[capacity..2*capacity];
                spareRange=previous.masks[2*capacity..3*capacity];
            }
            ++metrics.reuses;
        } else {
            // Both element types have no indirections. Phobos' safe allocator
            // preserves memory safety; no spare byte is exposed before the
            // producer initializes its active output extent.
            auto pixels=minimallyInitializedArray!(float[])(3*capacity);
            auto masks=minimallyInitializedArray!(ubyte[])(3*capacity);
            foreach(c;0..3)sparePlanes[c]=pixels[c*capacity..(c+1)*capacity];
            spareValid=masks[0..capacity];spareOriented=masks[capacity..2*capacity];spareRange=masks[2*capacity..3*capacity];
            ++metrics.allocations;
        }
        const oldBytes=previous.active?15*previous.capacity+keyBytes(previous.key):0;
        while(metrics.retainedBytes-oldBytes>limit-charge) {
            const other=oldest(slot);assert(other!=size_t.max);
            metrics.retainedBytes-=15*entries[other].capacity+keyBytes(entries[other].key);
            entries[other]=Entry.init;
        }
        Entry candidate;candidate.capacity=capacity;candidate.exchanged=true;
        candidate.planes=planes;candidate.valid=valid;candidate.oriented=oriented;candidate.range=range;
        finishWrite(key,slot,candidate,output);
        planes=sparePlanes;valid=spareValid;oriented=spareOriented;range=spareRange;
    }
}

@safe unittest
{
    import raster : Region2D;
    import std.exception : assertThrown;
    PlanarTileCache cache;cache.reserve(1024*1024,2);
    TileIdentity key;key.identity="exchange";key.revision="1";key.tile=Region2D(0,0,3,2);
    float[][3] planes;foreach(ref p;planes){p=new float[16];p[]=.25f;}
    auto valid=new ubyte[16],oriented=new ubyte[16],range=new ubyte[16];valid[]=1;
    FeaturePlanes32 published;
    cache.exchange(key,planes,valid,oriented,range,published);
    assert(published.channels[0][5]==.25f&&published.validity[5]==1);
    foreach(ref p;planes)p[]=.75f;
    valid[]=255;oriented[]=255;range[]=255;
    assert(cache.find(key,published)&&published.channels[0][5]==.25f);
    assert(published.validity[5]==1&&published.orientationValid[5]==0&&published.rangeFailure[5]==0);
    const before=cache.metrics;
    auto invalid=key;invalid.tile.width=size_t.max;
    assertThrown!Exception(cache.exchange(invalid,planes,valid,oriented,range,published));
    assert(cache.metrics.commits==before.commits&&cache.metrics.retainedBytes==before.retainedBytes);
    assert(cache.find(key,published)&&published.channels[0][5]==.25f);
    valid[]=1;oriented[]=1;range[]=0;
    key.revision="2";cache.exchange(key,planes,valid,oriented,range,published);
    assert(published.channels[0][5]==.75f);
    assert(published.validity[5]==1&&published.orientationValid[5]==1&&published.rangeFailure[5]==0);
    foreach(ref p;planes)p[]=.5f;valid[]=1;oriented[]=0;range[]=0;
    key.revision="3";cache.exchange(key,planes,valid,oriented,range,published);
    assert(cache.metrics.commits==3&&cache.metrics.reuses>0);
}
