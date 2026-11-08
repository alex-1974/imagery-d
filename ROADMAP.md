# imagery-d Roadmap

## Current state

`imagery-d` is transitioning from architecture research toward its first
evidence-backed production capability.

M1 — Image Semantic Core is complete and accepted by
`docs/adr/0002-image-semantic-core.md`.

M2 — Source / Cache / Pipeline Architecture is complete and accepted by
`docs/adr/0003-source-cache-pipeline-architecture.md`.

The M2 contract experiment passed under DMD 2.111.0 and LDC 1.41.0 against
the established `raster-d` ownership and ROI boundary.

M3 — First Production Vertical Slice is complete. It admitted scalar Levels
under ADR 0006 and RGB8 histogram, derived tone LUTs and luminance stretch
under ADRs 0007–0011. The complete source set is published as v0.2.0 using
raster-d v0.5.5 and color-d v0.3.0. This pre-1.0 completion does not freeze
the API or ABI.
imagery-d's own DUB registration is planned for v1.0.0 unless a concrete
consumer need makes earlier registration necessary.
The v0.2.0 release plan and completed publication record are in
`docs/release/PLAN-0.2.0.md` and `docs/release/RECORD-0.2.0.md`.

The generic raster foundation is supplied by `raster-d`.

**Scope boundary (2026-10-17):** The intended product is a general image
processing library for D, including GIMP/Photoshop-like photographic and
multichannel workflows, scientific images and GIS/remote-sensing images.
General operators take supplied image data and processing parameters. Input
provenance, STAC/sensor/product formalities, geographic/spectral interpretation
and scientific dataset correctness are a **consumer or optional adapter**
responsibility, not requirements for general `imagery-d` APIs. Computational
correctness, documented pixel/colour/alpha/mask and ROI semantics, safety,
ownership and numerical error policy remain the library's responsibility.
See [scope clarification](docs/research/general-image-processing-scope-correction-2026-10-17.md).

## M0 — Repository and knowledge handover — COMPLETE

Goals:

- establish the independent repository;
- capture the pre-pivot imagery research;
- record the `imagery-d -> raster-d` boundary;
- preserve references to historical evidence in `raster-d`;
- establish benchmark/corpus policy.

Exit gate:

- repository structure committed;
- architecture and research documents reviewed;
- no generic raster responsibility duplicated.

Status: **complete**.

## M1 — Image Semantic Core — COMPLETE

Research and decide:

- image versus generic raster abstraction;
- pixel/channel semantics;
- pixel-format policy;
- alpha/mask/NoData semantics;
- colour metadata boundary;
- common-grid typed processing-view contract;
- heterogeneous product boundary.

Status: **complete**.

The semantic architecture is accepted by
`docs/adr/0002-image-semantic-core.md`.

The M1 contract experiment validated the provisional common-grid ImageView
lifetime and ROI composition under both DMD and LDC.

M1 did not itself admit a production package/API.

## M2 — Source / Cache / Pipeline Architecture — COMPLETE

Research and decide:

- Source, Resource, Locator and revision identity;
- product/source/access responsibility boundaries;
- native region materialization above `raster-d`;
- encoded, decoded and transformed cache boundaries;
- cache identity and retained-raster lifetime;
- shared in-flight production;
- subscriber cancellation;
- priority, generation and prefetch semantics;
- progressive immutable result stages;
- explicit Product-to-typed-ImageView materialization;
- semantic plan versus execution plan.

Status: **complete**.

The architecture is accepted by
`docs/adr/0003-source-cache-pipeline-architecture.md`.

The focused M2 contract experiment mechanically validated:

- semantic production-key boundaries;
- equal-key single-flight;
- subscriber cancellation/publication semantics;
- cache eviction independent from delivered `RasterLease` lifetime;
- covering logical coverage to exact resident ROI;
- semantic equivalence across different execution strategies.

M2 did not admit a speculative general source/cache/pipeline production API.

## M3 — First Production Vertical Slice — COMPLETE

M3 selects and proves the smallest concrete image-domain capability that
justifies the first production package surface.

The milestone begins with capability selection rather than framework
implementation.

A candidate must have a concrete consumer and be independently useful.

Possible classes of vertical slice include:

