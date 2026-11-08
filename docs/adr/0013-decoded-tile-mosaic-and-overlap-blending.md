# ADR 0013 — Decoded tile mosaics and explicit overlap blending

**Status:** ACCEPTED FOR M5 QUALIFICATION

## Decision

M5 starts with two deliberately separate capabilities:

1. A regular decoded RGBA8 tile-grid mapper that produces an owned viewport
   using nearest source-pixel selection.
2. An explicit aligned RGB8 overlap blend that decodes sRGB to linear light,
   applies a caller-provided u8 weight map, and re-encodes to RGB8.

The caller owns tile registration, overview identity, source quality,
validity/NoData semantics and weight-map construction. `imagery-d` validates
the supplied grid, ROI, scale, layouts and output budget; `raster-d` owns the
retained storage and borrowed views.

The operations publish only after complete success and preserve an existing
published owner on returned failure. They do not introduce a scheduler,
cache, source adapter, implicit reprojection, implicit resampling policy or
universal mosaic framework.

## Evidence

The independent M5 qualification consumers pass on `raster-d` 0.5.5:

- decoded tile mosaic: 70,272 independent component-oracle checks across
  planar/interleaved and signed-layout cases, alpha declarations, ROIs and
  horizontal/vertical seams;
- overlap blend: 43,008 oracle checks, all weights from 0 through 255,
  eight layouts, zero maximum byte error and explicit linear-light midpoint.

## Deferred

Public promotion requires a follow-up API review covering quality/source
selection, NoData and mask semantics, arbitrary tile-grid geometry,
multiresolution identity and performance budgets. These are not inferred from
the current regular-grid qualification.
