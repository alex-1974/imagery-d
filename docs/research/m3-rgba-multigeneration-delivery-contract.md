# M3 RGBA — Issue #74: independently retained multigeneration delivery

**Status:** research-only external DUB consumer proof stacked in Draft PR
[#73](https://github.com/alex-1974/imagery-d/pull/73). No released
imagery API, raster-d reference-count API, thread-safety claim, merge or
production memory-budget admission.

## Specific blocker resolved within the experiment

The former two-slot `OwnedDeliveryCache` used one accounting ticket per
cache slot. After A was evicted but externally retained, a new generation
B **could not be published in the same slot** until the last A subscriber
had retired. Merely retaining a public `RasterLease` could not tell the
cache when to release A's charge. A new `raster-d` public refcount snapshot
would not by itself provide a final-release signal.

This experiment separates three identities:

1. **Cache slot**: a mutable place for the *current* raster lease; there
   are exactly two cache slots. Cache eviction drops only this one owner.
2. **Generation ID**: a strictly increasing, never reused identifier for
   each admitted raster backing. The old A ID remains valid after B
   occupies the same cache slot. Recycled ticket storage gets a *new* ID.
3. **Physical raster backing**: independently retained and finally
   released only by the existing public `raster-d RasterLease!SRgba8`.
   Neither the accounting class nor the ticket fields own pixel storage.

The implementation is isolated in
`experiments/m3_rgba_layer_compositing/smoke/source/owned_generation_delivery.d`.

A **single GC-managed GenerationAccounting metadata record per cache**
holds a *fixed-size array of three* `GenerationRecord` value tickets;
each has its own `GenerationPhase`, unique ID, byte charge,
cache-presence flag and explicit subscriber count. The class stores no
`RasterLease`, native pointer, view or arbitrary user callback. Three
records is a research cap, not a selected production cache capacity.
No dynamically indexed D array/AA of noncopyable owning structs is used,
respecting workspace D copy caveat TC-0016.

The cache holds at most one `RasterLease` per cache slot. Each
move-only `GenerationDelivery` holds its **own genuinely retained
RasterLease** and a GC class reference plus generation ID. The control
record survives cache-owner destruction if any external delivery still
references it. On delivery close the physical lease is dropped **before**
the subscriber count is decremented and the charge potentially refunded.
No delivery method returns a raw lease or borrowed raster view.

## Admissibility and failure transitions

For a checked `OwnedPayloadPlan` from the pre-existing ROI preflight:

- `reserve`: reject invalid plan, metadata arithmetic overflow, lack of
  byte capacity, full three-record table or an occupied cache slot;
  otherwise allocate a unique generation ID, assign a free ticket and
  charge `peakPayloadBytes + peakMetadata`.
- `adoptCompleted`: only an already-completed, valid public
  `RasterLease!SRgba8` may be published; reduce the in-flight charge
  to `retainedPayloadBytes + retainedMetadata`, move one cache owner
  lease and mark the ticket delivered.
- `abort`: failed/injected producer discards the reservation charge
  without publishing; abandoned pending reservation is cleaned up by
  the cache destructor.
- `evict`: retire only the cache's own real lease. If external
  deliveries remain, retain the generation's full delivered charge.
- `GenerationDelivery.close / ~this`: retire the handle's physical
  lease first, then decrement its accounting subscriber count.
  Refund the charge *exactly once* when neither cache nor external
  subscriber owns that generation.
- After the last generation owner retires, its fixed-array ticket may
  be reused, but its old ID is **never** reused. A held-old-generation
  handle therefore cannot alias a freshly admitted one.
- The class's counter is **accounting participation**, not raster-d's
  internal non-atomic physical reference count.

All accounting transitions occur as actual statements, **never only
inside `assert`**, so release builds preserve refunds and aborts.
The experiment is strictly **single-threaded**; no concurrent
`tryRetain`, cache eviction or decrement is supported.

### Byte-charge trace (16 × 16 RGBA, illustrative metadata)

With a producer peak of `8 × 16² + 128 = 2176` and a delivered
charge `4 × 16² + 64 = 1088`:

| Event | Cache slot 0 | External owners | Charged bytes | Active tickets |
|---|---|---|---:|---:|
| Publish A, retain A0/A1 | A | A0, A1 | 1,088 | 1 |
| Evict A | empty | A0, A1 | 1,088 | 1 |
| Reserve B while A retained | pending B | A0, A1 | **3,264 peak** | 2 |
| Publish, deliver, evict B | empty | A0, A1, B0 | 2,176 | 2 |
| Publish, deliver, evict C | empty | A0, A1, B0, C0 | 3,264 | 3 |
| Attempt fourth while all three tickets live | empty | same | unchanged/rejected | 3 |
| Retire A0, move A1, retire moved A1 | empty | B0, C0 | 2,176 | 2 |
| Publish/evict D using A's freed record | empty | B0, C0, D0 | 3,264 | 3 |
| Cache destructor, B/C/D still retained | gone | B0, C0, D0 | 3,264 | 3 |
| Close B, C, D independently | gone | none | 0 | 0 |

The test also verifies a **3263-byte constrained budget**: A's
delivered 1088 plus B's new peak 2176 requires 3264; B is refused
without modifying existing charges while A is held, then succeeds
after A's final close. Failure injection and a pending reservation
at cache destructor return their credit in debug **and release**.

A packed ROI is actually produced by the independent consumer's
`tryCompositeOwnedPackedResearch`, which runs the existing real
prepared RGBA compositor and imports public raster-d malloc-owned
packed output. The test reads all A pixels from two independently
retained handles across publication of successors; B/C/D are read
after eviction and even after cache-owner destruction.

## What this does **not** prove

The `peakMetadata=128` and `retainedMetadata=64` allowances are
**illustrative charges**, not measured bounds on native allocator
bookkeeping, the GC GenerationAccounting object's actual size, or
peak process residency. In particular the new record array is larger
than the previous two-entry prototype, so previous **128-byte GC
class measurements cannot be reused** to estimate this new class.
The producer preflight also does not control the native allocator's
physical peak. A real bounded-budget admission design must reconcile
the measured complete metadata sizes and native memory separately.

The prototype still limits **simultaneously charged generations to
three**, even if RAM is plentiful. More than three generations must be
rejected without leaks; there is no LRU, parking queue, tile-key hash
lookup, backpressure scheduler or generalized subscriber dispatcher.

Most importantly, `raster-d` leases and the accounting state are
non-atomic; **no cross-thread access, asynchronous cancellation,
inter-thread move, background finalizer, or GC-allocated
`GenerationDelivery`** is qualified here. Values must be scoped
RAII owners or explicitly closed; a GC-managed class *for accounting
metadata* is not evidence for deterministic destruction of
GC-stored owner handles.

The shared class has no mechanism to observe arbitrary *external raw
RasterLease escapes*. The caller must keep delivery ownership behind
the controlled handle boundary for exact final-owner accounting.

## Follow-up before public API admission

1. Finish full DMD/LDC debug-and-release consumer matrix and separate
   negative compile tests for copying/escaping the new handle.
2. Measure actual **per-cache metadata allocation** for the new
   fixed-three-generation record and its lifetime across cache
   destruction; do not substitute older 128-byte measurements.
3. Stress reservation failure/abort/retire in multiple cache slots,
   varied close order and peak capacity exactly at threshold.
4. Define cancellation, concurrency, generation-limit/backpressure,
   D container/move and memory-residency semantics before any
   `imagery-d` production API or `raster-d` API requirement.

**Disposition: research ADAPT candidate, API DEFER.**
Keep Issue #74 OPEN and stacked PR #73 OPEN/DRAFT;
no sibling repo writes or merger of the grandfathered research branch.
