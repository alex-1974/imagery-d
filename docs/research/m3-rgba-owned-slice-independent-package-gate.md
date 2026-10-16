# M3 RGBA — separately compiled owned-result prototype and consumer gate

**Date:** 2026-10-16 · Issue #75 · Research #74 · Draft PR #73  
**State:** implemented **research-only**; four-compiler CI qualification pending.
**Admission:** no public API, no source/ release package, no accepted ADR,
no merge and no performance claim for this newly packaged producer.

## Purpose and precedence

The full M3 smoke consumer already compiles as an independent DUB executable,
but its `tryCompositeOwnedPackedResearch` allocation/publication helper
remained **private to that very large consumer**. Therefore the 432-scene
oracle and 40-case XPS performance record alone did **not** prove that
an image-domain owned producer, *exported from a separate DUB library*,
links and preserves its output-state contract for an ordinary caller.

This targeted research extraction exercises precisely that missing seam:

1. The existing **research-only** DUB library
   `experiments/m3_rgba_layer_compositing/dub.sdl` compiles a new small
   `imagery.presentation.owned` module alongside its existing validated
   `imagery.presentation.composite` math module.
2. `tryCompositeOwnedRgbaResearch` consumes two borrowed decoded image
   views and an existing prepared context and ROI. It allocates fresh
   four-channel scratch and an independently backed packed
   `RasterLease!SRgba8` using **only public raster-d v0.2.0** resource,
   import, lease and view operations. It uses color-d through the shared,
   already-tested prepared compositor, NOT copied blending mathematics.
3. A new **separate, small DUB executable**
   `experiments/m3_rgba_layer_compositing/owned_slice_smoke`
   depends only on the library package and its public dependencies.
   No private imagery or raster import, research GenerationCache,
   custom backing or extra controller is used.
4. The existing targeted GitHub RGBA workflow executes that new
   application in **debug and release on DMD 2.112.1/2.113.0
   and LDC 1.42/1.43**. A missing external import/link,
   incorrect pixel result or failure-state contract fails this gate.

The prototype's `Research` name and `experiments/` path explicitly
prevent it from becoming an accepted production contract by accident.

## Minimal observed/required behavior

The new externally compiled executable exercises **eight cases**:
all four upper/lower PM-association masks × mixed/transparent alpha.
Fixtures use independent packed-interleaved and planar four-band
source layouts, a non-origin ROI, runtime opacity 0.37,
and a separate four-band reference destination. For every case,
all **12 packed ROI pixels** are compared byte-for-byte against
the independent *existing prepared-destination implementation*;
this is **not a replacement** for the existing broad
432-scene independently calculated numerical oracle.

It then:
- calls the owned producer again with its output still nonempty;
  the response must be `invalidOutput`, with the existing
  owner preserved; no destructive D `out` parameter is used;
- retains an ordinary `RasterLease` copy, drops the first
  owner, changes a real source pixel via a separate retained
  writable source lease, and verifies the previously packed
  result still reads its original pixel;
- separately tests invalid/out-of-bounds ROI, inert `.init`
  prepared state, and an invalid **last-coordinate** canonical
  PM input before successful publication;
- prints distinct success receipts for the eight cases,
  negative input group and complete external DUB run,
  each enforced by the CI step.

This is a *package-seam and ownership* test. Source mutation
**during** the call is not made thread-safe; raster-d's
non-atomic shared lease remains a single-thread restriction.
The prior stage-local late mutation test in the full
research consumer is retained unchanged.

## Resource state and stop conditions

For `N=checked(ROI width × ROI height)`, the current
prototype requests **4N scratch + 4N packed pixel bytes**
(max 8N requested pixel payload at once), holding
4N in the completed result. It does NOT reserve those bytes
against a concurrent process quota, bound total RSS or
charge metadata/control-block allocations.
It does NOT duplicate raster-d's physical ownership/refcount.

**Before pixel allocation**, it rejects empty/overflowed
payload dimensions, already-owned `ref` output, invalid
context/layers/ROI and noncanonical linear-PM pixel bytes.
The four-mask fused local read check catches observed late
PM invalidity before using that local pixel.
A failed pack or read can partially mutate **private**
scratch/packed buffers, but never publishes a result;
ordinary RAII destroys those allocations.

**Current fallible boundary is provisional:** image semantic
faults return existing `RgbaCompositeError`; physical
`malloc`/adoption/import failures currently throw
`Exception` via the prototype's native helpers. The
underlying runtime may instead throw an Error-class OOM.
No `@nogc`, `nothrow`, arbitrary OOM recovery,
physical cap, thread safety, exact last-owner budget
refund or failure-atomic source snapshot is claimed
for this **allocating** operation.

