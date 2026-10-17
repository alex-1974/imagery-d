# R-IM-02a — Executable image histogram consumer contract

**Date:** 2026-10-17. **Status:** RESEARCH IMPLEMENTATION / COMPILER EVIDENCE PENDING.  
**Parent:** R-IM-01 Draft PR #76, branch `research/r-im-01-feature-api-matrix`.  
**Topic branch:** `research/r-im-02-histogram-consumer`.  
**No production admission:** no root `dub.sdl`, no `source/imagery`, no accepted public operation name, no release API or production ADR. Does not change any sibling repository or stacked RGBA Draft PR #73.

## R-IM-02 four independent consumer classes

| Class | Consumer need | Executable evidence in this topic | State / next stop |
|---|---|---|---|
| **C1: General image** | 8-bit photos with channel-selected intensity histogram, ROI and optional explicit pixel mask | **Prototype ubyte consumer** uses a real 3-band `RasterLease!ubyte`, selects bands 0 or 2, probes planar/interleaved, stored/physical interpretation and ROI partition consistency. The current fixture is synthetic numeric intensity data; it does **not** assume sRGB luminance or perform a colour transfer. | Implemented; compiler/CI result to verify. RGB presentation/luminance remains separate `color-d`-aware study. |
| **C2: Scientific image** | 16-bit and float samples, valid mask, NaN, band calibration, deliberate exclusion policy | **Prototype ushort/float consumer**, same matrix, including one deliberate valid `float.nan`; physical means `raw*scale+offset` with finite caller-supplied parameters. | Implemented; compiler/CI pending. Does not yet use immutable named-band metadata or real sensor units. |
| **C3: Optical/multispectral EO** | red/NIR spectral IDs, native unequal grids, chosen co-registered target, calibrated masked normalized difference | No ND operator implemented in this slice. Need an explicit negative mismatched-grid test **before** resampling and an aligned, mask-propagating independent numeric oracle **after** application-level resolution. | **OPEN: R-IM-02b**; do not equate band numbers with wavelengths or accept unaligned sources. |
| **C4: Dunia viewport** | user-visible image background+overlay, source revision, display grid and independent result retention versus direct renderer blending | No existing Dunia image-renderer implementation; previous read-only [candidate audit](https://github.com/alex-1974/imagery-d/blob/research/m3-rgba-layer-compositing/docs/research/m3-rgba-dunia-consumer-admission-audit-2026-10-17.md) records the gap. | **NOT AN ADOPTED CONSUMER**. Preserve this hypothesis; do not edit Dunia or claim RGBA public B selection. |

**R-IM-02 is not complete** merely because C1/C2 have a synthetic, independent DUB test consumer. A genuine non-test consumer remains a separate gate before any first production API.

## Current narrow implementation

A separately compiled research DUB **library**:

`experiments/r_im_02_histogram/source/imagery/analysis/histogram_research.d`

and independent DUB **executable**:

`experiments/r_im_02_histogram/smoke/source/app.d`

Both depend only on **read-only pinned `raster-d v0.2.0`** (`2f2415851e45001df92ce56dad409f680684ba8d`), via a sibling path. CI provisions that dependency through a checkout, not a repository write.

The current **fixed-eight-bin** `tryHistogram8Research` is a deliberately provisional contract probe rather than a proposed universal public histogram signature. The fixed bucket count avoids prematurely committing to a generic allocator/owner or variable-size error contract.

- Input: one selected plane in a borrowed `RasterView!ubyte`, `RasterView!ushort`, or `RasterView!float`; nonempty checked `Region2D`; optional separate one-plane `RasterView!ubyte` mask with **identical pixel grid**; caller-supplied stored/physical meaning.
- **Stored:** raw sample numeric value without implicit byte normalization or sRGB decoding.
- **Physical:** `double(raw)*scale+offset` with explicitly supplied finite `double` scale/offset; no inferred unit/sensor calibration.
- **Mask:** 0 invalid, nonzero valid. A masked pixel is counted only as `masked`, before attempting pixel read.
- **Non-finite:** unmasked NaN or infinity after optional conversion increments `nonFinite`, not a histogram bin.
- **Range:** `[minimum, maximum)`, minimum included and maximum **excluded**; finite out-of-range increments `outsideRange`, not an endpoint bin.
- **Bins:** eight half-open subintervals of equal width within the requested half-open range. No hidden clipping, saturation or quantization of input.
- **Output:** `Histogram8` holds eight `ulong` counts and separate `counted`, `masked`, `nonFinite`, `outsideRange` totals. Its `.init` is an empty valid accumulator, **not a success status**.
- **On a classified error:** the caller's old `ref Histogram8` remains untouched. After successful full traversal the private stack candidate is published in one assignment. Rejected bad band, zero/overflow ROI, mask geometry, invalid interval and nonfinite physical calibration are checked before publication.
- **No claim** of concurrent mutation safety, atomic values, a shared cache budget, physical noalias for writable output, multithreaded speed, `@safe`/`@nogc` or end-to-end allocation freedom.

The reference range policy is deliberately **different** from OpenImageIO's documented `ImageBufAlgo::histogram`: OIIO covers its declared endpoint interval and **clamps below-min/above-max values to endpoint bins**. We explicitly count them as `outsideRange` instead; these implementations are **not** semantically equivalent without a normalization policy. [OIIO histogram](https://openimageio.readthedocs.io/en/stable/imagebufalgo.html).

## Independent executable test design

Each DUB consumer run creates real malloc-backed, public `raster-d`-adopted raster owners and uses writable `raster-d` views to initialize fixtures. **No synthetic duplicate ownership/refcount implementation** is introduced.

Synthetic grid: **8×6**, **3 image bands**, optional **one-band mask** with `valid(x,y) = ((x+2*y)%5 != 0)`; data `band*8 + x + 2*y`. For `T=float`, band 2 at `(2,3)` is deliberately NaN and unmasked. Scales: stored identity versus physical `2*raw+1`, histogram range `[0,64)`.

Cross-product: 3 sample types × 2 storage layouts × 2 mask states × 2 value meanings × 2 selected bands = **48 configurations**.

For **every** configuration, a consumer-specific reference oracle evaluates the exact deterministic fixture independently of the library method. The oracle computes bucket number from the fixture's integer-domain quotient by 8 (not the implementation's floating normalized ratio). It compares **all eight bin totals and all four classification counters**, then repeats the operation over four nonoverlapping 4×3 ROIs. Summed partition counters/bins **must exactly equal** the whole-ROI result: **48 full and 192 partitioned operations = 240 output comparisons**.

