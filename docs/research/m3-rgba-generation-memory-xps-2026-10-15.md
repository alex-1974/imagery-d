# M3 RGBA — native XPS generation-memory evidence (2026-10-15)

**Issue:** [imagery-d #74](https://github.com/alex-1974/imagery-d/issues/74).
**Disposition:** ADAPT research; **DEFER** all-in resident-memory admission and public API.
This report archives native single-host evidence and does **not** replace the
[measurement protocol](m3-rgba-generation-memory-qualification.md).

## Original archive, integrity and provenance

User-delivered `imagery-m3-generation-memory-xps.tar.gz`, SHA-256:

```
014d18b2c8c715fa4e85d425fedda5a5ca884eca843a99c7afbb9822d79131c0
```

- Capture timestamp: **2026-10-15 07:47:07 UTC**.
- **65 tar entries** including the root directory, **64 regular files**:
  20 full phase stdout traces, 20 strict validator summaries,
  20 standard-error logs, `environment.txt`, `build.log`,
  `summary-self-test.txt`, and `CHECKSUMS.sha256`.
- Independently recomputed **all 63 / 63 file SHA-256 digests** in the
  embedded manifest: **PASS**. No unchecksummed regular files,
  duplicate paths, unsafe absolute/parent-traversal names or links.
- Every stderr file is empty; all 20 consumer logs terminate with
  `M3 GENERATION MEMORY PASS:`. The validator self-test is PASS,
  and the LDC release consumer compiled and linked successfully.
  The only build diagnostics are existing nonfatal `mir-core 1.7.4`
  `ldc.intrinsics.LLVM_version` deprecations.
- Independently parsed **200/200 ten-phase rows** and all 20 stored
  CSV summaries. The ordered 0→1→1→1→2→3→3→2→1→0
  active-generation profile, exact `4 × side²` per-generation
  packed RGBA bytes, exact illustrative `4 × side² + 64` per-generation
  charge, recorded control-GC delta and counts of `VmHWM` decreases
  all agree with the original traces.
- Example raw-file SHA-256: `side-256-run-0.txt`
  `83bbfbcd987da9bc9e4b2daca29e03fb22877af4f2a6ccd2be1d02bd6564b1dc`;
  `side-512-run-0.txt`
  `e1efd54ebc23af1151d73fd0244b19f6ab687a9e940c92ee27baf475bb10bf19`.
  **The original archive, not rounded values below, is the raw source.**

| Item | XPS recorded value |
|---|---|
| Computer | `xps-15`, Intel Core i7-9750H, 6C/12T |
| Kernel | Linux `6.17.0-22-generic`, Ubuntu x86_64 |
| Compiler | **LDC 1.43.0**, release build |
| DUB | **1.42.0** |
| imagery-d immutable HEAD | `ba646c96f0dda1d4359a3b2af809d74f1e368c45` |
| raster-d v0.2.0 SHA | `2f2415851e45001df92ce56dad409f680684ba8d` |
| color-d v0.2.0 SHA | `3359f08f4e83941ac1a8451cadefb146b5736019` |
| CPU governor | `powersave` on all 12 logical CPUs |
| Build source | `git archive HEAD` plus pinned tagged dependencies; local untracked build files and old research archives **excluded** |
| GitHub CI for exact source | **5/5 workflows SUCCESS** |

The archive intentionally contains no source snapshot; the exact source
SHA and dependency pins identify the immutable build inputs. The binary
original archive is **not committed to Git**.

## Experimental unit and exact payload contract

Every recorded process creates *two source-image fixtures before its
initial checkpoint*, a fixed three-ticket `GenerationAccounting`
object, and three separately retained physical `raster-d` packed
RGBA backings A/B/C. Each succeeding generation replaces the same
cache slot while the previous generation remains externally held.

There are **five independent release-process invocations per side**,
at ROI sides 16, 64, 256, and 512: **20 separate processes total**.
Ten snapshots within each process cover `fixtures`, `accounting`,
`a_live`, `a_evicted`, `ab_live`, `abc_live`,
`cache_exited`, `a_closed`, `b_closed`, `c_closed`.

The snapshot sampler records actual requested packed-pixel bytes,
the deliberately **illustrative** ledger charge, current-thread
cumulative GC allocation, process-level glibc `mallinfo2`
`uordblks/hblkhd/fordblks` and Linux
`/proc/self/status` `VmRSS/VmHWM`. Memory and per-request
timing distributions are **different experiments**: no throughput,
codegen comparison, allocation-time peak, whole-GC heap size or
allocator-call hook appears here.

## Process RSS observations

The table reports **median of five within-process paired differences**
from the `fixtures` checkpoint. Brackets show the minimum and
maximum paired differences across those five separate processes.
RSS is in **KiB**; requested payload is in **KiB** but is not RSS.

| ROI side | Requested retained A+B+C payload | Δ RSS at `abc_live` vs `fixtures` | Δ RSS at `c_closed` vs `fixtures` |
|---:|---:|---:|---:|
| 16 | 3 KiB | **104** [104, 228] KiB | **104** [104, 228] KiB |
| 64 | 48 KiB | **168** [164, 292] KiB | **168** [164, 292] KiB |
| 256 | 768 KiB | **1,124** [1,124, 1,192] KiB | **224** [224, 292] KiB |
| 512 | 3,072 KiB | **4,196** [4,196, 4,324] KiB | **224** [224, 352] KiB |

The baseline itself includes source fixtures, the D runtime and
whatever initial allocations are resident. These observations
**cannot be decomposed** to an exact per-raster RSS charge.
At small ROIs freed chunks remain resident in process/allocator
arenas; at larger ROIs RSS falls markedly when native mappings
are retired. The nonzero final RSS delta is **not** evidence that
a public `RasterLease` owner remains after the ledger reaches zero.

## glibc allocator observation, distinct from RSS

This table uses medians of **within-process** changes from
`fixtures` to `abc_live`, and from `fixtures` to
`c_closed`, for `mallinfo2.uordblks` and `hblkhd`.
All numbers are raw **bytes**. Their sum is a diagnostic
glibc-reported delta, **not** total process memory and **must not**
be added to RSS or to the GC allocation counter.

| ROI side | Δ `uordblks` at A+B+C | Δ `hblkhd` at A+B+C | Δ (`uordblks+hblkhd`) at A+B+C | Δ (`uordblks+hblkhd`) after all close |
|---:|---:|---:|---:|---:|
| 16 | 38,256 | 0 | 38,256 | 38,256 |
| 64 | 84,352 | 0 | 84,352 | 35,152 |
| 256 | 559,648 | 266,240 | 825,888 | 35,328 |
| 512 | 2,132,288 | 1,052,672 | 3,184,960 | 35,104 |

The clear 256/512 pattern shows that the allocator used a mapped
region for one of the large owned backings and arena chunks for
others; after final closes the extra `hblkhd` mapping is gone.
For sides 16 and 64 there were **no recorded mapped malloc bytes**.
A roughly 35 KiB retained glibc-reported delta from the fixture
baseline remains in many profiles (including after final owner
retirement). The process-wide allocator numbers include unrelated
runtime effects; that residual **cannot** be assigned wholly to
control-record overhead, and the observed deltas are not a certified
per-generation allocator cost. A cache-creator-only control GC
allocation is separately measured below.

## GC metadata and control ledger

Every one of the **20/20** runs observed:

- `GC.stats().allocatedInCurrentThread` = **0** at `fixtures`;
- exactly **+256 bytes** upon construction of the one
  three-generation `GenerationAccounting` metadata class;
- **no further thread-GC allocations** at any sampled stage,
  from A/B/C creation through cache destruction and final close;
- exactly **0 accounted bytes and 0 active generations**
  after final C close, with physically retained A/B/C owners
  having been explicitly released in their tested scopes.

This reproduces the earlier XPS multigeneration report's
256-byte class observation and all eight compiler/variant
consumer observations on hosted GitHub CI. It measures cumulative
allocation events only; there is **no sampled live GC-heap size**,
collector pause or automatic GC release proof. The 64-byte
metadata included in each **illustrative** delivered-generation
charge is less than the separately observed one-time 256-byte
class allocation and cannot be interpreted as a complete
physical budget.

## Empirical Linux `VmHWM` anomaly: reproduced

Although nominally a high-water mark, `VmHWM` is **not
monotonic in all of these actual host traces**. A sampled
decrease occurred after `cache_exited` at the `a_closed`
event in:

- **0/5** side-16 runs;
- **0/5** side-64 runs;
- **3/5** side-256 runs, with drops of **64, 80, 64 KiB**;
- **4/5** side-512 runs, with drops of **64, 64, 100, 64 KiB**.

Overall: **7 of 20 independent processes** recorded one
`VmHWM` decrease. The phase-stage validator records the
original values, counts and maximum decreases rather than
discarding correct lifetime evidence. All process snapshots
still satisfy **`VmHWM >= VmRSS` within the same sample**,
and the cumulative GC allocation counter remains monotonic.

This is evidence about the behavior of the **sampled Linux
process statistic**, not about a violation of raster ownership
or a decrease in actual historical maximum RSS. The maximum
*observed* `VmHWM` over these ten checkpoints is not a
certified exact peak RSS either.

## Research interpretation and next gate

**Qualified by this pinned release evidence:** exact 20/20
phase-accounting traces with real packed output and independent
generation final closes; requested pixel payload and ledger
counter laws; 20/20 observations of 256 thread-GC bytes for
the metadata class; process-level glibc/RSS dynamics and
the repeated nonmonotonic `VmHWM` reporting effect.

**Still unqualified:**

1. **All-in exact memory admission bound** covering producer
   scratch, transient packed import, raster-d native backing
   control blocks, allocator overhead, retained generations,
   shared GC class, GC heap residency and the source fixtures.
2. Exact allocation **peak at materialization time**:
   ten checkpoints bracket the producer, not each malloc/free;
   even `VmHWM` is an insufficient allocator-level contract.
3. Multiple threads, asynchronous cancellation and a
   production queue/backpressure/cache policy. The current
   `raster-d` reference-count ownership remains non-atomic.
4. Generalization across other libc/OS/compiler combinations
   or user-sized caches and ROI distributions.

**Next evidence:** a separately scoped allocation-event
instrumentation probe at the owned-raster construction/import
boundary, with exact requested bytes and native control-block
cost, plus a live/peak counter that stays meaningful independent
of OS page-reclamation behavior. First distinguish instrumented
`malloc` requests, `raster-d` control-record costs, and
intermediate staging lifetimes; then synthesize an explicit
bounded admission equation. Keep all instrumentation in
research code, not in the lean production package.

**Decision: ADAPT research; DEFER public API / memory-bound claim.**
Keep Issue #74 OPEN and stacked PR #73 OPEN/DRAFT.
The original binary evidence archive remains user-held,
not Git history; no sibling repositories have been modified.
