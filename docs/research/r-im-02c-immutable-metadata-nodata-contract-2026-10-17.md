# R-IM-02c — immutable band metadata and explicit NoData in spectral consumer

**Date:** 2026-10-17  
**Classification:** experimental semantics / independent DUB consumer, **not** production API admission, accepted ADR, real Sentinel-2 calibration, true grid alignment, XPS benchmark or native allocation contract.  
**Parent:** [R-IM-02b Draft PR #79](https://github.com/alex-1974/imagery-d/pull/79); [histogram Draft PR #77](https://github.com/alex-1974/imagery-d/pull/77); [library API matrix #76](https://github.com/alex-1974/imagery-d/pull/76). The grandfathered RGBA [Draft PR #73](https://github.com/alex-1974/imagery-d/pull/73) is unaffected.

## 1. What is reused exactly

The following are **byte-for-byte copies of existing imagery-d M3.2 research modules** from `research/m3-rgba-layer-compositing`, added under their original paths in this independent R-IM topic so the ordinary DUB research consumer can compile against the **original type implementations**:

| Existing source / experiment | Git blob SHA in original branch | Reused property |
|---|---|---|
| `experiments/m3_2_semantic_display/source/m3_2_channel_metadata/contract.d` | `caa88e88e9309205236dc8a0a2ea1934371dc265` | `IntrinsicChannel`: opaque semantic ID, quantity label, explicit stored→physical scale and offset; **not** an EO wavelength or spectrally typed unit. |
| `experiments/m3_2_validated_roi/source/m3_2_metadata_owner/contract.d` | `4982c58d2d70dfea94bac09e8e141c9056ff6d0c` | `ResearchMetadataState.snapshot` (copies to genuinely immutable GC-owned descriptors) and `fromImmutable` (already truly immutable references). |
| `experiments/m1_5_image_view_contract/source/m1_5_image_view/contract.d` | Already present in topic ancestry, **not copied or edited** | Original `ChannelDescriptor`, opaque `semanticId`, common-grid image-semantic experimentation. |

The research-only DUB manifest explicitly imports/compiles these original source modules. **No second `ChannelDescriptor`, `IntrinsicChannel` or raster ownership/refcount hierarchy is created.** This is **source reuse for experimental qualification, not a public dependency/ABI commitment**.

The source does not copy M3.2's whole public import facade or its long-lived metadata-source framework. The new adapter is intentionally narrow.

## 2. Adapter contract and trust boundaries

The experiment adds `imagery.analysis.spectral_metadata_research` next to the existing spectral research kernel:

- `ResearchMetadataImage!T` references a borrowed `RasterView!T`, its **original M3.2 `ResearchMetadataState`**, a selected raster plane, a caller-declared `ResearchGrid`, and an explicit typed raw NoData rule.
- On every call, the adapter checks descriptor count against actual raster plane count, selected plane bounds, one-to-one `ChannelDescriptor.semanticId == IntrinsicChannel.semanticId`, rejects zero/duplicate IDs and an empty/missing or mismatched quantity label.
- The selected `IntrinsicChannel` supplies **the only scale and offset passed to the normalized-difference executor**. The caller cannot bypass it by separately providing arbitrary `scale`, `offset` or an unrelated `bandId` at the adapter boundary.
- Missing calibrations, nonfinite float calibration fields, invalid grid, mask, ROI or output are rejected **before the first output write**. The original `float` scale/offset precision is widened to double; no fabricated higher-precision calibration is assumed.
- A matching nonempty `quantityLabel` is a **metadata-consistency check**, **not** scientific proof of matching physical units, calibrated reflectance or sensor identity. A real source/product adapter must validate meaningful units, spectral roles, wavelengths and provenance. The adapter's `ResearchUnit.otherConsistentUnit` is a *research placeholder*, not a public physics taxonomy.
- The earlier `ResearchGrid` remains a caller declaration: matching frameId, origin, signed pixel steps and pixel dimensions is necessary but **not** proof of actual co-registration or equal native sensor resolutions.
- The operation remains restricted to **already aligned common-grid** borrowed input views. There is no built-in resampling, CRS conversion, imageio integration or I/O.

The adapter still delegates to the **same** R-IM-02b normalized-difference kernel; it does not duplicate spectral arithmetic, raster memory ownership, cache or scheduling.

## 3. Separate NoData, mask and nonfinite semantics

The R-IM-02b **research-only** `ResearchSpectralBand!T` now carries a *default-inert* optional `ResearchNoData!T` with a raw stored-sample sentinel. Existing consumers with no NoData policy should behave unchanged (verify both baseline and added consumer in CI).

| State of one input | Operation | Expected output |
|---|---|---|
| Optional mask equals 0 | Do not use invalid source; separate mask policy wins | numeric=0, output validity=0 |
| Mask valid, raw equals configured finite NoData sentinel | Treat raw sample as invalid **before physical calibration** | numeric=0, output validity=0 |
| NoData disabled, raw=0 and other input nonzero | Calibrate and perform ordinary numeric division | valid if denominator nonzero |
| Both calibrated values sum to exactly zero | Invalid mathematical operation, no invented epsilon | numeric=0, output validity=0 |
| Two equal nonzero calibrated values | Index exactly 0 with **validity=255** | numeric=0, output validity=255 |
| Unmasked NaN / infinity or nonfinite calibrated/ratio value | Invalid as mathematical value, not silently treated as NoData/alpha | numeric=0, output validity=0 |
| Configured float NaN as an *equality* NoData sentinel | Reject policy as `invalidNoData` rather than pretend NaN compares equal | no output writes |

NoData is **not** an alpha channel and not a sensor acquisition quality bitmask. Explicit cloud/shadow/snow/quality-state policies remain deferred. The output's numeric zero is *only* meaningful together with its separate validity byte.

Unlike the earlier histogram research, this adapter produces two caller-owned output rasters. It does **not** enforce physical disjointness or transactional rollback on a late sample/write failure; research fixtures supply independently owned destination buffers. Do not expose this exact `Into` transport as a public safe contract without resolving noalias/partial writes (M3 design Issue #75 is the analogous independent case).

## 4. Executable correctness oracle

The new `metadata_consumer.d` is compiled as part of the **separately built** `experiments/r_im_02b_spectral/smoke/` DUB executable, retaining the existing full R-IM-02b consumer test unchanged except for its entry point invoking the new consumer.

Synthetic workload:

- Two real raster-d owned 8×6 images, three channels each, in opposing planar/interleaved layouts. Band selection is **plane 1**, but **semantic IDs differ** between operands: 77 (first/NIR scenario) and 42 (second/red scenario).
- Both source metadata snapshots contain explicit opaque quantity label `same-opaque-unit`, calibration `0.01f` / `0.0f`. A **new snapshot generation** for the red-side image deliberately changes only its selected scale to `0.02f`.
- The mutable arrays used for both snapshots are subsequently mutated again, including a forged ID, false calibration and a new label; previously-created immutable snapshots remain unmodified. The independent numerical oracle expects the **original** or **refreshed** generation exactly.
- Both masks can be enabled or omitted. Separate valid-region patterns ensure invalidity cannot silently be conflated with either selected spectral band.
- The first/NIR input's explicit *raw* sentinel is **427**, reached at fixture position (5,3). It must be invalid even if both masks permit the pixel.
- Additional independent probes: valid equal-band numeric zero at (1,1); mathematically invalid 0/0 at (5,2); float NaN at (2,3); infinity at (6,4); signed physical values at (7,5).
- Cross-product: **2 sample types × 2 layouts × 2 mask states × 2 immutable metadata generations = 16 cases**. Each case checks one complete 8×6 ROI plus four 4×3 quadrants independently, for **80 complete numeric+validity output pairs** and **16 × 96 = 1,536 expected whole/partition pixel positions**.
- Independent oracle uses the **synthetic input formula and documented float-calibration values**, not the actual sample input or executor implementation. For each pixel: check output mask, numerical agreement and **bit-exact whole/partition identity for the same source pixel**.
- At least four bad immutable metadata configurations per case must be rejected before any of the 48 prior numeric/mask output sentinels are overwritten: **mismatched channel ID, incompatible opaque quantity labels, absent calibration and nonfinite calibration**. Float cases additionally reject NaN NoData sentinels.

### Tests still missing

Independent negative cases for *duplicate* matching IDs, metadata count mismatch and malformed `.init` use are important prior to claiming full adapter semantics. Native random corpus, real scientific products, explicit NoData-range policies, physical unit conversions, quality-mask meanings, unaligned-source materialization, destination alias, later write-failure injections, DMD/LDC compile-negative borrow escape and any XPS performance are **not** qualified by this limited experiment.

## 5. CI and decision status

Dedicated research-only workflow `.github/workflows/r-im-02c-metadata-spectral-consumer.yml` targets DMD **2.111 / 2.113**, LDC **1.41 / 1.43**, independent DUB consumer **Debug and Release**. It requires both the inherited R-IM-02b PASS receipt and the new metadata/NoData PASS receipt, and asserts no production `dub.sdl` or `source/imagery` root.

**Only actual exact-HEAD GitHub Actions success can qualify these statements.** Successful authoring is not a compiler or numeric correctness PASS. The completed runs and source SHAs are to be appended after verification.

### Disposition

- Accept as a **research integration experiment**, *only if* exact-HEAD compiler and independent-oracle CI pass.
- Do **not** infer complete satellite scientific validity from an opaque matching quantity label.
- Retain original M1/M3.2 reference modules and R-IM-02b tested functionality; do not silently rewrite their historical evidence.
- No public API names, released DUB root, merge to `develop`/`research-integration` or migration of grandfathered PR #73.
