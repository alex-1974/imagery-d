# M3 RGBA — Native XPS allocation-event and backing lifetime evidence, 2026-10-15

**Status:** archived research evidence; **ADAPT** the experiment,
**DEFER** a production memory-admission bound or public API.
Linked to [Issue #74](https://github.com/alex-1974/imagery-d/issues/74)
and the existing stacked [Draft PR #73](https://github.com/alex-1974/imagery-d/pull/73).
This is a follow-up to the earlier [20-process native RSS/glibc/GC study](m3-rgba-generation-memory-xps-2026-10-15.md),
not a replacement for its process-level measurements.

## Provenance and integrity

User-supplied original evidence archive
`imagery-m3-native-alloc-events-xps.tar.gz`
has SHA-256:

```text
bf2cf7fc3c71ae1278ed2ab870d5d95ac42a1627a783db8ebd8407ed32ba641e
```

- Archive: **55 entries**, of which **54 regular files**;
  no duplicate paths, absolute/parent-traversal paths, symlinks or other
  unexpected member types.
- Original `CHECKSUMS.sha256`: **53/53 independently verified PASS**.
  All regular files other than the manifest itself are listed, including
  `libm3_alloc_events.so`, the C/D build logs, environment,
  parser self-test, and all process trace/summary/stdout/stderr files.
- All **12/12 native processes** passed the independent consumer's
  `M3 GENERATION MEMORY PASS:` check; all 12 stderr logs are empty.
  Both C and D release builds completed. The D build has only
  previously observed, nonfatal `mir-core 1.7.4`
  `ldc.intrinsics.LLVM_version` deprecations.
- Python verifier self-test reports
  `NATIVE ALLOCATION EVENT VALIDATOR SELF-TEST PASS`.
- Beyond trusting that result, the uploaded **12 raw event streams**
  were independently reparsed: six explicit allocation intents,
  six corresponding size- and type-matched malloc results,
  pointer-specific scratch/output frees, all nine ordered stages,
  event/bytes peaks, unclassified allocation residuals and all
  12 stored CSV summaries were cross-checked.

| Exact pinned execution | Value |
|---|---|
| Capture | 2026-10-15 **09:18:24 UTC** |
| Computer | `xps-15`, Intel Core i7-9750H, 6 cores / 12 threads |
| Kernel | Linux `6.17.0-22-generic`, Ubuntu x86_64 |
| Compiler | **LDC 1.43.0**, release |
| DUB | **1.42.0** |
| C compiler | `cc (Ubuntu 15.2.0-16ubuntu1) 15.2.0` |
| `imagery-d` source SHA | `b579c5dd73fcf2ba91990280e5015a521ee9ebe6` |
| raster-d `v0.2.0` SHA | `2f2415851e45001df92ce56dad409f680684ba8d` |
| color-d `v0.2.0` SHA | `3359f08f4e83941ac1a8451cadefb146b5736019` |
| Exact measured source CI | **5/5 workflows SUCCESS**, four independent DMD/LDC consumer jobs SUCCESS |

The runner compiled *immutable `git archive` snapshots* of the
recorded commits/tags. The live `imagery-d` working tree reported
untracked research/build artifacts; these did **not** enter the snapshot.
The original binary archive remains outside Git history; the
report records its hash, source pins and results instead.

## Real experiment and event meaning

Each process creates two existing RGBA fixtures, then publishes
three **real source-over/composited** A/B/C ROI generations in
succession into the same cache slot. Each generation retains its
own public `raster-d RasterLease!SRgba8` backing after eviction.
Its last independent subscriber closes after the producing
cache is destroyed.

The optional research-only `LD_PRELOAD` glibc recorder captures
allocation/free events **on the instrumented thread**, bracketed
by explicit phases. The D call sites tag:
`kind=1`: four-channel pixel scratch, `P=4 × side²` requested bytes;
`kind=2`: independently owned packed output, also `P` bytes.
There are **two separate pixel-buffer requests per generation**.
Other intercepted libc malloc requests are `kind=0` and
**must not** be silently attributed to raster-d control blocks.

Each trace has **146 event lines** (including start/stop/intent
markers), **67 intercepted allocation events**, **55 intercepted
free events**, exactly **six known tagged pixel allocations**
and one free of a pointer that was not allocated *during the
instrumented window*. The last event is the stage-9 termination
marker. No tagged pixel allocation remains live.

### Requested pixel bytes and simultaneous backing peak

The table contains **identical results in all three independently
executed processes per side**. Values are exact **requested
bytes**, not allocator usable sizes, committed memory or RSS.

| ROI side | Single real packed or scratch backing `P` | Six tagged requests over complete trace `6P` | Largest simultaneously live known pixel backings `4P` |
|---:|---:|---:|---:|
| 16 | 1,024 B | 6,144 B | **4,096 B** |
| 64 | 16,384 B | 98,304 B | **65,536 B** |
| 256 | 262,144 B | 1,572,864 B | **1,048,576 B** |
| 512 | 1,048,576 B | 6,291,456 B | **4,194,304 B** |

**Why `4P`, not `3P` or `6P`:** During C's
publication there are two already retained packed generations
(A and B, `2P`) and **both** C's four-channel scratch (`P`)
and newly allocated packed output (`P`) at the same time.
After C's scratch frees, A/B/C leave `3P` packed output
payloads concurrently retained. This concrete event order
validates the claimed peak **for the six explicitly tagged
consumer pixel backings in this source path**, not all native
allocations during production.

### Exact byte-owner lifetime by generation

| Generation | Scratch malloc and free | Packed malloc | Packed pointer finally freed |
|---|---|---|---|
| A | stage 2 → **stage 2** | stage 2 | **stage 7**, last A external owner closes |
| B | stage 4 → **stage 4** | stage 4 | **stage 8**, last B external owner closes |
| C | stage 5 → **stage 5** | stage 5 | **stage 9**, last C external owner closes |

Stages 3/4/5 evict/reuse the cache slot; stage 6 destroys
the cache owner. **None** prematurely frees an externally
retained packed backing. All six tagged pointers have a real
matching observed `free` event. Pointer reuse by glibc is
accepted **only after** the previous allocation has freed;
the parser rejects simultaneous aliasing.

## All intercepted requested-byte events (unclassified included)

The pointer ledger covers all **observed/intercepted libc calls
on the tagged thread**, not only the six pixel tags:

| ROI side | Largest concurrently outstanding intercepted requested bytes | Bytes of nonpixel requests among all 61 unclassified allocation events | Intercepted requested bytes remaining at end of stage 9 |
|---:|---:|---:|---:|
| 16 | **40,504** | 50,576 | **35,336** |
| 64 | **101,768** | 50,576 | **35,336** |
| 256 | **1,084,808** | 50,576 | **35,336** |
| 512 | **4,230,536** | 50,576 | **35,336** |

These values are exact for **all three repeats at each
ROI side**. They should **not** be equated with process RSS:
the tracked quantity is the sum of *requests still pending a
corresponding intercepted free*, and it does not include
allocator headers/rounding/fragmentation or other unobserved
allocation mechanisms. The largest sampled/intercepted requested
total occurs during C's production (stage 5), when the known
pixel backing count reaches `4P`.

Each run observes **61 unclassified allocation requests totaling
50,576 requested bytes**. Those 61 requests have a systematic
phase pattern: 15 requests in stage 1, 12 requests in each
of the three actual producer stages (2/4/5), and two requests
in each of the five remaining stages (3/6/7/8/9). The stage-1
requests account for **36,832** requested bytes; producer
stages have 2,088 unclassified requested bytes apiece and
other stages 1,496 bytes apiece. This pattern includes the
measurement infrastructure and lazy runtime/process behavior;
it does **not** prove a 2,088-byte raster-d import overhead.

By the end of stage 9, the event ledger still tracks **13
unclassified pointers totaling 35,336 requested bytes**,
and **all 13 were originally allocated in stage 1**:

- Four requests of **8,192 B** each;
- three of **48 B** each;
- one each of **1,024, 832, 272, 256, 32 and 8 B**.

There is additionally **one unmatched free of a pointer from
before the recording window**, recorded in every process.
The unclassified stage-1 residual, taken alone, is **not a
proven raster leak**: the tests do not attribute it to individual
image owners, and the sampler calls Linux `/proc`/`fopen`
as well as unrelated runtime facilities. A GC control-record
allocation may itself be visible as a malloc request while its
lifetime is governed by the GC, **so do not add the previous
256-byte GC allocation counter to an intercepted malloc
total without a double-counting analysis**. Likewise,
the 35,336 outstanding intercepted requests do **not**
establish that 35,336 B of extra live image memory should
be counted in a production cache budget.

### Intercept-only limitations

The following are **not measured or ruled out**:

- allocations that predate the stage-1 marker, allocations on
  other threads or those made after tracing stops;
- glibc internal operations bypassing public interposed
  symbols, direct `mmap`/`munmap`, custom/native allocators;
- resident/committed size, physical allocator metadata,
  page rounding/arena caching, true all-in peak RSS;
- precise physical peak inside `realloc` itself;
- long-term GC live metadata/collection, asynchronous
  cancellation or concurrent non-atomic RasterLease sharing.

The separately captured prior native process-RSS result
is helpful context but cannot be arithmetically added to
these requested-byte event totals.

## Research conclusions and next discriminating experiment

**Qualified:** in these 12 exact-source XPS processes, the
three independently retained published pixel backings
survive evictions/cache destruction and are freed in the
correct last-owner order; the three four-channel scratch
backings free during their respective producer calls. Their
maximum simultaneous **tagged** requested payload is exactly
`4 × 4 × side²` bytes for this three-generation overlap
schedule. The independent broader consumer lifetime oracle
and exact-host compiler matrix remain green.

**Still unresolved:** which of the unclassified malloc events
are actually caused by raster-d import/adoption, layout
metadata, view creation, GC, `fopen`/sampler initialization,
and ordinary druntime behavior. The 13 stage-1 residuals
need not be ownership defects.

Recommended **next**, strictly research-only:

1. Add **minimal allocation-event controls** using the same
   recorder/compiler/glibc: (a) memory sampler and phase markers
   alone, (b) raw malloc/free of a pixel buffer without importing
   a RasterLease, (c) adopt/import/close a real raster-d buffer
   without compositing, and (d) full source-over/import.
   Diff **event groups and pointer-specific lifetimes**, not
   RSS snapshots or unstructured malloc-size guesses.
2. Identify the native raster import control object and
   staging scratch by explicit **call-site attribution** or
   controlled differences. Do not claim a production all-in
   native memory budget until the event-coverage gaps,
   transient scratch peak, GC/allocator residency and
   generation pool exhaustion policy are addressed.
3. Keep single-threaded/explicit-close ownership scoped.
   No cross-thread or async cancellation guarantee is
   established by this archive.

**Disposition: ADAPT research, production/API DEFER.**
Issue #74 stays **OPEN**, stacked PR #73 **OPEN/DRAFT**.
Do not merge or modify sibling repositories.
