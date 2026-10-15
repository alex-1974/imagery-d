# M3 RGBA — native XPS matched allocation-control results, 2026-10-15

**Issue:** [#74](https://github.com/alex-1974/imagery-d/issues/74).
**Research disposition:** **ADAPT** the measured allocation-lifetime
model, **DEFER** public API admission, exact `raster-d` control-block
type attribution, and an all-in resident/native admission budget.
The original evidence archive is user-held, *not* committed.

## Source, environment and verification

Uploaded evidence archive:
`imagery-m3-native-alloc-controls-xps.tar.gz`

```text
SHA256  9c0f8feb443d84e5fbdc13e875a765db5581419d6bec336346330d8b2ae48de1
```

- Archive has **247 tar entries**, **246 regular files** and one
  directory. There are **no duplicate, absolute, parent-traversal,
  linked or unexpected file types**.
- All **245/245 SHA-256 entries** in the embedded
  `CHECKSUMS.sha256` were independently recomputed and verified.
  All other regular files occur in the manifest.
- Four controls × four ROI sides × three independent release processes
  = **48/48 complete traces**, each with **nine correctly ordered**
  allocation phases, nine-stage summary and one aggregate CSV.
  **48/48 consumer PASS**, **all 48 stderr files empty**,
  Python control-parser self-test PASS. The C interposer build log
  is empty and the D release consumer linked successfully.
- The original raw FD9 events were **independently replayed into a
  separate per-pointer outstanding-bytes ledger** (not trusting the
  precomputed summary CSVs). All 48 stage-CSV counters, free
  lifetimes, complete aggregate summaries and all exact
  `raw → import → full` phase comparisons agreed.
- The D build contains only previously observed,
  **nonfatal** `mir-core 1.7.4` LLVM-version deprecation
  diagnostics. There are no build failures.
- Observation timestamp: **2026-10-15 09:53:23 UTC**.
  Host `xps-15`, Intel Core i7-9750H (6C/12T),
  Ubuntu/Linux x86_64 kernel `6.17.0-22-generic`,
  LDC **1.43.0 Release**, DUB **1.42.0**,
  `cc (Ubuntu 15.2.0-16ubuntu1) 15.2.0`.
- Immutable imagery source commit:
  `eabe1bd0ead50e0c1c0b2105155eec735dbdb26d`;
  **5/5 GitHub workflow gates SUCCESS**, including the full
  independent four-compiler consumer matrix.
  raster-d `v0.2.0` =
  `2f2415851e45001df92ce56dad409f680684ba8d`;
  color-d `v0.2.0` =
  `3359f08f4e83941ac1a8451cadefb146b5736019`.
- The runner builds from `git archive HEAD` and pinned dependency
  tags. The worktree's separately listed untracked build/research
  files are **not included** in these source snapshots.

This result follows the prior
[12-process full-path native event study](m3-rgba-native-allocation-events-xps-2026-10-15.md)
and the [four-way controlled experiment specification](m3-rgba-native-allocation-controls.md).

## Controlled comparison

All four cases share the same instrument, nine phases, warm
source-image fixtures (before tracing), prepared source-over context,
per-phase Linux/glibc memory sampling and one fixed-three-ticket
accounting class. The different paths are:

| Mode | Pixel allocation | Raster-d adoption/import | Compositing |
|---|---|---|---|
| `markers` | no new tagged pixels | common source fixtures only | no |
| `raw` | three direct malloc scratch/packed pairs | common source fixtures only | no |
| `import` | same three pairs, publicly adopted/imported | scratch and packed ROI backing | no |
| `full` | actual producer ROI buffers | yes, with cache delivery/eviction | real prepared RGBA source-over |

The opt-in raw control uses a C-compiled opaque volatile touch to
prevent LDC from dead-eliminating a scratch malloc; the strict
pointer/free contract remained unchanged. The interposer is a
**single-instrumented-thread LD_PRELOAD/glibc research helper**,
not a general-purpose allocator profiler and not an installed
imagery-d dependency.

### All-ROI result, three native repeats per size

The **unclassified** event counts/bytes below are identical
across ROI sides **16, 64, 256, 512** and across the three
separately launched processes at every side.

| Metric, entire nine-stage trace | `markers` | `raw` | `import` | `full` |
|---|---:|---:|---:|---:|
| Explicit tagged pixel `malloc` calls | 0 | 6 | 6 | 6 |
| Other intercepted `malloc`-like calls | 31 | 31 | **61** | **61** |
| Total other requested bytes | 48,800 | 48,800 | **50,576** | **50,576** |
| Other bytes in stage 1 | 36,832 | 36,832 | 36,832 | 36,832 |
| Other requests in producer stages 2+4+5 | 4,488 | 4,488 | **6,264** | **6,264** |
| Other outstanding requested bytes at stage 9 end | 35,336 | 35,336 | 35,336 | 35,336 |
| Frees with no allocation recorded during trace | 1 | 1 | 1 | 1 |

Thus `raw - markers` adds **only the six tagged known pixel
buffer allocations** in this setup. `import - raw` adds
**exactly 30 unclassified intercepted calls, requesting 1,776
bytes total**, and they all originate in the three producer
stages. `full - import` adds **zero intercepted calls or
requested bytes at every measured stage**. That equality is a
**host/compiler/workload observation**; it does not prove that
all compositor operations are allocation-free on all systems,
or that their memory costs and ownership structures are
universally identical.

### Producer-stage import-associated event signature

In each producer stage (A=2, B=4, C=5), subtracting the
`raw` event histogram from `import` reveals:

| Additional unclassified requested block size | Additional calls | Requested bytes |
|---:|---:|---:|
| 24 B | 2 | 48 B |
| 40 B | 2 | 80 B |
| 48 B | 2 | 96 B |
| 88 B | 2 | 176 B |
| 96 B | 2 | 192 B |
| **Total** | **10** | **592 B** |

Crucially, the pointer-specific trace distinguishes **when**
these extra native requests are freed:

- **Four additional allocations per generation**, one each
  of **24, 40, 48, 88 B**, together **200 B**, remain
  outstanding after their producer and are freed exactly
  in the respective final owner stage **A→7, B→8, C→9**.
- The other **six additional allocations**, one each of
  24, 40, 48, 88 B and two of 96 B,
  total **392 B**, are all freed within their own
  producer stage **2, 4 or 5**.
- Three simultaneously externally retained generations
  therefore account for an additional **600 B of
  intercepted requested bytes** relative to raw
  at `abc_live` and `cache_exited`, and the surplus
  returns to zero with the three final closes.
- This is reproducible in **all 36 `raw`/`import`/`full`
  paired comparisons** (four sizes × three processes ×
  three compared paths).

The enduring **200 B per retained generation** is a
*requested-size/lifetime association with the import
path*, **not** independently identified native
`raster-d` control-block type/size. The 392 B of
same-producer temporary requests are also not yet
attributed to specific code paths. Allocation headers,
usable-size rounding, GC-class residence, direct `mmap`,
threaded allocator activity and process RSS are outside
this measurement. The previously measured **256 B of
thread-GC class allocation** is **not automatically
additive** to malloc figures because possible double
counting has not been excluded.

### Peak concurrently outstanding intercepted requested bytes

The following are **exact per-process event-ledger peaks**,
identical in the three native repeats of each ROI size.
They cover the marked thread's intercepted malloc-family
requests only; they do **not** represent peak process RSS
or a certified all-in memory capacity.

| ROI side | `markers` | `raw` | `import` | `full` | `import - raw` peak difference |
|---:|---:|---:|---:|---:|---:|
| 16 | 36,832 B | 39,904 B | **40,504 B** | **40,504 B** | 600 B |
| 64 | 36,832 B | 100,872 B | **101,768 B** | **101,768 B** | 896 B |
| 256 | 36,832 B | 1,083,912 B | **1,084,808 B** | **1,084,808 B** | 896 B |
| 512 | 36,832 B | 4,229,640 B | **4,230,536 B** | **4,230,536 B** | 896 B |

The 16-side experiment reaches its own whole-process
intercepted-request peak at a different allocation phase
than the larger ROIs. **Do not infer a universal fixed
peak surcharge** from either the 600 or 896 B comparison.
For the six explicitly tagged pixels, the independently
confirmed maximum simultaneous requested payload remains
`4 × (4 × side²)` during C's production (previous
packed A/B plus current scratch and packed C).

