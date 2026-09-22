# ADR 0001: imagery-d is a higher-level consumer of raster-d

## Status

Accepted.

## Context

The original `imagery-d` repository developed a substantial generic raster
foundation while pursuing a future image engine.

Research and implementation demonstrated that the generic raster layer has a
coherent standalone domain useful beyond imagery.

On 2026-09-22 the existing repository/history was therefore pivoted to
`raster-d`.

A new image-domain library is still useful, but it must start above that generic
foundation rather than rebuild it.

## Decision

The dependency direction is:

```text
imagery-d
    |
    v
 raster-d
```

`raster-d` owns generic raster representation, ownership, views, layout,
operations, region/dependency mechanics, streaming/execution contracts and
generic performance infrastructure.

`imagery-d` owns image-domain semantics and processing, including candidates
such as:

- image/pixel/channel semantics;
- colour semantics;
- radiometric processing;
- normalization;
- filters and neighbourhood operators;
- mosaics and pyramids;
- image quality;
- imagery-specific source/cache policy;
- imagery-specific metadata integration.

## Boundary rule

A capability should not be implemented in `imagery-d` merely because imagery
uses it.

If the same abstraction is naturally useful for DEMs, scientific grids,
generic GDAL windows or other non-image rasters, it is presumptively a
`raster-d` concern.

If imagery research discovers a missing generic raster capability, the
requirement is handed to the `raster-d` project and evaluated there.

## Consequences

`imagery-d` can evolve image semantics independently without contaminating the
generic raster layer.

`raster-d` remains usable by non-image consumers.

No generic raster implementation is copied into this repository.

Historical evidence remains in `raster-d` and may be referenced rather than
duplicated.