The much broader original consumer has already qualified
actual first/second libc pixel ENOMEM and pre-/post-commit
public raster-d import faults. Those are **evidence about
the original private helper**, NOT yet execution evidence
for this newly extracted *library* helper. This distinction
is a mandatory next gate before admission.

## Native fault matrix for the **new** separately compiled producer

A new dedicated `native-faults` configuration of the independent
`owned_slice_smoke` application now explicitly selects the
`native-faults` subconfiguration of the **library dependency**.
This scope is important: a version flag in the executable's own
DUB configuration alone is not evidence that the library binary
contains the intended test-only instrumentation.

The new research-only fault adapter uses only the existing
Linux/glibc `LD_PRELOAD` interposer in
`experiments/m3_rgba_layer_compositing/alloc_events/`.
It tags the **actual native calls made inside**
`imagery.presentation.owned` using DUB version
`M3_OWNED_NATIVE_FAULTS`, never synthetic return codes,
and does not alter the normal `default` configuration.

The test case invokes the **separately linked library**
to create a real full-image 16×16 owned RGBA result
after the source fixtures and LUT are prepared. For each
of four independent faults it arms exactly one target:

| Kind | Actual injected site | Required observed state |
|---:|---|---|
| 1 | first scratch pixel `malloc(1024)` | no allocation published, no scratch backing |
| 2 | second packed pixel `malloc(1024)` | one scratch allocated/freed, no packed backing |
| 3 | public packed raster import metadata `malloc(24)` | scratch and packed allocations both released once; pre-commit `unchanged` disposition is raster-d's responsibility |
| 4 | public packed raster import metadata `malloc(40)` | scratch and packed allocations both released once; post-commit `releasedAfterCommit` disposition prevents double-free |

The evidence of exact pre-/post-commit dispositions still
comes from the **already qualified** public raster-d fault
probe in the original M3 consumer; the new library probe
asserts single-shot malloc failure, no externally visible
owner, and exactly once native release on the *actual new
producer*. Do not promote the two separate observations
into a stronger claim about arbitrary druntime `Error` OOM.

After disarming every fault, the same library producer
must materialize a readable complete result again from
the same sources and ROI. An invalid **last PM source
pixel**, with a first pixel malloc fault armed, must be
rejected **before any scratch allocation attempt**.
The four compiler jobs run these tests in Release under
the native Linux/glibc shim, separately from the Debug/Release
normal DUB consumer tests.

**State at implementation:** new fault instrumentation,
CI commands and negative fixture have been committed;
the exact-head CI run must complete successfully before
claiming this new matrix PASS. Real OOM at druntime
Error-level and true concurrent source mutation remain
outside this admission gate.

## Explicit LDC 1.43 release whole-owned comparison — UNMEASURED

The **original independent consumer's** private packed producer remains
as the unchanged reproducible baseline. The new `--owned-library-bench`
mode of that same separately built DUB executable compares three paths,
each allocating, packing, owning and retiring a **real complete**
`RasterLease!SRgba8` result in its timed work:

| CSV stage | Exact operation |
|---|---|
| `owned_old_order` | Original private allocation-before-full-ROI-preflight control |
| `owned_fused_checked` | Original private four-PM-mask Fused producer |
| `owned_extracted_library` | New separately compiled `imagery.presentation.owned` producer |

The existing `--owned-fused-bench` mode and its 40-case archival result
are **not modified**, relabelled or reanalysed as though they already
included the new producer. The new `--owned-library-bench` mode compares
**all four offset ROIs byte-for-byte** against the independent prepared
four-plane reference and between all three result producers, both
**before and after** timed records.

A new `tools/research/run_m3_rgba_owned_library_xps.sh` runner pins
`git archive HEAD` from this repository and read-only
`raster-d`/`color-d` v0.2.0 Git tags, demands LDC 1.43.0 Release,
records CPU/governor/compiler/source SHAs, archives the exact measured
executable, computes a strict SHA-256 file manifest, and generates
`LIBRARY_COMPARISON.csv` only after all cases pass. The independent
`tools/research/summarize_m3_rgba_owned_library_xps.py` parser has
a synthetic self-test and mutation-negative checks. It refuses missing
files, invalid stages, wrong counts/order, inconsistent per-layout
output checksums, altered binary or source provenance and malformed
PASS trailers.