Independent failure checks per case: invalid source band; out-of-range ROI; empty numeric range; invalid mask; and nonfinite physical calibration (where applicable). The previous nonempty `Histogram8` result must be preserved **byte-for-value** (all fields/bins) after every classified error.

This corpus currently contains **synthetic scalar values only**. No real sensor file, calibration metadata, spectral band identity, optional NoData sentinel, exact/approximate percentile, multithreading, 2048² scene, dynamic bin count or performance comparison is exercised. These omissions are **explicit future gates**, not silently PASS.

## Compiler gate

Targeted workflow: `.github/workflows/r-im-02-histogram-consumer.yml`:

- DMD 2.111.0 and 2.113.0; LDC 1.41.0 and 1.43.0;
- separate DUB library import/link and independent program execution in **Debug** and **Release**;
- captured runtime PASS receipt must include exact `48 cases, 240 complete`;
- positive `-preview=dip1000` compilation;
- no new mandatory `color-d`/`imageio-d` dependency or root production source.

**On initial documentation:** CI must actually complete successfully before any numeric or compiler PASS claim. The current assistant environment has **no D compiler/DUB installed**, so source authoring alone is not compile evidence. No XPS LDC benchmark was run or is claimed.

Reproduction from a workspace containing sibling `raster-d` v0.2.0:

```bash
dub run --root=experiments/r_im_02_histogram/smoke --compiler=dmd --build=debug --force
dub run --root=experiments/r_im_02_histogram/smoke --compiler=ldc2 --build=release --force
```

## Decisions and possible contradictions

- **Research direction:** histogram/statistics provides a generic consumer across images, scientific rasters and multispectral data without assuming RGB or requiring GUI/OSM types.
- **Boundary to review:** a generic histogram over numeric raster values might partly belong in `raster-d`. Only **explicitly image-domain semantics** (band identity, radiometric meaning, masks/quality, presentation policy) justify a higher `imagery-d` adapter. Do not duplicate an equivalent generic raster reduction blindly.
- **Potential discrepancy to resolve:** C1/C2 prototype passes scale/offset and band index as separate *arguments*, but the accepted M1 image view requires immutable band metadata and explicit identities. This is intentionally provisional; **the current prototype does not yet prove a semantic `ImageView!T` API**. R-IM-02's next integration must reuse the already-probed M3.2 metadata/ROI model without mechanically transplanting the large research dependency stack.
- **Future priority:** R-IM-02b: normalized difference on explicit aligned grid, zero denominator + invalid policy, independent numerical oracle; R-IM-02c: mask+NoData+histogram numeric and source metadata, before any source/public API choice. Separate C4 depends on a future genuine Dunia renderer feature.
- **Stop:** No public package, broad image operation library or scheduler, no automatic merge to research-integration/develop; existing grandfathered Draft PR #73 remains unchanged.

## Source references

- [R-IM-01 comparative matrix](r-im-01-feature-api-matrix-2026-10-17.md).
- [Accepted M1 ADR 0002](https://github.com/alex-1974/imagery-d/blob/develop/docs/adr/0002-image-semantic-core.md).
- [Accepted M2 ADR 0003](https://github.com/alex-1974/imagery-d/blob/develop/docs/adr/0003-source-cache-pipeline-architecture.md).
- [M3 independent common-grid ROI consumer (research)](https://github.com/alex-1974/imagery-d/blob/research/m3-rgba-layer-compositing/docs/research/m3-standalone-image-roi-consumer.md).
- [OIIO ImageBufAlgo histogram](https://openimageio.readthedocs.io/en/stable/imagebufalgo.html).
- [GDAL raster data model](https://gdal.org/en/stable/user/raster_data_model.html).
- [OTB BandMathX application](https://www.orfeo-toolbox.org/CookBook/Applications/app_BandMathX.html).
