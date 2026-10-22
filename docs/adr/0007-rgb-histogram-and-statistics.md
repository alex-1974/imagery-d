# ADR 0007 — First 8-bit RGB histogram and ROI statistics

**Status: PROPOSED, NOT YET ACCEPTED OR MERGED**  
**Date:** 2026-10-22. **Tracking:** Issue #107; candidate Draft PR.  
**Base:** develop, after published imagery-d v0.1.0.

## Boundary and consumer

An RGB photo/graphics consumer wants an exact per-channel stored-u8
histogram and minimum/maximum/mean over a selected rectangular ROI,
optionally excluding unselected pixels. No image decoder, sRGB conversion,
sensor metadata or source scheduler is involved.

**raster-d owns generic numeric reductions** as well as buffer, channel
layout, ROI and ownership primitives. Research R-IM-02a (#77) was an
eight-bin generic numeric histogram including physical calibration,
u16 and float. This proposal is intentionally DIFFERENT: a fixed-bin
**R,G,B image-domain interpretation**, with an explicit pixel-selection
contract and no generic raster-reduction API. None of the research
module or its stacked branch history is copied.

## Generic counting reuse — raster-d v0.3.0

The candidate now requires released raster-d v0.3.x. For an unmasked
ROI, form a zero-copy ROI view and call raster-d `histogram256` for
each of the three channels. RGB association, transactional publication,
and minimum/maximum/mean remain imagery-d responsibilities.

The binary-mask overload retains a checked single traversal using
`trySample`: raster-d v0.3.0 does not accept masks. Materializing selected
pixels would violate this API's no-pixel-allocation contract; invoking a
256-bin reduction for each selected pixel/run adds unnecessary work.
This narrowly scoped fallback implements image selection; it is not a
second public generic numeric histogram API. Both paths derive all
statistics from the same exact bins. `histogramInto` is unnecessary for
the fixed u8 domain; configurable/scientific histograms remain separate.

The public candidate signatures, binary-mask meaning, error enum and
preserve-on-returned-error policy are unchanged. Generic reduction failure
maps defensively to `sampleFailure`; its invalid-plane/count-overflow
conditions are already excluded by source and ROI validation.

## Proposed exact public signature

Source module: imagery.analysis.rgb_histogram, re-exported by imagery.

    struct RgbHistogram256 {
        ulong[256][3] bins;
        ulong includedPixels, excludedPixels;
        ubyte[3] minimum, maximum;
        double[3] mean;
    }
    enum RgbHistogramError : ubyte {
        notAttempted, none, invalidSource,
        invalidRegion, invalidMask, sampleFailure
    }
    @safe RgbHistogramError tryRgbHistogram256(
        scope RasterView!ubyte rgb, Region2D roi,
        ref RgbHistogram256 published);
    @safe RgbHistogramError tryRgbHistogram256(
        scope RasterView!ubyte rgb, Region2D roi,
        scope RasterView!ubyte selection,
        ref RgbHistogram256 published);

Exactly three R/G/B planes, each ubyte [0,255], no alpha or luma
inference. No RGB colour space, gamma, normalization or transfer
function inference; planes are counted as raw stored bytes.
The ROI must be nonempty and within the source. Optional mask is
a full-source-sized one-plane u8 image: **0 excludes, >0 includes
a pixel once**, not Levels' fractional edit strength.

Each channel's 256 counters add to includedPixels, whose sum with
excludedPixels equals the ROI area. Extrema and means are over
included pixels; with zero included pixels, all fields remain zero
and extrema have no observed-sample interpretation.
RgbHistogramError.init == notAttempted; never a returned success.

## Ownership, allocation, math and errors

The source/mask are borrowed, not retained. The result is a fixed-size
value, no heap or output raster allocation. On all normally returned
errors the old published result remains byte-for-value unchanged.
Check source/ROI/mask up front and access every sample with raster-d's
trySample for the masked path. No concurrent input mutation guarantee, no nothrow/OOM
recovery. Public @safe calls use no @trusted or raw memory code.

All bins and pixel counts are exact 64-bit integers; ROI cardinality
is prechecked against ulong.max. Means are computed in a fixed order
from the exact bins using double, with ordinary rounding. No claim
of bit-exact real-number means or universal machine-state guarantees.
Runtime scales linearly with selected ROI pixels, plus 768 bins for
final statistics. No need for research-grade benchmark campaigns
for this small image-domain candidate.

## Qualification and admission

Use DMD/LDC Debug+Release ordinary independent DUB consumer, both
planar/interleaved, independently signed row/sample strides and padding,
0/128/255 mask, 5 ROIs per scene (80 cases), exact reference
bin counts, image sample min/max/mean, full-versus-partition
equality, nested source/mask ROI views, all-active mask equivalence,
all-excluded success, invalid source/ROI/mask and rollback.
Render DDox and check curated import imagery. Preserve all historical
research PRs and do not alter raster-d or the published v0.1.0 tag.

**Admission remains a separate decision.** This Draft PR is a
production-shaped candidate for future 0.x develop, not a public
release, a generic scalar histogram, a fixed 8-bin continuation,
or a source to merge without review of this ADR and its CI evidence.
