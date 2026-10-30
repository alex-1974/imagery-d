# M5 decoded regular-tile mosaic qualification

**Status:** ALGORITHM QUALIFIED; PUBLIC API DEFERRED

- Date: 2026-10-30
- Tracking: [Issue #134](https://github.com/alex-1974/imagery-d/issues/134)
- Historical evidence retained in draft PRs #69, #71 and #73
- Current dependency baseline: raster-d 0.5.5, color-d 0.3.0

## Question and scope

Can already-decoded homogeneous RGBA8 tiles on one explicit regular logical
grid produce a bounded owned viewport with exact seams and deterministic
pixel-origin nearest sampling on the current imagery-d baseline?

The experiment accepts a complete row-major grid of equal-size four-plane
tiles, explicit logical tile origins, explicit straight, premultiplied or
unknown alpha association, a nonempty mosaic ROI and a positive rational
scale. It copies all four stored bytes without colour conversion, alpha
conversion, compositing or validity inference. The result is a new ROI-local
interleaved RGBA8 raster, published only after all writes succeed.

The candidate is deliberately isolated under
`experiments/m5_decoded_tile_mosaic/`. It is excluded from source archives and
is not imported by `imagery`.

## Geometry and failure contract

For output coordinate `(x,y)`, pixel-origin nearest sampling uses:

```text
sourceX = roi.x + floor(x * denominator / numerator)
sourceY = roi.y + floor(y * denominator / numerator)
```

The scaled ROI dimensions must divide exactly by the denominator. Complete
grid, tile shape/origin, alpha enum, ROI, scale arithmetic, output payload and
budget validation occur before allocation. Checked arithmetic covers tile
count, canvas extent, scaled dimensions, output payload and signed raster
strides. A returned failure preserves the caller's previous owner.

The budget covers only the new `width * height * 4` pixel payload. It excludes
source owners, the prior result, raster metadata, allocator overhead and total
RSS. In the qualification matrix the largest 24x16 result requests exactly
1,536 bytes; 1,535 bytes fails before allocation. The six 4x4 source tiles
hold 384 pixel bytes in total.

## Independent oracle

The current matrix covers:

- planar and interleaved sources;
- positive/negative rows and positive/negative sample strides;
- straight, premultiplied and explicitly unknown alpha association;
- whole canvas, 2x upsample, 1/2 downsample, non-origin seam-crossing crop,
  cropped 2x upsample and rational 3/2 crop;
- horizontal and vertical tile boundaries;
- 144 complete output rasters and 70,272 independently computed component
  comparisons.

Negative cases cover a missing tile, wrong origin, wrong tile shape,
unspecified and out-of-range association values, outside ROI, zero and
overflowing scale, fractional output shape and a one-byte-short budget. Every
returned failure retains the prior sentinel result.

Local DMD Debug and LDC Release runs pass. Hosted CI runs the same complete
oracle in Debug and Release on DMD 2.111/2.113 and LDC 1.41/1.43. Hosted
elapsed time is not used as a performance claim.

## Decision

The regular-grid copy algorithm and owned rollback form are technically
viable on the current dependency baseline. They also demonstrate that tile
boundaries need not create seams when every output pixel is derived from one
global logical coordinate.

Do **not** admit this RGBA-specific nearest-mapping surface to the public
package yet. No concrete non-test application currently requires this exact
CPU-owned RGBA result, and nearest-neighbour scale policy is too narrow to
stand in for M5 resampling or mosaic semantics generally. Dimensions and tile
origins also do not establish real-world grid-transform compatibility.

Future promotion requires a real consumer choosing this result form and
sampling rule. Otherwise the proven loop should remain consumer code while
imagery-d develops separately justified resampling, sparse/overlap mosaic,
quality and seam-blending contracts. ADR 0012 overview selection remains
independent: it chooses an available grid but does not materialize pixels.

## Explicit non-goals

No decoder, provider/network/cache, CRS/reprojection, sparse or overlapping
mosaic, interpolation/antialias filter, alpha compositing, feathering,
source-quality policy, progressive delivery, scheduler or DAG is claimed.
The historical draft branches remain preserved and are not merged or rebased.
