module owned_generation_delivery;

// Issue #74: research-only bounded MULTI-GENERATION control plane.
// raster-d RasterLease alone owns and retains the physical pixels;
// this GC-managed record tracks DELIVERY participants and byte charges.
// No resource-bearing structs in GC containers, no unqualified copies.
// Not atomic/thread safe; not a public imagery or raster-d API.
import color : SRgba8;
import raster : RasterLease;
import owned_payload_budget : OwnedPayloadPlan;

enum GenerationPhase : ubyte { vacant, reserved, delivered }

private struct GenerationRecord
{
    size_t id;
    size_t cacheSlot;
    GenerationPhase phase;
    size_t charged;
    size_t deliveredCharge;
    size_t subscribers;
    bool cacheHeld;
}

// Three independent generations, even when all belong to SAME cache slot.
// Metadata capacity bounded structurally: a single GC accounting object
// owns exactly three records and no raster storage.
final class GenerationAccounting
{
    private size_t capacity_;
    private size_t charged_;
    private size_t nextId_ = 1;
    private GenerationRecord[3] records_;

    this(size_t capacity) @safe { capacity_ = capacity; }

    size_t charged() const @safe { return charged_; }
    size_t capacity() const @safe { return capacity_; }

    size_t active() const @safe
    {
        size_t n;
        foreach (record; records_)
            if (record.phase != GenerationPhase.vacant) ++n;
        return n;
    }

    size_t subscribers(size_t id) const @safe
    {
        foreach (record; records_)
            if (record.id == id && record.phase != GenerationPhase.vacant)
                return record.subscribers;
        return 0;
    }

    GenerationPhase phase(size_t id) const @safe
    {
        foreach (record; records_)
            if (record.id == id && record.phase != GenerationPhase.vacant)
                return record.phase;
        return GenerationPhase.vacant;
    }

private:
    GenerationRecord* find(size_t id) @safe
    {
        if (id == 0) return null;
        foreach (ref record; records_)
            if (record.phase != GenerationPhase.vacant && record.id == id)
                return &record;
        return null;
    }

    // Credit is refunded only after the last genuine raster-d lease in
    // this closed-world delivery model has been dropped.
    void maybeRefund(size_t id) @safe
    {
        auto record = find(id);
        if (record is null || record.phase != GenerationPhase.delivered ||
            record.cacheHeld || record.subscribers != 0)
            return;
        assert(record.charged <= charged_);
        charged_ -= record.charged;
        *record = GenerationRecord.init;
    }

    bool reserve(size_t slot, OwnedPayloadPlan plan,
        size_t peakMetadata, size_t retainedMetadata,
        out size_t id) @safe
    {
        // Never trust a caller-built undersized payload plan: the exact
        // four-channel + packed scratch semantics are 8N peak, 4N retained.
        if (plan.pixels > size_t.max / 8 ||
            plan.fourPlaneBytes != plan.pixels * 4 ||
            plan.packedBytes != plan.pixels * 4 ||
            plan.retainedPayloadBytes != plan.pixels * 4 ||
            plan.peakPayloadBytes != plan.pixels * 8)
            return false;
        if (slot >= 2 || plan.pixels == 0 ||
            plan.retainedPayloadBytes == 0 ||
            plan.peakPayloadBytes < plan.retainedPayloadBytes ||
            peakMetadata < retainedMetadata ||
            plan.peakPayloadBytes > size_t.max - peakMetadata ||
            plan.retainedPayloadBytes > size_t.max - retainedMetadata ||
            nextId_ == size_t.max)
            return false;
        const size_t peak = plan.peakPayloadBytes + peakMetadata;
        const size_t delivered = plan.retainedPayloadBytes + retainedMetadata;
        if (delivered > peak || charged_ > capacity_ ||
            peak > capacity_ - charged_)
            return false;
        foreach (ref record; records_)
        {
            if (record.phase == GenerationPhase.vacant)
            {
                id = nextId_++;
                record = GenerationRecord(id, slot, GenerationPhase.reserved,
                    peak, delivered, 0, false);
                charged_ += peak;
                return true;
            }
        }
        return false; // bounded metadata exhausted even if bytes remain.
    }

    bool abort(size_t id) @safe
    {
        auto record = find(id);
        if (record is null || record.phase != GenerationPhase.reserved ||
            record.cacheHeld || record.subscribers != 0 ||
            record.charged > charged_)
            return false;
        charged_ -= record.charged;
        *record = GenerationRecord.init;
        return true;
    }

    bool publish(size_t id, size_t slot) @safe
    {
        auto record = find(id);
        if (record is null || record.phase != GenerationPhase.reserved ||
            record.cacheSlot != slot || record.cacheHeld ||
            record.deliveredCharge > record.charged ||
            record.charged > charged_)
            return false;
        charged_ -= record.charged - record.deliveredCharge;
        record.charged = record.deliveredCharge;
        record.cacheHeld = true;
        record.phase = GenerationPhase.delivered;
        return true;
    }
}

