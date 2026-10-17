# M3 RGBA — Issue #74: consumer-shaped subscriber-delivery workflow qualification

**Status: research benchmark harness, native XPS result not yet collected.**
Kept in the existing stacked OPEN/DRAFT PR #73 with no production API,
merge, sibling repository write, refcount API request or ownership change.
The last native microbenchmark result is documented separately at
[m3-rgba-delivery-xps-2026-10-14.md](m3-rgba-delivery-xps-2026-10-14.md).

## Question and experimental boundaries

The preceding native XPS microbenchmark measured a **+4.000 ns median
paired overhead** for explicit retained `OwnedDeliveryHandle` vs ordinary
raster-d `RasterLease` retain/release on the i7-9750H with LDC 1.43.0.
That does **not** predict the impact on a cache-hit→subscriber-read or
new ROI→deliver→evict→release workflow.

This consumer-controlled experiment therefore times two paired families
with **real raster-d `RasterLease!SRgba8` backing**, the same prepared
`imagery-d` source-over operation, and a pixel read for each of the two
independently retained subscribers.

The raw lease comparison is intentionally a **weaker, closed-world
manual-accounting consumer baseline**, not a drop-in semantic equivalent
for independent delivery capability. The controlled version carries
separately retained, move-only delivery handles and shared accounting
metadata. Both producer paths use the same `runReservedOwnedProbe` with
its checked ROI reservation, actual source-over pixel work and
malloc-backed raster import.

### Family A: repeated warm-cache deliveries

1. Precompute one complete ROI for each implementation (not timed).
2. On every hot-cache iteration, acquire two independent handles to
   that same physical cached backing.
3. Read a pixel from each and verify agreement.
4. Independently retire each handle, while preserving the cache-held
   backing and its delivered budget charge for later hits.

Compared stages:

- `hot_raw_two_subscribers`: direct `RasterLease` retains followed by
  identical pixel samples; the closed-world baseline knows its owners.
- `hot_controlled_two_subscribers`: two calls to `tryDeliver`, borrowed
  pixel samples and two separate `OwnedDeliveryHandle.close` calls.

This measures cache-hit delivery/reader overhead, **not** the
allocation/computation of an ROI or key-hash lookup.

### Family B: complete fresh ROI with eviction

On each iteration:

1. Reserve a bounded test charge and **execute the same real prepared
   RGBA source-over and packed import** into a new raster-d backing.
2. Keep one cache owner and independently retain two subscriber owners.
3. Evict the cache owner while both subscribers remain live.
4. Subscriber A reads and retires; subscriber B reads after A's
   retirement, then retires.
5. Refund the delivered test charge only after the last known handle.

Compared stages:

- `roi_raw_evicted`: local `RoiReservationLedger`, direct raster-d
  retains, explicit last-retain refund by a closed-world caller.
- `roi_controlled_evicted`: one GC-managed `DeliveryAccounting` object
  per cache, real raster-d lease handles in the typed cache and
  independently releasable delivery values. Destruction after final
  delivery retirement releases the charge.

This is a measured **source-over + packing + ownership + eviction**
comparison, not a native memory limit or a general scheduling benchmark.
One extra GC-managed accounting object is explicitly *inside* each
cold controlled iteration; its cumulative GC bytes are recorded.

Both families require pixel reads and update an observed checksum
derived from sampled RGBA values. For hot results the consumer compares
**every pixel** between raw and controlled materializations before
any timing. On all measurements, the summarizer rejects missing stages,
unequal work counts, different checksums, zero timings and missing PASS
trailers.

## Run modes, result schema and sample selection

Independent DUB consumer:

```sh
dub run --root=experiments/m3_rgba_layer_compositing/smoke \
    --compiler=ldc2 --build=release -- \
    --delivery-workflow-bench --side=16 --rounds=13 \
    --hot-iterations=250000 --churn-iterations=16 --warmups=2
```

Supported ROI sides: **16** and **64**. The prepared source fixtures
remain 8 pixels wider/higher than the ROI (ROI starts at 3,4).
The original 432-scenario RGBA differential oracle remains separate;
no public imagery API is exported.

Output schema:

```text
experiment,side,round,stage,iterations,elapsed_us,thread_gc_bytes,digest
```

Four stages are measured per round, with their order rotated every
round. Hot and fresh-ROI cycles have different iteration counts: their
per-cycle durations **must not be compared directly** without
normalization. All comparisons are paired by matching side, round,
stage-family and identical iteration count.

`tools/research/summarize_m3_rgba_delivery_workflow_xps.py` validates
the pairing and outputs per-round nanoseconds per cycle, the signed
controlled-minus-raw delta, ratios, per-stage GC bytes and separate
medians for each ROI size and family. It never interprets a GC-byte
delta as total native RSS.

## Native reproducibility and CI

New runner:

```sh
bash tools/research/run_m3_rgba_delivery_workflow_xps.sh
```

It creates a fresh `imagery-d/data/m3-rgba-delivery-workflow-xps/<UTC>/`
directory and builds **immutable git archives** of:

- the current imagery-d HEAD,
- `raster-d v0.2.0`,
- `color-d v0.2.0`.

Requires **LDC 1.43.0** and records compiler, kernel, CPU, governors,
frequencies, repository commit identity and working-tree state. For
each ROI side it preserves stdout, stderr, raw CSV, validated paired
summary, build log and SHA-256 hashes. It does not write to any sibling
repository. The normal mode tests **13 rounds × 250,000 hot hits and
16 fresh ROI cycles per stage**, plus two warmups. `--smoke` uses
two rounds, 4,096 hot hits and two fresh ROIs per stage.

CI smoke is for compilation, semantics and result integrity, **not for
timing claims**. All four supported DMD/LDC versions run side-16
workflow probes; LDC 1.43 also exercises side 64. The pinned runner
receives a `bash -n` check, the summarizer has a self-test.

## Limits and next decision

1. The benchmark is single-threaded. It proves no concurrency, callback
   cancellation or GC-allocated handle destruction contract.
2. No actual native benchmark values exist until the XPS runner is
   executed on the target machine. Do not infer results from hosted CI.
3. The raw baseline's **manually controlled last-owner knowledge**
   permits refund in this *specific closed-world comparison*; it does
   **not** generalize to arbitrary escaped raster leases.
4. Memory charges retain the existing **illustrative** 64-byte retained
   and 128-byte in-flight metadata allowances; these are not certified
   allocation bounds. The metadata GC object and any remaining native
   accounting are not included in the current admission constraint.
5. The existing `runReservedOwnedProbe` test-ledger publish transition
   occurs before its scratch raster goes out of scope, so its accounting
   is a **sequential research trace**, not a proven concurrent upper
   bound on transient native memory.
6. No XPS CPU affinity/frequency isolation is assumed; record the
   environment and repeat if order/drift threatens interpretation.

**Disposition:** collect native XPS evidence, compare overhead separately
for hot and cold workflows, and only then consider whether the
DeliveryHandle's extra metadata and retain overhead are justified
against realistic use patterns. Issue #74 remains OPEN and draft PR #73
remains OPEN/DRAFT, preserving the grandfathered research stack.
