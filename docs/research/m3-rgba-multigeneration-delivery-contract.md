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

### Cross-slot capacity, scope-exit and metadata observations

The extended consumer checks a separate **3400-byte** two-cache-slot
case: slot 0 contains current B (1088) and an evicted but still
subscribed A (1088); a fresh 2176-byte-peak C in slot 1 would require
4352 bytes and is rejected without partial publication. Closing the
last A subscriber lowers the charge to 1088, and the same C reservation
now fits at a 3264-byte transient peak before it publishes at 2176.
After eviction from both slots, B and C release independently and the
aggregate charge returns to zero.

A separate scoped-delivery case verifies automatic `~this()` refund
**after** its producing `GenerationCache` has left scope, with no
explicit `close` call. This is stack/RAII lifetime evidence only; it
does not authorize GC-allocated delivery handles.

The independent consumer emits a
`M3 RGBA multigeneration GC metadata observation:` line containing
the `GC.stats().allocatedInCurrentThread` delta around **one new
three-record GenerationAccounting instance**. This observation is
compiler/host dependent; it must be read from the actual successful
build's logs and **cannot** establish complete RSS/native allocator
headroom.

**Observed hosted CI evidence, 2026-10-15:** The exact
`7732cb38ce6f3d9e04ef324409091ec1881e41e8` source completed all
five GitHub workflows successfully. In the independent source-over
consumer logs, **DMD 2.112.1, DMD 2.113.0, LDC 1.42.0, and LDC 1.43.0
each report 256 thread-GC-allocated bytes** for one newly constructed
three-ticket `GenerationAccounting` class, in **both debug and release**.
The standalone raw lease reference does not allocate this metadata;
the earlier *different* two-ticket `DeliveryAccounting` measured
128 bytes on the XPS. The **256 bytes are a concrete observed GC
allocation delta**, not an allocator size guarantee or complete
RSS/native-malloc/import/reservation bound.

A packed ROI is actually produced by the independent consumer's
`tryCompositeOwnedPackedResearch`, which runs the existing real
prepared RGBA compositor and imports public raster-d malloc-owned
packed output. The test reads all A pixels from two independently
retained handles across publication of successors; B/C/D are read
after eviction and even after cache-owner destruction.

## Serialized cancellation interleavings

The separate `checkGenerationCancellationOrder` research consumer
trace tests *synchronous* cancellation as explicit `close()`:

- A in slot 0 has two deliveries, B in slot 1 has one; attempts to
  deliver into an already-live target or explicitly retain into a
  nonempty handle must fail without changing ownership or credit.
- Evict A, publish C in the same slot while A and B are still held;
  then **retain another A owner after eviction**. All three distinct
  generation charges remain live and old A remains readable.
- Run **256 temporary retain/close pairs** on the evicted A delivery
  and check for **zero additional thread-GC bytes** in that interval,
  with unchanged charge and subscriber counts.
- Close A1 and B0 while B is still cached; a final external B close
  must **not** refund B until B's cache owner also retires.
- Evict B, close A0 twice (the second close rejects without a second
  refund), close A's final surviving subscriber, then evict C while
  its last external owner remains live. C's final close returns all
  credit.
- Test marker: `M3 RGBA generation cancellation PASS:` must appear
  in **debug and release** in all four supported compiler jobs.

This establishes ordering properties in one serialized thread only.
A `close()` call from a different task/thread at the same time as
`tryRetain`, `evict` or another `close()` remains **unsupported**.
Do not infer atomicity, thread-safe asynchronous cancellation or
safe D GC-container destruction from these tests.

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

1. Qualify the new cancellation trace across all DMD/LDC
   debug/release configurations, including zero-GC hot cancellation.
2. Repeat the **256-byte observed class-allocation** result in a
   pinned native XPS run; separately determine complete native/GC
   memory residency and allocator overhead.
3. Stress failure/abort/retire and multi-generation close order beyond
   three fixed tickets and both cache slots.
4. Define truly concurrent cancellation, generation-limit/backpressure,
   D container/move, GC-stored owning-value and memory-residency contracts
   before any public `imagery-d` API or `raster-d` API requirement.

**Disposition: research ADAPT candidate, API DEFER.**
Keep Issue #74 OPEN and stacked PR #73 OPEN/DRAFT;
no sibling repo writes or merger of the grandfathered research branch.
