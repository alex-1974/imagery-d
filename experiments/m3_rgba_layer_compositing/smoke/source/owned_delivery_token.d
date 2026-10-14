module owned_delivery_token;

// Issue #74: research-only DELIVERY accounting, not raster backing ownership.
// Physical bytes remain owned exclusively by public raster-d RasterLease.
// The GC-managed accounting record retains ONLY counters, NEVER raster data.
// Non-atomic: callers must serialize all shared accounting/lease operations.
import color : SRgba8;
import raster : RasterLease;
import owned_reservation_probe : RoiReservationLedger, TicketPhase;

final class DeliveryAccounting
{
    // Research visibility only: no public imagery API or allocator policy.
    private RoiReservationLedger ledger_;
    private bool[2] cacheHeld_;
    private size_t[2] externalRetains_;

    this(size_t capacity) @safe
    {
        ledger_ = RoiReservationLedger(capacity);
    }

    size_t charged() const @safe { return ledger_.charged; }

    size_t externalRetains(size_t slot) const @safe
    {
        return slot < externalRetains_.length
            ? externalRetains_[slot] : 0;
    }

private:
    void maybeRefund(size_t slot) @safe
    {
        if (!cacheHeld_[slot] && externalRetains_[slot] == 0)
        {
            // The only counted raster backing in this closed-world model
            // is now gone; a released slot can be reused.
            assert(ledger_.phase(slot) == TicketPhase.delivered);
            // The release is mandatory in release builds too. NEVER put
            // an ownership/accounting transition inside assert().
            const bool released = ledger_.release(slot);
            assert(released);
        }
    }
}

// Move-only independent delivery; every handle holds its OWN genuine
// raster-d retain plus an accounting participation in the same backing.
// No cast/raw view/lease escapes. The accounting record is a GC object so
// a handle may outlive the cache owner; GC does NOT own the raster payload.
struct OwnedDeliveryHandle
{
    @disable this(this);

private:
    DeliveryAccounting account_;
    size_t slot_;
    RasterLease!SRgba8 backing_;

public:
    bool live() @safe
    {
        return account_ !is null;
    }

    bool trySample(size_t x, size_t y, out SRgba8 pixel) @safe
    {
        if (account_ is null)
            return false;
        scope auto borrow = backing_.view();
        return borrow.trySample(0, x, y, pixel);
    }

    // An explicit independent retain avoids relying on D copy constructors
    // inside dynamic arrays / AAs (workspace TC-0016). It does not allocate
    // a second raster backing, per-handle heap token or second pixel charge.
    bool tryRetain(ref OwnedDeliveryHandle result) @safe
    {
        if (account_ is null || result.account_ !is null ||
            account_.externalRetains_[slot_] == size_t.max)
            return false;

        // First create a genuine raster-d retained handle. The accounting
        // increment follows only after that has succeeded.
        result.backing_ = backing_;
        result.account_ = account_;
        result.slot_ = slot_;
        ++account_.externalRetains_[slot_];
        return true;
    }

    bool close() @safe
    {
        if (account_ is null)
            return false;

        auto accounting = account_;
        const size_t slot = slot_;
        // Release physical backing BEFORE the possible budget refund.
        backing_ = RasterLease!SRgba8.init;
        account_ = null;
        slot_ = 0;

        assert(accounting.externalRetains_[slot] > 0);
        --accounting.externalRetains_[slot];
        accounting.maybeRefund(slot);
        return true;
    }

    ~this() @safe
    {
        // RAII: no explicit unsubscribe required on normal scope exit.
        close();
    }
}

// Research-only scoped cache that cannot be copied. A subscriber's
// independently retained OwnedDeliveryHandle can OUTLIVE its cache object.
struct OwnedDeliveryCache
{
    @disable this(this);

private:
    DeliveryAccounting account_;
    RasterLease!SRgba8[2] cached_;

public:
    this(size_t capacity) @safe
    {
        // One GC-managed metadata/control record per two-entry cache;
        // its allocation is NOT part of measured 8N ROI pixel payload.
        account_ = new DeliveryAccounting(capacity);
    }

    DeliveryAccounting auditForResearch()
    {
        return account_;
    }

    // Only the existing real producer may access this test adapter.
    ref RoiReservationLedger producerLedger()
    {
        return account_.ledger_;
    }

    bool adoptCompleted(size_t slot, ref RasterLease!SRgba8 produced)
    {
        if (slot >= cached_.length ||
            account_.ledger_.phase(slot) != TicketPhase.delivered ||
            account_.cacheHeld_[slot] ||
            account_.externalRetains_[slot] != 0 ||
            cached_[slot].view().planeCount != 0 ||
            produced.view().planeCount == 0)
            return false;

        cached_[slot] = produced;
        produced = RasterLease!SRgba8.init;
        account_.cacheHeld_[slot] = true;
        return true;
    }

    bool tryDeliver(size_t slot, ref OwnedDeliveryHandle result)
    {
        if (slot >= cached_.length ||
            !account_.cacheHeld_[slot] ||
            cached_[slot].view().planeCount == 0 ||
            result.live() ||
            account_.externalRetains_[slot] == size_t.max)
            return false;

        result.backing_ = cached_[slot];
        result.account_ = account_;
        result.slot_ = slot;
        ++account_.externalRetains_[slot];
        return true;
    }

    bool evict(size_t slot)
    {
        if (slot >= cached_.length || !account_.cacheHeld_[slot])
            return false;

        cached_[slot] = RasterLease!SRgba8.init;
        account_.cacheHeld_[slot] = false;
        account_.maybeRefund(slot);
        return true;
    }

    ~this() @safe
    {
        // A cache owner exiting scope cannot make a delivery invalid:
        // external handles carry independent raster-d leases and the
        // GC-backed accounting state that records their participation.
        foreach (slot; 0 .. cached_.length)
            if (account_ !is null && account_.cacheHeld_[slot])
                evict(slot);
    }
}
