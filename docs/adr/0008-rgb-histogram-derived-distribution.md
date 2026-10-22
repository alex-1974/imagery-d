# ADR 0008 — Derived RGB8 cumulative counts and percentiles

**Status: ACCEPTED FOR DEVELOP SOURCE API — RELEASE DEFERRED**
**Date:** 2026-10-22. **Base:** accepted ADR 0007.

## Consumer and boundary

An image editor needs percentile cutoffs, for example 1 and 99, from a
selected RGB region before choosing contrast limits. The already accepted
`RgbHistogram256` contains all necessary exact counts. These functions read
that result, not the image, and introduce no raster reduction, output image,
colour-space assumption or mask interpretation.

## Proposed contract

`tryRgbCumulativeCounts(const ref RgbHistogram256, ref ulong[256][3])`
returns inclusive counts through each stored byte. The final entry equals
`includedPixels` for each channel; a valid empty selection yields zeroes.

`tryRgbPercentile(const ref RgbHistogram256, uint percentile,
ref ubyte[3])` accepts integer 0..100. Zero selects the first observed byte.
For 1..100, the one-based rank is `ceil(percentile * includedPixels / 100)`;
each channel selects its first byte whose cumulative count reaches the rank.
No interpolation or floating-point rounding is involved. The rank is
computed by quotient and remainder to avoid multiplication overflow even
when `includedPixels == ulong.max`.

Both functions return `bool`. A caller can edit the public histogram record,
so each call validates that every channel's bins sum exactly to
`includedPixels`, without overflow. A malformed record fails; an empty
selection also has no percentile. Failure leaves the output unchanged. A
valid histogram's `.init` is the empty result, and has a valid cumulative
distribution but no percentile. These functions are `@safe pure nothrow
@nogc` and allocate no pixel buffer.

## Qualification

An independent consumer checks cumulative counts and ranks against source
pixels across the existing 80 planar/interleaved, signed-stride, ROI and
binary-mask cases. Focused tests cover boundaries, repeated values, empty
selection, invalid input and `ulong.max` counts. The public import/API probe,
source-archive consumer and DDox page gate cover the distributed surface.
This decision does not select a release version or change published v0.1.0.

## Decision — 2026-10-22

Accept the narrowly scoped derived distribution API for `develop`.
The independent DMD/LDC consumer, external archive consumer, public API
probes and DDox pass. All eleven active checks on the initial PR #111 head
`206611995b6023f1419419dd5aafee8695a33763` completed successfully;
the optional portability canary was skipped by design. The owner authorized
continuation after this review. The final documentation commit receives its
own exact-head checks before integration. This is source admission only;
release version, API freeze and publication remain separate decisions.