### Stage-specific outstanding-bytes comparison

All four sides have the following **exact** additional
*other* outstanding intercepted requested bytes at
the end of each phase, `import minus raw`:

| End of stage | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Additional requested bytes | 0 | **200** | 200 | **400** | **600** | 600 | **400** | **200** | **0** |

The same signature holds for `full minus raw`. It
matches independent packed last-owner lifetime, not
premature eviction/cached owner teardown. No tagged
pixel buffer or import-associated additional pointer
remains outstanding at the final phase.

The **35,336 B residual**, common to **all four** modes
at the end of the trace, belongs to **13 unclassified
stage-1 pointers**; it was already present in the
earlier full-path experiment. The `markers` control
shows it **without any newly generated pixelbuffer
or raster import**. This strongly refutes attributing
that entire residual to raster import or treating it as
an image payload leak. The exact owners of these
runtime/sampler/accounting requests remain unknown.

## What this proves, what remains unknown

**Qualified for this immutable XPS code/toolchain:**

- A/B/C real underlying packed pixel backing lifetimes
  and separately held subscriber frees are respected.
- Import-only and complete source-over have the **same
  observed** interposed malloc requested-size/phase
  profile, even though full performs the actual RGBA
  computation, cache reservation, delivery and eviction.
- A controlled import path adds a repeatable
  **10 malloc requests / 592 requested bytes per
  A/B/C producer**, split by pointer lifetime into
  **392 transient bytes and 200 retained bytes**,
  relative to direct raw malloc/free.
- The old unexplained 35,336 B final outstanding
  requested-byte residual exists in the markers-only
  baseline, not just in image importing.

**Unqualified / still needed before production:**

1. **Type-level attribution:** do the four long-lived
   `kind=0` pointers correspond to specific `raster-d`
   lease/resource/control fields, versus druntime or
   adjacent imports? Event size/lifetime alone is not
   enough. Next experiment should add explicitly
   attributed research call-site/stack probe or controlled
   substeps for `tryAdoptMallocResource`,
   `tryImportOwnedRaster`, view/retention, and final
   lease teardown. No edits to sibling raster-d required
   to compare its public operations, though deeper
   internal attribution may need discussion.
2. **Allocator/residency completeness:** intercepted
   malloc request counts omit allocator headers,
   page rounding/usable size, direct mmap, internal
   bypasses, other threads, GC live heap, and peak
   process RSS. They cannot prove a strict all-in
   capacity formula. The host-specific earlier process
   RSS measurements are *not additive* with these
   requested-byte observations.
3. **Concurrency/cancellation and capacity:** non-atomic
   external `RasterLease` owners, async cancellation,
   ticket exhaustion and backpressure still lack a
   production policy/qualification.

**Decision: ADAPT continued scoped research;
DEFER public API, cache-budget contract and merge.**
Issue #74 stays OPEN; existing stacked PR #73 remains
OPEN/DRAFT on its grandfathered base. Keep all
instrumentation in the research consumer, with no
sibling repository modifications.