**Full XPS configuration** stays comparable to the prior owned
research evidence: 512×512 fixtures, two source interpretations,
mixed/fully-transparent, two physical source layouts, five square
ROI sides (16–256), **40 cases**; seven same-case rotating
three-stage rounds × 24 full-result iterations.
Case-specific *paired* median library/private and library/old
runtime ratios are primary. Report cohort medians of the
10 cases per meaning/pattern, *not* ratios of unrelated stage
means. Do not interpret different Git commits' wall times as
paired; pairing is only within each new case's rounds.

**Provisional review rule:** use the existing local **+5%**
regression trigger to **investigate**, not automatically
reject, case-specific library/private ratios >1.05.
If the extracted producer regresses, inspect full-call
allocation/import costs and **measured** codegen/size before
introducing optimizer state or another abstraction. Track
GC deltas and exact release-binary size separately; neither
is a physical RSS guarantee. No claim about an unmeasured
new library performance result is permitted.

**CI gates before XPS acceptance:** debug/release external
producer + owner tests and native faults on all four DMD/LDC
versions, Release three-stage semantic/timing smoke,
validator self-test and Bash syntax on each compiler,
one LDC1.43 immutable pinned XPS smoke with all manifest SHA
checks. **Current new comparison status:** IMPLEMENTED,
not yet qualified by its exact-head CI or by native full
XPS. A separate XPS run/receipt will be needed for a
measured performance conclusion.

## XPS result received and independently reproduced — PERFORMANCE BLOCKED

The previously UNMEASURED separately compiled library benchmark has now
been run on XPS-15 against exact research commit
`28211cd4fdd367abe8ea318c5f20c523fa5b8cc1`.
The independently checked complete original archive
`20261016T130848Z.tar.gz` includes **43/43** SHA-256 manifest
files (including original release executable), **840/840**
within-case rotated full-owned measurements, and **40/40**
strictly reproduced six-decimal summary rows.
**All five exact-measured-source GitHub workflows passed.**

**However, 39/40 cases cross the +5% performance investigation trigger
for the linked library relative to the private fused reference.**
Median of ten case-specific median library/private ratios:

| Case | Library/private |
|---|---:|
| encoded-straight, mixed | **1.091172** (+9.1%) |
| encoded-straight, transparent | **1.307473** (+30.7%) |
| linear-PM, mixed | **1.085019** (+8.5%) |
| linear-PM, transparent | **1.243223** (+24.3%) |

The median of case-specific paired **absolute** extra times is
about **+7.8 ns/pixel** in *all four cohorts*. A read-only
disassembly of the **original measured ELF** shows the private
packed loop using fully inlined byte loads/32-bit packed store,
whereas the linked library's packed loop retains **four actual
`trySample` calls plus one `trySetSample` call per pixel**.
This supports, but does not alone quantify, an inter-module
inlining/codegen explanation.

**Complete independent replay and the specific next bounded
link-time-optimization/codegen control:** see
[m3-rgba-owned-library-xps-independent-results-2026-10-16.md]
(m3-rgba-owned-library-xps-independent-results-2026-10-16.md).

The earlier section recording the planned UNMEASURED experiment
is historical preregistration. The scientific verdict NOW is
**RESEARCH ADAPT / EXTRACTED LIBRARY PERFORMANCE BLOCKED**.
The private owned fused source's earlier favorable XPS result
is not reinterpreted as performance evidence for this new
separately compiled producer. No production package/API,
ADR acceptance, merge or release is authorized.

## After CI

- If compile/import/link/byte checks fail, fix within this
  experimental seam; do not weaken old oracle or raster-d
  ownership rules to make the test green.
- Independently inject failures into the **new library
  producer** for first/second malloc, metadata adoption,
  pre-/post-commit resource disposition and late pack.
  Confirm output preservation and exactly-once physical
  disposal under release builds.
- Freeze neither public package names nor the research
  `ref` output signature until the real non-test downstream
  consumer and concrete error policy are selected.
- Bench the **newly compiled minimal B producer**, rather
  than transferring the 40-case performance measurements
  from the older, private research consumer. The original
  43/43 fully reconciled XPS evidence remains the reference.
- Record the public source module, attrs, `.init`,
  DIP1000 negative-contracts and nonrecoverable Error-level
  allocation policy in a numbered M3 ADR *only after*
  the independent consumer and error matrix succeed.

**Disposition: QUALIFY THE SEAM, not public admission.**
