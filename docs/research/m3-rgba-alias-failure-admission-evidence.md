# M3 RGBA — real four-plane alias witness and output-failure boundary

**Date:** 2026-10-15. **Issue:** #75 (Design), #74 (retention Research).
**Status:** research-only; independent four-compiler CI qualification
PENDING for this test's exact commit. **No public API / no M3 ADR admission.**

## Narrow question

Can an imagery-d caller use **public** `raster-d v0.2.0`
borrows, entirely in `@safe`, to hand the *same physical
RGBA backing* to the four-plane source-over compositor as both
input and writable output, **without** a preceding physical
overlap check? The research code's own docstring currently
requires source/output nonoverlap but cannot independently
verify it.

A separate [raster-d public ownership/overlap boundary]
(m3-rgba-performance-alias-boundary.md) already proves
`tryCopyRasterPlane` rejects same-plane source/destination
overlap with `sourceDestinationOverlap` **before writes**,
and accepts distinct disjoint planes within the very same
physical owner. Merely sharing a `RasterLease` does
not itself prove that the sampled bytes overlap.

## New independent DUB consumer experiment

`experiments/m3_rgba_layer_compositing/alias_boundary/source/app.d`
is compiled as an **independent DUB executable** against the
research imagery library and the pinned released raster-d/color-d
APIs. The existing test uses genuine public
`OwnedByteResource`, `tryImportOwnedRaster` and
`RasterLease!ubyte` and previously verified physical overlap
rejection by public `tryCopyRasterPlane`.

The appended research `@safe` witness:

1. Uses the same actual four-plane raster backing through
   `original` and one independently retained *same-type*
   `RasterLease!ubyte`.
2. Sets one alpha byte to 128 via the retained owner's
   publicly obtained writable view and verifies that the
   original owner observes that same byte.
3. Builds a real `ResearchPreparedRgbaContext` with
   runtime opacity **0.37**, without retaining raster pointers
   or changing color-d's math.
4. Passes a scope-borrowed view of `original` for **both**
   source layers, and a writable scope-borrowed view of the
   retained same backing as output. ROI is the full 4×3
   image. All arguments are within the existing normal
   validated public shape/color/alpha contract.
5. Checks whether `tryCompositeRgbaSourceOverPrepared`
   returns `RgbaCompositeError.none`, **rather than**
   rejecting physical overlap. Reads the original owner
   after the call to verify the very same backing's
   alpha value was modified.

**This establishes an accepted-overlap counterexample to
a future claim of automatic noalias certification**, if the
four-compiler research run passes. It does NOT establish
out-of-bounds access, a memory-safety violation or pixel
corruption for this particular aligned 1:1 in-place case.
The research kernel reads all current-pixel channels
before writing them; correct-looking output for this
specific mapping cannot be generalized to arbitrary
valid alias patterns, channel layouts, offset regions or
future vectorized kernels.

The witness adds no forged raster owner, pointer casts,
raw address retyping, second freeing obligation or
changes in sibling repositories. The four-compiler CI
explicitly requires its PASS trailer in addition to
the previous public raster alias-boundary proof.
A sample `@safe` signature is not a physical alias
certificate; D's borrow/lifetime rules and semantic
nonoverlap are distinct contracts.

## Source-output contract alternatives

| Approach | What it actually proves | Production decision |
|---|---|---|
| Four-plane caller destination with a documented noalias precondition | Borrow lifetime and `@safe` checked sampling, **not** physical noalias | **Not accepted** while unsafe image-semantic alias misuse may be silently accepted. Decide whether a documented consumer invariant is sufficient for the named consumer. |
| Public `raster.copyInto` / `zipTransformInto` | Genuine physical overlap preflight for the operation's accepted source/destination forms | Accepted *raster* mechanism; current generic packed zip callback lacks runtime opacity and checked quantization/error result semantics. Do not pretend it is a drop-in four-band image-domain function. |
| New independently owned packed result | Source/output pixel storage never aliases *by construction*, one distinct malloc-backed result published after complete materialization | Candidate for consumer requiring independent output, but actual malloc/import fault disposition and Tier-P-only memory scope require separate qualification. |
| Full staged transaction for a caller-supplied output | Could preserve target until final commit if storage/copy and failure contracts were defined | Not implemented. Requires additional allocation and a reviewed output-commit mechanism; not a free `@nogc` upgrade. |

**An allocation-free destination API and transactional
complete-on-publication owned output are different claims**;
neither should be promoted by silently selecting the
strongest semantics of both.

## Failure-state matrix and gaps

- **Preflight invalidity** (bad ROI/source interpretation,
  opacity, inert prepared context, noncanonical linear PM):
  existing consumer verifies classified rejection *before
  destination writes*. This must stay in both variants.
- **Unexpected sampled source or writable destination failure**:
  existing four-plane operation may return `sampleFailure`
  after previous target pixels were modified. The current
  valid public view usually prevents such failures, but no
  universal failure-atomicity proof exists. A deterministic
  late-write failure injection is still needed if a public
  caller-destination API promises stronger behavior.
- **Physical overlap:** no classified physical-overlap error
  exists in the four-plane research enum and the function
  performs no prewrite overlap test. The new witness
  intentionally shows the absence of such rejection,
  rather than weakening the test to assume `@safe` suffices.
- **Owned result native failure**: no return owner is
  published before successful packing; however actual
  allocation/import exception safety, first/second
  allocation failures and post-commit resource disposition
  remain a separate open research gate. Logical quota
  rejection is not equivalent to allocator OOM.

## Gate and next engineering decision

1. Require PASS on the exact research HEAD under the
   independent DMD 2.112.1/2.113.0 and LDC 1.42.0/1.43.0
   alias-boundary release matrix. If witness unexpectedly
   fails, inspect the actual public API behavior and
   update the observation before making an assertion.
2. Keep the previously established independent 432-scene
   correctness oracle and prepared-context tests unchanged.
3. Decide the specific real consumer and result form in
   [Design Issue #75](https://github.com/alex-1974/imagery-d/issues/75).
   If the destination path is selected, write down a
   **credible mechanism** for alias and partial-write
   handling without copying `raster.internal` source.
4. If the owned path is selected, prioritize native
   import/failure proof; keep Tier P (8N requested
   peak/4N retained) distinct from physical RSS.
5. Only an explicit M3 ADR may admit and name the minimal
   production operation. No research-cache types, new
   general scheduler or public ownership framework
   should be promoted on the strength of this witness.
