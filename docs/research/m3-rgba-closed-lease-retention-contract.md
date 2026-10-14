# M3 RGBA — Retained packed-output accounting at the raster-d boundary

**Status:** research-only, consumer-scoped proof, **not** a public API, cache
architecture promotion or claim of automatic last-reference observation.
Draft PR #73 remains stacked on Draft PR #69; no sibling repository changes.

## Actual public raster-d v0.2.0 contract inspected

The *public* `RasterLease!T` owns a retained raster representation;
copying a lease shares that **same** backing. Its internal reference count is
**non-atomic** and is explicitly not implicit cross-thread synchronization.
`view()` creates a **non-owning** lifetime-tied `RasterView!T`; it is not a
second retained owner. `tryWritableView()` also does not imply exclusivity.

Important distinctions in the public surface:

- `RasterLease.view()`: public borrowed non-owning view.
- `RasterLease.tryWritableView()`: public borrowed writable view, **not**
  a unique owner or a synchronization lock.
- `RasterLease.hasBacking` and `tryPhysicalResourceBytes`: declared
  `package(raster)`, **not** accessible from imagery-d.
- Last-owner reference-count observation, released-last-owner callback,
  arbitrary same-backing identity query, or a general accounting hook:
  **not exposed** by the public raster-d v0.2.0 package.
- Public `tryImportOwnedRaster` reports pre/post-commit resource disposition
  but this is an **import ownership** question, not a last-held-lease
  notification.

Therefore, **with freely copyable and escapable RasterLease outputs, an
imagery-d cache cannot know precisely when the last retained external copy
disappears using the present public interface**. Cache eviction means only
*the cache's own* retained lease has been released. Releasing the memory
budget then would be unsound if a consumer still retains the backing.

This is not repaired by pretending a copied lease is a new pixel allocation,
by polling `view().planeCount`, or by accessing private raster-d internals.
No new raster ownership/refcount implementation belongs in imagery-d.

## Scoped consumer alternative: never export an owning lease

In the independent M3 DUB consumer, the research-only
`ScopedRoiDeliveryConsumer` wraps **two** delivered results and a
`RoiReservationLedger` value. Its copy constructor is disabled. It calls
the actual `runReservedOwnedProbe` which constructs publicly imported,
genuine `RasterLease!SRgba8` resources and transfers the local result
into one private slot. The consumer does **not** return or publish any
copyable raster owner: its only read interface copies an SRgba8 sample
through a borrowed internal view. Thus it can define when all owners it
controls have been retired.

The control-plane transition for a 16² example is:

```text
budget=3400 bytes (illustrative 128/64 metadata headroom)
   create result A : peak admission 2176 -> delivered retained 1088
   create result B : peak admission 2176 -> delivered retained 1088
   total delivered charge = 2176
   retire A        : release private RasterLease A -> charge 1088
   retire A again  : reject without changing charge
   retire B        : release private RasterLease B -> charge 0
   reuse freed slot: another fully admitted result may publish
```

The consumer rejects overwriting an already delivered slot, an out-of-range
slot, reading before publication or after retirement. Both independent
results compare exactly at every sample. The existing 432-scene reference
oracle remains separately gated.

This **does not prove detection of the last arbitrary escaped lease**. It
demonstrates a different and much stricter interface: clients never receive
a retaining owner. The statement that the last internally retained handle
is retired follows from this closed-world rule, not from inspecting raster-d's
private reference count. No general memory-admission system is introduced.

## Where the closed-world model is insufficient

The accepted M2 source/cache ADR explicitly permits a delivered raster
materialization to outlive eviction of its cache entry (multiple
subscribers may retain a delivered materialization). An API that only permits
synchronous `trySample` calls cannot replace that freely retained delivery
contract. It may still be useful as an internal synchronous presentation
operation or a strictly scoped callback, but a broader M3 materialization
must preserve M2 semantics.

Three conceptual alternatives require separate admission evidence:

1. **All subscribers hold imagery-controlled delivery handles, no raw
   retaining RasterLease escapes.** Such a handle can retain the already
   owned raster lease and separately track *accounting participation*.
   Whether an associated lifetime/control record can be implemented
   without duplicating raster-d backing ownership, extra allocation or
   hidden synchronization is not established here. The physical owner
   must remain raster-d.
2. **Pass freely retained RasterLease directly.** Exact last-retain
   accounting is **blocked** without a public raster-d capability. Charge
   cannot safely be refunded merely because an imagery cache evicts.
3. **Explicit closed-scope borrowing only.** The two-slot experiment
   proves this local shape in a single-threaded consumer; long-lived
   cache subscribers would need a different contract.

A resource-cost policy may conservatively hold a reservation longer,
but must not silently call that *exact residency accounting*. A future
public raster-d **lifetime notification** would require its own scoped
research, API design and tests in raster-d, not an undocumented imagery
dependence or writes to a sibling repository.

## Remaining gate and test limits

- Dedicated consumer code is *single-threaded*. The raster-d owned control
  uses non-atomic lease retains, and the ledger has no synchronization.
- Metadata allowances (128 in-flight / 64 retained bytes) are illustrative,
  not measured or guaranteed upper bounds.
- The sample-only interface ensures no owner export **by code structure**
  inside this experiment; it does not retroactively cover arbitrary
  RasterLease copies in other M3 or M2 research consumers.
- Owner removal and budget release are explicitly paired in one method.
  This is not a callback from raster-d or deterministic observability of a
  detached owner's final destructor.
- There is no persistent cache, eviction policy, multi-subscriber cancellation
  or full source snapshot integration in this experiment.
- Native allocator/control-block exhaustion, post-commit import failure
  injection and thread race tests remain open.
- No change to the currently **BLOCKED** original four-plane source versus
  caller-owned packed output physical alias guarantee (Candidate A).

**Research recommendation:** Before a production admission ADR, select a
concrete subscriber-delivery model and demonstrate cache eviction with an
externally retained result and correct credit release. If subscriber-owned
raw RasterLease must remain a public feature, identify the minimal required
public raster-d observability contract **as an issue/proposal only**; do not
work around private state or duplicate the backing owner. Keep PR #73 Draft.
