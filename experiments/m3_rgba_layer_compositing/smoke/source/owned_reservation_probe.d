module owned_reservation_probe;

// Consumer-scoped two-request accounting model. Real checked charges, but
// NOT a thread-safe/global manager, allocator, or raster lease hook.
import owned_payload_budget : OwnedPayloadPlan;

enum TicketPhase : ubyte { empty, inFlight, delivered }

private struct Ticket
{
    TicketPhase phase;
    size_t charged;
    size_t deliveredCharge;
}

struct RoiReservationLedger
{
    size_t capacity;
    size_t charged;
    private Ticket[2] tickets;

    bool tryReserve(size_t slot, OwnedPayloadPlan plan,
        size_t peakMetadataBytes, size_t deliveredMetadataBytes)
        @safe nothrow @nogc
    {
        if (slot >= tickets.length || tickets[slot].phase != TicketPhase.empty
            || plan.pixels == 0 || plan.retainedPayloadBytes == 0
            || plan.peakPayloadBytes < plan.retainedPayloadBytes
            || peakMetadataBytes < deliveredMetadataBytes
            || plan.peakPayloadBytes > size_t.max - peakMetadataBytes
            || plan.retainedPayloadBytes > size_t.max - deliveredMetadataBytes)
            return false;
        const size_t peakCharge = plan.peakPayloadBytes + peakMetadataBytes;
        const size_t delivered = plan.retainedPayloadBytes
            + deliveredMetadataBytes;
        if (charged > capacity || peakCharge > capacity - charged)
            return false;
        tickets[slot] = Ticket(TicketPhase.inFlight, peakCharge, delivered);
        charged += peakCharge;
        return true;
    }

    // Only after successful pixel completion AND result publication.
    bool publish(size_t slot) @safe nothrow @nogc
    {
        if (slot >= tickets.length ||
            tickets[slot].phase != TicketPhase.inFlight)
            return false;
        const size_t former = tickets[slot].charged;
        const size_t reduced = tickets[slot].deliveredCharge;
        if (reduced > former || former > charged)
            return false;
        charged -= former - reduced;
        tickets[slot].phase = TicketPhase.delivered;
        tickets[slot].charged = reduced;
        return true;
    }

    // Consumer explicitly calls after *all* retained RasterLease handles
    // have been destroyed. This research ledger CANNOT detect that itself.
    bool release(size_t slot) @safe nothrow @nogc
    {
        if (slot >= tickets.length || tickets[slot].phase == TicketPhase.empty
            || tickets[slot].charged > charged)
            return false;
        charged -= tickets[slot].charged;
        tickets[slot] = Ticket.init;
        return true;
    }

    TicketPhase phase(size_t slot) const @safe nothrow @nogc
    {
        return slot < tickets.length ? tickets[slot].phase
            : TicketPhase.empty;
    }
}

bool checkReservationLedgerContract(OwnedPayloadPlan plan)
    @safe nothrow @nogc
{
    if (plan.peakPayloadBytes != 2048 ||
        plan.retainedPayloadBytes != 1024)
        return false;
    // Two requests compete for the same bounded pool. Explicit import
    // metadata headroom is a test input; not an empirically proven bound.
    RoiReservationLedger ledger = RoiReservationLedger(3400);
    if (!ledger.tryReserve(0, plan, 128, 64) ||
        ledger.charged != 2176 ||
        ledger.phase(0) != TicketPhase.inFlight)
        return false;
    if (ledger.tryReserve(1, plan, 128, 64) ||
        ledger.charged != 2176)
        return false;
    if (!ledger.publish(0) || ledger.charged != 1088 ||
        ledger.phase(0) != TicketPhase.delivered)
        return false;
    if (!ledger.tryReserve(1, plan, 128, 64) ||
        ledger.charged != 3264)
        return false;
    if (ledger.tryReserve(1, plan, 128, 64) ||
        ledger.charged != 3264)
        return false;
    if (!ledger.release(1) || ledger.charged != 1088)
        return false;
    if (ledger.release(1) || ledger.charged != 1088)
        return false;
    if (!ledger.release(0) || ledger.charged != 0 ||
        ledger.phase(0) != TicketPhase.empty)
        return false;

    // Metadata and peak budget arithmetic cannot wrap or be bypassed.
    if (ledger.tryReserve(0, plan, size_t.max, 0) ||
        ledger.tryReserve(0, plan, 32, 33) ||
        ledger.tryReserve(2, plan, 128, 64) ||
        ledger.charged != 0)
        return false;
    if (ledger.publish(0) || ledger.release(0))
        return false;
    return true;
}
