# Imagery research handover from the pre-pivot repository

## Purpose

This document records image-domain knowledge accumulated before the original
`imagery-d` repository was pivoted to `raster-d` on 2026-09-22.

It is not a claim that every idea below has been validated or admitted.

The goal is to prevent useful image-engine research from being lost while
keeping generic raster implementation and evidence in `raster-d`.

## Established architectural constraints

The pre-pivot work established or strongly motivated:

- RAM as an explicit budget rather than a dataset-size limit;
- no implicit whole-image copy requirement;
- support for imagery larger than RAM;
- region-first processing;
- explicit neighbourhood/halo requirements;
- separation of provider tiles, cache blocks and processing tiles;
- source-independent processing;
- reusable destination/workspace storage;
- correctness paths plus measured specialised fast paths;
- scheduling outside individual image algorithms;
- cancellation/priority for interactive workloads;
- future GPU compatibility without requiring a GPU implementation initially;
- real-world reproducible imagery benchmarks.

## Image-domain concerns retained for this project

### Image semantics

- pixel formats;
- channel interpretation;
- colour semantics;
- alpha/masks;
- relationship between stored sample values, radiometry, colour and display.

### Radiometry and normalization

- colour/exposure normalization;
- radiometric normalization;
- cross-source normalization;
- seam-sensitive local/global decisions.

### Filters

- blur;
- sharpening;
- convolution;
- neighbourhood operators;
- image-semantic resampling/interpolation where applicable.

### Mosaics and pyramids

- multiresolution images;
- image pyramids/overviews;
- mosaics;
- seam treatment;
- blending;
- source-resolution/quality selection.

### Image quality

- image-quality assessment;
- source quality;
- blur/noise/contrast-related metrics;
- quality implications for mosaics and interactive selection.

### Advanced/deferred

- shadow detection and correction;
- feature extraction;
- segmentation;
- ML-assisted interpretation.

These were deferred until the engine foundation existed; they were not rejected.

## Source/cache/execution considerations

The earlier design expected image processing to work above sources such as:

- in-memory images;
- GeoTIFF / COG;
- GDAL;
- XYZ/TMS;
- WMTS;
- WMS;
- cached mosaics;
- outputs of other operations.

Image-oriented execution requirements included:

- visible-data priority;
- obsolete-work cancellation;
- asynchronous loading;
- prefetching;
- decoded-data reuse;
- progressive refinement;
- parallel execution.

The exact ownership boundary between `imagery-d`, `raster-d`, future I/O
libraries and applications remains research.

## GPU/display considerations

Future architecture should not require whole CPU-buffer rewrites merely to
perform interactive presentation transforms such as:

- brightness;
- contrast;
- gamma;
- saturation;
- opacity.

This is a design requirement, not yet an accepted GPU API.

## Geospatial imagery metadata

Relevant metadata requirements include:

- ground extent;
- geotransform;
- CRS;
- GSD/resolution;
- NoData;
- alpha/masks;
- provenance;
- acquisition metadata.

Not every image must be georeferenced.

Generic CRS/projection infrastructure does not belong here.

## Benchmark corpus policy

Large imagery is not versioned in Git.

Store reproducible:

- scene definitions;
- source definitions;
- retrieval parameters;
- provenance;
- hashes.

The corpus should cover differing:

- latitudes and hemispheres;
- terrain and elevation;
- urban/rural content;
- providers;
- effective resolutions;
- image quality;
- neighbouring imagery;
- mosaic seams.

## Historical sources

The authoritative implementation history and generic raster evidence remain in
`raster-d`.

Especially relevant historical material includes:

- pre-pivot `DESIGN.md`;
- pre-pivot `BENCHMARK.md`;
- pre-pivot roadmap/research material;
- ADR 0002 concerning non-versioned benchmark imagery;
- ADR 0003 defining the repository pivot and future imagery boundary;
- raster memory/view/ownership experiments;
- region/streaming research where it constrains future image operations.

Generic raster mechanics should be referenced from that repository rather than
copied here.
