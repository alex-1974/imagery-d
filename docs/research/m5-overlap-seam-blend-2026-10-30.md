# M5 explicit overlap seam blend qualification

**Status:** LINEAR-LIGHT CONTRACT QUALIFIED; PUBLIC API DEFERRED

- Date: 2026-10-30
- Tracking: [Issue #136](https://github.com/alex-1974/imagery-d/issues/136)
- Dependencies: raster-d 0.5.5, color-d 0.3.0

## Question and responsibility boundary

Can two already-aligned decoded RGB8 sRGB sources be combined across an
overlap without an artificial processing-tile seam when the consumer supplies
the complete per-pixel source weighting policy?

The research candidate accepts two equal-grid, three-plane encoded-sRGB byte
rasters, a full-grid one-plane u8 weight map, a nonempty ROI and an output
payload budget. Weight 0 selects source A exactly, 255 selects source B
exactly, and intermediate weights use `weight / 255` in linear-light sRGB.
The result is encoded and half-up quantized into a new ROI-local interleaved
RGB8 owner. Returned failure preserves the previous owner.

The weight map is not inferred. Registration, source provenance, validity,
cloud/quality assessment, temporal preference, seam location and feather
shape remain consumer or later policy responsibilities. This kernel only
executes the explicit image-domain blend.

## Why linear light

Interpolating encoded sRGB bytes is not light-linear. The exhaustive
black-to-white feather test demonstrates the distinction: weight 128 produces
encoded byte 188 after linear-light blending, whereas direct encoded-byte
interpolation would produce approximately 128. Endpoints remain exactly 0
and 255.

color-d supplies the exact 256-entry sRGB decode table, typed linear-light
value and explicit encoding/storage conversion. The independent oracle uses
the scalar sRGB piecewise equations directly and does not call color-d.

## Qualification matrix

The 260x9 source fixture contains a non-origin 256x7 overlap. Its first ROI
row is the exhaustive black/white weight ramp 0 through 255; the remaining
rows use distinct deterministic RGB patterns for both sources.

Eight source/mask layout combinations cover planar/interleaved storage,
positive/negative rows and positive/negative sample strides. Every combination
checks:

- one complete owned 256x7 result;
- all 43,008 output component values against the independent scalar oracle;
- exact left/right 128-pixel partition reconstruction, another 43,008
  component comparisons;
- exact endpoints, midpoint 188 and monotonic black-to-white feathering.

Observed local maximum error is zero bytes; the acceptance bound remains one
byte for floating-point transfer/quantization portability. Invalid source
grids, invalid weight planes, empty/outside ROIs and a one-byte-short payload
budget are rejected without replacing the prior result.

Local DMD Debug and LDC Release pass. Hosted CI executes the full oracle in
Debug and Release with DMD 2.111/2.113 and LDC 1.41/1.43. Hosted elapsed time
is not used as a performance claim.

## Memory and publication

The requested pixel payload is exactly `roi.width * roi.height * 3` bytes;
the qualified 256x7 result is 5,376 bytes and a 5,375-byte budget fails before
allocation. The bound excludes both sources, weight map, prior result, raster
metadata, allocator overhead and total RSS. A temporary owner is published
only after every output component has been written successfully.

## Decision

The semantic result is clear: an explicit weight field and linear-light sRGB
blend are sufficient to make an aligned two-source overlap independent of
processing partitions. Source ranking/quality must not be silently inferred
inside the pixel kernel.

Do **not** admit the current RGB8/two-source surface publicly yet. No concrete
non-test consumer has selected this exact owned CPU result, and the experiment
does not solve alpha, validity/NoData, more than two contributors, transform
alignment or automatic seam construction. The candidate stays under
`experiments/`, outside the source archive and root import.

Future API promotion requires a real consumer plus explicit decisions for
alpha/validity and weight ownership. Future M5 policy work may construct the
weight field from source quality, but that policy must remain separately
testable from the colour-correct blend.

## Non-goals

No grid registration, reprojection, source-quality inference, automatic seam
location, alpha, NoData, scientific multiband semantics, more than two
sources, pyramids, cache, progressive delivery, scheduler or DAG is claimed.