- one narrowly defined image-operation family over already-materialized
  common-grid images;
- one narrowly defined Source-to-native-grid-image materialization path;
- another image-domain capability that exercises the accepted M1/M2
  boundaries without requiring a speculative universal framework.

If an image-operation family is selected, candidates may include:

- colour/display transform;
- radiometric or exposure transform;
- normalization;
- finite-neighbourhood filtering;
- image-quality analysis.

If a source/materialization slice is selected, it must remain deliberately
narrow and must not expand into a general backend/cache framework before the
consumer evidence requires that surface.

### M3 selection gate

Before implementation, record:

1. concrete consumer requirement;
2. exact capability and non-goals;
3. input/source class;
4. semantic output contract;
5. relationship to `raster-d`;
6. source/resource/revision behavior where applicable;
7. region/residency behavior;
8. correctness oracle;
9. failure/cancellation behavior where applicable;
10. memory budget and residency accounting;
11. benchmark scene/workload;
12. DMD correctness matrix;
13. LDC optimized benchmark/codegen plan.

### M3 implementation rule

Only abstractions required by the selected vertical slice may be promoted into
production code.

Research type names from M1/M2 experiments do not become public API merely
because they already exist.

A general scheduler, public DAG or universal source/cache framework remains
out of scope unless concrete evidence independently requires one.

### M3 exit gate

M3 completes only when:

- one vertical capability has been explicitly selected;
- its semantic and memory contracts are documented;
- its correctness oracle exists;
- the required minimal production API has been identified;
- DMD correctness evidence passes;
- LDC optimized-performance evidence passes;
- benchmarks demonstrate the intended bounded-region behavior;
- an ADR explicitly accepts or rejects admission of that production surface.

**M3 result (completed 2026-10-30):** ADR 0005 accepts the
primary general-image scope; ADR 0004 selected scalar Levels for
qualification; ADR 0006 admits the minimally scoped owned-result API.
ADRs 0007–0011 add RGB8 analysis, derived maps and luminance stretch.
Independent DMD/LDC consumers, source archives, Decimal and byte oracles,
ROI ownership, bounded memory and LDC Release performance passed. v0.1.0
published Levels and v0.2.0 published the complete admitted RGB source set.

## M4 — Reproducible imagery corpus — COMPLETE

**Completion (2026-10-30):** The corpus retains its seven deterministic
synthetic fixtures and now pins three distinct NASA JPEG visualizations by
source record, download URL, dimensions, byte length and SHA-256. Optional
retrieval stores bytes under ignored `data/m4/`. Offline Pillow-to-P6 checks
verify exact RGB histograms over full, partitioned, non-origin and masked ROIs
and verify serial, four-worker and masked luminance stretch against the
independent scalar sRGB/XYZ-D65-Y oracle. The decoder and source bytes remain
outside imagery-d and its source package.

