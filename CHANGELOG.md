# Changelog

## Unreleased — RGB luminance stretch (ADR 0011 accepted)

- Add percentile-based RGB8 luminance stretching in linear sRGB, with
  XYZ-D65-Y histogram bounds, optional threshold-selection mask, ROI-local
  owned float output and compile-time clipping policy.
- Use color-d for transfer/color definitions and retain an independent
  standard-library Python byte oracle.
- Optimize the RGB8 transfer path with per-call decode/encode lookup tables;
  local Release measurements and the remaining full-resolution preview limit
  are recorded in the luminance-stretch performance receipt.
- Integrate `color-d ~>0.3.0`'s exact reusable RGB8 decode table and
  `raster-d ~>0.5.5`'s scoped strided row pointers for the histogram and
  output passes, hoisting row base and sample stride outside each pixel loop.
- Evaluate the XYZ-D65 Y matrix row directly when luminance is the only
  required component; local DMD Release throughput improved about 3.6× on the
  1024×768 full-operation benchmark, with the independent byte oracle passing.
- Reduce the interpolated sRGB encode table from 16,384 to 4,096 intervals;
  local DMD throughput gained a further 5.7% while the byte oracle remained
  within its one-code tolerance.
- Tune the encode-table interval count per backend: 4,096 for DMD and 1,024
  for LDC. On this host the 1,024-entry-spacing variant improved LDC's
  1024×768 throughput by about 11%, while DMD retains its faster 4,096 path.
- Hoist the percentile-range reciprocal out of the per-pixel loop; the latest
  local repeated 1080p measurements are 125 ms/call (DMD) and 57 ms/call
  (LDC), still short of the 33 ms 30-fps target.
- Upgrade to `raster-d ~>0.5.5` for validated multi-view phase APIs and the
  worker-capture fix for exact disjoint parallel row coverage. imagery-d now
  uses worker-private histogram slots; a measured worker sweep shows 1080p
  below 30 fps budget with eight DMD workers or four LDC workers.

## Unreleased — RGB histogram source API (ADR 0007 accepted)

- RGB8 per-channel histograms and ROI statistics with explicit binary selection.
- Require raster-d v0.3.x; unmasked counts reuse its generic `histogram256`.
- Masked counts retain checked image-selection traversal; results publish only
  on success. No change to the published imagery-d v0.1.0 release.
- Derive exact RGB cumulative counts and integer 0–100 nearest-rank
  percentiles from a completed histogram, with no second raster traversal.
- Build a per-channel RGB8 percentile contrast-stretch lookup table from the
  same counts; equal channel bounds yield an identity map.
- Build an exact-integer RGB8 histogram-equalization lookup table with
  constant-channel identity and explicit per-channel byte semantics.

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
