# M3 RGBA — independent DeliveryHandle cost on XPS (2026-10-14)

**Evidence status: archived native single-host microbenchmark, not public API
admission.** Consumer-first imagery-d Issue #74, stacked Draft PR #73. This
report is derived from two uploaded XPS evidence archives and is attached to
imagery-d research **without modifying raster-d or color-d**.

## Provenance and integrity

| Field | Smoke | Native normal |
|---|---|---|
| UTC capture | 2026-10-14 13:48:28 | 2026-10-14 13:48:48 |
| Archive name | `20261014T134828Z.tar.gz` | `20261014T134848Z.tar.gz` |
| Archive SHA-256 | `78e4f2641324e286c21db9f09a980b1a126234134f625fc2c2200bd6ae034d01` | `9a71a65a5aa1cf92d9c1efe052f26223d0c258f60902bc7f47391dd7a2944d87` |
| `paired-raw.csv` SHA-256 | `ef390e1151884541538c4fae483ce127bfc3318e86a20dcf227b9694701d7a12` | `909a2154e0b44712856ff8e6b6c87fbd99846c1963a7c015bb9271f7764b4577` |
| `paired-summary.csv` SHA-256 | `dad28d6dd18145ca3e1e38035af329299da70804ae621397317f195d293d762c` | `3a499e785a9d1c95adfee52bf89a831f3b01c26d5273f0062b8c4bfaedac5330` |
| Mode | 2 rounds × 4,096 pairs per path | 13 rounds × 250,000 pairs per path |

All five `CHECKSUMS.sha256` entries in **each archive** (raw CSV,
runner stdout, environment, build log, derived summary) were independently
verified: **PASS**. The `DELIVERY-BENCH PASS` trailer is present in
both runs, CSV rounds are complete and paired, and the build logs end in a
successful link. Minor `mir-core 1.7.4` deprecation diagnostics for
`LLVM_version` are not benchmark errors.

**Both** archives record:

- `imagery-d` HEAD: `d6aeefe89dc861d854699aa9a45d8c531944850d`
- `raster-d v0.2.0`: `2f2415851e45001df92ce56dad409f680684ba8d`
- `color-d v0.2.0`: `3359f08f4e83941ac1a8451cadefb146b5736019`
- Host: `xps-15`, Intel Core **i7-9750H** (6 physical cores / 12
  logical CPUs), Linux x86_64, Ubuntu kernel `6.17.0-22-generic`.
- Compiler: **LDC 1.43.0**, release; DUB **1.42.0**.
- The CPU scaling governor was `powersave` on every recorded CPU.
  No explicit core-affinity/frequency isolation was established.
- The snapshot builds were sourced from **archived pinned commits**,
  independent of unrelated untracked files in the working tree.

At the time of this archive review, **5/5 GitHub workflows on this exact
source commit were SUCCESS**. Those jobs verify compiler and consumer
contracts, not the native timings below.

## Normal XPS results: complete 13-round paired comparison

One timed unit is a **retain followed by release**:

- `raw_raster_lease`: retain an existing public `RasterLease!SRgba8`
  backing by copying its owner and then reset that retained owner.
- `owned_delivery_handle`: call `tryRetain` and then `close` on an
  explicitly retained move-only DeliveryHandle. This performs a genuine
  raster-d retained-owner operation **plus** consumer accounting updates
  and checked lifecycle logic. These are **not identical feature contracts**.
- No RGBA blending or decode is performed inside either timed loop.
- Four warmup rounds were run on both stages. Stage order alternates per
  measured round (raw first on even-numbered rounds, handle first on odds).

| Metric | Raw raster lease | Owned delivery |
|---|---:|---:|
| Median ns / retained pair | **4.452** | **8.540** |
| Mean ns / pair | 4.434 | 8.446 |
| Range ns / pair | 4.064–4.828 | 7.880–8.864 |
| Completed pairs | 3,250,000 | 3,250,000 |
| GC allocated bytes during stage loops | 0 in all 13 | 0 in all 13 |

