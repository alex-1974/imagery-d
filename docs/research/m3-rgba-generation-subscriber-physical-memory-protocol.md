# M3 RGBA — retained-generation subscriber-count physical-memory control

**2026-10-15 · Research only · Issue #74 · Draft PR #73**

**Status: source/validator/runner implemented; actual XPS evidence NOT YET measured.**
Decision: **ADAPT** a paired diagnostic design; **DEFER** any production
memory budget/admission, API, merge or release. No changes to raster-d or
color-d. This is a *new* experiment, not an overwrite of the qualified
[20-process three-generation XPS observation](m3-rgba-generation-memory-xps-2026-10-15.md)
or the [24-process GC-range attribution](m3-rgba-native-gc-range-control-xps-2026-10-15.md).

## Exact question

When one fixed set of **three independently generated, retained public
`raster-d` RGBA backings** is held across a cache-slot eviction/replacement
sequence, what *additional Linux process memory observation* is associated
with **four independent subscriber handles per backing rather than one**?

This isolates subscriber *multiplicity* rather than conflating it with
creation of extra pixel buffers, independently released generations, or
shared druntime GC-range accounting.

**Null prediction (checkable at semantic/accounting level):**

- Each process has precisely three real, distinct-generation packed
  raster backings A, B and C, all surviving same-slot eviction.
- Exact byte-size of requested retained pixel buffers is **3 × 4 × side²**
  when A/B/C all live, in **both** subscriber conditions.
- The research ledger's **illustrative** charge is
  **3 × (4 × side² + 64)** in both conditions; the `+64` is not a
  measured or admitted metadata overhead.
- The extra subscribers hold **real independent raster-d leases**
  and must not each allocate a new packed pixel buffer or increment
  the *generation* charge.
- Closing the additional nine handles leaves one lease per generation,
  without refund; only closing the final three releases the backing
  and drops the ledger to zero.
- No assumption that RSS, `mallinfo2`, cumulative thread GC allocation
  or `VmHWM` differ by exactly zero bytes. They are measured observations,
  not semantic assertion thresholds.

## Frozen design and comparators

Implement in the **already independent research DUB consumer**:

`--generation-subscriber-memory --side=N --subscribers=1|4`

The same prepared pair of real source images and compositor is created
in both cases **before** the first checkpoint; the same A/B/C ROI
coordinates, source-over, packed import, cache-slot order and releases
are used. The four-subscriber arm performs nine extra independent
`GenerationDelivery.tryRetain` calls (three per generation).
No move-disabled handle is copied, no resource-bearing struct is placed
in a GC collection, and no new raster-d API is used.

Phases (all read from actual `sampleGenerationMemory()`):

1. `fixtures`: prepared independent source pixel fixtures.
2. `accounting`: sole fixed three-ticket accounting class.
3. `a_live`: one live A generation; one or four genuine subscriber handles.
4. `a_evicted`: A's cache owner removed, subscriber(s) still own pixels.
5. `ab_live`: two distinct generations with A's cache slot reused.
6. `abc_live`: three distinct packed output generations retained.
7. `cache_exited`: scoped cache destroyed; subscriber owners survive.
8. `extras_closed`: in four-subscriber mode, retire nine extra handles,
   retaining one primary handle per generation. One-subscriber arm is
   an intentionally idle control at this phase.
9. `a_closed`: final A owner released.
10. `b_closed`: final B owner released.
11. `c_closed`: final C owner released and full ledger refunded.

Independent release-built **XPS LDC 1.43.0** processes: ROI sides
16, 64, 256, 512; **five repeats per side/condition** =
**40 processes**. The `--smoke` mode uses ROI 16 and 256 with one
repeat (four processes). Compiler version and dependency peeled SHAs
are hard-checked; Git snapshots via `git archive HEAD` exclude
active untracked work. All evidence is written into a *fresh imagery-d*
directory with per-run log, empty stderr, normalized 11-stage CSV,
environment, builds and SHA-256 manifest.

The strict validator rejects missing/duplicate markers, phase-order
changes, wrong active/subscribe/charge/payload counts, malformed
integer metrics, GC cumulative counter regressions, and internally
inconsistent RSS/HWM snapshots. It **does not** assume monotonic
`VmHWM` across phases; the older 20-process XPS study observed seven
decreases on this host. Negative synthetic fixtures must be rejected.

`paired-subscriber-differences.csv` reports each stage's
**(four−four-fixtures) − (one−one-fixtures)** per-pair differences for
RSS, HWM, glibc `mallinfo2.uordblks/hblkhd` and thread-GC cumulative
allocations. These processes are independently started and paired only
by side and repetition index, not by shared allocator state.
No median or ratio from this experiment alone becomes an allocator
bound; even unchanged RSS cannot show that zero physical bytes were
ever allocated for extra handles.

## Limitations and decision rules

- The controlled variable is **1 vs 4 concurrent retained subscriber
  handles on each of three unchanged physical generations**.
  No thread concurrency or asynchronous cancellation is tested.
- All sampled memory metrics are *process-wide*. glibc's reported
  native used and mapped bytes are not the whole GC heap and cannot be
  added to `VmRSS` or cumulative GC allocations. Page reclamation,
  arena retention and previous allocations affect them.
- Sampling occurs at **11 named phase boundaries**, not within each
  malloc/free, GC collection, or process kernel mapping call.
  It cannot prove true instantaneous producer peak.
- A successful narrow observation supports the existing no-extra-pixel
  and no-extra-ledger-charge ownership model. It does **not** promote
  a physically complete memory-budget equation. Before that decision,
  evidence must cover GC allocation/residency, native usable sizes and
  producer high-water at all relevant moments, allocator reuse and
  multithread usage, with a specified admission policy and safety
  margin. Keep the research probe separate from release code.
- Exact physical per-subscriber bytes **cannot** be inferred just from
  a difference between two process `malloc` or RSS snapshots.

**Run only after green CI at the exact research HEAD:**

`bash tools/research/run_m3_rgba_generation_subscriber_memory_xps.sh --smoke`

`bash tools/research/run_m3_rgba_generation_subscriber_memory_xps.sh`

Archive the checksummed output **excluding `snapshot/`** and keep it
outside the Git history as raw evidence. Preserve the active stacked PR
base and its grandfathered workflow.
