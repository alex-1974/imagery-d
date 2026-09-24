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

M3 — First Production Vertical Slice is the current milestone.

No production D package/API has yet been admitted.

The generic raster foundation is supplied by `raster-d`.

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

## M3 — First Production Vertical Slice — CURRENT

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

## M4 — Reproducible imagery corpus

Implement tooling/specification for:

- scene definitions;
- source definitions;
- retrieval parameters;
- provenance;
- hashes;
- local non-versioned data;
- boundary/mosaic/seam cases.

M3 may use minimal reproducible fixtures before M4.

M4 generalizes those needs into durable corpus infrastructure.

## M5 — Mosaics and multiresolution imagery

Only after the earlier milestones provide stable primitives.

Research:

- pyramid/overview semantics;
- source-resolution selection;
- mosaics;
- blending;
- seam treatment;
- source-quality policy.

## M6 — Advanced image analysis

Deferred:

- shadow processing;
- feature extraction;
- segmentation;
- ML-assisted interpretation.

These do not drive the initial library architecture without evidence.
