# ADR 0009 — RGB8 percentile contrast lookup table

**Status: PROPOSED FOR DEVELOP SOURCE API**
**Date:** 2026-10-22. **Base:** accepted ADRs 0007 and 0008.

## Consumer and boundary

The existing P6 image consumer wants to stretch each stored R/G/B component
using the 1st and 99th percentiles of its image. Scalar Levels applies one
pair of thresholds to all selected channels and returns a float raster; it
does not directly represent separate RGB byte-domain percentile maps. The
smallest image-domain addition is therefore a fixed RGB8 lookup table.
The caller applies it to selected pixels using its own image-output policy.

## Proposed contract

`tryRgbPercentileStretchLut(const ref RgbHistogram256 histogram,
uint lowerPercentile, uint upperPercentile, ref ubyte[256][3] published)`
accepts `0 <= lowerPercentile < upperPercentile <= 100`. It uses ADR 0008's
exact nearest-rank rule independently for each channel. Values at or below
the lower observed byte map to 0; at or above the upper byte map to 255.
Interior bytes map by linear interpolation rounded to nearest integer,
ties upward. When both observed bounds coincide, the entire channel is an
identity map rather than an arbitrary black/white result.

An empty or malformed public histogram, or invalid percentile order,
returns false and leaves the prior 3×256-byte destination unchanged.
Valid result `.init` is not a success indicator; callers check the boolean.
The operation is `@safe pure nothrow @nogc`, reads no raster, and allocates
no pixel buffer. The full table is published only after all channels pass.

If the source histogram used a binary selection mask, that mask only
determines the distribution and percentile bounds. Applying the table to
all pixels or an explicit subset is the consumer's separate decision. The
function neither reads nor modifies alpha, decodes sRGB, performs ICC
conversion, nor treats a mask as fractional editing strength.

## Evidence and scope

The independent D consumer checks lookup values and monotonicity against
its source-byte oracle over 80 existing ROI/layout/mask cases. The P6 file
consumer checks exact new output bytes for four SHA-pinned M4 RGB fixtures,
a constant channel, no input overwrite and invalid arguments. Public import,
source-archive and DDox gates cover the proposed packaged API.

This is a source candidate for `develop`, not a release/API freeze. It does
not add an owned RGB image-output API, a general raster lookup operator,
real-image provenance or colour-management semantics.