**M4 seed 1 (2026-10-20):** Manifest-driven offline synthetic RGB/ROI,
adjacent-tile seam, weighted-selection mask, u16 and f32 sample fixtures.
Generator/provenance/dimensions/byte order/SHA-256 are explicit;
verification uses Python's standard library only. The binary payloads
are generated on demand and remain untracked. This is corpus tooling,
not a new public image-processing API.
See [M4 seed contract](docs/research/m4-corpus-seed-2026-10-20.md)
and [Issue #103](https://github.com/alex-1974/imagery-d/issues/103).

**M4 operator consumers:** Levels is checked through the P6 application
(#105). The follow-up histogram check (#109) uses the same SHA-pinned
RGB/ROI/tile fixtures, independent exact counts and binary mask semantics
for the admitted ADR 0007 API. The separately downloaded real-source
collection complements these synthetic boundary cases; neither class claims
decoder or scientific-source correctness.

**Histogram analysis follow-up:** Inclusive cumulative counts and integer
nearest-rank RGB8 percentiles derive from the accepted histogram record.
They retain its stored-byte and binary-selection semantics and do not add
another raster reduction or image-output operator.

**Contrast-map follow-up:** A per-channel percentile stretch LUT derives
from that record. The P6 consumer applies it to a new image and checks
exact bytes on the synthetic corpus. Masked histogram selection only
estimates thresholds; the consumer explicitly chooses where to apply the
mapping. This does not infer a colour space or add an owned image output API.

**Equalization follow-up:** A second fixed RGB8 LUT derives independent
per-channel maps from exact cumulative counts. The existing P6 consumer
checks output bytes against rational CDF arithmetic on the SHA-pinned M4
fixtures. Flat channels retain identity; a mask again estimates the map
but does not specify which pixels receive it.


M4's durable tooling covers:

- scene definitions;
- source definitions;
- retrieval parameters;
- provenance;
- hashes;
- local non-versioned data;
- boundary/mosaic/seam cases.

M3 may use minimal reproducible fixtures before M4.

M4 generalizes those needs into durable corpus infrastructure. New sources
and operator checks may be added incrementally without reopening the milestone.

**Post-M4 pointwise fusion qualification (2026-10-30):** Issue #114 compares
a prepared RGB8 percentile LUT followed by a full-size copy with direct LUT
application into the final ROI output. Exact output passed for interleaved and
planar layouts, positive and negative row strides and a non-origin ROI. The
direct consumer path removes one full-size RGB temporary and measured 1.59×
to 1.70× faster on the documented local LDC Release workloads. Existing public
histogram/LUT composition is sufficient; no graph, scheduler or new public
fusion API is admitted.

## M5 — Mosaics and multiresolution imagery — IN PROGRESS

Only after the earlier milestones provide stable primitives.

**First vertical slice (2026-10-30):** ADR 0012 admits explicit selection
among caller-described overview grids over one common logical extent. The
coarsest grid that meets both target dimensions is selected; unavoidable
undersampling is reported rather than disguised as final/native detail.
Malformed, empty or unordered level lists fail before publication. This pure
policy does not read pixels or add resampling, mosaics, sources, caches,
progressive delivery, a scheduler or a DAG. See
[Issue #132](https://github.com/alex-1974/imagery-d/issues/132).

**Decoded regular-tile qualification (2026-10-30):** A current-baseline
experiment reconstructs only the narrow, already-decoded RGBA8 regular-grid
mapping proven by historical draft PR #69. Across 144 complete outputs and
70,272 independent component checks, global pixel-origin nearest sampling is
exact across horizontal/vertical seams, layouts and signed strides. An owned
result with an exact payload budget provides complete returned-failure
rollback. Public API admission remains deferred: there is no concrete
non-test consumer for this exact CPU-owned RGBA result and nearest-only policy
does not define general resampling or mosaic semantics. See
[qualification report](docs/research/m5-decoded-tile-mosaic-2026-10-30.md)
and [Issue #134](https://github.com/alex-1974/imagery-d/issues/134).

**Explicit overlap/seam qualification (2026-10-30):** Two aligned RGB8 sRGB
sources blend from a caller-supplied u8 weight field in linear light. The
0..255 black/white ramp proves the encoded midpoint is 188 rather than the
incorrect encoded-byte interpolation near 128. Across eight signed/planar
layout combinations, 43,008 independent oracle comparisons and 43,008 exact
whole-versus-partition comparisons pass. Source registration, quality ranking,
validity and weight construction remain outside the kernel; no automatic
quality inference is admitted. The two-source RGB8 API remains research-only
until a real consumer resolves alpha/validity and result-form needs. See the
[seam report](docs/research/m5-overlap-seam-blend-2026-10-30.md) and
[Issue #136](https://github.com/alex-1974/imagery-d/issues/136).

Research:

- pyramid/overview semantics (selection slice admitted; generation and grid
  transform validation remain open);
- source-resolution selection;
- mosaics;
- blending;
- seam treatment;
- source-quality policy.

## M3 follow-up — Editing semantics

Photoshop/GIMP-aligned editing requires a shared mask, alpha and NoData
contract before additional adjustments or compositing are admitted. ADR 0008
records the M3 qualification boundary: selection coverage is explicit and
graded, validity is separate, alpha association is declared, and owned results
publish transactionally. See [Issue #140](https://github.com/alex-1974/imagery-d/issues/140).

## M6 — Advanced image analysis

Deferred:

- shadow processing;
- feature extraction;
- segmentation;
- ML-assisted interpretation.

These do not drive the initial library architecture without evidence.
