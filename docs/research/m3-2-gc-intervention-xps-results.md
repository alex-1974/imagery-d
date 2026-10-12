# M3.2.16 — Independent Dell XPS GC-intervention qualification

**Audit date:** 2026-10-12.
**Decision:** evidence integrity **PASS**; 20 timed GC collections in the normal
condition demonstrably coincide with important setup spikes. Explicit
per-batch precollection **moves work outside the measured region and loses
badly when accounted for**. Bounded deferred collection prevents recorded
in-batch cycles but **increases typical setup cost, heap growth, minor page
faults, and leaves substantial non-GC tails**. **No release- or production-GC
policy is admitted.**

Tracking: [issue #54](https://github.com/alex-1974/imagery-d/issues/54);
[draft stacked PR #55](https://github.com/alex-1974/imagery-d/pull/55);
[M3.2.16 protocol](m3-2-gc-intervention-protocol.md);
[M3.2.15 earlier measured GC-order tails](m3-2-gc-order-xps-results.md).

## 1. Source, provenance, limits

- **Archive:** `gc-intervention-20261012T123133Z.tar.gz`, exact
  SHA-256 **`50dd5facccbbe09a618e4c24d8a6a1f4c4fe12ba9f21dc1b96abc14a053fd03a`**.
  Raw archive remains externally supplied, not binary-bloated Git history.
- **Measured imagery HEAD:** `5899e16ff41eff0d369e0dd5ca42fc8658ff413c`,
  branch `research/m3-2-16-gc-intervention`; the same exact code has
  [four-compiler functional CI SUCCESS](https://github.com/alex-1974/imagery-d/actions/runs/38248728229)
  (DMD 2.111/2.113, LDC 1.41/1.43).
- **Raster dependency HEAD:** `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`,
  not the `v0.2.0` peeled tag `2f2415851e45001df92ce56dad409f680684ba8d`.
  Thus results are **local dependency-state research**; the archived build
  identifies raster-d `~release/0.2`, not the tagged 0.2.0 release.
- Dell XPS 15, Intel i7-9750H, Ubuntu kernel 6.17.0-22-generic,
  LDC 1.41.0 (DMD frontend 2.111.0 / LLVM 19.1.7), DUB 1.40.0,
  LDC release build, default CPU affinity / `powersave` governor,
  nearly full 4 GiB swap (412 KiB free at start). The experiment did not
  independently control CPU clocks, system contention or thermals.
  The worktree audit lists only pre-existing untracked generated imagery
  and raster artifacts; this audit **does not modify sibling repositories**.
- **Binary SHA manifest:** `7e473a5db140ecacdd9b45d14f818d14240965564a2e0618193a57c2a24eaf16`.
  The binary itself was **not archived**, so its hash cannot be independently
  recalculated; symbol list, full compressed disassembly, build and compiler
  negative gates were retained.
- Precisely 5 repeats × 3 distinct GC-policy **OS processes** × 1,024
  recorded rounds = **15,360 measured batches**. Each batch performs two
  independently allocated immutable metadata snapshots of 256 mutable
  channel descriptors, verified-image and Prepared binding, and **one
  actual 32×32 planar/validity 3-component calibrated ROI mapping**.
  Each process also runs 16 unrecorded warmups. These are between-process
  comparisons, **not 7,680 within-process matched target/control pairs**.

## 2. Independent integrity and codegen audit

The archive was independently parsed **without importing the repository
`analyze_gc_intervention.py`**:

1. All exactly **15 expected uniquely keyed log files** and exact contiguous
   1,024-round policy/process matrices; no missing, duplicate or reordered
   rounds/policies.
2. Separately regenerated each recorded checksum for the first mapped pixel
   of every ROI, including rotating metadata choice, binding permutation,
   physical scale/offset, validity and pixel origin. Independent oracle and
   logged `checksum` and `expected`: **15,360/15,360 PASS**.
3. Every source log record versus `gc-intervention-raw.csv`: identical;
   all 15 process-median/max/GC/heap/fault summaries reproduced from logs
   and matched both `gc-intervention-processes.csv` and JSON.
   All **27 setup tails >50 µs** independently matched JSON.
4. Program output additionally reports its independently checked **full
   three-component last-ROI pixel oracle** PASS on all 15 processes.
   The external oracle checks *every recorded first-pixel result*, not all
   intermediate pixels; for reuse=1 the final ROI is the only ROI.
5. Archived positive and compiler-negative M3.2.6/9/11/12 gates PASS,
   including source/lifetime escapes and private-constructor forging.
6. LDC disassembly retains the actual `measureReuseBatch` call from
   `measureGcInterventionBatch`, both `gc_malloc` + `memcpy`
   snapshot copies, the real Prepared mapping wrapper, bracketing
   `GC.stats`, `GC.profileStats`, `getrusage`, and conditional
   `gc_collect`/`gc_disable`/`gc_enable`. The active paths are
   not success-bit-only optimization artifacts.

Measured StopWatch values have **100-ns granularity**; sub-resolution
effects and close single-batch deltas require caution.

## 3. Actual measurements: three different cost contracts

All rows below concern the same 256-channel 32×32 1-ROI physical mapping
workload; units are **microseconds per batch** except counters/memory.
Each policy has **5,120 measured batches** across five processes.

| Recorded metric | Normal automatic GC | Explicit precollect before every batch | Bounded deferred GC |
|---|---:|---:|---:|
| Median setup inside timed batch | **1.4 µs** | **0.7 µs** | **6.8 µs** |
| Median complete timed batch | **10.6 µs** | **10.0 µs** | **16.2 µs** |
| Maximum setup | **751.0 µs** | **27.2 µs** | **154.5 µs** |
| Setup >50 µs | 18 | 0 | 9 |
| GC collections in timed batch | 20 | 0 | 0 |
| Collections explicitly before timer | 0 | **5,120** | 0 |
| GC pause inside timed batch, summed | **4.1345 ms** | 0 | 0 |
| GC pause explicitly before timer, summed | 0 | **139.1152 ms** | 0 |
| Minor / major faults inside batch, summed | 5,052 / 0 | 0 / 0 | **22,550 / 0** |
| Maximum reported used GC heap | 4,547,264 B | 177,664 B | **18,728,976 B** |
| GC allocation in timed batches | 90,849,280 B | 90,849,280 B | 90,849,280 B |

Snapshot allocation is **exactly 17,744 B per batch** in all three
policies. Thus neither `GC.disable()` nor `GC.collect()` replaces
the copies or makes the operation `@nogc`.

**Whole selected sample, measured time accounting:** summing the
individual recorded `total_ns` batch values across five processes
and then adding *explicit outside-timer collection wall time*:

| Cost (all 5,120 batches per condition) | Normal | Precollect | Deferred |
|---|---:|---:|---:|
| Sum of timed batch wall times | **68.5479 ms** | **53.4601 ms** | **88.0709 ms** |
| Explicit before-batch `GC.collect` wall time | 0 | **142.6184 ms** | 0 |
| **Sum of these recorded components** | **68.5479 ms** | **196.0785 ms** | **88.0709 ms** |

The last row is **not an independently timed whole-process duration**:
it excludes setup of input fixtures, instrumentation, oracles,
GC toggling and program exit/cleanup. Still, the two collection costs
are not interchangeable. A low *in-window* precollect median cannot
justify calling this policy fastest or allocation-free. With the
external collection work counted, this protocol's selected recorded
components cost **~2.86×** those of automatic GC; compare *process-level*
sample totals as well before extrapolating.

Per-process totals (normal vs precollect, including explicit
outside-timer work, vs deferred), **ms**:

| Repeat | Normal | Precollect with external collection | Deferred |
|---:|---:|---:|---:|
| 0 | 13.238 | 39.124 | 17.365 |
| 1 | 13.662 | 39.864 | 17.420 |
| 2 | 13.447 | 39.515 | 18.605 |
| 3 | 14.928 | 38.847 | 17.693 |
| 4 | 13.274 | 38.728 | 16.987 |

These are *separate-process* comparisons with different collector and
heap histories. They are strong for **mechanism and cost visibility**,
not a universal cross-policy consumer performance verdict.

## 4. Natural GC threshold and real-time tails

Normal GC executes **exactly four timed collections per process**,
always at recorded rounds **225, 471, 718, 965**. With 16 warmups,
these repeat approximately every **246–247 snapshot batches**, i.e.
roughly 4.36 MiB of reported GC allocations per interval
(17,744 B × 246 ≈ 4.37 MB). Just before the first collection,
reported `GC.stats().usedSize` reaches **4,547,264 B**; immediately
after, **178,864 B**. Subsequent pre-collection usage is approximately
4,527,456 B. This is **consistent with** a repeated GC heap
threshold/pressure trigger; the collector's exact algorithmic trigger
and heap growth policy were not instrumented. Do not label 4.5 MB
a universal GC threshold.

The first collection at round 225 incurs setup delays per process:
**751.0 / 643.0 / 555.3 / 730.6 / 410.0 µs**. Matching GC pause:
**739.8 / 635.4 / 543.4 / 718.2 / 394.7 µs**. They account
for ~96–99% of those first spikes. Of the 20 in-window collections,
**16** coincide with setup >50 µs; four more GC intervals yield
46.8–49.5 µs setup and are retained. Two **additional** normal
setup >50 µs spikes (90.9 and 111.6 µs, both in process 3)
have **zero recorded GC cycles**, four minor faults each.

**No production tail bound** can be inferred: normal path's
max of 751 µs remains a real consumer-visible occasional stall.

## 5. Deferred GC produces a different repeatable no-GC tail

Deferred `GC.disable` executed **zero** reported in-batch cycles
and **zero** reported collections after `GC.enable` in this run.
But it retained all 17,744 B of per-batch GC allocation and the used
heap grew to **18,728,976 B** by the end; its maximum reported used heap
is **4.1×** normal and **105×** precollect. It accumulated **22,550**
minor faults versus normal 5,052, despite zero major faults.

A particularly clear reproducible event: in **every deferred process**,
**recorded round 710** has a **131.8–149.5 µs setup** with exactly
**77 minor page faults** and zero GC pause:

| Repeat | Setup at round 710 | Minor faults | GC collections |
|---:|---:|---:|---:|
| 0 | 146.0 µs | 77 | 0 |
| 1 | 149.5 µs | 77 | 0 |
| 2 | 139.1 µs | 77 | 0 |
| 3 | 137.9 µs | 77 | 0 |
| 4 | 131.8 µs | 77 | 0 |

All have `heap_used_before=13,155,680 B` and
`heap_used_after=13,173,440 B`. The same deterministic
allocation position and large minor-fault count point to
**GC heap page provisioning / OS page mapping as a candidate**
for this *non-collection* stall. No allocator or page-map trace
isolates its exact mechanism, so the claim remains conditional.

Four additional deferred >50 µs setups vary by process and are also
reported without a GC collection. The maximum deferred setup is
**154.5 µs**; it does not guarantee absence of latency spikes.

At the per-process time-sum level, deferred is **more expensive in
this workload**, despite removing collection pauses. Do not promote
`GC.disable` as a long-running production strategy; D's emergency
allocation conditions may still cause collection, and memory is
not reclaimed through this probe.

## 6. Precollect moves work; it does not eliminate it

Every recorded precollect batch runs one explicit `GC.collect`
*before* timing (5,120 outside-timer cycles). The **median explicit
collection wall time is 26.7 µs**, maximum **87 µs**.
Across all five processes, explicit collection wall time sums to
**142.6184 ms**, with GC-recorded pause time **139.1152 ms**.
No collections, pauses or minor faults were recorded *inside* the
timed batches; their setup median is 0.7 µs.

Thus precollect is a useful **positive control** showing that
collections can be displaced outside the measured region, but it
is **not an amortizing precollection policy**: collecting before every
one-off ROI makes total recorded work substantially larger.

No external collection is required for every ROI in a real program;
a later design could explore **strategic, infrequent** manual
collections based on a consumer-controlled idle period with full
lifecycle accounting. That possibility remains unmeasured here.

## 7. Host, paging, and codegen constraints

Five per-repeat before/after system snapshots report **no change**
to `pswpin` or `pswpout`. `getrusage` also recorded zero major
faults in the 15,360 timed batches. The near-full swap is therefore
a documented **host-pressure confound**, not a demonstrated cause
of these specific observed stalls. Minor faults are real and strongly
different under deferred collection; process-wide rusage deltas do
not identify allocator origin.

`GC.stats` used/free heap observations may lag immediately-live
object state, and `GC.profileStats` collections are counts of
reported GC activity, not a stack-level trace of the triggering
allocation. This is a research Linux-only instrumentation surface
and does not change any public imagery-d platform or GC promise.

The three conditions use distinct processes and rotate launch order,
but do not have equal heap histories by construction. Medians from
1024 rounds are correlated within each process; **five independent
process repetitions are the proper replication unit**, not 5,120
independent random trials.

## 8. Decision and next controlled experiment

**Research accepted:**
- full record integrity; independent calibrated pixels; retained
  static safety and private-access tests;
- four natural GC cycles/process at repeated allocation positions,
  with observed GC pause duration tightly matching largest setup tails;
- external precollection demonstrably transfers collection outside
  timed work, but adds larger lifecycle cost at frequency one/batch;
- deferred automatic collection removes measured cycles, **not**
  per-batch allocations, page faults or tail latency;
- repeatable minor-fault-related, collection-free round-710 spike,
  with bounded evidence for a page-provisioning hypothesis.

**Not admitted:** universal Prepared reuse breakpoint; stable bounded
worst-case latency; recommendation to disable GC; a no-GC snapshot
claim; exact `raster-d v0.2.0` release result; new public API;
merger of the stacked research into `develop`.

**Focused follow-up:** compare realistic **reuse=4/16** under the
same actual pixel semantics and add bounded **allocation/reuse and
lifetime options** to minimize repeated mutable descriptor snapshots
without weakening ownership; separate a low-frequency precollect
during consumer-idle periods from artificial per-batch collection.
For a causal OS-paging claim, instrument GC-heap allocation/page
commit and CPU scheduling around deferred round 710, with controlled
affinity and substantially lower memory/swap pressure. Any optimized
path must preserve exactly the current immutable ownership and full
pixel oracle. **Do not modify raster-d to complete this imagery-d
research.**

**PR #55 stays OPEN/DRAFT** stacked above PR #53. Raw archive stays
outside Git; the relevant measurements and negative conclusions are
retained here as a reproducible summary.
