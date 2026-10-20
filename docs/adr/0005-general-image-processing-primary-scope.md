# ADR 0005 — General image processing is the primary imagery-d scope

**Status:** ACCEPTED PROJECT DOMAIN DIRECTION — INTEGRATED TO DEVELOP VIA PR #84  
**Date:** 2026-10-20 (clarification originally given on 2026-10-17)  
**Repository:** `imagery-d`  
**Scope:** Architectural scope only, not production symbol admission,
source/archive release, or reinterpretation of accepted M1/M2 experiments.  
**Review:** [Draft PR #84](https://github.com/alex-1974/imagery-d/pull/84).

## Context

M1 ADR 0002 accepted image-semantic terminology and a possible common-grid
image view; M2 ADR 0003 accepted optional source/materialization/cache
architecture. Both explicitly postponed production API admission. Earlier
experimental work focused heavily on remote-sensing product interpretation.
The project owner explicitly clarified on 2026-10-17 that the primary product
must instead be an independent, **general-purpose image-processing library
in D** serving photography/graphics, scientific images, and GIS/EO consumers.

An image-processing function should not require external scene/sensor truth
to compute a well-defined result from supplied pixels.

## Decision

1. **Primary contract:** `imagery-d` implements documented image-domain
   computations on caller-supplied image planes, image channels, masks,
   colour/alpha semantics (when necessary), and explicit algorithm
   parameters. Ordinary Levels, convolution, histogram or compositing must
   accept an appropriate valid materialized image without STAC, CRS,
   satellite identity, product revision or source provenance.
2. **Algorithm correctness stays inside the library:** validation, region
   and stride safety, lifetime, failure and result-publication semantics,
   numerical behavior, explicit units/colour domain and selection/mask
   policy are library obligations. A consumer cannot cure an algorithm's
   broken image mathematics by supplying trusted source metadata.
3. **Source truth belongs to the consumer/optional adapter:** authentic
   sensor calibration, georeferencing, spectral role, physical meaning,
   provenance, inter-scene scientific comparability and acquisition
   correctness are not mandatory properties of generic image operators.
   When requested, specialized adapters may provide such information
   without changing the basic operator precondition.
4. **No duplicated low-level foundation:** `raster-d` owns generic
   sample/plane/stride, ROI, backing lifetime and storage semantics;
   `color-d` remains responsible for independent colour mathematics
   where an image operator needs it. This does not introduce mandatory
   dependencies until a concrete operation justifies them.
5. **Accepted M1/M2 concepts remain valid but optional for a first
   operator:** a common-grid `ImageView` may represent richer semantics
   when a consumer requires them; source/cache/materialization remains
   one possible path to a pixel view, not a required intermediary for
   already materialized caller data.
6. **Promotion discipline:** no source reader, scheduler, universal
   operation DAG, renderer, image codec or EO-ingest framework follows
   from this domain clarification. Each production API still requires
   its own independently validated consumer, ownership/error contract,
   benchmark and separate explicit admission decision.

## Alternatives considered

- **Require satellite product metadata for generic operators — rejected.**
  Ordinary pixel operations can be fully specified without such metadata;
  imposing it couples the library to one application class.
- **Erase the accepted M1/M2 model — rejected.** Those represent coherent
  optional higher-level functionality with valid research evidence.
- **Make `imagery-d` a generic raster storage library — rejected.** This
  duplicates the already released `raster-d` boundary.
- **Infer sRGB/alpha/validity from source layout — rejected.** Conflates
  representation with semantic interpretation and would silently alter
  scientific and graphics consumer results.
- **Promote R-IM-02d synthetic STAC gate as core — rejected.** It is
  valid retained specialized research, but not a generic API requirement.

## Evidence and relationship to M3

- The 2026-10-17 [scope study](../research/general-image-processing-scope-correction-2026-10-17.md)
  specifies the full source-vs-algorithm responsibility matrix, R-IM-01/02
  dispositions and the plain-RGB/RGBA consumer test.
- The standalone image Levels qualification [Draft #97](https://github.com/alex-1974/imagery-d/pull/97)
  and its source-archive consumer demonstrate the intended no-STAC,
  no-CRS property, but **do not** admit the public API by themselves.
- M3 candidate selection under ADR 0004 is a **separate priority
  decision** (on still-unmerged Draft #96).
- The current [Draft #97 admission review](https://github.com/alex-1974/imagery-d/blob/feat/m3-levels-owned-result/docs/m3-levels-admission-review-2026-10-20.md)
  contains the narrower Levels consumer/oracle/ownership evidence.

## Consequences

- First production operators should be testable on normal supplied image
  buffers, including gray, RGB/RGBA and explicit float/multichannel cases.
- Geospatial metadata is not required, but is not banned from separately
  justified geospatial image processing modules.
- Historical research PRs (#73, #76/#77/#79/#80/#82 and the stacked M3
  research) retain their SHA, evidence and individual admission status.
- Accepted M1/M2 ADR documents are **not edited or reinterpreted as
  public API commitments**. This numbered ADR is the forward clarification.
- This Draft document records the accepted domain direction and **does
  not authorize a merge, package release, tag, or public API freeze**.
  `develop` continues to reflect its existing state until integration.

**Integration condition:** Review the proposed README/DESIGN/ROADMAP
changes in this PR against current `develop`, then merge through the
ordinary guarded documentation PR process **only when explicitly
authorized**. Subsequent ADR 0004 and Levels implementation integration
must preserve this accepted domain boundary.
