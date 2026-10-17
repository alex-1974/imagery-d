# M3 RGBA — Issue #74: independently retained DeliveryHandle (research)

**Status:** consumer-only prototype; no production API, API admission ADR, benchmark or
raster-d change. Evidence is stacked in Draft PR #73. The currently pinned public
dependencies are raster-d v0.2.0 and color-d v0.2.0. This report explicitly
separates proposed semantics from compiler/consumer evidence.

## Problem and basis

The two-subscriber [closed-world experiment](m3-rgba-multisubscriber-delivery-evidence.md)
proved independent *private subscriber slots* but did not establish a transferable
delivery whose lifetime can extend past destruction of the producing cache
object. [Issue #74](https://github.com/alex-1974/imagery-d/issues/74)
asks for that proof *before* requiring raster-d to publish a refcount.

The public `RasterLease!SRgba8` is the **only owner of physical pixel
storage**. Copies of a lease retain one underlying backing. The reference count
is internal/non-atomic. Borrowed views do not own backing.

The workspace's DLANG_PRACTICES §3.5 / TC-0016 notes that copy constructors
may not run on every dynamic-array or associative-array runtime copy path.
Accordingly this experiment **prohibits implicit copy of the DeliveryHandle**
and instead tests *explicit independent retain*, explicit move and RAII scope
destruction. No production-level claim of freely copyable D value semantics.

## Prototype, kept inside the independent DUB consumer

`experiments/m3_rgba_layer_compositing/smoke/source/owned_delivery_token.d`

- `OwnedDeliveryCache`: noncopyable owner of at most two cache-held genuine
  raster-d `RasterLease!SRgba8` values; a cache may go out of scope while
  delivery handles remain in a different scope.
- `OwnedDeliveryHandle`: noncopyable **independent value** holding one
  real raster-d `RasterLease!SRgba8` and a shared accounting participation.
  `tryRetain(ref other)` creates a separate handle with an independent real
  lease retain; `close()` and `~this()` retire it. `std.algorithm.mutation.move`
  transfers a handle; a moved-from handle becomes inert.
- `DeliveryAccounting`: **one GC-managed class per cache**, containing a
  `RoiReservationLedger`, cache-presence flags and *delivery-participation*
  counts. A handle retains an ordinary class reference so that accounting
  metadata remains accessible after cache destruction. The class stores **no
  raster backing, raw backing pointer, subscriber lease or release callback**.
  Its count is **NOT raster-d's internal refcount**.
- The only public-facing handle read operation copies an `SRgba8` value from
  a temporary `RasterView` borrow. No retained raster-d lease, pointer or
  borrowed view is returned.
- On explicit close or RAII destructor the handle drops its real raster-d
  `RasterLease` **before** it decrements accounting participation and
  potentially releases the last delivered charge. On cache destruction,
  cache-owned leases are dropped but delivered charges remain until all
  independent delivery handles have closed.
- Exactly one cache-owner allocation of GC-managed **accounting metadata**
  occurs on construction; `tryRetain` itself creates no new metadata object.
  The ordinary copied raster-d lease uses its existing retained-owner
  machinery. GC handles only metadata lifetime; native backing remains
  deterministically RAII-managed. **Metadata allocation size and time have not
  yet been measured or admitted**.

### Controlled transition trace: ROI A and B, 16 x 16

The existing experimental ledger charges `4N + 64` bytes after delivery
(1,088 for 16²), and reserves `8N + 128` bytes (2,176) while producing.
The 64/128 metadata allowances are **illustrative unqualified numbers**, not
actual measured allocation upper bounds.

| Event | Cache handles | Independent delivery handles | Reported charge |
|---|---|---|---:|
| Create A and adopt | A | none | 1,088 |
| Deliver A; explicitly retain two more copies | A | A0, A1, A2 | 1,088 |
| Evict cache A | none | A0, A1, A2 | 1,088 |
| Create/deliver/evict B | none | A0, A1, A2, B0 | 2,176 |
| Close A0 and B0 | none | A1, A2 | 1,088 |
| Explicitly move A1 to an independent value | none | moved A1, A2 | 1,088 |
| Retain a scoped A3, let it destruct | none | A1, A2 (after scope) | 1,088 |
| Close moved A1; destroy cache scope | none | A2, still live | 1,088 |
| Read A2 and close last independently held delivery | none | none | 0 |
| Separate post-cache RAII survivor leaves scope | none | none | 0 |

The test verifies byte-exact output values after cache eviction/destruction,
invalid/occupied delivery failure without mutation, duplicate close, explicit
move leaving its source inert, nested scope destructor behavior, and a separate
delivery whose destructor executes **after** the cache has disappeared.
All operations are **single-threaded**.

### Arithmetic and native-ownership caveat

`RoiReservationLedger` accounts expected ROI **payload plus illustrative
metadata**, not measured total native allocator memory. The shared accounting
class is GC allocated, and must not be interpreted as zero allocation merely
because `tryRetain` performs no explicit heap operation. The benchmark from
the original owned-output research does not quantify this new handle.

Release builds must execute account credit release, not hide a required
transition inside `assert`. The research module performs `ledger.release`
as a statement and uses `assert` only to check its outcome.

## API and safety boundaries NOT established

1. This is a **research-only module**, not an accepted public imagery API.
   The accounting metadata is not a native owner but its mutable counters
   constitute a *separate delivery-participation state*. That should be
   considered independently of raster-d physical ownership.
2. The module deliberately **forbids implicit copy**; explicit retain/move/RAII
   needs CI evidence. Passing the four-compiler basic consumer is necessary
   but does not cover D array/AA copy behavior, which is avoided structurally.
3. The GC accounting class avoids a dangling pointer into a stack-owned cache,
   but it adds a metadata heap object. GC-managed **delivery handles
   themselves** are **not** an admitted use case: deterministic RAII
   destruction must remain demonstrable for each handle.
4. No thread safety: raster-d lease refcount is not atomic, and the
   accounting record has ordinary mutable fields without synchronization.
5. No delivery cancellation race, duplicate subscription across separate
   threads, source snapshot lifecycle, cache eviction policy or generalized
   unlimited subscribers. The prototype has two cache slots and unlimited
   handle retains only to the extent manually exercised.
6. No `@safe`/DIP1000 qualified **public** handle API yet. The module's
   control plane is a research test of lifetime behavior, not a permission
   to promise attributes without independent negative compile tests.
7. Free export of bare `RasterLease` remains incompatible with **exact**
   last-owner accounting in imagery-d today. A snapshot refcount alone would
   not deliver a last-owner event (raster-d #250).

**Interim recommendation:** treat an explicitly retained, move-only delivery
capability with a separate metadata accounting record as a feasible **candidate
for further testing**, not an accepted production solution. Next qualify
release-configuration RAII and compiler behavior, measure metadata allocation
and retain/close overhead, and test positive/negative borrow/lifetime cases.
Then decide whether the extra GC metadata and constrained copy model satisfy
M2's real consumer needs; if not, compare the conservative raw-lease alternative
and the narrower raster-d lifecycle-observation question.

**No merge, public API promotion, sibling write, refcount exposure or closure
of Issue #74 is warranted solely from this research prototype.**
