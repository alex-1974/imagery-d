# M3 RGBA — consumer-shaped DeliveryHandle XPS evidence (2026-10-14)

**Status:** independently verified native XPS research evidence for [imagery-d #74](https://github.com/alex-1974/imagery-d/issues/74), on stacked Draft PR #73. **Not** a public API, performance admission, concurrent-residency proof, or release decision. [Experimental workload contract](m3-rgba-delivery-workflow-qualification.md).

## Source, provenance and integrity

User-supplied archive `20261014T183947Z.tar.gz` captured 2026-10-14 at **18:39:47 UTC**, SHA-256:
`a72c2f258544c5085a31cd13b56f0cd1e5743408991881da1d23c96316ac0f5a`.

The archive contains immutable source/dependency snapshots, `environment.txt`,
`build.log`, and for both 16×16 and 64×64 ROI sizes separate raw CSV,
full runner stdout/stderr and summarized paired CSV. **All eight entries in
`CHECKSUMS.sha256` were independently recomputed and matched.**
Both `DELIVERY-WORKFLOW PASS:` trailers exist, each ROI size has 52
well-formed rows (13 rounds × four stages), and each corresponding raw/
controlled pair has identical iteration counts and sampled-pixel digests.
The release build successfully linked; warnings in `mir-core 1.7.4`
about deprecated `LLVM_version` are not build failures.

| Provenance | Verified archive value |
|---|---|
| Host / CPU | `xps-15`, Intel Core i7-9750H, 6 physical cores, 12 threads |
| OS | Ubuntu/Linux x86_64, kernel 6.17.0-22-generic |
| Compiler | **LDC 1.43.0**, release build; DUB **1.42.0** |
| imagery-d source commit | `844b9cbf35b3153aa554f68ccfa00d2a3adf5d77` |
| raster-d v0.2.0 | `2f2415851e45001df92ce56dad409f680684ba8d` |
| color-d v0.2.0 | `3359f08f4e83941ac1a8451cadefb146b5736019` |
| CPU governor | **powersave** for all 12 logical CPUs |
| Explicit affinity/frequency isolation | **not recorded** |
| Modes | normal; 13 paired rounds per ROI size |
| Iterations per stage, per round | **250,000** hot cache hits; **16** fully produced/evicted ROIs |

The source commit had **5/5 GitHub workflows SUCCESS**, including the
four independent DMD/LDC consumer jobs. CI confirms benchmark behavior
and safety probes; it is **not** evidence of XPS speed.

Hashes for archival verification:

```text
archive.tar.gz       a72c2f258544c5085a31cd13b56f0cd1e5743408991881da1d23c96316ac0f5a
side-16-raw.csv      eedccc69a6b674579435602ac08ac97f83363680470e1a8078fb5c4472afb476
side-64-raw.csv      8383e4ed7cb254b63b1f79aa0af1286999682e653361d807d5d8ee5f48c0b08d
side-16-summary.csv d2d0d66c2be09fef5b1b0e8b10d889e7095ed309b95a776fc5a4b2c8d074f349
side-64-summary.csv 81c57821e21370381e31864bb0fb15ff439da803f1c29940dec03ac22bba574c
```

## A — hot cache: two independently retained subscribers

The ROI already exists *before* the timed loop. Each iteration delivers
two distinct retaining owners, reads one sample through each, checks
pixel equality and retires both owners; no new raster is computed.
The baseline performs real copied `RasterLease!SRgba8` retaining while the
candidate performs the equivalent delivery with **controlled accounting**.
No thread GC allocation occurred in any of these timed stage loops.

| Statistic (per two-subscriber cache hit) | 16×16 | 64×64 |
|---|---:|---:|
| Raw RasterLease, median | **27.364 ns** | **26.728 ns** |
| Controlled DeliveryHandle, median | **40.668 ns** | **38.420 ns** |
| Median of **paired** controlled − raw | **+13.748 ns** | **+11.900 ns** |
| Median of **paired** controlled/raw ratios | **1.496321×** (+49.6%) | **1.440593×** (+44.1%) |
| Range of paired delta | +10.720 to +14.792 ns | −1.024 to +14.324 ns |
| Slower controlled rounds | **13/13** | **12/13** |
| Iterations per implementation | **3,250,000** | **3,250,000** |
| Observed thread-GC allocation in hot stages | 0 bytes | 0 bytes |

**Result:** additional accounting and checked delivery state cause a
repeatably measurable relative overhead at this tiny hot-path granularity,
but only about **12–14 ns** in absolute time per *two-subscriber hit*.
The previous isolated `tryRetain/close` +4 ns per pair describes a
different operation and is not directly additive.

## B — complete source-over, import, delivery, eviction, last refund

Each cycle includes a real prepared source-over RGBA composition, fresh
malloc-backed raster-d import, two independent subscribers, cache-owner
eviction, sampling after eviction and final budget refund. Raw uses
**explicit closed-world** manually tracked final release; controlled uses
`OwnedDeliveryCache` and two `OwnedDeliveryHandle` values.

| Statistic (per complete ROI cycle) | 16×16 | 64×64 |
|---|---:|---:|
| Raw, median | **34.6875 µs** | **489.7500 µs** |
| Controlled, median | **34.1875 µs** | **517.7500 µs** |
| Median of **paired** controlled − raw | **+0.0625 µs** | **+10.0000 µs** |
| Median of **paired** controlled/raw ratios | **1.001783×** (+0.18%) | **1.020712×** (+2.07%) |
| Range of paired delta | −5.2500 to +5.8125 µs | −185.8125 to +105.2500 µs |
| Slower controlled rounds | **7/13** (one tied) | **10/13** |
| Cycles per implementation | **208** | **208** |
| Stage GC allocation per 16 controlled cycles | **2,048 bytes** | **2,048 bytes** |
| Stage GC allocation per 16 raw cycles | **0 bytes** | **0 bytes** |

**Important statistical detail:** a median of *paired deltas* is not
the difference of the two independently calculated medians. Thus
16×16 independently has `34.1875 - 34.6875 = -0.5000 µs`, whereas
the paired median delta is **+0.0625 µs**; do not accidentally
replace the latter with the former.

The controlled cold workflow allocates **128 measured thread-GC bytes
per cache/ROI** (2,048/16), consistently on both ROI sizes. This
corresponds to the shared `DeliveryAccounting` metadata object.
Those bytes are **not** a complete bound on native backing/allocator
bookkeeping, peak memory residency, or all transient scratch objects.
The raw reference avoids that specific GC control-object allocation.

**Interpretation:** the cold 16×16 paired delta is indistinguishable
from run-to-run variability at the current sample size. At 64×64 the
paired median is about +2.1%, but the wide **negative and positive**
per-round excursions preclude a confidently quantified end-to-end
slowdown from this one short, unfixed-frequency run. Do **not**
advertise cold-cycle parity or a precise 2.1% regression as proved.

## Why the two workload results differ

Hot two-subscriber hits spend only tens of nanoseconds on ownership and
single-pixel access, so an extra 12–14 ns constitutes roughly
45–50% relative cost. Full ROI cycles include tens to hundreds of
microseconds of actual RGBA computation, import and allocation, so the
control plane is a far smaller fraction of timed work. But the
controlled cold path additionally creates a GC-managed accounting
object *per produced ROI*; this overhead remains a relevant memory
and GC-pressure concern even if CPU time appears small.

The raw path has **weaker semantics**, because its caller knows all
outstanding references and can manually refund after the last. That
does not solve independently escaped RasterLease last-release accounting
in a general public delivery API. No public raster-d refcount exposure
or lifecycle hook is justified solely by these timings.

## Research decision: DEFER production API admission

**Accepted as evidence:**
- real pinned native source and dependencies, successful functional
  paired comparisons and strong hot two-subscriber control-plane cost signal;
- measured per-produced-ROI GC metadata allocation; 
- no thread-GC allocation in warm-cache subscriber loops.

**Not established:**
- a statistically reliable small cold ROI time delta, exact worst-case
  native/GC overhead or peak memory reservation including GC metadata;
- multithread safety (raster-d lease count is non-atomic), cancellation
  races, arbitrary escaped raw leases, realistic cache key lookup or
  scheduler behavior;
- general adoption of move-only DeliveryHandle by consumer containers
  and UI workflows.

**Next qualification:** vary the number of subscribers/cache hits per
new ROI, not just an all-hot or all-cold binary workload. Include a
real-world hit/miss distribution, cache eviction pressure and measured
per-cache GC footprint, and repeat cold rounds under more stable CPU
affinity/frequency conditions with more full-ROI iterations. Preserve
the API distinction; report *amortized end-user workflow overhead*
rather than comparing feature-inequivalent primitives in isolation.

The original evidence archive is external to Git; this lightweight
report stores derived facts and stable checksums without committing
large binaries or replay snapshots. Keep Issue #74 OPEN and Draft PR
#73 stacked OPEN/DRAFT with no merge, source API promotion or sibling
repository edits.
