# M3.2.20 — scoped Prepared mapping spanning multiple logical ROI packets

**XPS result (2026-10-13):** independent 40-process archive replay **PASS**:
25,600 correctly ordered real ROIs, 153,600 independently computed
corner pixel values, 0 GC bytes during both mapping strategies.
Single scoped session needs only one internal preparation per generation
instead of 32; observed median throughput advantage ranges from
~0% to ~10%, with mixed repeat-level signs (14/20 favorable).
**No general performance or public persistent owner promotion.**
See [independent M3.2.20 Dell XPS audit](m3-2-scoped-prepared-xps-results.md).

**Status:** exploratory **research-only** semantics+evidence prototype;
[issue #62](https://github.com/alex-1974/imagery-d/issues/62),
[draft PR #63](https://github.com/alex-1974/imagery-d/pull/63)
stacked on [M3.2.19 #61](https://github.com/alex-1974/imagery-d/pull/61).
No public production API, changes in sibling repositories, merge to
`develop`, new `@trusted` or unsafe alias cast.

## 1. The exact lifetime claim

The existing
`ResearchLongLivedMetadataSource.tryMapOrderedInto` owns **no
pixels**. It receives scope-borrowed source/mask/output and caller
observation buffers, constructs a checked
`ValidatedImmutableImage` then a private `PreparedSemanticMap`
**once per method call**, and maps all supplied ROIs with that
Prepared token. Its metadata source holds genuinely immutable
GC-backed descriptor arrays, either borrowed immutable source
or two explicit `.idup` snapshots of caller-mutable data.

M3.2.19 established that a Prepared token referring to *local*
primary/validity leases cannot escape, in `@safe`
`-preview=dip1000`, on DMD 2.111/2.113 and
LDC 1.41/1.43; failure preflight, partial write and explicit
error-state contracts also pass.

This experiment exploits a **single scoped call** that covers
multiple logically distinct processing packets. Both raster
`RasterLease` owners, the old/new immutable metadata sources,
and the destination/observation buffers live across the
entire call. No Prepared token is returned or stored beyond
its creator's stack frame, and no caller controls a separate
cached Prepared object.

**It does not establish a persistent prepared-cache API across
separate method invocations.** That requires a separate
anchored owner/lifetime proof and is deliberately not attempted.

## 2. Two matched consumer treatments

The benchmark `runScopedPreparedSessionExperiment` has two
explicit policies, both using the **same existing** checked
`tryMapOrderedInto` code to map the same actual pixels:

| Policy | Actual method calls per phase | Identity/Prepared setup count per phase | Mapped ROIs |
|---|---:|---:|---:|
| `reprepare` | `packetCount` | `packetCount` | `packetCount × reuse` |
| `session` | **1** | **1** | `packetCount × reuse` |

The ROI sequence is **the same** and bounded, using the
existing 4-origin grid, 8×8 or 32×32 ROI side, 4/16 ROIs
per logical packet, 256 planar masked source planes, selected
output channels (254,253,255), physical calibration and a
reused writable 3-channel destination. A 32-packet batch maps
128 or 512 ROIs regardless of treatment.

The caller constructs immutable metadata **before timing**.
Two genuinely immutable generations from two independent
snapshots are exercised in each OS process:

- original: scale `0.625`, offset `-6`, label `BEFORE`;
- refreshed: scale `0.6875`, offset `-7`, label `AFTER`.

The original mutable input is edited before the refreshed
owner is constructed; the original immutable generation
must remain unchanged. There is no hidden metadata change
mid-Prepared session.

Before the stopwatch begins, both policies allocate and touch
exactly the same source/mask/destination, all ROI windows and
both flat per-ROI observation arrays. The timed section for each
phase includes **all its actual mapping calls and O(channelCount)
validation/Prepared setup**. There is **no logging, initial
snapshotting, fixture construction or independent pixel oracle
inside the stopwatch**. A per-thread druntime GC allocation counter
is checked before/after the timed section: both paths must
allocate **0 bytes** during the actual prepared mapping loop.

The selected elapsed time is **not full process wall time**:
fixture creation, array initialization, independent oracles,
logging and process cleanup remain outside.

## 3. Ordered physical pixel oracle

Every actual ROI emits a row with precise logical
`packet`, `roi`, `x`, `y`, all 3 first-pixel components and
all 3 opposite-corner last-pixel components. The D code checks
these six values against independently reconstructed physical
sample/mask/calibration formulas, and also checks **every sample
of all three output channels of the final ROI**.

The external `analyze_prepared_session.py` does **not**
import the existing M3.2.18 analyzer or trust the D values.
It reconstructs:

- exact unique process matrix, mode, ROI side, reuse, phases;
- every ROI's expected position and order within packet;
- every one of its 6 expected source-channel pixel values,
  validity mask and original/refreshed calibration;
- `session` setup-count **1**, `reprepare` setup-count
  **packetCount**, same `packetCount × reuse` real mappings;
- zero per-phase GC bytes, complete positive completion marker,
  no missing/extra/reordered records;
- complete raw ROI/phase/process CSV and JSON derivation.

Like M3.2.18, printed float samples use a **0.01001 absolute
logging tolerance** after `writeln` rounding; the D-side test
compares the `float` values directly. External six-corner
samples are not a full-pixel oracle of **every intermediate ROI**;
only the final raster is checked at all pixels.

Tests of the analyzer challenge missing processes, swapped or
missing ROI rows, forged coordinates and individual values,
nonzero claimed GC, extra preparation/mapping count and
duplicated completion markers. A compiler green build without
independently auditable evidence is not sufficient to promote
a performance conclusion.

## 4. Process-isolated reference methodology

The XPS runner `qualify_prepared_session_xps.sh` records
exact imagery/raster HEADs and worktree state, compiler/toolchain
identities, CPU governor/affinity, system memory and swap before
and after each repeat, optimized binary hash, disassembly,
symbols and existing scope/lifetime/forgery build gates.

Default experiment:

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/imagery-d
git status --short --branch
git fetch origin
git switch research/m3-2-20-scoped-prepared-session
git pull --ff-only origin research/m3-2-20-scoped-prepared-session

COMPILER=ldc2 REPEATS=5 PACKETS=32 SIDES=8,32 REUSES=4,16 \
  bash experiments/m3_2_validated_roi/tools/qualify_prepared_session_xps.sh
```

This runs **5 repetitions × 2 policies × 2 ROI sides ×
2 reuse counts = 40 independent OS processes**, each
emitting two original/refreshed phases of **32 logical packets**,
for **2,560 logical packets** and **25,600 actually mapped ROIs**
with **153,600 independently reconstructed corner values**.
Policies rotate process launch order by repetition index.
The process is the independent repetition unit; per-ROI values
within a process are *correlated evidence*, not repeated
statistical samples.

Do not claim a speedup before the reference XPS archive is
collected and independently audited; hosted CI timings are
functional integration tests only. If there is a clear win,
report it alongside preparation included in the timing and
source construction excluded, and account for any page faults,
GC activity and CPU scheduling uncertainty. A fair speedup
must not be attributed to eliminated pixel work or erased
allocation; both actual pixel paths remain identical.

## 5. Boundaries and next step

**Admissible from CI:** compiles on DMD 2.111/2.113 and
LDC 1.41/1.43; existing DIP1000 and owner/scope negatives
remain; both real map paths and original/refreshed pixel
oracles pass; no per-session GC allocation; transcript
analyzer rejects forged/missing/reordered observations.

**Not admitted by this experiment:** returning or storing
`PreparedSemanticMap` past a scope-borrowed raster owner,
mutable→immutable zero-copy freeze, an OS-level no-pause
guarantee, per-packet independent heap comparison, public
`ImageLease` or new `containers-d` API.

A later externally reusable Prepared handle would need
explicit retained ownership of pixels, validity and immutable
metadata together, validated generation/epoch semantics,
failure paths and whole-source negative escaping/copy tests.
Prefer preserving current minimal checked contract rather
than creating unnecessary general infrastructure.
