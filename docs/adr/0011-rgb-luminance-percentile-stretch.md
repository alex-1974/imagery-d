# ADR 0011 — RGB luminance percentile stretch

**Status: ACCEPTED FOR DEVELOP SOURCE API — RELEASE DEFERRED**
**Date:** 2026-10-23

## Decision

Add `tryRgbLuminanceStretchOwned` for decoded three-plane RGB8 input. The
consumer supplies a nonempty ROI, integer lower/upper nearest-rank percentiles,
and a result-payload budget. Output is a new ROI-local interleaved
`RasterLease!float` containing normalized encoded-sRGB values.

The distribution uses CIE XYZ D65 Y after explicitly decoding encoded sRGB to
linear-light sRGB through color-d. A fixed 65,536-bin uniform histogram over
Y in [0,1] estimates thresholds. Input and threshold values use
`floor(Y * 65536)` (with 1 assigned to the final bin); selected bin indices
drive the transform. Nearest-rank percentiles use exact integer ranks. This
avoids a pixel-sized sorting copy.

For nonconstant selected bounds, each pixel's linear RGB is uniformly scaled
so its quantized Y maps linearly between the selected bins. A zero-Y pixel
stays black. If both percentiles land in the same bin, the transform is the
identity. The optional binary mask estimates thresholds only; all ROI pixels
are transformed.

The compile-time `Clip` parameter (default `true`) selects hard linear-sRGB
clipping or whole-call `outOfGamut` failure. Returned failures preserve the
previous published result. Alpha, profiles, transfer metadata and NoData are
not inferred. `color-d ~>0.2.0` owns color conversions; imagery-d owns ROI
traversal, histogramming and output ownership.

## Qualification

The independent DUB consumer calls the public API against registry
`color-d@0.2.0`, checks neutral endpoint behavior, and runs the existing Levels
and RGB-histogram consumer suite. `yBin` is a template so color-d's generic
conversion instances are emitted in the final consumer module rather than
being left as unresolved references in imagery-d's static library.

The documented color-d Fast CI pair, DMD 2.113.0 and LDC 1.43.0, passes
imagery-d unit tests. The independent consumer also passes with DMD 2.113.0
and LDC 1.43.0 (release). An independent Python sRGB/XYZ-D65-Y scalar oracle
passes 11 P6 cases, including the pinned M4 fixtures, neutral and constant
images, and mask-selected thresholds; four invalid requests are rejected
without output publication. The exact byte tolerance is one code value to
account for the consumer's float-to-byte serialization.

An initial bounded LDC Release benchmark is recorded in
`docs/performance/m3-luminance-stretch-2026-10-23.md`: 4.311 Mpixel/s at
512×384 and 4.370 Mpixel/s at 1024×768 on one pinned local CPU. It is a
diagnostic baseline rather than a cross-platform speed claim. DMD 2.111.0 and
LDC 1.41.0 also pass imagery-d unit tests, the independent owned consumer and
the P6 oracle on the sRGB/XYZ-D65 path used here. These direct checks do not
qualify color-d's broader API or remove its documented Phobos `cbrt` limitation;
the [color-d requalification request](https://github.com/alex-1974/color-d/issues/195)
is tracked separately.
Release admission remains deferred pending normal exact-head CI and
supported-hardware qualification.
