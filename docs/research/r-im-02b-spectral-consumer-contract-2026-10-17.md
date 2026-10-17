# R-IM-02b — Aligned multispectral normalized difference consumer

**Research date:** 2026-10-17  
**Status:** RESEARCH IMPLEMENTATION — exact-HEAD compiler qualification must be checked independently.  
**Dependency:** [R-IM-02a histogram Draft PR #77](https://github.com/alex-1974/imagery-d/pull/77), whose parent is the [R-IM-01 matrix Draft PR #76](https://github.com/alex-1974/imagery-d/pull/76). This is a separate, stacked research topic.  
**Production:** NO public API, accepted ADR, root `dub.sdl`, `source/imagery/**`, actual satellite reader, sensor-specific format, resampler, or externally adopted application.

## Why this is a useful second consumer

The first independent R-IM-02a consumer tested masked stored/physical histograms for photographs and scientific data, but **could not qualify spectral arithmetic, two independently identified bands, co-registration requirements, or separate output validity**. R-IM-02b isolates these questions without introducing an I/O backend, a sensor-specific NDVI type, cache, scheduler or generalized expression language.

A normalized difference is defined on physical compatible quantities:

```text
index = (physical(A) - physical(B)) / (physical(A) + physical(B))
physical(X) = double(stored(X)) * scale(X) + offset(X)
```

For example, A may represent a caller-declared NIR band and B a caller-declared red band. **No band number implies NIR, red, wavelength, sensor name or spectral interpretation**; the current `uint bandId` is merely a caller-declared opaque identity, **not** a validated STAC/EO/Sentinel metadata binding.

## Research source and independent DUB consumer

Research-only DUB library: `experiments/r_im_02b_spectral/dub.sdl`, module `source/imagery/analysis/spectral_research.d`.  
Independent DUB executable: `experiments/r_im_02b_spectral/smoke/dub.sdl`, module `smoke/source/app.d`.

The library depends on **pinned raster-d v0.2.0** commit `2f2415851e45001df92ce56dad409f680684ba8d`. Both inputs are real `RasterLease!T` owners held by the caller; the operation accepts only borrowed `RasterView!T` descriptors. Outputs are caller-owned, disjoint `RasterLease!float` and `RasterLease!ubyte`, with writable views passed separately.

The prototype accepts `ushort` and `float` inputs and supports separate types in the generic template, but the first consumer only instantiates homogeneous source pairs (`ushort/ushort`, `float/float`). Neither arbitrary band/sample types nor package-level promotion is inferred.

## Exact grid/region contract

`ResearchGrid` records a **caller-declared coordinate-frame identity**, pixel-grid origin and signed per-axis steps. It is **not** a CRS object or geographic transformation. Validation rejects:

- unspecified coordinate-frame ID or nonfinite/zero grid step;
- **different frame IDs, origins or signed pixel steps**;
- differing source raster dimensions even if the numeric grid descriptors agree;
- a zero-sized or out-of-range ROI, without clipping or implicit resampling;
- a mask not covering the complete corresponding source grid;
- an output numeric or validity raster without **exact ROI extent and one band**.

This **does not establish real sensor co-registration** solely from caller metadata. A future materializer/registration stage must establish that the grid declarations truthfully correspond to actual source pixels. Same array size is specifically insufficient evidence of alignment.

The result of ROI at source coordinate `(roi.x,roi.y)` is stored at output-local `(0,0)`, with exact ROI dimensions. Region coordinates do not accidentally become world/global coordinates.

## Radiometric, mask and numerical contract

- Two independent `ResearchSpectralBand!T` inputs select **plane indices separately from opaque band IDs**. Nonzero IDs are required, but identities, spectral wavelengths and sensor roles are not checked against immutable product metadata yet.
- Both inputs must explicitly declare `calibrated=true`, the **same non-unspecified unit category**, and finite scale and offset. This does **not** prove genuine reflectance calibration or unit equivalence beyond the coarse research enum.
- Source masks A and B are independent optional 1-channel `ubyte` rasters: **zero invalid; nonzero valid**. Invalidity is the union of explicitly selected mask failures. It is separate from alpha, NoData and acquisition quality metadata.
- A source NaN, infinity, nonfinite physical result, exactly zero denominator, nonfinite normalized ratio or float-output overflow produces **numeric 0.0f plus output mask=0**. A valid zero ratio remains numeric 0.0f with **output mask=255**. This is the essential distinction.
- **No invented denominator epsilon**, saturation to [−1,1], absolute/relative unit conversion or implicit negative-value rejection. Signed values and magnitudes outside [−1,1] may be physically meaningful for generic normalized differences when denominator is small or source inputs are signed.
- On success, output always contains a complete ROI of numeric floats and a separate complete ROI of 0/255 validity bytes.
- **Preflight rejection leaves caller-owned output completely unchanged**; unexpected access/write failure after pixel processing begins can leave a *partial* result (no rollback, no alias enforcement). This is deliberately **not an accepted general public caller-owned API**; test destinations use independent real raster-d owners.
- No claim of `@safe`, `@nogc`, `nothrow`, atomic concurrent snapshot, physical malloc recovery, global memory budget, last-lease accounting, or allocator-/RSS-free operation.

## First complete numerical consumer oracle

The independent executable builds a deterministic **8×6 image with three bands** (selected band **plane 1**, independent IDs **77 for A/NIR** and **42 for B/red**). It initializes separately adopted and imported public `raster-d` owners for the source rasters, source validity masks, numeric result and result-validity mask.

General integer DN formulas for selected plane:

```text
redDN(x,y) = 200 + x + 2y
nirDN(x,y) = 400 + 3x + 4y
except both DN=0 at (5,2) for the true-zero-denominator fixture,
and both DN=333 at (1,1) for the **valid zero ratio** fixture
```

The `float` version adds NaN at (2,3), infinity at (6,4), and a signed physical case at (7,5) with red=1200 and NIR=−400. The physical calibration is `DN*0.01 + offset` with offsets **0.0** and **1.5**. Thus the zero-DN pixel is invalid under zero offset but correctly valid under nonzero offset; calibration semantics are observable.

Independent masks:

```text
red valid if (x + 2y) % 5 != 0
nir valid if (2x + y) % 7 != 0
```

Cross-product: **2 input types × 2 layouts of red × 2 layouts of NIR × 2 red-mask states × 2 NIR-mask states × 2 calibration offsets = 64 configurations**.

Each configuration evaluates one **8×6 whole output** and **four 4×3 quadrants**, with every numeric sample and validity byte checked against an **independent fixture-derived mathematical oracle** (not by calling the production function or reading source values to make expected values). Entire quadrant outputs must match the recorded whole output **exactly** for corresponding pixels, including invalid values: **64 × 5 = 320 complete ROI+mask pairs**, **64 × (48 + 4×12)=6,144 result-pixel comparisons** before counting negative checks.

Twelve separately classified negative tests per configuration exercise mismatched resolution, frame ID, shifted origin, **zero pixel step**, **unequal source dimensions**, NaN calibration, unit mismatch, absent calibration, invalid band index, out-of-bounds ROI, missing required mask, and **wrong output dimensions**. The previously initialized 8×6 numeric/mask output must remain **unchanged in all 48 pixels** after the series of preflight rejections.

**An ordinary independent consumer test is not a real deployed satellite consumer.** No external Sentinel-2 product, quality mask encoding, native 10m/20m/60m resampling, sensor calibration, xarray-like time axis, temporal change analysis or scene provenance is claimed.

## CI acceptance and further limits

Workflow: `.github/workflows/r-im-02b-spectral-consumer.yml`. Matrix:

| Compiler | Debug | Release |
|---|---|---|
| DMD 2.111.0 | CI required | CI required |
| DMD 2.113.0 | CI required | CI required |
| LDC 1.41.0 | CI required | CI required |
| LDC 1.43.0 | CI required | CI required |

The workflow imports the **separately compiled research package** in a **distinct DUB executable**, runs the independent full-pixel and negative test oracle, and rejects any accidental production root `dub.sdl`/`source/imagery`. Results are not marked PASS until checks on the **exact source head** have completed.

Next semantic admission blockers: replace provisional opaque `bandId` and coarse unit with the already studied M1/M3 immutable band/product descriptors; define real target-grid materialization/resampling separately; add proper source NoData/quality semantics, controlled nonalias/complete-on-publication output semantics, wide numeric-domain tests and LDC XPS benchmarking against comparable tools. Do not automatically copy this caller-output signature to production.

**Grandfathered RGBA Draft PR #73 is untouched; do not merge it, PR #76, #77 or the present research into `develop` merely because these tests pass.**
