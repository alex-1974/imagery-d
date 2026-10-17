# R-IM-01 — Comparative image-library feature and API matrix

**Research date:** 2026-10-17  
**Status:** RESEARCH / DESIGN INPUT ONLY — **no admitted production API, ADR, benchmark result or package**.  
**Scope:** general image processing in D **and** optical/multispectral satellite imagery. Dunia is a prospective application, not the public API's owner.  
**Repository:** `imagery-d` only. This independent research branch starts from `research-integration` at `f47c0ca521b89b526d6e943335bca57b773e08ef`; it does **not** rebase/modify the stacked M3 RGBA Draft PR #73 or any sibling repository.

## 1. Objective and evidence discipline

This is **R-IM-01** from [the 2026-10-17 landscape plan](https://github.com/alex-1974/imagery-d/blob/research/m3-rgba-layer-compositing/docs/research/m3-rgba-first-public-result-form-decision-proposal-2026-10-16.md) and the user-provided `imagery-d-library-landscape-and-roadmap-2026-10-17.md`. Compare **capability, API shape, storage/ROI/validity/ownership rules, and ecosystem boundaries**. Do not treat a presence in another library as evidence that `imagery-d` must reimplement it.

Evidence labels:

- **S** = explicitly documented in a named external primary source linked below.
- **A** = already accepted `imagery-d` architecture (M1 ADR 0002 or M2 ADR 0003).
- **R** = existing `imagery-d` **research implementation**, *not* a public API; link to its separate evidence.
- **P** = new proposal/decision hypothesis requiring further consumer/implementation evidence.
- **U** = not verified at API/code level, so no behavioral/performance claim.

The *recommendation* on every matrix row is **P** even when the compared capability is **S**. Versioned documentation was consulted in October 2026: OpenImageIO 3.2.x docs, libvips 8.18, OpenCV 4.x, scikit-image 0.26, GDAL online raster model, Rasterio 1.4.4, OTB 10.0, current xarray documentation, the eo-learn repository and DUB `dlib` 1.3.1. This is not a version-pinned binary comparison and **does not include timed measurements**.

## 2. Reference-API comparison: concrete observations

| Library / subsystem | Verifiable surface and contract distinction | Lesson for D | Evidence |
|---|---|---|---|
| OpenImageIO `ImageBufAlgo` | `channels(src, order, constants, names)` offers both *returned result* and `bool channels(dst, src, ...)`; in-place allowed but may **copy**. `histogram(src, channel, bins, min, max, ignore_empty, roi, nthreads)` returns counts and reports error via empty vector/`geterror`; `over(A,B,ROI)` requires declared alpha. | Offer a chosen semantic operation separately from physical destination/ownership; never promise `Into` is zero-copy, failure-atomic, or alias-safe merely because OIIO has one. Its `ignore_empty` is **not** a general NoData/mask policy. | [OIIO ImageBufAlgo](https://openimageio.readthedocs.io/en/stable/imagebufalgo.html) |
| libvips | `VipsRegion`/`vips_region_prepare` request image **rectangles**; partial images generate demand-driven regions via start/generate/stop, with threaded downstream evaluation. Operators generally produce new images and may reuse intermediate regions; ~300 operations. | Reuse the accepted M2 *region-first* concept; analyze demand/halo and allocation separately. **Do not** copy its GObject operation database, global scheduler, implicit runtime or lazy public DAG on faith. | [libvips evaluation](https://www.libvips.org/API/current/how-it-works.html), [operation list](https://www.libvips.org/API/current/func-list.html) |
| OpenCV `imgproc` | `GaussianBlur(src,dst,ksize,sigmaX,sigmaY,borderType)` has concrete pixel-depth and border constraints, with in-place support; `remap`, `resize` and `warpAffine` carry explicit interpolation, border and destination/transform semantics, and `warpAffine` forbids in-place. | Destination aliases and types are **operation-specific**, not one universal contract. Image coordinate/pixel-center policy must be specified for comparable resampling. | [filters](https://docs.opencv.org/4.13.0/d4/d86/group__imgproc__filter.html), [transforms](https://docs.opencv.org/4.13.0/da/d54/group__imgproc__transform.html) |
| scikit-image | Explicit algorithm namespaces such as `filters`, `exposure`, `morphology`, `segmentation`, `registration`, `measure` and `transform`. Gaussian/DoG/threshold algorithms document boundary/`channel_axis`/dtype semantics; `correlate_sparse` is specifically **correlation**. | Narrow, named algorithm families. Clarify convolution versus correlation and spatial versus channel axes; avoid Python ndarray dtype/coercion semantics as D defaults. | [API](https://scikit-image.org/docs/stable/api/skimage), [filters](https://scikit-image.org/docs/stable/api/skimage.filters.html) |
| GDAL / Rasterio | GDAL band model has per-band **NoData**, optional **mask**, scale/offset, unit, colour interpretation, overview and **block size**. Rasterio has explicit `read(window=...)` and `block_windows`; actual I/O can expand to underlying blocks. | Preserve intrinsic bands/metadata; logical ROI is not the same as I/O cost or native block; no requirement to coerce into RGBA. Do not rewrite GDAL drivers, CRS handling or generic raster storage here. | [GDAL model](https://gdal.org/en/stable/user/raster_data_model.html), [mask RFC15](https://gdal.org/en/stable/development/rfc/rfc15_nodatabitmask.html), [Rasterio windows](https://rasterio.readthedocs.io/en/stable/topics/windowed-rw.html) |
| STAC / EO extension | Common `bands` have per-band names; EO adds `eo:center_wavelength`, `eo:full_width_half_max` and `eo:common_name`. STAC bands may mean spectral, **classification or quality** data rather than only visible RGB. | Carry opaque provider band identities plus optional spectral role/wavelength metadata; typed image processing should not infer physical meaning from list position. | [STAC bands](https://github.com/radiantearth/stac-spec/blob/master/commons/common-metadata.md), [EO](https://github.com/stac-extensions/eo) |
| xarray | `DataArray` labels dimensions/coordinates; `Dataset` collects aligned arrays. Label alignment/broadcasting is a chosen semantic policy, not just a view of raw bytes. | Keep heterogeneous products with independent grids separate from a common-grid `ImageView!T`; never silently adopt named-axis broadcasting/resampling in pointwise image operators. | [xarray terminology](https://docs.xarray.dev/en/stable/user-guide/terminology.html) |
| Orfeo ToolBox 10 | `BandMathX` operates on multiband expressions; `OpticalCalibration`, `Mosaic`, `Pansharpening`, `OrthoRectification` and `Superimpose` distinguish radiometry, fusion and geometric registration. OTB acknowledges non-streamable work in parts of mosaic harmonisation despite a RAM setting. | Satellite use requires explicit calibrated values, co-registered grid, masks, provenance and honest non-streamable cost disclosures. Do not introduce a giant multisensor/OTB application runtime into the core. | [catalog](https://www.orfeo-toolbox.org/CookBook/Applications.html), [BandMathX](https://orfeo-toolbox.org/CookBook/Applications/app_BandMathX.html), [calibration](https://www.orfeo-toolbox.org/CookBook/recipes/optpreproc.html), [mosaic](https://orfeo-toolbox.org/CookBook/Applications/app_Mosaic.html) |
| eo-learn | `EOPatch`, `EOTask`/`EOWorkflow` with modules for coregistration, features, masking, geometry, I/O and visualization. | Treat time-series/quality-aware EO pipelines as *future consumers*, not an excuse for an early public task graph/scheduler. | [eo-learn](https://github.com/sentinel-hub/eo-learn) |
| Existing D `dlib.image` | DUB registry lists 8-/16-bit and float channels, filters, convolution, resize, FFT, HDRI and common image I/O. **Individual signatures, lifetime behavior, performance and current compiler gates were not source-audited** here. | Acknowledge existing D competition/possible differential reference; **do not** claim these features are absent from D or that `dlib` satisfies `raster-d` ownership semantics. | [DUB dlib](https://code.dlang.org/packages/dlib) |

### Important differences that invalidate naive API copying

- **ROI cost:** a 64×64 logical ROI may still provoke a larger block read (Rasterio/GDAL), more input halo (filter), or no new image at all (borrowed view). Distinguish **logical output pixels**, **input demand**, **native I/O**, **temporary pixel payload**, **retained owner**, and **process RSS**.
- **Validity:** NoData is a source metadata/sentinel rule; a validity mask controls usable data; alpha controls coverage/compositing; quality/cloud probability encodes acquisition conditions. An API silently merging any two is unsuitable for scientific results.
- **Numeric space:** encoded display RGB, linear-light RGB, stored raw DN, reflectance, radiance and generic dimensionless scalar values are *not* interchangeable. A histogram over display bytes is not the same operation as a reflectance histogram.
- **Destination:** OpenCV/OIIO destination overloads have varying reallocation/aliasing rules. For D, `@safe` alone **does not certify physical noalias**, as the existing M3 compositor experiment demonstrated.
- **Bigger than RAM:** libvips partial-image machinery and OTB region execution show useful mechanisms; *which* of these are needed in `imagery-d` beyond accepted M2 architecture remains a measured consumer decision, not a blanket public DAG contract.

## 3. Capability-to-workspace responsibility matrix

Legend for disposition: **ADAPT** = research an imagery-semantic operation/API; **REUSE** = consume existing workspace domain rather than reimplement; **DEPEND** = optional, separately qualified adapter/dependency; **REFERENCE** = differential/contract benchmark without dependency; **DEFER** = later research only; **REJECT** = explicitly outside imagery-d. **P0/P1/P2/P3** are provisional research priority labels, *not* admitted roadmap milestones.

| ID | Capability / API question | Evidence anchor | Primary workspace owner / surface | Disposition | Priority | Hard contract / next evidence |
|---|---|---|---|---|---|---|
| IM-01 | N-channel image and immutable band IDs | GDAL, STAC, OIIO; A M1 | `imagery.core` above raster | ADAPT | P0 | Explicit identity, role optional, unknown preserved; no inferred RGB |
| IM-02 | Planar/interleaved and strided buffers | libvips, GDAL; A M1 | **`raster-d`** | REUSE | P0 | No new backing/stride/refcount in imagery |
| IM-03 | Borrowed ROI, lifetime and source owner | libvips region; A M1/M2 | `raster-d` borrow, `imagery` semantic binding | REUSE | P0 | DIP1000 borrow, .init, nonowning views; separate logical coverage |
| IM-04 | Stored→physical per-band scale/offset | GDAL; R M3.2 | `imagery.core` radiometry | ADAPT | P0 | Missing calibration, overflow, unit, NaN/invalid output explicitly specified |
| IM-05 | Mask ≠ alpha ≠ NoData ≠ quality | GDAL RFC15, STAC; A M1 | `imagery.core` semantics with `raster-d` storage | ADAPT | P0 | Per-operator invalid policy; no implicit all-zero value on invalid |
| IM-06 | Per-band wavelength/FWHM/role | STAC EO; P | `imagery.core` optional metadata | ADAPT | P0 | Optional units, product-level provenance, no guessed wavelengths |
| IM-07 | Heterogeneous product/multi-grid bands | xarray, OTB; A M1/M2 | `imagery` product/source model | ADAPT | P0 | Do NOT embed unequal grids in one common-grid `ImageView!T` |
| IM-08 | Typed samples and checked conversions | GDAL, OIIO, dlib; A M1 | **`raster-d`** types, imagery value meaning | REUSE | P0 | No implicit byte normalization / float conversion |
| IM-09 | Logical ROI versus block/halo demand | libvips, Rasterio; A M2 | `raster-d` mechanics + imagery operation | ADAPT | P0 | Measurable input demand/cost; no silent whole-frame materialisation |
| IM-10 | Source/resource/revision and identity | GDAL, OTB; A M2 | `imagery.source` semantics, optional backend | ADAPT | P0 | Source != Resource != URL; coherent materialization snapshot |
| IM-11 | Reusable pixelbuffer ownership and adoption | libvips vs OIIO; A M1 | **`raster-d` RasterLease** | REUSE | P0 | No new imagery-side physical backing/refcount implementation |
| IM-12 | Image decoding/encoding PNG/TIFF/etc. | OIIO, GDAL, dlib | **`imageio-d`** or opt-in adapter | DEPEND | P1 | Not mandatory for pure image operators; metadata round-trip proof |
| IM-13 | Georeference metadata CRS/transform | GDAL; A M1/M2 | imagery metadata; **`proj-d`/`geodesy-d`** math | ADAPT | P1 | Optional; distinguish source-world/pixel/ROI spaces |
| IM-14 | Window/COG/XYZ/WMS/WMTS access | GDAL/Rasterio; A M2 | optional source/adapters, external I/O | DEPEND | P2 | No generic HTTP/GDAL driver cloned into imagery core |
| IM-15 | Shared production, cache, cancellation | libvips, eo-learn; A M2 | conceptual imagery source/pipeline | DEFER | P2 | No public scheduler/cache until concrete adoption |
| IM-16 | Arbitrary external lease retention accounting | internal #74; R | imagery delivery boundary, maybe raster handback | DEFER | P2 | Exact last-owner refund **not** established for raw free copies |
| IM-17 | Image region statistics | OIIO pixelstats, GDAL | imagery semantics over raster reduction | ADAPT | P1 | Masked sample count, NaNs, numeric precision, whole/tiled invariance |
| IM-18 | ROI histogram with band/unit choice | `ImageBufAlgo::histogram`, libvips | `imagery.analysis` | ADAPT | P1 | Bin closure/overflow, signed/float ranges, NoData, deterministic counts |
| IM-19 | Quantiles / percentiles / stretch range | scikit-image exposure, libvips | `imagery.analysis` + presentation | ADAPT | P1 | Exact vs approximate quantile, histogram binning, tiled global statistics |
| IM-20 | Explicit RGB/false-colour channel mapping | OIIO channels, STAC EO; R M3.2 | `imagery.presentation` | ADAPT | P1 | Caller-selected ordered components; no automatic 'RGB=0,1,2' |
| IM-21 | Tone/exposure/contrast/stretch | scikit-image exposure, OIIO | `imagery.presentation` | ADAPT | P1 | Display vs physical value, global vs local context, alpha/validity |
| IM-22 | Core colour models/transfer/source-over math | OIIO over, OpenCV; R M3 | **`color-d`** | REUSE | P0 | No second sRGB, alpha or Porter–Duff implementation |
| IM-23 | Two-layer complete owned RGBA compositing | OIIO over, libvips composite; R M3 Direct-4N | `imagery.presentation` research | ADAPT | P1 | B preferred research, public form unadmitted; #75 caller gate open |
| IM-24 | General convolution vs correlation | OpenCV filter2D, scikit-image | `imagery.filter` with `raster-d` halo | ADAPT | P1 | Kernel orientation, border, accumulator, masked weight, type |
| IM-25 | Gaussian/box/median/edge gradients | OpenCV/scikit-image/libvips | `imagery.filter` | ADAPT | P1 | Whole/tile equivalence, separability, halo, truncation, NaN rules |
| IM-26 | Sample interpolation & resize | OpenCV, OIIO, Rasterio | `imagery.transform` or raster boundary review | ADAPT | P1 | Pixel-center vs area, filters, antialias, NoData/alpha weight |
| IM-27 | Affine/perspective image warp | OpenCV | `imagery.transform` plus geometry math | ADAPT | P2 | Backward mapping, coordinate conventions, input demand, no implicit CRS |
| IM-28 | Local threshold/mask generation | scikit-image filters | `imagery.analysis` | ADAPT | P1 | Output quality/validity mask kept distinct from alpha |
| IM-29 | Generic two-band ratio / normalized difference | OTB BandMathX; P | `imagery.analysis.spectral` | ADAPT | P1 | Aligned calibrated grids, masked zero denominator, no band-number hardcoding |
| IM-30 | Optical calibration / reflectance/radiance | OTB OpticalCalibration, GDAL scale | `imagery` radiometry; sensor adapters later | ADAPT | P2 | Domain/units/solar geometry/provenance; not just DN/255 |
| IM-31 | Multigrid registration prior to indices | OTB Superimpose; xarray alignment | imagery source/transform boundary | ADAPT | P2 | Explicit chosen grid, resampling, uncertainty, no silent co-alignment |
| IM-32 | Pyramids/overviews/scale selection | GDAL overviews, libvips; A M2 | imagery materialization, raster layout mechanics | ADAPT | P2 | Explicit target grid/resampling, full/partition result consistency |
| IM-33 | Seam-safe mosaics/harmonization | OTB Mosaic, libvips | `imagery` mosaic family | DEFER | P2 | Seam quality, masking, nonstreamable working-set warnings |
| IM-34 | Morphology + connected regions | OpenCV/scikit-image | `imagery.filter` / `imagery.analysis` | ADAPT | P2 | Connectivity, label type, halo, multi-tile boundary merging |
| IM-35 | Registration/change detection/time series | scikit-image registration, eo-learn | `imagery.analysis` optional future | DEFER | P2 | Acquisition time, revisions, coregistration error, sensor comparability |
| IM-36 | Cloud/shadow/snow/quality inference | eo-learn, STAC, OTB | `imagery.analysis` quality | DEFER | P2 | Quality as separate typed results/probabilities, not synthetic alpha |
| IM-37 | Pansharpening/hyperspectral/PCA | OTB | optional research family | DEFER | P3 | Sensor-specific methods, uncertainty, tests/corpus before API |
| IM-38 | SAR speckle/polarimetry | OTB SAR | optional remote-sensing research | DEFER | P3 | Complex numeric/unit model and scientifically valid oracle |
| IM-39 | General ML/inference/task DAG | eo-learn, CV ecosystem | optional adapters/application | DEFER | P3 | No compulsory model runtime/scheduler in baseline |
| IM-40 | GPU/GUI renderer, map drawing, OSM tags | applications | **Dunia / renderer / osm-d** | REJECT | — | Library remains GUI/OSM-neutral; optional future compute only |
| IM-41 | D-level differential tests for existing dlib.image | DUB dlib | independent reference and benchmarks | REFERENCE | P1 | Inspect actual source/API/versions; no current parity claim |
| IM-42 | Automatic inter-CRS reprojection in pointwise operator | GDAL/OTB vs M1 | **proj/geo adapters** | REJECT | — | Georeference is optional, target grid explicit; no hidden warp |
| IM-43 | Strong thread-safety from existing raster leases | A M2; R #74 | **raster-d** ownership | REJECT | — | Nonatomic reference counter does NOT become atomic by imagery wrapper |

**Interpretation:** Every ADAPT/DEPEND recommendation is **a research direction**, not a promise that the module/type exists. Explicit **REUSE** rows are *not* items to reimplement in imagery-d. Do not count REJECT/DEFER rows as planned shipped features.

## 4. Four mandatory consumer lenses before choosing first public operation

| Lens | Minimal independently checkable input | Expected result | Why it can falsify an API |
|---|---|---|---|
| General RGB photo | Encoded 8-bit RGB/RGBA, mixed planar/interleaved, optional alpha, ROI | Histogram/contrast or explicitly selected colour presentation | Tests whether photographic byte/colour assumptions infect scalar image APIs |
| Scientific single-grid | 16-bit unsigned and 32-bit float multi-band, scale/offset/units, invalid mask, NaNs, ROI | Physical-value histogram and/or filter with controlled invalid propagation | Rejects default "RGB=first 3", implicit clamping and hidden normalization |
| Multispectral EO | At least red/NIR with *different native product grid/resolution*, spectral IDs, calibrations, quality mask | Explicitly chosen aligned grid → masked normalized difference and numerical index | Exposes silent co-registration, invalid denom, non-physical DN division |
| Dunia viewport (**future hypothesis**) | Georeferenced source/overlay, chosen display grid, pan/zoom region, potentially different image lifetimes | Correct retained image or direct renderer composition | Must prove **actual** non-test CPU owned-result requirement; current Dunia app has no such path |

These are **research acceptance fixtures**, not proofs of adopted downstream use. For a first API, favor a truly nontrivial independent test **plus a named actual use** over a synthetic toy consumer manufactured to satisfy Issue #75.

## 5. Common ABI/API contract worksheet (to apply to each shortlisted operation)

For an operation X, determine and test all twelve fields before public admission:

1. **Semantic input:** sample type, band IDs/roles, stored versus physical units, alpha/NoData/validity and unknown metadata.
2. **Grid and regions:** source/destination grid, absolute-vs-relative ROI, pixel-center/area convention, halo, clipping and outside-image border policy.
3. **Numeric law:** exact formula, floating rounding, dtype widening, integer overflow, NaN, ±Inf, under/over-range and tolerant/error comparison.
4. **Output transport:** returned value vs new owned `RasterLease` vs caller destination; preserve existing owner on rejection; empty and `.init` semantics.
5. **Ownership:** scope borrow and DIP1000 negative escapes; non-atomic shared owner caveat; no implicit raw-pointer escape.
6. **Alias:** prove physical non-overlap or identify precisely permitted overlap, not just `@safe` declaration.
7. **Failure:** classified semantic failure versus native allocation/import exception/`Error`; partial mutation and publication boundary.
8. **Allocation:** requested-pixel peak, released/retained payload, native metadata and GC/RSS separately, not a fake exact hard quota.
9. **Work partition:** whole ROI vs tiled/striped output equivalence; source access amplification, halo and global-statistics pass.
10. **Execution:** one-shot vs amortised prepared context; no global scheduler mandate; thread/concurrency claims separately.
11. **Independent verification:** cross-layout/origin/large-data fixture, reference mathematical oracle, negative compile cases and DMD/LDC Debug/Release.
12. **Performance:** pinned comparable D and C++/Python reference, same semantics/precision/errors and I/O boundary; raw paired timings plus codegen and observed memory on native XPS.

## 6. Next controlled step: R-IM-02 (NOT IMPLEMENTED BY THIS REPORT)

Create four independent, **executable** DUB consumer scenarios from ``4`` before selecting one public first package API. Narrow research candidates:

- **Primary cross-domain comparator:** ROI histogram/statistics with explicit *stored-vs-physical*, mask and NaN policies (image, scientific and multispectral scenarios).
- **First scientific image result:** a two-band normalized difference over **already aligned calibrated** rasters, with explicit valid mask/zero-denominator policy. Source-grid alignment remains a separate upstream step.
- **Image-processing locality reference:** small kernel correlation/convolution with explicit border+halo semantics; compare one whole output with partitioned output.

No production module `source/imagery/**`, no root `dub.sdl`, no accepted ADR, no M3 result-form selection and no sibling-repo edits are authorized by this document. RGBA Draft PR #73 remains grandfathered/open/draft. Delivery accounting Issue #74 and RGBA design Issue #75 remain separate.

## 7. Traceable primary references

- OpenImageIO 3.x [ImageBufAlgo](https://openimageio.readthedocs.io/en/stable/imagebufalgo.html)
- libvips 8.x [Evaluation / regions](https://www.libvips.org/API/current/how-it-works.html), [Operations](https://www.libvips.org/API/current/func-list.html)
- OpenCV 4.x [filters](https://docs.opencv.org/4.13.0/d4/d86/group__imgproc__filter.html), [geometry](https://docs.opencv.org/4.13.0/da/d54/group__imgproc__transform.html), [connected components](https://docs.opencv.org/doc/doxygen/html/d3/dc0/group__imgproc__shape.html)
- scikit-image [API](https://scikit-image.org/docs/stable/api/skimage), [filters](https://scikit-image.org/docs/stable/api/skimage.filters.html), [exposure](https://scikit-image.org/docs/stable/api/skimage.exposure.html), [transform](https://scikit-image.org/docs/stable/api/skimage.transform.html)
- GDAL [raster model](https://gdal.org/en/stable/user/raster_data_model.html), [RFC 15](https://gdal.org/en/stable/development/rfc/rfc15_nodatabitmask.html); Rasterio [windowed I/O](https://rasterio.readthedocs.io/en/stable/topics/windowed-rw.html), [masks](https://rasterio.readthedocs.io/en/stable/topics/masks.html)
- STAC [bands](https://github.com/radiantearth/stac-spec/blob/master/commons/common-metadata.md); [EO extension](https://github.com/stac-extensions/eo)
- xarray [terminology](https://docs.xarray.dev/en/stable/user-guide/terminology.html)
- OTB 10 [application catalog](https://www.orfeo-toolbox.org/CookBook/Applications.html), [BandMathX](https://orfeo-toolbox.org/CookBook/Applications/app_BandMathX.html), [optical calibration](https://www.orfeo-toolbox.org/CookBook/recipes/optpreproc.html), [mosaics](https://orfeo-toolbox.org/CookBook/Applications/app_Mosaic.html)
- eo-learn [repository/documented modules](https://github.com/sentinel-hub/eo-learn)
- DUB [dlib.image listing](https://code.dlang.org/packages/dlib)
- imagery-d [accepted M1 ADR 0002](https://github.com/alex-1974/imagery-d/blob/develop/docs/adr/0002-image-semantic-core.md), [accepted M2 ADR 0003](https://github.com/alex-1974/imagery-d/blob/develop/docs/adr/0003-source-cache-pipeline-architecture.md), [M3 independent direct-4N XPS audit](https://github.com/alex-1974/imagery-d/blob/research/m3-rgba-layer-compositing/docs/research/m3-rgba-direct-packed-4n-xps-independent-results-2026-10-17.md), [Dunia candidate-only audit](https://github.com/alex-1974/imagery-d/blob/research/m3-rgba-layer-compositing/docs/research/m3-rgba-dunia-consumer-admission-audit-2026-10-17.md)

**Conclusion:** Prefer semantics-first, ROI-first and independently testable D operators; keep generic raster memory in `raster-d`, colour math in `color-d`, I/O in `imageio-d`/adapters, and application/rendering in Dunia. The first API remains **unselected** pending R-IM-02 consumer evidence and an explicit ADR.
