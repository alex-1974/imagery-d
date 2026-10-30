# imagery-d v0.2.0 — RGB analysis and luminance stretch

This source release extends v0.1.0 Levels with RGB8 image analysis and
tone-mapping helpers. It remains a pre-1.0 D library for already decoded
rasters, with explicit pixel, ROI, mask and output contracts.

## Added

- `RgbHistogram256` and `tryRgbHistogram256` count stored RGB bytes over an
  ROI and report per-channel minimum, maximum and mean. An optional binary
  mask selects samples; zero excludes, every nonzero byte includes once.
- Derived inclusive cumulative counts and integer nearest-rank percentiles
  require no second image traversal.
- Percentile contrast-stretch and histogram-equalization LUTs produce exact
  3×256-byte maps. The caller decides where to apply a map. A histogram mask
  selects samples for estimating the map, not pixels to edit.
- `tryRgbLuminanceStretchOwned` estimates bounds from XYZ-D65-Y luminance,
  scales linear-light RGB uniformly and publishes a new ROI-local owned
  normalized encoded-sRGB float image. Its optional binary mask estimates
  thresholds only; clipping policy and worker count are explicit.

Scalar Levels remains available with the v0.1.0 source contract. The
package now depends on `raster-d ~>0.5.5` and `color-d ~>0.3.0`.

## Compatibility and distribution

Linux x86-64 is the supported baseline. macOS and Windows remain best
effort. Pre-1.0 source APIs may evolve; no stable ABI or portable latency
guarantee is promised. The luminance operation is sequential by default;
applications can choose an explicit worker budget for previews.

This release is distributed as a GitHub source archive with API docs.
imagery-d is not registered on DUB; registration is planned for v1.0.0
unless a concrete earlier need arises.
