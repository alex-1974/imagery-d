# ADR 0011 — RGB luminance percentile stretch

**Status: ACCEPTED FOR DEVELOP SOURCE API — RELEASE DEFERRED**
**Date:** 2026-10-23

## Decision

Add `tryRgbLuminanceStretchOwned` for decoded three-plane RGB8 input. The
consumer supplies a nonempty ROI, integer lower/upper nearest-rank percentiles,
and a result-payload budget. Output is a new ROI-local interleaved
`RasterLease!float` containing normalized encoded-sRGB values.

The distribution uses CIE XYZ D65 Y after explicitly decoding encoded sRGB to
linear-light sRGB through color-d. The RGB8 transfer values and XYZ-D65-Y
arithmetic use `float`, matching the owned float output. A fixed 65,536-bin
uniform histogram over Y in [0,1] estimates thresholds. Input values use
`floor(Y * 65536)` (with 1 assigned to the final bin); selected bin indices
drive the transform. The bin width is exactly 1/65,536 in computed float Y;
values close to a boundary follow float rounding. Nearest-rank percentiles use
exact integer ranks. This avoids a pixel-sized sorting copy.

For nonconstant selected bounds, each pixel's linear RGB is uniformly scaled
so its quantized Y maps linearly between the selected bins. A zero-Y pixel
stays black. If both percentiles land in the same bin, the transform is the
identity. The optional binary mask estimates thresholds only; all ROI pixels
are transformed.

The compile-time `Clip` parameter (default `true`) selects hard linear-sRGB
clipping or whole-call `outOfGamut` failure. `color-d ~>0.3.0` supplies the
exact reusable 256-entry RGB8 decode table. The per-call output-curve table
uses 4,096 intervals on both compiler paths. DMD and the LDC scalar tail
interpolate between adjacent samples; the LDC vector path uses the nearest
sample directly to remove per-channel interpolation work. The LDC lookup's
grid quantization contributes at most about 0.41 of an 8-bit code value before
float rounding, and the independent byte oracle remains the numerical
acceptance gate with a one-code-value tolerance.
`raster-d ~>0.5.5` supplies scoped affine/multi-plane windows and the
multi-view phase API; no raw pointer escapes the callback. The kernel hoists
row bases and sample strides out of the pixel loop. v0.5.5 fixes the worker
capture defect tracked in [raster-d #278](https://github.com/alex-1974/raster-d/issues/278).
Imagery allocates one private histogram/count slot per requested worker and
reduces those slots after the phase barrier. Callback failure may leave partial
temporary writes, but imagery publishes only on complete success. The
independent byte oracle is the numerical acceptance gate. Returned failures
preserve the previous published result.
Alpha, profiles, transfer metadata and NoData are not inferred. Imagery owns
the RGB8 lookup-table lifetime, ROI traversal, histogramming and output
ownership.

## Qualification

The independent DUB consumer calls the public API against
`raster-d@0.5.5` and `color-d@0.3.0`. DMD and LDC tests pass, and the P6
consumer passes the independent XYZ-D65-Y byte oracle with a maximum one-byte
error for serial and four-worker cases. Pixel callbacks remain synchronous
and scoped; raster-d joins all workers before the API returns.

The documented color-d Fast CI pair, DMD 2.113.0 and LDC 1.43.0, passes
imagery-d unit tests. The independent consumer also passes with DMD 2.113.0
and LDC 1.43.0 (release). An independent Python sRGB/XYZ-D65-Y scalar oracle
passes 12 P6 cases, including the pinned M4 fixtures, a deterministic 256×256
RGB sample, neutral and constant images, and mask-selected thresholds. The
observed maximum error is one output byte; four invalid requests are rejected
without output publication. The byte tolerance is one code value to account
for float-to-byte serialization.

An initial bounded LDC Release benchmark, the v0.4 scoped-kernel follow-up and
the production-size matrix are recorded in
`docs/performance/m3-luminance-stretch-2026-10-23.md`. With raster-d v0.5.5,
four workers measured 18.1–18.7 ms/call at 1080p with LDC and 36.2–39.1
ms/call with DMD, including the mask case. These are local diagnostics, not a
portable performance claim or release qualification. DMD and LDC pass imagery-d unit
tests and the independent consumer P6 oracle on the sRGB/XYZ-D65 path used
here. These direct checks do not qualify color-d's
broader API or remove its documented Phobos `cbrt` limitation; the
[color-d requalification request](https://github.com/alex-1974/color-d/issues/195)
is tracked separately.
Release admission remains deferred pending normal exact-head CI and
supported-hardware qualification.