**Pair-preserving comparison:** median `owned - raw` **+4.000 ns**
per pair; range **+3.340 to +4.760 ns**; 13/13 differences are positive.
Median of the **per-round** `owned / raw` ratios is **1.905660×**
(or **+90.566%**). These are different descriptive statistics from
`8.540 / 4.452` (the ratio of independently computed medians).

Original paired stage elapsed times, transcribed from the SHA-verified
`paired-raw.csv` (microseconds per **250,000 pairs**):

```csv
round,raw_elapsed_us,owned_elapsed_us,owned_minus_raw_us
0,1113,2121,1008
1,1199,2178,979
2,1129,2159,1030
3,1083,2135,1052
4,1207,2216,1009
5,1153,2140,987
6,1136,2085,949
7,1086,2179,1093
8,1022,2022,1000
9,1135,1970,835
10,1040,2019,979
11,1093,2018,925
12,1016,2206,1190
```

All 26 raw rows additionally contain `iterations=250000`,
`thread_gc_bytes=0`, cumulative completed-pair count, and stage identity.
The original archive and its SHA-verified CSV (hashes above) remain the
authoritative detailed evidence.

### Smoke consistency check

The separate smoke archive has two rounds of 4,096 pairs per stage,
two/ two positive paired differences, and a reported median of **4.150391
ns raw** versus **8.422852 ns delivery**; median paired delta
**+4.272461 ns**. Its very small elapsed times and sample count mean
it is a functional/sanity check, **not** independent statistical
qualification. All measured stages recorded zero thread-GC bytes.

## Metadata and assembly cross-check

Each run reports:

```text
DELIVERY-METADATA research_cache_control_gc_thread_bytes=128
```

This is the observed **128-byte thread GC allocation delta for one
`DeliveryAccounting` object**, constructed before the timed loops.
It does **not** represent a measured bound on all native backing,
allocator-bookkeeping, RSS, all consumer metadata or per-ROI overhead.
The existing ROI budgets of 64 retained / 128 peak metadata bytes were
**illustrative test charges** and remain unqualified as actual memory
admission limits.

The archived normal-run LDC executable contains the
`owned_delivery_bench.executePairs` function with an actual baseline
call to `RasterBackingOwner.__postblit()` followed by calls to
`RasterBackingOwner.~this()` in the raw path. This limited assembly
sanity check rules out the most obvious failure mode of LLVM eliminating
the entire raw lease-retain/release operation; it does **not** establish
a full, platform-independent codegen/performance guarantee.

## Interpretation and decision

**Observation:** the controlled delivery operation is consistently
slower than a plain RasterLease retain/release **by approximately 4 ns
per pair** on this XPS and compiler. No timed-loop GC allocation was
observed, but the cache's shared accounting metadata had a one-time
128-byte GC allocation. The controlled operation does more work and
provides independent charge participation and last-controlled-owner
refund semantics that a freely copyable raw lease does not provide.

**Research disposition: DEFER public admission; continue Issue #74.**
The result is not a reason to expose a raw raster-d reference count or
pretend a counter snapshot gives a final-release event. It is also not
evidence that 4 ns is negligible across real deliveries.

Before production promotion:

1. Measure end-to-end **delivery creation, cache hits, multiple
   subscriber lifetimes, cancellation/eviction and rendering** with a
   realistic distribution of retains per ROI.
2. Establish the **actual physical metadata and allocator overhead**;
   refactor or separately account for the GC control object before
   claiming a fully bounded native residency budget.
3. Evaluate control-plane codegen and any meaningful optimization only
   against equivalent semantics (not merely the raw-lease fast path).
4. Include drift-sensitive repetition / CPU affinity and frequency
   controls if the effect is near accepted performance thresholds.
5. Independently prove the remaining D lifetime/array and concurrent
   ownership boundaries. `raster-d` uses non-atomic refcounting;
   no thread-safety inference is permitted.

No source, API, release, CI, dependency or sibling-repo changes are
justified by these performance numbers alone. Maintain PR #73 OPEN/DRAFT
and Issue #74 OPEN.
