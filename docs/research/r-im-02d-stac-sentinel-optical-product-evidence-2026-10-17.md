# R-IM-02d — Scientific band/product semantics: STAC and Sentinel-2 evidence

**Research date:** 2026-10-17  
**Classification:** source-backed standards audit + executable **synthetic** optical adapter. **Not** public API, production-accepted source metadata schema, complete Sentinel-2 import, native XPS benchmark, georegistration, library dependency, or satellite product certification.  
**Stack:** R-IM-01 [#76](https://github.com/alex-1974/imagery-d/pull/76) → R-IM-02a [#77](https://github.com/alex-1974/imagery-d/pull/77) → R-IM-02b [#79](https://github.com/alex-1974/imagery-d/pull/79) → R-IM-02c [#80](https://github.com/alex-1974/imagery-d/pull/80) → current topic. **Grandfathered RGBA PR #73 and its entire independent stacked history remain untouched.**

## 1. Primary reference observations, not assumptions

| External primary standard/source | Actually documents | Boundary for imagery-d |
|---|---|---|
| [STAC common metadata](https://github.com/radiantearth/stac-spec/blob/master/commons/common-metadata.md#bands) | `bands` (formerly `eo:bands` / `raster:bands`) with provider band `name`, plus common `nodata`, `unit`, `data_type`; general Band Objects may be spectral, classification, quality or other data. | A band *name* is an external provider key; never equate plane index, internally assigned channel ID, radiometric measurement and spectral role. Quality/categorical bands are not reflectance bands. |
| [STAC Electro-Optical extension](https://github.com/stac-extensions/eo) | Optional `eo:common_name`, `eo:center_wavelength` and `eo:full_width_half_max` in **micrometres**; values describe approximate spectral response, not the full sensor response curve. | Spectral role/wavelength/BW are **optional product evidence**; no compulsory guessed value from arbitrary channel position or label. Full band-response curves remain optional linked provenance. |
| [STAC Raster extension v2](https://github.com/stac-extensions/raster) | Band-associated `raster:scale`, `raster:offset`, `raster:spatial_resolution`, optional `raster:sampling`; calibration is `physical = stored * scale + offset`. The current version must be checked before writing a STAC parser because prefix/layout changed from older schemas. | Preserve independent *stored* and *physical* values, units, validity and signed offsets. A logical ROI does not prove source native resolution or CRS. |
| [ESA Sentinel-2 MSI overview](https://step.esa.int/main/wp-content/help/versions/10.0.0/snap-toolboxes/eu.esa.opt.opttbx.s2msi.reader/Sentinel2Overview.html) | 13 bands on **10 m (4), 20 m (6), and 60 m (3)** native grids. Red B04 and broad NIR B08 are **10 m**, narrow NIR B8A is **20 m**. | Different band native grids cannot be silently put into one common-grid `ImageView`. A user-selected resolution/registration step is needed before incompatible-band pointwise analysis. |
| [Copernicus/Sen2Cor processing-baseline explanation](https://forum.step.esa.int/t/get-sentinel-2-reflectance-values-from-dn-for-mosaicking/44397/6) | L2A Level-2A processing baselines ≥04.00 introduced additive BOA offsets; the documented PB04 and listed PB05 examples use `(DN - 1000)/10000` for surface reflectance, and **DN=0 stays NoData**. Products can be reprocessed, so acquisition date alone is **not** the processing baseline. | Offsets are **product-specific read metadata**, not a hardcoded rule for all Sentinel, dates, baselines or other sensors. Apply stored NoData classification **before** offset. Negative calibrated reflectances can be valid; no default clamp to [0,1]. |

### Specific scientific semantic separations

1. **Asset/provider band key:** e.g. asset `RED` with Band `B04`, or `NIR`/`B08`. It is not an index into a common array by itself.
2. **Opaque internal identity:** existing M1 `ChannelDescriptor.semanticId` and M3 `IntrinsicChannel.semanticId`. Can be checked for consistent per-plane binding but does not prove spectral meaning.
3. **Spectral role/response:** `eo:common_name`, wavelength, bandwidth, optional response-curve provenance. A role label asserts a classification; its truth depends on the source reader.
4. **Physical quantity:** reflectance versus radiance versus classification/quality or unresolved. Reflectance is dimensionless but **TOA and surface reflectance have different physical interpretation**. A general normalized difference may use either when explicitly selected; a vegetation interpretation must record which was used.
5. **Calibration:** `scale/offset` and *processing baseline* are external source/product claims, distinct from exposure/sRGB colour math. Validation at one precision does not retroactively upgrade originally stored `float` M3.2 metadata to binary64.
6. **Validity:** exact **raw NoData** sentinel ≠ scene quality/cloud label ≠ mask byte ≠ alpha ≠ NaN ≠ arithmetic zero denominator.
7. **Native grid:** source shape and physical pixel spacing/resampling history are not identical to a *materialised*, caller-declared `ResearchGrid` value.
8. **Provenance:** product/scene identifier, asset identity, processing baseline and semantic source revision matter. They must be verified by the reader or a trusted adapter, **not simply accepted because the caller filled fields**.

## 2. Minimal research-only product-evidence adapter

New module (within existing research DUB package, **no new foundation library**):

`experiments/r_im_02b_spectral/source/imagery/analysis/optical_product_research.d`.

`ResearchOpticalAsset` is an **additional product/asset claim record** (scene/asset/band/processing baseline, role, physical quantity, optional wavelength/FWHM, native GSD, expected scale/offset, raw NoData). It is *not* a replacement for `ResearchMetadataState`, `IntrinsicChannel` or `ChannelDescriptor`; the original M3.2 **immutable snapshot remains the sole source of stored physical calibration during execution**.

`tryOpticalNdIntoResearch` is intentionally **ushort-only** and invokes the existing R-IM-02c snapshot-bound generic ND executor after a preflight check. It validates:

- nonempty and matching caller-declared product ID and processing baseline, plus provider asset/band keys;
- distinct opaque selected IDs that match those in the existing M3.2 immutable snapshot;
- explicit `red` versus `nearInfrared` roles, not quality/categorical bands or unspecified;
- **same** explicitly declared reflectance kind (surface or TOA) rather than guessing compatibility from an opaque label;
- positive finite optional wavelength and FWHM in micrometres, and explicit matching positive finite native GSD in metres;
- advertised asset scale/offset match **the existing M3.2 float values after down-conversion**, not independent hidden calibration;
- consistency of any previously configured raw NoData with declared asset NoData;
- under the inherited R-IM-02c path, chosen ROI, image plane cardinality, exact common grid, source masks and destination sizes.

The adapter **does not** infer spectral role merely from `B04`/`B08` or wavelength. These are checked, caller-declared assertions with no sensor authority. Matching native GSD is a necessary warning gate in this narrow case, not proof of same CRS/pixel origin/coregistration.

**Unresolved design:** A current `ResearchOpticalAsset` is caller-writable; it can be forged. For a *future* production binding, source reader/product metadata validation must produce a trusted immutable representation with explicit revision/lineage, and final `raster-d` ownership and method return lifetime must be proven. No public source API is proposed here.

## 3. Synthetic Sentinel-2-shaped independent consumer

Source: `experiments/r_im_02b_spectral/smoke/source/optical_product_consumer.d`. It is a separate DUB executable module (in the already established independent research consumer package).

- Two independently allocated and imported `raster-d` ushort 2-plane, **6×4** fixtures. Selected **plane 1**, IDs **77 (synthetic NIR/B08)** and **42 (synthetic red/B04)**; provider keys and optional approximate wavelengths for reference only. Opposite planar and interleaved layouts.
- Original immutable M3.2 metadata snapshot supplies selected `0.0001f` scale and per-profile `0.0f` or `-0.1f` offset. Caller arrays are mutated after snapshot creation; immutable calibration and IDs must remain unchanged.
- Cases: synthetic older `03.01` baseline with zero offset and synthetic `04.00` profile using `(DN−1000)/10000`. The historical conversion example is sourced from Copernicus/Sen2Cor; **no real source file was read**.
- **Raw DN=0** deliberately appears in either band and is invalid independently of calibrated negative value; a separate optional spatial mask is tested; one pixel uses equal nonzero bands yielding **valid ND=0**; one pixel uses a red DN sufficiently low for **negative calibrated surface reflectance**, which must **not** be clamped and may produce index magnitude >1.
- **8 configurations** = 2 layouts × 2 mask states × 2 processing-offset profiles. Each produces 1 full ROI + 4 nonoverlapping quadrant ROIs = **40 complete numeric+validity result pairs**. Each pixel from each result is checked against *independent fixture formula*: 8×(24+4×6)=**384 numeric+validity pixel positions**. Whole versus partitioned output must be **exactly equal**.
- Negative preflight checks, with **all destination numeric and validity sentinels preserved**: mismatched product scene, processing baseline, selected ID, quality-band role, reflectance/radiance confusion, unequal native GSD, missing native GSD, invalid spectral wavelength, asset vs M3.2 calibration disagreement, conflicting raw NoData. The inherited ND tests continue to cover true unaligned `ResearchGrid`, invalid ROI and other cases.
- Tested E/O quality separation: a validity mask is supported, **but no actual Sentinel-2 Scene Classification Layer (SCL) is decoded**, and no shadow/cloud/snow threshold is inferred or hardcoded.

### What is NOT proven

- Neither source came from a Sentinel-2 SAFE file, STAC catalog or measured calibrated product;
- scene IDs, processing baseline, band roles and units are **caller-declared** and may be forged;
- matching declared grid/native GSD is *not* independently proven georeferencing;
- the M3.2 `float` representation is not enough to promise exact binary64 STAC radiometry;
- calling a destination-writing ND path does not prove no physical source alias or late-failure atomic publication;
- no real 10/20/60m resampling, cloud mask semantics, temporal comparison, source backend, map view, benchmark or deployed Dunia application is validated.

The test qualifies **source-boundary semantics** and can falsify an unsafe silent assumption. It cannot on its own qualify real satellite scientific use.

## 4. CI evidence and next decision

Workflow `.github/workflows/r-im-02d-optical-product-consumer.yml`: DMD 2.111.0 / 2.113.0, LDC 1.41.0 / 1.43.0, **Debug and Release**, separate DUB consumer, pinned read-only `raster-d v0.2.0` at `2f2415851e45001df92ce56dad409f680684ba8d`. It demands prior R-IM-02b and R-IM-02c receipts as well as the new R-IM-02d receipt. **No compiler PASS claim until exact-HEAD CI completes.**

Next qualified research choices:

1. A version-aware STAC/provenance ingestion adapter and a real (perhaps open-license) EO fixture with independent metadata/schema verification – **not** a generic STAC parser embedded in the imagery kernel.
2. Defined choice of **binary64/typed scientific calibration** instead of M3.2 float snapshots where externally supplied scale/offset fidelity requires it; numerical oracle and meaningful units before public API.
3. Distinct scene quality and cloud/land classifications, including the semantics of unknown/unobserved states; do not map them to alpha or infer validity.
4. Native-grid source materialization and resampling with explicit target grid, pixel geometry, quality-aware interpolation and snapshot/ownership states.
5. A genuine non-test downstream consumer and performance evidence on XPS before any public API or Accepted ADR.

**Decision:** preserve as separate experimental research evidence. No public API/root DUB/source code; no merge, rebase or retarget of Draft PR #73 or parent research. No writes to other workspace repositories.
