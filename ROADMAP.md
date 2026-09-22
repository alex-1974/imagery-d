# imagery-d Roadmap

## Current state

`imagery-d` is currently an architecture/research repository.

No production D package/API has yet been admitted.

The generic raster foundation is supplied by `raster-d`.

## M0 — Repository and knowledge handover

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

## M1 — Image semantic core research

Research and decide:

- image versus generic raster abstraction;
- pixel/channel semantics;
- pixel-format policy;
- alpha/mask/NoData semantics;
- colour metadata boundary.

No API implementation before the semantic model is accepted.

## M2 — Source/cache/pipeline architecture

Research:

- source/backend contract;
- source identity and provenance;
- decoded versus compressed cache policy;
- visible-region priority;
- cancellation;
- prefetching;
- progressive refinement;
- relationship to generic `raster-d` region/streaming contracts.

## M3 — First image operation family

Select one concrete, independently useful operation family based on consumer
evidence.

Candidates may include:

- colour/display transform;
- normalization;
- finite-neighbourhood filtering;
- image-quality analysis.

Admission requires:

- explicit mathematical/semantic contract;
- reference implementation or oracle;
- whole-image versus streamed equivalence rule;
- memory contract;
- benchmark plan;
- DMD and LDC verification plan.

## M4 — Reproducible imagery corpus

Implement tooling/specification for:

- scene definitions;
- source definitions;
- retrieval parameters;
- provenance;
- hashes;
- local non-versioned data;
- boundary/mosaic/seam cases.

## M5 — Mosaics and multiresolution imagery

Only after M1–M4 provide stable primitives.

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
