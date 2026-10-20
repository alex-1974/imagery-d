# Scope clarification — imagery-d is a general image-processing library

**Date:** 2026-10-17  
**Source of clarification:** explicit project-owner direction in the ongoing imagery-d research conversation.  
**Status:** DESIGN CLARIFICATION FOR REVIEW, not a new Accepted ADR or public API.  
**Precedence:** apply alongside accepted [M1 ADR 0002](../adr/0002-image-semantic-core.md) and [M2 ADR 0003](../adr/0003-source-cache-pipeline-architecture.md); no silent rewriting of their research history.

## Core purpose

`imagery-d` is an **application-independent image processing library for D**. Its users can include photo-editing applications (GIMP/Photoshop-like workflows), graphics tools, scientific instruments, remote-sensing applications and Dunia.

The library's central job is **operating on image data**: image/pixel/channel transformations, analysis, convolution, blending/compositing, masks, tone/contrast operations, resizing and other image-domain algorithms.

**It does not authenticate, interpret or certify the external origin of those samples.** Image/satellite acquisition metadata and application decisions are inputs prepared by the consumer or an explicitly optional, external adapter. A filter must work on a valid general image without a satellite identity, map projection, band wavelength, STAC asset, satellite processing baseline, geographic registration certificate or remote-sensing quality taxonomy.

A satellite image is an *example of image data* for imagery-d, not the library's governing data model.

## Deliberate responsibility boundary

| Responsibility | Party | Example |
|---|---|---|
| Source truth, provider/product provenance, satellite processing baseline, sensor band identification, CRS/world positioning, scene classification interpretation | **Consumer / specialized source adapter** | Dunia or an EO application decides that a particular input plane represents red or NIR and that its calibration/projection is correct. |
| Which physical values a source sample represents; whether two source datasets are scientifically comparable; whether/how grids should be aligned for the task | **Consumer / source stage** | A science consumer converts raw DN into calibrated reflectance, chooses a common pixel grid, and supplies the resulting images/values and masks. |
| Defined mathematical/image operation over provided data and declared operation parameters | **imagery-d** | Normalize difference of two value channels; blur; levels/curves; scale; histogram; composite RGBA layers; morphological mask operations. |
| Correct numerical result, documented ranges/rounding/borders/overflow, mask/alpha policy, ROI behavior, error handling and ownership/alias guarantees | **imagery-d** (with `raster-d` and `color-d` boundaries) | A provided 5×5 image kernel cannot silently corrupt a destination, assume contiguous storage, or change semantics across tile boundaries. |
| Generic pixel/raster storage, layout/strides, leases, spatial ROI/halo mechanics, generic reductions | **raster-d** | No duplicate image-owned raw buffer/refcount hierarchy. |
| General colour/transfer function/compositing mathematics | **color-d** | `imagery-d` applies explicit colour operations across images while `color-d` owns colour transforms. |
| Decoding/encoding file formats | **imageio-d** or optional adapters | TIFF/PNG/JPEG/EXR is not a requirement of a bare pixel operation. |
| UI, display/edit tools, drawing, OSM tags and application decisions | **Consumer** | Dunia / photo editor chooses UX and layer editing operations. |

**Crucial distinction:** The consumer is responsible for whether its source image and interpretation are *factually/scientifically appropriate*. `imagery-d` is still responsible for whether its output is *computationally correct* for the inputs and contract supplied. No shifting library correctness or bounds safety onto the user.

## Operation contracts: what is mandatory, what is optional

Mandatory only where the **chosen algorithm** needs it:

- Supported sample type(s), number and selection of input/output channels, shape/ROI/layout requirements.
- Required colour encoding and alpha association for colour/compositing operations. Pure scalar arithmetic does not require an sRGB or display profile.
- Explicit border/interpolation/rounding/mask rules, as appropriate; documented handling for NaN and zero division.
- Checked dimensions, legal ROI, destination shape, resource lifetime, error/publication and physical aliasing/ownership semantics.
- For pointwise two-input algorithms: common **logical pixel grid** and compatible dimensions; **no** mandatory proof of map projection or geospatial registration. The caller decides whether the two images represent comparable facts.

Optional, depending on the consumer or an adapter:

- Channel human labels and spectral identities, wavelengths, response curves, sensor or platform names.
- Radiance/reflectance meaning, calibration provenance, physical units, georeferencing/CRS, acquisition time, STAC/SAFE product identity, processing baseline.
- Advanced quality flags and source-specific NoData policies. Generic validity masks and caller-selected raw sentinel policies **can be computational input rules** without carrying scene knowledge.
- Lazy cache/source/remote access machinery; a valid in-memory image or user-provided raster must be enough.

The accepted M1 image-semantic common-grid view and immutable metadata boundary remain available research architecture. They are **not** a license to impose STAC/satellite provenance on ordinary blur, histogram or layer compositing. M2's source architecture is *one potential way* to obtain data, not a mandatory dependency of each image kernel.

## Consequence for current research and old experiments

- **R-IM-01 / #76**: keep broad reference-library matrix; rebalance priorities toward GIMP/Photoshop-like general operations (layers/opacity/blend, tone/levels/curves, selection masks, transforms, convolution, histogram, morphology) and generic use without source metadata.
- **R-IM-02a / #77**: useful computational evidence for histogram/ROI, but future image API must avoid obligatory physical/sensor semantics.
- **R-IM-02b / #79**: normalized difference is a **generic** two-input numerical image operation; band roles are caller-selected; no mandatory NIR/red or sensor provenance.
- **R-IM-02c / #80**: immutable metadata and explicit NoData may be useful **optional adapters**, but no future generic ND/histogram API may require a `ResearchMetadataState` to execute.
- **R-IM-02d / #82, Issue #83**: product-asset/STAC/processing-baseline evidence gate was a valid **specialized research question**, but **REJECT as a generic imagery-d core admission gate**. Its DMD/LDC and synthetic result history must be preserved with the label *research-only, application/source-adapter concern*. It must **not** drive the first public API, not become a mandatory dependency, and should not be used as the basis of a new satellite-data ingestion phase (formerly proposed R-IM-02e).
- **M3 RGBA / #73**: research remains valuable as a generally useful compositing operation for photo editors, graphics applications, and potentially Dunia. Keep its independent consumer and ownership admission gates open.

Do not merge obsolete adapter assumptions into a public API merely because their CI is green. Do not delete or rewrite historical experimental results; **a rejected core architecture is still a useful research finding**.

## Revised near-term research shortlist

1. **General image processing:** choose practical GIMP/Photoshop-like consumers for levels/contrast, layer compositing/opacity/blending, ROI filters and transforms; identify direct image-domain semantics beyond `raster-d` and `color-d`.
2. **Generic two-image/value operation:** ND or arithmetic over already comparable supplied image data; prove mask and zero-division rules without asset metadata.
3. **Ownership/performance:** input source vs destination alias, output publication, vectorization, large image/ROI streaming and optimized LDC comparisons against comparable image-library algorithms.
4. **Only if separately requested/justified:** optional geospatial/EO adapter research that maps external metadata into ordinary image buffers and processing parameters. It must remain a distinct dependency boundary.

No source code or public API change is authorized by this clarification. Proposed adjustments to existing Accepted ADR text, if eventually needed, require **an explicit numbered follow-up ADR or amendment**, not an unmarked rewrite.

**Core test:** Can a consumer with plain valid RGB/RGBA, grayscale, multichannel or float image buffers call the processing function without supplying any satellite/geospatial metadata? For a general operation, the answer must be **yes**.
