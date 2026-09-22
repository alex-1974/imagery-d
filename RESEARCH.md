# imagery-d Research

## Status

This is an evidence backlog, not an implicit feature list.

Research findings must be promoted deliberately into an ADR, roadmap item,
public contract, implementation and verification plan.

## R01 — Image and pixel semantics

Questions:

- What constitutes an image above the generic `raster-d` representation?
- Which pixel formats need first-class semantics?
- How are planar and interleaved channels represented without duplicating
  raster layout mechanics?
- How should alpha, masks and NoData interact?
- Which colour metadata belongs to the image and which belongs to a rendering
  pipeline?

Status: **research required before first public image type**.

## R02 — Colour and display semantics

Research topics:

- colour spaces and transfer functions;
- channel interpretation;
- alpha/compositing semantics;
- brightness;
- contrast;
- gamma;
- saturation;
- opacity;
- conversion versus non-destructive display transforms.

The eventual API should distinguish stored pixel values, radiometric values,
colour interpretation and presentation transforms.

## R03 — Radiometry and normalization

Research topics:

- radiometric normalization;
- colour/exposure normalization;
- normalization across neighbouring imagery;
- provider/sensor differences;
- histogram/statistical methods;
- local versus global normalization;
- seam avoidance;
- reproducibility and numerical contracts.

This is a primary future `imagery-d` domain.

## R04 — Filters and neighbourhood operators

Research topics:

- blur;
- sharpening;
- convolution;
- gradient/edge operators;
- resampling/interpolation where image semantics matter;
- operation-specific halo requirements;
- boundary conditions;
- streamed versus whole-image equivalence.

Generic halo/dependency mechanics should be reused from `raster-d`.

## R05 — Mosaics and pyramids

Research topics:

- image pyramids;
- overviews;
- multiresolution selection;
- mosaics;
- seam handling;
- blending;
- neighbouring image selection;
- source quality/resolution selection.

Provider tiles, processing tiles and cache blocks must remain separate concepts.

## R06 — Imagery source/cache architecture

Candidate sources:

- local files;
- GeoTIFF / COG;
- GDAL-backed datasets;
- XYZ/TMS;
- WMTS;
- WMS;
- local caches;
- generated upstream operations.

Questions:

- What is imagery-specific above `raster-d` streaming?
- How are source identity, provenance and validity represented?
- How are visible-region priority, cancellation and prefetching expressed?
- Which caches store compressed source material versus decoded imagery?
- What belongs to an application scheduler rather than the library?

Status: **research before implementation**.

## R07 — Image quality

Research topics:

- objective image-quality metrics;
- blur/sharpness estimates;
- noise;
- contrast/dynamic range;
- cloud/haze or acquisition defects where applicable;
- source-quality ranking for overlapping imagery;
- mosaic seam quality.

## R08 — Shadow processing

Research topics:

- shadow detection;
- shadow confidence;
- optional correction/normalization;
- interaction with radiometry and colour;
- preservation of provenance.

## R09 — Feature extraction and segmentation

Deferred research:

- feature extraction;
- segmentation;
- image-derived assistance for mapping workflows.

This must not turn `imagery-d` into an OSM-specific package.

## R10 — ML-assisted interpretation

Deferred.

Research only after conventional processing, provenance, reproducibility and
resource-control contracts are mature.

Questions include:

- model/resource ownership;
- tiling/context requirements;
- reproducibility;
- CPU/GPU backend boundaries;
- confidence/provenance representation;
- separation between generic library facilities and application-specific
  interpretation.

## Research rule

Image-domain research may impose requirements on `raster-d`, but must not
silently redefine generic raster concepts inside `imagery-d`.

When a missing generic capability is discovered, document the consumer
requirement and hand it to the `raster-d` project for its own admission process.
