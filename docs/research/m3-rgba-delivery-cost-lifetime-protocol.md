# M3 RGBA — Issue #74 DeliveryHandle cost and lifetime qualification protocol

**Status:** executable research harness and compiler gates; no native XPS
measurement or accepted public API. PR #73 stays stacked OPEN/DRAFT on
`research/m3-decoded-rgba-tiles-consumer`. No sibling source changes.

## Question

Does an independently retained `OwnedDeliveryHandle` add acceptable
allocation and latency cost compared with directly copying and retiring
an ordinary `raster-d v0.2.0` `RasterLease!SRgba8`, while preserving the
already qualified RGBA subscriber and cache-eviction semantics?

The implementation uses:
- one actual `RasterLease!SRgba8` per retained delivery, retaining exactly
  the same physical backing rather than duplicating pixel storage;
- **one additional GC-managed DeliveryAccounting metadata object per cache**,
  which can outlive its cache while delivered handles remain;
- explicit `tryRetain(ref OwnedDeliveryHandle)`, `close()`, and scoped RAII
  destructor; `@disable this(this)` prevents implicit copies.

Its reference count tracks **accounting participants**, not the internal
raster-d physical-reference count. The current implementation is single-threaded.

## Compiler and safety gates

The independent DUB consumer now includes functions declared `@safe`
that read a live delivery's first `SRgba8` sample and explicitly retain
then retire a second delivery owner. The implementation marks the relevant
lifecycle methods as `@safe`, subject to successful DMD/LDC compile gates.

Additional negative configurations:

| DUB config | Intentionally rejected |
|---|---|
| `negative-delivery-raw-lease-escape` | consumer tries to return the delivery's private physical `RasterLease` |
| `negative-delivery-implicit-copy` | consumer tries to implicitly copy the move-only delivery |
| existing `negative-local-lease-escape` | return a borrowed view after a local `RasterLease` has expired |

The existing four-compiler workflow expects these dedicated configurations
to FAIL with diagnostics in the consumer rather than failing for missing
packages/other unrelated reasons. Debug and release normal runs must still
execute the 432-scene independent reference oracle, subscriber and
controlled-lifetime tests.

**Not proved:** arbitrary thread-safe concurrent copies/retirements, lifetime
of GC-allocated DeliveryHandle values (as opposed to their GC-managed
metadata), callback/cancellation races, or public stable API attributes.

## Paired retain/release benchmark

New standalone research module:
`experiments/m3_rgba_layer_compositing/smoke/source/owned_delivery_bench.d`

Invocation:

```sh
dub run --root=experiments/m3_rgba_layer_compositing/smoke \
    --compiler=ldc2 --build=release -- \
    --delivery-bench --rounds=13 --iterations=250000 --warmups=4
```

The independently compiled consumer prepares two real, same-size,
malloc-backed, publicly imported `RasterLease!SRgba8` values. One is a
raw-lease baseline; the other is held through `OwnedDeliveryCache` and
`OwnedDeliveryHandle`. That separation avoids using an *unaccounted*
external owner of the target backing. Both reference-counted owners
retain and release their existing physical payload: no RGBA composition,
source loading, decode or cache-hash lookup is timed.

Measured stages per cycle:

1. `raw_raster_lease`: copy one genuine RasterLease, then reset the copy.
2. `owned_delivery_handle`: `tryRetain` one move-only DeliveryHandle,
   then `close` it, including the accounting-participation update and
   eligibility checks.

Warm-ups execute the same count on both paths. Order alternates by round;
every row reports elapsed microseconds, iterations, thread GC allocation
bytes, cumulative completion count and stage label. Emitted stages have
**different control-plane semantics**: the delta quantifies measured
additional delivery accounting plus contract checks relative to the raw
raster lease. It is **not a speedup comparison of equivalent APIs** and
does not isolate which instruction causes any overhead.

The benchmark prints the *observed* per-cache
`GC.stats().allocatedInCurrentThread` delta around construction of a
single accounting object. This is not a native-memory bound, not a
portable object-size proof and not a value that can replace the illustrative
128/64-byte ROI headroom used in existing reservation examples. All
performance claims require actual paired XPS evidence.

### Pinned XPS capture

Run from the imagery-d working tree on the Dell XPS with LDC 1.43.0,
existing sibling checkouts containing their v0.2.0 tags and the
workspace research branch available:

```sh
bash tools/research/run_m3_rgba_delivery_xps.sh
```

The runner:
- creates a *new* ignored `data/m3-rgba-delivery-xps/<UTC>/` evidence tree;
- archives the immutable imagery HEAD, raster-d v0.2.0 and color-d v0.2.0
  into private snapshot subdirectories;
- builds the snapshot consumer in **release** mode with **LDC 1.43.0**;
- runs thirteen rounds, 250,000 retains per stage per round, four warmups;
- keeps raw stdout plus CSV, build log, environment and SHA-256 checksums;
- never edits sibling source trees, and refuses an existing nonempty
  evidence directory.

`--smoke` selects two rounds × 4096 iterations. CI validates shell syntax
and executes the benchmark mode directly on GitHub runners with two
smoke rounds **only to prove functional and output contracts**; hosted
runner performance is not the XPS measurement.

### Analysis gate after native capture

Verify archive checksums, source/dep exact commit identities, compiler,
CPU/governors, per-round paired rows, number of complete iterations,
and normal-mode GC delta. Report for each path median and min/max
microseconds per retained pair and for each round the raw-minus-accounted
signed difference (and relative delta) **without discarding the paired
order evidence**. Check that slowdown direction is repeatable across
rounds, not shared machine drift. Include independent ordinary ROI
production and cache-subscriber end-to-end costs before promoting this
abstraction to a public API.

## Open architecture decisions

1. A separately GC-managed accounting object solves *metadata lifetime*
   for explicitly retained handles without implementing another raster
   physical backing owner. It adds one allocation and a metadata lifecycle
   that must be budgeted and measured.
2. Retaining a DeliveryHandle does **not** duplicate the physical resource;
   the raster-d `RasterLease` remains the owner of bytes and their final
   release. Closing the last controlled handle may refund the matching
   delivery cost only after its real lease has been dropped.
3. The current `RoiReservationLedger` is a two-entry research charge model
   with illustrative metadata, not a global total-process resident budget.
4. Arbitrary raw `RasterLease` export still prevents observing its last
   external destruction. A public read-only refcount snapshot does not
   automatically solve that. raster-d #250 remains open.
5. A public `@safe` delivery abstraction must separately address thread
   semantics, D copy/move and array behavior, callback borrowing, cancellation,
   GC metadata retention, and total measured overhead.

**Issue #74 is not ready to close.** Code and CI probes are research evidence
only; no API freeze, merge, release or sibling modifications are authorized.
