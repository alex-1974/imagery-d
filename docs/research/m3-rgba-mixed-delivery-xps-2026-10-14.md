# M3 RGBA — mixed DeliveryHandle XPS evidence (2026-10-14)

**Status:** verified native research evidence for imagery-d [Issue #74](https://github.com/alex-1974/imagery-d/issues/74), preserved on stacked Draft PR #73; **not** a production API, release, allocator guarantee or reason to modify raster-d.

## Provenance and evidence validation

Uploaded `20261014T190941Z.tar.gz` (recorded UTC capture 2026-10-14 19:09:41) has SHA-256:

```
145293bf8db66ea503100ca948bbf167f92847156f285cffca177cfe7b988417
```

**All 57 original `CHECKSUMS.sha256` entries were independently verified**: 18 raw CSVs, 18 complete runner logs, 18 summary CSVs, `environment.txt`, `build.log`, and summarizer self-test. All 18 runners have a PASS trailer. Per-profile summaries were checked against **all 324 raw stage rows**, comprising **162 nine-round paired observations**, each containing 200 requests per baseline and controlled variant. All profiles have identical raw/controlled event counts and sampled RGBA-channel digests. The release build linked successfully; existing `mir-core 1.7.4` deprecated `LLVM_version` diagnostics are nonfatal.

| Source item | Recorded provenance |
|---|---|
| Host | `xps-15` / Intel Core i7-9750H, 6C/12T |
| OS | Linux/Ubuntu x86_64, kernel 6.17.0-22-generic |
| Compiler | **LDC 1.43.0**, Release; DUB 1.42.0 |
| imagery-d exact commit | `7af46c403089b0e7e96cab7df7b415ea1c10c812` |
| raster-d v0.2.0 | `2f2415851e45001df92ce56dad409f680684ba8d` |
| color-d v0.2.0 | `3359f08f4e83941ac1a8451cadefb146b5736019` |
| CPU | all governors `powersave`; frequency snapshot ~4 GHz; **no pinned affinity/frequency** |
| Snapshot | immutable `git archive` source/dependency pins; unrelated live untracked files did not enter builds |

Example archived raw hashes: `side-16-hit-75-subs-2-raw.csv` =
`ffd920a6d06b5e4be8e8f2f278c0f5d53d487ef27c00e21118328c200aa24cc4`;
`side-64-hit-75-subs-4-raw.csv` =
`dfca4ef6d7294cd2fb392c8cd8be477c68c9b0e599e24f3abbdc263629a6d42f`.
Retain the original archive for all unrounded stages and hashes.

## Experimental scope

The [mixed workload contract](m3-rgba-mixed-delivery-qualification.md) defines a deterministic two-slot direct-mapped cache with four alternating real ROI keys. Each paired variant uses actual `raster-d` leases, actual source-over/packed-import ROI computation on misses, and one/four independently retained subscriber reads per event. On a miss, one old subscriber survives cache eviction, reads the old raster, then retires **before** replacement admission to the same accounting slot.

- **25% hits:** 50 hits, 150 misses/evictions per 200-request trace.
- **75% hits:** 150 hits, 50 misses/evictions.
- **95% hits:** 190 hits, 10 misses/evictions.
- Subscribers: **1, 2, 4**; ROI sides: **16**, **64**.
- Nine paired rounds per profile; raw/controlled measurement order rotates.
- A two-slot cache with two seeded actual ROIs is created **inside every timed variant**.

The direct raw `RasterLease` comparison has a **weaker closed-world manual ledger**. It is not a feature-identical freely transferable delivery capability; the controlled path supplies independently retained accounting-aware handles.

## All 18 paired benchmark profiles

Time columns give the *independent* stage median in **µs per request**. Delta and ratio are the medians of **within-round paired** controlled-minus-raw and controlled/raw values (not differences/ratios of independent medians).

| Side | Hit rate | Subs | Raw µs/req | Controlled µs/req | Paired Δ µs/req | Paired ratio | Controlled slower |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 25% | 1 | 22.635 | 22.690 | +0.070 | 1.0031× | 9/9 |
| 16 | 25% | 2 | 22.615 | 22.135 | −0.300 | 0.9866× | 4/9 |
| 16 | 25% | 4 | 23.110 | 23.200 | +0.095 | 1.0041× | 7/9 |
| 16 | 75% | 1 | 7.920 | 7.935 | −0.005 | 0.9994× | 4/9 |
| 16 | 75% | 2 | 8.125 | 7.845 | −0.050 | 0.9936× | 4/9 |
| 16 | 75% | 4 | 7.960 | 8.060 | +0.070 | 1.0086× | 9/9 |
| 16 | 95% | 1 | 1.835 | 1.865 | +0.015 | 1.0083× | 6/9 |
| 16 | 95% | 2 | 1.900 | 1.915 | +0.025 | 1.0135× | 5/9 |
| 16 | 95% | 4 | 1.960 | 1.950 | +0.040 | 1.0214× | 5/9 |
| 64 | 25% | 1 | 338.590 | 337.675 | +3.310 | 1.0096× | 6/9 |
| 64 | 25% | 2 | 347.755 | 347.930 | +2.405 | 1.0070× | 5/9 |
| 64 | 25% | 4 | 346.595 | 344.725 | −2.680 | 0.9922× | 3/9 |
| 64 | 75% | 1 | 115.805 | 115.140 | +0.375 | 1.0033× | 5/9 |
| 64 | 75% | 2 | 116.180 | 116.085 | −0.095 | 0.9992× | 4/9 |
| 64 | 75% | 4 | 121.050 | 117.755 | −3.465 | 0.9714× | 0/9 |
| 64 | 95% | 1 | 27.500 | 27.465 | ±0.000 | 1.0000× | 4/9 |
| 64 | 95% | 2 | 26.875 | 26.950 | +0.080 | 1.0030× | 7/9 |
| 64 | 95% | 4 | 27.465 | 27.560 | +0.100 | 1.0036× | 9/9 |

Across these **individual profile medians**, paired ratios range
**0.9714×–1.0214×**, so none shows the 44–50% *end-to-end* penalty
suggested by comparing only two pure-hot delivery primitives.
Actual source-over work on misses dominates mixed traces.
This is **not** proof of performance equivalence at every load or
a general speedup of the controlled variant.

At 16×16 and 95% hits, the controlled path had **+15, +25, +40 ns**
median paired deltas per request for 1/2/4 subscribers, respectively;
the ratios were +0.83%, +1.35%, +2.14%. These relatively small
absolute deltas are consistent with the earlier hot ownership
overhead but **different measured operation scopes** must not be added.

### Significant anomalies and measurement sensitivity

1. **16×16 / 25% hits / 2 subscribers**: raw rounds 7 and 8 took
   **8,374 and 9,608 µs per 200 requests**, whereas controlled took
   **4,423 and 4,427 µs**. Paired deltas **−19.755 and
   −25.905 µs/request** are strong raw-path outliers; avoid means
   or claims of a real speedup from this profile. The median paired
   delta over nine rounds is −0.300 µs/request.
2. **64×64 / 75% hits / 4 subscribers**: controlled was faster in
   **all nine pairs**, with paired deltas between **−2.090 and
   −4.160 µs/request**; median **−3.465 µs** or −2.86%.
   This is a reproducible observation **within this single session**,
   not a demonstrated architectural advantage. CPU scheduling,
   cache effects, compilation differences and other confounders
   remain unisolated.
3. The per-stage timer records whole **µs**, and stages contain
   **200 requests**: 1 µs of stage timing resolution equals
   **5 ns/request**. CPU governor was `powersave` without controlled
   CPU affinity; small deltas require independent reruns.

## GC allocation and ownership interpretation

**Every one of the 162 paired rounds** reported:
- **Raw path: 0 thread-GC allocated bytes**.
- **Controlled path: exactly 128 thread-GC allocated bytes**.

This is the **one-time allocation of one shared `DeliveryAccounting`
object per timed two-slot cache**, regardless of whether that cache
performs 10, 50 or 150 misses within its 200 requests. No per-hit,
per-retain or per-miss extra GC allocation was observed in these traces.
For these exact profiles the 128-byte measurement amortizes to
0.64 GC bytes per request, but that does **not** establish a real
allocator size bound or imply fractional actual allocations.

The GC counter does **not** measure peak RSS, native `malloc`/raster
backings, allocator overhead, GC retention across cache destruction,
or the fully bounded residency budget. The two-slot experiment
continues to require **last-release-before-slot-reuse** and does
not solve simultaneous outstanding old and newly admitted generations
in one slot.

## Decision and next qualification

**Keep the controlled move-only DeliveryHandle as a research candidate,
but DEFER public API admission.** Its extra accounting has a small
*amortized* CPU cost in these 18 deterministic XPS profiles and a
measured 128-byte GC class allocation per two-slot cache, with
scope-qualified correctness for single-threaded retention/eviction.

Before broader API selection:
- qualify accounting for *simultaneously retained multiple generations*
  without slot reuse or premature refunds (possibly a per-generation
  record rather than one fixed ticket per cache slot);
- bound actual metadata/physical memory and GC-record lifetime;
- exercise cancellation, D container/copy/move, GC-stored handles
  and concurrency boundaries; raster-d's internal refcount is non-atomic;
- repeat the two anomalous profiles on independent native sessions
  with controlled CPU load, affinity and frequency, plus a realistic
  cache-key/eviction distribution.

**No merge, production package API or raster-d refcount exposure**
is justified by this one XPS run. Preserve Issue #74 OPEN and
stacked Draft PR #73 OPEN/DRAFT.
