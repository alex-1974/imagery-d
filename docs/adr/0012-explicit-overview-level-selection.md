# ADR 0012 — Explicit overview-level selection

**Status:** ACCEPTED FOR DEVELOP SOURCE API — M5 CONTINUES

**Date:** 2026-10-30

**Tracking:** [Issue #132](https://github.com/alex-1974/imagery-d/issues/132)

## Question

What is the smallest production primitive that can begin M5 without admitting
a source framework, resampler, mosaic engine, scheduler or cache API?

## Decision

Add the pure `imagery.pyramid.overview_selection` module and re-export it from
`import imagery`. It selects one already-described overview grid for a target
sample density over a common logical image extent.

```d
struct OverviewLevel { size_t width, height; }
struct OverviewSelection { size_t index; bool avoidsUndersampling; }
enum OverviewSelectionError : ubyte {
    notAttempted, none, invalidTarget, emptyLevels, invalidLevels
}
OverviewSelectionError trySelectOverviewLevel(
    scope const OverviewLevel[] levels,
    size_t targetWidth,
    size_t targetHeight,
    ref OverviewSelection published)
@safe pure nothrow @nogc;
```

The candidate list is ordered finest to coarsest. Both dimensions must be
non-increasing and at least one must strictly decrease at every step. This
admits ordinary pyramids, arbitrary non-power-of-two reductions and monotonic
anisotropic/ripmap-like sequences, while rejecting duplicates and incomparable
or reversed grids.

The target dimensions describe required samples over the same logical extent.
Selection returns the last, coarsest level whose width and height are both at
least the target dimensions. It therefore does not undersample either axis.
If even the finest level is smaller than the target, index zero is returned
with `avoidsUndersampling == false`; the quality deficit cannot be mistaken
for native/final detail.

All list validation precedes publication. Invalid input preserves the caller's
previous result. No pixel count multiplication, floating-point tolerance,
allocation or raster access is involved, so dimensions through `size_t.max`
remain defined.

## Boundary and ownership

The caller asserts that every level covers the same logical image extent and
uses compatible alignment. Dimensions alone cannot prove that fact. The
selected index refers to the exact caller-owned list; imagery-d retains
nothing.

This is image-domain resolution policy, so it belongs in imagery-d. Generic
grid storage, region geometry, views and future resampling mechanics remain in
raster-d. Each selected grid still has distinct semantic/cache identity under
ADR 0003. A coarse stage remains a complete immutable stage and must not be
presented as a requested final native grid.

## Qualification

- D module unittests cover exact thresholds, coarser/finer boundaries,
  arbitrary and anisotropic levels, `size_t.max`, every malformed-list class,
  empty targets/lists and retained publication on failure.
- The independent DUB consumer calls the curated root import and checks
  adequate selection, explicit unavoidable undersampling and rollback.
- Ddoc renders the module, records and selection function.
- DMD and LDC Debug/Release CI remains the admission gate.

## Deferred

This decision does not read image bytes, verify grid transforms, create or
resample overviews, choose interpolation or antialiasing, compose mosaics,
blend seams, manage source/cache identity, publish progressive stages or
introduce a scheduler/DAG. Those M5 questions require separate consumers and
oracles. It is not a v0.3 release decision or compatibility freeze.
