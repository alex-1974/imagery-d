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
