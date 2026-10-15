# M3 RGBA — Issue #74: Linux/glibc memory-residency qualification

**Status: research measurement protocol, XPS results pending.** This
is *not* an adopted memory budget or a public imagery API. The
preceding exact native [multigeneration XPS result](m3-rgba-generation-xps-2026-10-15.md)
verified a **256-byte thread-GC allocation delta** for one control
object, **not** total native/GС memory residency.

## Question

Three independently retained raster-d generations of the *same*
cache slot may overlap. The existing research ledger counts only
**4N retained pixel bytes plus an illustrative 64-byte metadata
allowance per generation**, and uses **8N + 128 bytes** at producer
peak. It does not include the measured 256-byte GC class, the
raster-d owned-buffer control blocks, glibc's allocation overhead,
allocator-held freed chunks, the source image fixtures, or the GC
heap's residency. A precise native memory or RSS upper bound cannot
be inferred from those ledger charges.

We must distinguish:

1. **Known requested pixel payload:** one actual packed RGBA
   `RasterLease!SRgba8` backing per live generation, four bytes
   per pixel, with `N=width×height`. At three simultaneously
   retained generations this is exactly `3×4N` requested bytes
   in this test. It is not the allocator's usable size or RSS.
2. **Illustrative accounted bytes:** `number of live generations ×
   (4N + 64)` in this prototype. This is an *example ledger*,
   neither all-in accounting nor a physical-memory limit.
3. **Thread-GC allocation counter:** observed bytes added to
   `GC.stats().allocatedInCurrentThread` for a newly constructed
   three-ticket metadata class, and cumulative across the test.
   This measures allocation events, *not* live GC heap or how long
   the accounting class remains strongly reachable.
4. **glibc allocator observations:** native `mallinfo2.uordblks`
   (allocated arena chunks), `hblkhd` (mapped malloc regions) and
   `fordblks` (free chunks held in arenas). These are process-wide
   and may include unrelated glibc/druntime allocations. They are
   **not** sums that may be added to `VmRSS` or to GC counts.
   Some allocations use mappings not represented as allocated
   `uordblks`; glibc mallinfo2 is only valid on the pinned
   Ubuntu/glibc execution environment.
5. **Operating-system residency:** `/proc/self/status` fields
   `VmRSS` and `VmHWM` in KiB, read with a fixed stack buffer.
   `VmHWM` is the process-lifetime high-water mark and may
   include a transient scratch peak that happened *between*
   our snapshots; it cannot attribute such a peak to one
   specific producer stage. `VmRSS` is sampled current resident
   memory, which may stay high when freed memory remains in
   allocator arenas or cached GC pages.

These five quantities measure different properties and **must not
be summed as a total.** No allocator-wide interposition,
backing-pointer access or modifications to raster-d are made.

## Actual workload

An independently compiled research consumer subcommand
`--generation-memory --side=<16|64|256|512>` allocates two real
RGBA source fixtures before the baseline, prepares the existing
source-over context, then creates three distinct real packed ROIs
(A, B, C) into **cache slot 0**. On each cache eviction, the old
generation's `GenerationDelivery` subscriber retains an independent
public raster-d lease. A/B/C coexist until explicitly released.
The test executes the full existing checked and prepared RGBA
compositor, owned resource import and move-only delivery logic.

A single process samples ten phases, with **no prints in the sampled
region**:

| Phase | Retained generations | Intended state |
|---|---:|---|
| fixtures | 0 | two input fixtures and prepared image state |
| accounting | 0 | one three-record GC accounting object |
| a_live | 1 | A packed backing delivered |
| a_evicted | 1 | A cache owner gone, external owner live |
| ab_live | 2 | B replaces A in the same slot |
| abc_live | 3 | C replaces B while A and B live |
| cache_exited | 3 | cache's stack owner exited; A/B/C external owners live |
| a_closed | 2 | A physically released/refunded |
| b_closed | 1 | B physically released/refunded |
| c_closed | 0 | C physically released; all tickets vacant |

The data schema records:
```text
experiment,side,phase,active_generations,
requested_live_payload_bytes,illustrative_charge_bytes,
thread_gc_cumulative_bytes,glibc_malloc_used_bytes,
glibc_mmap_bytes,glibc_free_bytes,vmrss_kib,vmhwm_kib
```

The Python validator rejects missing or reordered stages,
implausible generation/pixel/accounting counts, negative
measurements, GC allocation counter or `VmHWM` decreases, and
an inconsistent PASS trailer. It does **not** force `VmRSS`,
`mallinfo2` or GC allocated bytes to decrease upon a release.
It requires a strictly positive one-time GC control allocation,
but does **not** bake the previous 256-byte observation into a
cross-toolchain memory size guarantee.

### Validation and native runner

The independent consumer builds normally under DMD and LDC on
GitHub's Ubuntu CI. The new release smoke gate runs side 16 on
**DMD 2.112.1, DMD 2.113.0, LDC 1.42.0 and LDC 1.43.0**; LDC 1.43
additionally runs side 256. The validator has positive and
negative self-test fixtures, and the XPS shell runner gets
`bash -n` syntax validation.

Native LDC 1.43.0 with pinned raster/color **v0.2.0**:

```sh
bash tools/research/run_m3_rgba_generation_memory_xps.sh --smoke
bash tools/research/run_m3_rgba_generation_memory_xps.sh
```

The script builds **immutable archived snapshots** of imagery-d
`HEAD` and the two dependency tags into a fresh evidence
directory. The full run creates *five independent processes per
ROI side* for sides 16, 64, 256, 512 (**20 process traces**),
each with ten stage samples,  stdout/stderr, validated summary,
compiler/CPU/governor environment, build logs and SHA-256 manifest.
`--smoke` uses one run each for sides 16 and 256.
The user-host executable uses its normal release configuration
and the same independently tested consumer production calls.

## What the evidence will and will not establish

It can demonstrate:
- reproducible **requested payload vs ledger charges** for A/B/C;
- actual **host-specific glibc allocator behavior** under
  repeated separately launched generation scenarios;
- OS `VmRSS` snapshots and whole-process `VmHWM` evolution,
  including the effect of allocator reuse and page granularity;
- a clean split between *GC control-plane allocation count*
  and *native memory/residency observations*.

It cannot, even after the XPS run, establish an exact production
**all-in worst-case capacity formula**. In particular:
- the input fixtures are present before the baseline and are
  excluded from the three-generation *relative* count;
- the transient scratch/intermediate packing peak is not sampled
  as a stage on its own; `VmHWM` may include it but is
  process-wide;
- malloc arenas, mappings, allocator reuse, GC collector
  timing and page fault behavior are implementation-dependent;
- no caller-outside-delivery raw owner, arbitrary job queue,
  multithreaded reference counting, cross-thread cancellation
  or asynchronous publication is qualified.

**Next gate after observed XPS data:** build a separately
instrumented owned resource lifetime ledger/allocator experiment
or prove an allocator-bound contract, including transient scratch
and imported resource control blocks, *without leaking unrelated
research instrumentation into the public library*. This can
then inform an explicit bounded eviction/backpressure API design
and concurrency policy.

**Decision remains ADAPT research, DEFER public admission.**
Issue #74 OPEN, stacked PR #73 OPEN/DRAFT; no merge and no
write to raster-d/color-d or any other repository.
