# M3.2.20 — Independent Dell XPS scoped Prepared session audit

**Evidence date:** 2026-10-13 (archive timestamp `06:09:06 UTC`).  
**Verdict:** exact 40-process/25,600-ROI independently rechecked
functional and numerical evidence **PASS**; both execution strategies
have **0 measured hot-path GC bytes**, and a single scoped Prepared
session reduces the number of checked image/Prepared constructions
without losing mapped-pixel work. **Performance benefit is small
or inconsistent across most strata; no new persistent Prepared owner,
new public API, or general speedup is admitted.**

Tracking: [Issue #62](https://github.com/alex-1974/imagery-d/issues/62),
[stacked Draft PR #63](https://github.com/alex-1974/imagery-d/pull/63),
[exact M3.2.20 experimental contract](m3-2-scoped-prepared-session-contract.md),
[previous M3.2.19 failure/escape tests](m3-2-source-error-and-scope-contract.md),
[M3.2.18 independent XPS ordered ROI evidence](m3-2-metadata-source-xps-results.md).

## 1. Provenance

- **Original user-uploaded archive:** `prepared-session-20261013T060906Z.tar(1).gz`;
  independent SHA-256
  **`71880956739f08cee978d987fd7b94dce811d9a261932eb3ef0fa9a3818729cc`**.
  Its top-level directory is `prepared-session-20261013T060906Z/`.
  It contains **one additional nested 1,689,540-byte archive with a
  similar filename**, which was *not* used to substitute/replace the
  top-level process logs or CSVs. Store the original user archive outside
  Git; do not silently commit binary evidence.
- **Exact measured imagery-d HEAD:** `49c284f15d31f72cfed6a7c157bd685ca0ce2994`,
  branch `research/m3-2-20-scoped-prepared-session`.
  The same exact source HEAD passed
  [GitHub Actions #38309363285](https://github.com/alex-1974/imagery-d/actions/runs/38309363285)
  **4/4** on DMD 2.111/2.113 and LDC 1.41/1.43,
  including the complete LDC 1.43 hosted data runner.
  This hosted CI supports correctness/reproducibility **not**
  Dell XPS performance.
- **Local raster-d source HEAD:** `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`;
  **different from** peeled `raster-d v0.2.0` tag
  `2f2415851e45001df92ce56dad409f680684ba8d`.
  The build used the local `raster-d ~release/0.2`;
  these are **local dependency state research results**, not an exact
  tagged-v0.2.0 consumer benchmark.
- **Machine/toolchain:** Dell XPS 15, Intel Core i7-9750H
  (six cores, 12 hardware threads), Ubuntu
  `6.17.0-22-generic`, LDC 1.41.0 (DMD frontend 2.111.0,
  LLVM 19.1.7), DUB 1.40.0, optimized release configuration.
  CPU governor `powersave`, OS-default affinity, no pinned CPU
  frequency or thermal/scheduler tracing.
- **Worktree provenance:** imagery and raster had pre-existing
  **untracked generated test/benchmark binaries**; imagery also had
  earlier M3.2.16–18 evidence archives untracked. The archived
  `git status --short` does not indicate tracked source edits.
  No sibling repository was changed as part of this qualification.
- **Reported optimized binary SHA-256 manifest:**
  `16207522404021d54fcc00bda8dee4277126c84cbdd143b7fa40d05d50d7aaa5`.
  The archive includes `build.log`, `timed-binary.sha256`,
  `symbols.txt`, `disassembly.txt.gz` and previous M3 gates,
  but **does not include executable bytes**. The manifest hash
  therefore **cannot be independently recomputed from archived
  executable bytes**.

## 2. Independent completeness and numerical replay

This audit uses an independently written Python replayer operating
directly on the **raw original uploaded tar members**, without importing
the repository's `analyze_prepared_session.py` or treating its
CSV/JSON output as an oracle:

- **Exactly 40 independently launched OS processes:**
  5 repetitions × 2 modes (`reprepare`, `session`) ×
  2 sizes (8×8, 32×32) × 2 reuse counts (4,16).
- **80 measured original/refreshed phases**, each comprising
  32 logical packets. Thus **2,560 logical packets** in the
  complete evidence.
- **25,600 actually mapped ordered ROIs** (12,800 per strategy).
  The independent replay confirms **153,600 individual real
  output corner values** from those ROIs: all three output
  planes at first and opposite last pixel for each window.
- The independent expected pixel is reconstructed from
  selected source channels **254, 253, 255**, actual origin
  `(x,y)∈[(0,0),(3,7),(13,17),(29,23)]` in ordered cyclic
  packet/ROI indexing, stored channel sample
  `channel*16 + 2*y + x`, masked zeros when
  `(x+y)%11 == 0`, and exact metadata-generation
  calibration `original = sample*0.625 - 6`,
  `refreshed = sample*0.6875 - 7`.
- **All 153,600 observed corner samples PASS** against independent
  prediction, with **maximum printed-value absolute difference
  0.00500000000011**, within the archived printed-float tolerance
  **0.01001**. This is **rounding tolerance of the logged text**,
  not an error tolerance for the actual full-precision output.
  The D source compares its in-memory float values to independent
  expected values directly, plus checks **all three channels
  of every pixel of the last ROI**. The external replayer does
  not verify interior pixels of each intermediate ROI.
- Every 40-process log has exactly one success marker and a
  complete `original` then `refreshed` sequence, with
  **strict ROI order, packet index, ROI index, window origin,
  ROI side and selected values**. It rejects missing,
  duplicated or reordered expected rows by direct comparison.
- Every field of all 25,600 raw ROI rows matches
  `prepared-session-rois.csv`; all 80 raw phase records match
  `prepared-session-phases.csv`; all 40 independent
  process-level sums match `prepared-session-processes.csv`
  and the aggregate JSON. The repository analyzer's own
  success log was independently confirmed, **but it was
  not the basis of the independent oracle**.
- Every source phase reports **0 bytes allocated by druntime GC
  during mapped execution**. Both modes invoke the real checked
  mapped-pixel kernel; archived optimized symbols/disassembly
  include `runScopedPreparedSessionExperiment`,
  `tryMapOrderedInto` and
  `researchExecuteCheckedPixels`. The binary also contains
  `gc_malloc` calls for other setup paths; those do not
  establish allocation in the measured mapping hot path.

These are **source-specific correctness/allocation proofs**,
not a universal runtime/OS no-GC-pause or no-page-fault guarantee.

## 3. Measured setup amortization and actual work

The only intentional distinction is how the existing
`ResearchLongLivedMetadataSource.tryMapOrderedInto`
gets called:

- **`reprepare`:** **32 scoped adapter calls** per generation,
  each constructing a checked verified image + Prepared mapping
  for the packet's 4 or 16 ROIs.
- **`session`:** **1 scoped adapter call** per generation over
  the *exact same flat ordered ROI list*, keeping its internal
  Prepared value locally alive for the full 32-packet session.

Across the **20 processes per mode**, exactly **12,800 ROIs
per mode** were mapped. The source construction control
flow requires **1,280 preparation invocations** total for
`reprepare` and **40** for `session`; those are
*derived from verified source call structure and the log count
fields*, **not an independently traced internal instruction counter**.

Both actually perform all pixel mappings, GC hot-path allocation
zero, on the same workload. Neither optimization discards
validity checking or the actual checked per-pixel kernel.
Inputs, immutable snapshots, all windows and observation buffers
were constructed **before** the timed phases. The timed
`elapsed_ns` covers the entire sequence of actual adapter
calls (including Verified/Prepared setup), but **not**
caller object acquisition, output/oracle checks, text logging,
OS process launch or teardown.

### Five-process median of combined two-phase work

The following values are the **median of each process's
original+refreshed phase elapsed time**, in microseconds
for **64 logical packets** (32 per metadata generation).
They are **not** medians of packet samples and **not** whole
process wall time.

| ROI side | ROIs/packet | Reprepare median | Session median | Reprepare/Session median ratio | Session faster, repeat-group comparisons |
|---|---:|---:|---:|---:|---:|
| 8×8 | 4 | **182.0 µs** | **164.8 µs** | **1.104×** | **4/5** |
| 8×8 | 16 | **652.6 µs** | **651.5 µs** | **1.002×** | **3/5** |
| 32×32 | 4 | **2,395.6 µs** | **2,335.8 µs** | **1.026×** | **3/5** |
| 32×32 | 16 | **9,780.5 µs** | **9,466.7 µs** | **1.033×** | **4/5** |

The median-of-group-difference values (reprepare minus session)
are respectively **+8.7, +7.0, +30.5, +352.2 µs**;
single group differences have mixed signs in all four strata,
including as low as **−58.2 µs** at 8×8×16 and
**−298.5 µs** at 32×32×16. There are only
**14 positive out of 20** sequential launch-group comparisons.
Five repeats of each mode are **different OS processes, not
perfect matched/independent randomized within-process trials**;
the 20 signs span shared host/time/configurations.
Do not infer a significant universal speedup from these signs.

**Interpretation:** single-session preparation is safe and
can reduce fixed validation/binding work without changing
actual pixel work. The proportional gain is **most apparent
in the smallest 8×8×4 stratum**, around **1.10× ratio of
process medians**. Under 8×8×16, the selected performance
median is effectively the same. At 32×32, 1.03×
relative differences are small enough that host/runtime
variance is a material concern.

The **selected time savings**, not throughput ratios, are
`(reprepare − session)/reprepare`: about **9.45%,
0.17%, 2.50%, 3.21%** respectively, using medians
of separate process populations. No crossover or full
end-to-end consumer gain should be claimed from those
figures alone.

### Original and refreshed phase checks

Each policy/size/reuse also has **five original and five refreshed
phase records**. Their physical pixel values are different
by construction. The eight phase-stratum comparisons all
pass semantic equivalence between the two policy treatments
within a generation; the phase-median time ratios stay
near 1 (typical examples:
8×8×4 original **87.7/82.6 µs**,
refreshed **86.4/82.2 µs**; 32×32×16 original
**4,873.0/4,708.9 µs**, refreshed
**4,815.2/4,743.8 µs**).
There is no valid basis to infer that metadata refresh
is itself free: refreshing happens **outside** the stopwatch.

## 4. System/runtime confounders and codegen

- CPU governor `powersave`, no explicit CPU affinity or
  frequency stability measurement, unknown host contention
  and thermal state. The test is a **single Dell XPS 15
  workload at one source/toolchain state**, not a universal
  optimizer/architecture law.
- The workstation's **4 GiB swap was essentially full**:
  all five before-repeat `SwapFree` snapshots show only
  **232 KiB free**. This is a system state risk, **not**
  evidence that individual mapped phases incurred swap I/O.
- Across the **five before/after repetition windows**, OS
  `pswpin`, `pswpout` and `pgmajfault` changes were
  **zero in each window**. OS-wide `pgfault` increased
  by about **21,946–21,974 per repetition**, but that
  counter includes unrelated host activity and cannot be
  attributed to any specific phase or source policy.
- M3.2.20 does **not** record per-phase GC collection pause,
  per-process scheduling/wakeups or minor/major fault counters
  around the timed work. **0 GC allocated bytes is not
  0 collector activity**. There is **no guaranteed hard
  maximum latency** and no GC-causality assignment.
- Source structure and optimized disassembly preserve actual
  scoped Prepared and checked pixel execution. A symbol
  presence check corroborates that these functions were compiled,
  not that the per-policy setup count was measured at
  the machine-instruction level. Binary SHA manifest
  provenance is **not independently verified** without
  executable bytes.

## 5. Research acceptance and decision

**Accept M3.2.20 as correctness/lifetime evidence:**

1. Entire source/mask/metadata borrow remains live inside
   one checked, `@safe @nogc` scoped method call covering
   several logically distinct ROI packets, without escaping
   Prepared into a caller-held object.
2. Real physical pixel work is equivalent and externally
   observed in 25,600 individually ordered ROIs
   (153,600 observed corners, full final-ROI checks);
   the old and refreshed metadata generations remain isolated.
3. No new GC allocations in either measured mapping method.
4. Batching saves construction work *by code shape*; the
   performance benefit ranges from near-zero to ~10%
   throughput increase in this one XPS run, and individual
   repeat groups sometimes disagree.

**Do not promote** a new persistent `PreparedSemanticMap`
handle/owner or expanded public lifetime API purely from
these results. Avoid a premature `RasterLease`/metadata
refcount-ownership composite solely to save this currently
modest fixed work. Reuse the existing scoped API / batching
for natural multi-ROI consumer workloads. If a future real
consumer genuinely needs Prepared across separate calls,
design an **anchored** lifetime owner as a new, explicit
research question with negative escape/copy tests and a
fair same-work full-lifecycle reference workload.

**Further qualification if needed:** alternate packet/reuse
counts (to find a real crossover), quiet/pinned CPU,
independently measured phase tails, phase-level fault/GC
instrumentation, exactly tagged raster-d release comparison
and full caller acquisition/allocation lifecycle, rather
than citing only the best single median.

**PR #63 remains OPEN/DRAFT and stacked on PR #61;**
no merge to `develop` or write to any sibling repository.
