# M3 RGBA — Issue #74: mixed hit/miss delivery ownership qualification

**Status: scoped research harness; no native XPS results and no public API.**
Extends the existing stacked OPEN/DRAFT PR #73 and the earlier
[two-subscriber XPS evidence](m3-rgba-delivery-workflow-xps-2026-10-14.md).
No sibling writes, scheduler, global cache, concurrency or production API
promotion are included.

## Why another workload

The independent native XPS proof found **+11.9 to +13.748 ns median
paired cost** for *two-subscriber hot cache hits* and a much noisier
full-ROI cycle comparison, with 128 observed thread-GC bytes per fresh
`DeliveryAccounting` cache. Pure hot and pure cold measurements cannot
show **amortized cost at intermediate hit ratios** or the effect of
one versus several subscribers.

The mixed experiment measures real `raster-d v0.2.0` leases and the
existing real prepared RGBA source-over/packed-pixel producer; the
controlled branch uses the consumer-only `OwnedDeliveryCache` and
move-only `OwnedDeliveryHandle`. The baseline uses directly copyable
`RasterLease!SRgba8` with an **explicit manually controlled
`RoiReservationLedger`**, a weaker *closed-world* contract. The
comparison is not a claim of feature-equivalent APIs.

## Deterministic finite-cache model

A **two-slot direct-mapped research cache** holds four logical ROI keys:

- Slot 0 alternates between key 0 and key 2.
- Slot 1 alternates between key 1 and key 3.
- Each key maps to a different `Region2D(3+key, 4+key, side, side)`
  of the same prepared input layers; comparisons therefore sample
  actual key-dependent RGBA.
- The initial two entries are computed **inside each timed variant**.
- Events alternate target slots. At event index `i`, a hit occurs
  when `((i % 100) * 37 + 11) % 100 < hit_percent`.
  Multiplication by 37 permutes residues modulo 100; for each
  consecutive multiple of 100 events, the hit percentage is exact.
- On a miss the old cached lease is first **independently retained**
  by one subscriber. Eviction drops only the cache owner; the
  retained pixel is read *after* eviction; the subscriber is
  released and only then is the matching accounting slot reused
  for a new real composited raster.
- On every request the newly current or cached ROI is delivered
  to `1`, `2` or `4` independently retained subscribers.
  Each reads the same pixel and retires separately.

**Important limitation:** unlike a fully general multi-generation
cache, this tiny ledger cannot reuse the same two ledger slots while
previous subscribers continue holding the evicted generation. The
experiment tests **last-owner-before-slot-reuse discipline** rather
than implementing additional generations, a queue, or backpressure
scheduler. Subscriber retention *past cache eviction* is exercised,
but not retention across admission of a second generation in that
same slot. This remains a **production design blocker** to address
separately.

### Equal-work and exact accounting checks

Each timed variant emits:

```text
experiment,side,hit_percent,subscribers,round,variant,requests,hits,misses,evictions,retains,refunds,elapsed_us,thread_gc_bytes,digest
```

The counters are defined as:

- `hits = requests * hit_percent / 100` (requests multiple of 100);
- `misses = requests - hits`;
- `evictions = refunds = misses` inside the event loop, excluding
  the final two cache cleanups;
- `retains = subscribers * requests + misses`; the final term is
  one outstanding old-generation subscriber per collision;
- `digest` includes the four RGBA channels of every delivered
  subscriber sample and every post-eviction old-generation sample,
  tagged with the logical ROI key.

Raw and controlled variants **must have identical hit/miss/eviction/
retention/refund counts and digest**. Any discrepancy fails the
research consumer. Both variants must end with zero outstanding
delivered charge; every controlled subscriber/lease closes exactly
once. Reusing a still-retained ledger slot is not allowed.

These counters are not an independent physical memory monitor.
Existing example peak/retained metadata headroom values remain
illustrative and do not cover every native or GC allocation.

## Benchmark and native capture

Consumer mode:

```sh
dub run --root=experiments/m3_rgba_layer_compositing/smoke \
    --compiler=ldc2 --build=release -- \
    --delivery-mixed-bench --side=16 --hit=75 --subscribers=2 \
    --rounds=9 --requests=200 --warmups=1
```

The supported profiles are the 3 × 3 full factorial:
`hit={25,75,95}` × `subscribers={1,2,4}`, for ROI sides
16 and 64. Raw and controlled order alternates per round.
Both stages include a real initial two-ROI warm cache and
compositing/import for subsequent misses; the controlled cache has
**one** shared GC accounting object per timed run (not one per miss).
The per-variant GC delta is measured, **not** treated as full native
RSS or worst-case allocator overhead.

The pinned XPS runner:

```sh
bash tools/research/run_m3_rgba_delivery_mixed_xps.sh
```

Requires LDC **1.43.0** and local repositories containing raster-d and
color-d **v0.2.0** tags. It archives immutable imagery-d HEAD plus
the two pinned dependencies into a fresh ignored evidence directory
under `data/m3-rgba-delivery-mixed-xps/<UTC>/`; records full source
commit, compiler, kernel, CPU/frequency/governor information; performs
9 paired rounds × 200 requests per variant for each of **18**
profiles; writes original timed CSV, stdout/stderr, validated paired
summary and SHA-256 checksums. `--smoke` uses two rounds with
100 requests and no warmup.

`tools/research/summarize_m3_rgba_delivery_mixed_xps.py` rejects:
missing/duplicate stage/rounds, wrong hit counts, impossible
retains/refunds/evictions, differing raw and controlled workload,
differing RGBA digests or missing PASS status. Reports per-request
microseconds, median **paired** controlled-minus-raw delta, median
ratio and observed per-stage thread-GC allocation.

The normal compiler CI is **not native XPS performance qualification**.
It exercises 25%/1-subscriber and 75%/2-subscriber side-16 profiles
across DMD/LDC, plus 95%/4-subscriber side 64 under LDC 1.43,
with validator and pinned-runner syntax gates.

## Decision and remaining work

**Current finding is a test design, not a performance result.**
Prior XPS overhead results remain valid for their individual
workloads; extrapolation to this mixed trace requires native capture.

The bounded consumer first proves that:
1. real cache hits do not create new raster backings;
2. misses really composite/import new backing and evict old ones;
3. one held subscriber survives eviction until deliberate release;
4. multiple subscribers share one backing/charge;
5. the old accounting slot is recycled **only after** last release;
6. comparator checks exactly identical real RGBA work.

**Deferred beyond this proof:** retaining evicted generation A
while generation B enters the **same** bounded ledger slot;
subscribers that cancel asynchronously, multi-threaded lease
access (raster-d's reference count is non-atomic), event-loop/UI
integration, real LRU or cache-key hashing, GC handle lifetime,
actual worst-case physical residency and fully accounted per-cache
metadata.

Issue #74 should stay **OPEN** and Draft PR #73 should stay
**OPEN/DRAFT** on its existing research base. Any public API
admission or request for a raster-d last-release lifecycle feature
requires separate, explicit evidence and decision.
