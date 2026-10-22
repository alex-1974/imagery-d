# ADR 0010 — RGB8 histogram-equalization lookup table

**Status: PROPOSED FOR DEVELOP SOURCE API**
**Date:** 2026-10-22. **Base:** accepted ADRs 0007–0009.

## Consumer and boundary

The existing P6 RGB image consumer needs a histogram-equalization alternative
to percentile contrast stretch. The admitted histogram already supplies exact
per-channel byte counts. The image-domain addition is one fixed 3×256-byte
lookup table; the consumer owns pixel application and output. No generic
raster reduction or second public raster owner is introduced.

## Proposed contract

`tryRgbEqualizationLut(const ref RgbHistogram256 histogram,
ref ubyte[256][3] published)` validates the public mutable record and
requires at least one included pixel. For each channel, let `first` be the
count in its first occupied bin, `n = includedPixels`, and `C(v)` the
inclusive cumulative count at stored byte `v`. For a nonconstant channel:

```text
mapped(v) = 0                                    if C(v) <= first
mapped(v) = roundHalfUp(255*(C(v)-first)/(n-first)) otherwise
```

This maps the first observed byte to 0 and the last to 255. If `first == n`,
the entire channel is identity: a flat channel receives no arbitrary colour
change. The multiplication and division use `core.int128.Cent` so counts
through `ulong.max` map exactly without overflow or floating-point rounding.
The output is monotone for each channel.

An empty or malformed histogram returns false and leaves the prior output
unchanged. The public record `.init` is a valid empty histogram, but cannot
produce an equalization map; the return boolean determines success. The
operation is `@safe pure nothrow @nogc`, reads no raster and allocates no
pixel buffer. Its histogram's binary mask only selects pixels for estimating
the CDF. Which image pixels receive the map is a separate consumer decision.

Independent per-channel equalization operates on stored RGB bytes and may
change colour relationships. It does not infer luminance, transfer function,
ICC profile, alpha, NoData or fractional editing-mask semantics.

## Qualification

Focused tests cover constant channels, empty/malformed records, caller-output
preservation, endpoints and `ulong.max` counts. The independent D consumer
checks all 256 entries and monotonicity against source-byte counts across 80
ROI/layout/mask cases. The P6 file consumer checks exact output bytes on four
SHA-pinned M4 fixtures against a Python rational oracle. The public import,
source-archive and DDox gates cover the distributed API. This proposal does
not select a release version or freeze the API.