// A delivery is a MOVE-ONLY value, holding its own independent physical
// backing lease AND an accounting generation ID in a GC metadata record.
struct GenerationDelivery
{
    @disable this(this);
private:
    GenerationAccounting account_;
    size_t id_;
    RasterLease!SRgba8 lease_;

public:
    bool live() @safe { return account_ !is null; }
    size_t generationForResearch() const @safe { return id_; }

    bool trySample(size_t x, size_t y, out SRgba8 pixel) @safe
    {
        if (account_ is null) return false;
        scope auto borrow = lease_.view();
        return borrow.trySample(0, x, y, pixel);
    }

    bool tryRetain(ref GenerationDelivery result) @safe
    {
        if (account_ is null || result.live()) return false;
        auto record = account_.find(id_);
        if (record is null || record.phase != GenerationPhase.delivered ||
            record.subscribers == size_t.max)
            return false;
        result.lease_ = lease_;  // raster-d retains the REAL backing.
        result.account_ = account_;
        result.id_ = id_;
        ++record.subscribers;
        return true;
    }

    bool close() @safe
    {
        if (account_ is null) return false;
        auto accounting = account_;
        const id = id_;
        auto record = accounting.find(id);
        assert(record !is null && record.subscribers > 0);
        lease_ = RasterLease!SRgba8.init; // native ownership first
        account_ = null;
        id_ = 0;
        --record.subscribers;
        accounting.maybeRefund(id);
        return true;
    }

    ~this() @safe { close(); }
}

// Only these two cache-slot raster leases have cache-owner lifetime.
// An evicted generation may remain delivered in the independent metadata
// even after a NEW generation has replaced its physical cache slot.
struct GenerationCache
{
    @disable this(this);
private:
    GenerationAccounting account_;
    RasterLease!SRgba8[2] cached_;
    size_t[2] ids_;
    size_t[2] pending_;

public:
    this(size_t capacity) @safe
    {
        account_ = new GenerationAccounting(capacity);
    }

    GenerationAccounting auditForResearch() @safe { return account_; }

    bool tryReserve(size_t slot, OwnedPayloadPlan plan,
        size_t peakMetadata, size_t retainedMetadata,
        out size_t id) @safe
    {
        if (account_ is null || slot >= 2 || ids_[slot] != 0 ||
            pending_[slot] != 0 || cached_[slot].view().planeCount != 0)
            return false;
        if (!account_.reserve(slot, plan, peakMetadata, retainedMetadata, id))
            return false;
        pending_[slot] = id;
        return true;
    }

    bool abort(size_t slot, size_t id) @safe
    {
        if (account_ is null || slot >= 2 || pending_[slot] != id ||
            id == 0 || !account_.abort(id))
            return false;
        pending_[slot] = 0;
        return true;
    }

    bool adoptCompleted(size_t slot, size_t id,
        ref RasterLease!SRgba8 result) @safe
    {
        if (account_ is null || slot >= 2 || id == 0 ||
            pending_[slot] != id || ids_[slot] != 0 ||
            cached_[slot].view().planeCount != 0 ||
            result.view().planeCount != 1)
            return false;
        // Publish the checked new generation in metadata before adopting
        // the already-completed physical raster. No fallible work follows.
        if (!account_.publish(id, slot))
            return false;
        cached_[slot] = result;
        result = RasterLease!SRgba8.init;
        ids_[slot] = id;
        pending_[slot] = 0;
        return true;
    }

    bool tryDeliver(size_t slot, ref GenerationDelivery output) @safe
    {
        if (account_ is null || slot >= 2 || ids_[slot] == 0 ||
            output.live() || cached_[slot].view().planeCount == 0)
            return false;
        auto record = account_.find(ids_[slot]);
        if (record is null || record.phase != GenerationPhase.delivered ||
            !record.cacheHeld || record.subscribers == size_t.max)
            return false;
        output.lease_ = cached_[slot];
        output.account_ = account_;
        output.id_ = ids_[slot];
        ++record.subscribers;
        return true;
    }

    bool evict(size_t slot) @safe
    {
        if (account_ is null || slot >= 2 || ids_[slot] == 0)
            return false;
        const id = ids_[slot];
        auto record = account_.find(id);
        assert(record !is null && record.cacheHeld);
        cached_[slot] = RasterLease!SRgba8.init;
        ids_[slot] = 0;
        record.cacheHeld = false;
        account_.maybeRefund(id);
        return true;
    }

    ~this() @safe
    {
        if (account_ is null) return;
        foreach (slot; 0 .. 2)
        {
            if (ids_[slot] != 0) evict(slot);
            if (pending_[slot] != 0) abort(slot, pending_[slot]);
        }
    }
}
