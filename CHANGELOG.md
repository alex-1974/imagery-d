# Changelog

## Unreleased

- Begin M5 with deterministic overview-grid selection over a common logical
  extent. The pure, allocation-free API chooses the coarsest level that avoids
  undersampling both target axes and explicitly reports when no available
  level can do so. Pixel resampling, overview generation and mosaics remain
  out of scope.

## v0.2.0 — RGB analysis and luminance stretch

- Add RGB8 histograms and ROI statistics with explicit binary selection,
  retained-result failure behavior and exact per-channel counts.
- Derive inclusive cumulative counts, integer nearest-rank percentiles,
  percentile contrast-stretch LUTs and histogram-equalization LUTs from the
  same histogram record. Masking selects estimation samples, not edit targets.
- Add RGB8 percentile luminance stretch using color-d sRGB transfer and
  XYZ-D65-Y bounds, with an ROI-local owned normalized float result, explicit
  payload budget, clipping policy and optional worker budget.
- Verify the luminance result against an independent P6 byte oracle on
  synthetic and file-consumer fixtures; retain a documented one-byte output
  tolerance for float-to-byte serialization.
- Improve the LDC luminance path with direct output lookup and by-reference
  reuse of color-d's RGB8 decode table. Local full-call measurements are
  documented separately and are not a portable latency promise.
- Upgrade source dependencies to `raster-d ~>0.5.5` and
  `color-d ~>0.3.0`. The published v0.1.0 Levels source contract remains.
- Extend internal M4 validation with SHA-pinned synthetic fixtures and an
  optional real-image RGB histogram check; corpus tools and image bytes are
  excluded from the source package.

## v0.1.0 — Initial release

- Candidate scalar Levels owned-result API for already materialized image channels; `@safe` through one narrowly reviewed `@trusted` malloc/adoption step.
- Explicit `LevelsError.notAttempted` invalid-success default, returned-failure publication semantics and required result pixel-payload budget.
- Scalar gamma-2 sqrt specialization; independent Decimal oracle regression covering 624 deterministic cases, including extreme finite float/selection cancellation.
- Real P6 and paired native Release consumers, rendered DDox, DIP1000 and non-exposed Into negative compile gates.
- Source-archive DUB consumer verified outside the Git checkout on DMD/LDC, Debug/Release.
- General-image scope (ADR 0005), first Levels priority (ADR 0004) and
  narrow source-API acceptance (ADR 0006) are documented.
- Initial Linux x86-64 release; macOS and Windows are best effort.
- Pre-1.0 source compatibility may change in future minor versions;
  no stable ABI is promised.
