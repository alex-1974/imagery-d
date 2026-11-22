# ADR 0018: Validate imageio geometry and color before owned materialization

**Status:** Candidate in PR #205; #174/#175 production qualification  
**Date:** 2026-11-22

The existing typed adapter accepted mismatched matrix/range policies, collapsed
metadata errors, dropped crop offsets during native copying, skipped geometry
when dimensions matched and rounded component interpolation before float RGB.
Its malloc adapters also exposed unnecessarily broad system-safety boundaries.

Keep the model/geometry/output composition from ADR 0012 and existing call
names. Harden preflight and use one declared coordinate equation across native
component expansion, RGB arrays and a new direct owned raster path. Invert
imageio's public sample-center contract plus explicit center offset; do not add
a separate image-resampling half-pixel convention. Regenerate target-grid
geometry after component expansion. Preserve source facts during native copying.

Only unsigned u8 YCbCr with known matching BT.601/709 matrix and full/video range,
sRGB transfer and sRGB/BT.709 primaries is admitted to RGB. Missing, unsupported,
conflicting and policy-mismatched cases remain distinct. Keep native access when
interpretation fails. Do not manufacture source metadata to make ordinary JPEG
output pass. Positive real-decoder tests use a separately declared fixture policy.

The direct owned API allocates one raster-d buffer, retains no source arrays,
keeps bilinear fractions until color conversion and publishes transactionally.
Color-d owns the conversion and byte quantizer; float outputs remain unclipped
encoded-sRGB. Small trusted helpers only allocate/copy/adopt checked memory.
No generic raster descriptor or refcount is reimplemented.

Zero-copy native inspection remains an imageio-slice operation with caller-owned
lifetime, not a new retained raster capability. Scope on its callback is compiler
checked; deep aggregate-slice retention is a semantic caller rule, explicitly
not claimed as a DIP1000 rejection. Independent retention uses the owned path.

The candidate has an explicit sub-cell-phase envelope to avoid cancellation of
huge rational translations. Arbitrary registration, CRS transforms, source truth,
decoder ROI residency, alpha/NoData interpretation and application scheduling
remain outside this adapter. #145/#146/#187 and #74 are not closed by it.

The [contract and reproducible consumer](../imageio-materialization.md) define
the numerical, metadata, ownership, budget, error and lifetime boundaries.
