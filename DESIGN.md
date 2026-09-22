# imagery-d Design

## 1. Purpose

`imagery-d` is a high-performance image and remote-sensing processing library
built above `raster-d`.

Its first expected consumers include interactive geospatial applications such
as an OpenStreetMap editor, while the library itself remains independent of
OSM-specific data structures and UI frameworks.

The architecture must support both interactive display workloads and later
analytical processing.

## 2. Fundamental constraints

### 2.1 RAM is a budget, not a dataset-size limit

The engine must not require a complete image or imagery mosaic to reside in
memory.

The total dataset may be substantially larger than physical RAM.

The working set may include:

- decoded source data;
- source/cache blocks;
- processing regions;
- temporary buffers;
- output buffers;
- metadata;
- later GPU-resident resources.

No operation should silently require a complete-image copy.

### 2.2 Large and multiresolution imagery

The architecture must permit:

- individual high-resolution images;
- imagery mosaics;
- multiresolution imagery;
- streamed datasets;
- neighbouring imagery needed for processing context.

Avoidable 32-bit dataset-size assumptions are not acceptable.

### 2.3 Interactive execution

The architecture should permit:

- prioritisation of visible data;
- cancellation of obsolete work;
- asynchronous source loading;
- prefetching;
- reuse of decoded data;
- progressive refinement;
- parallel execution.

The public image model must not be tied to one scheduler.

### 2.4 Allocation behaviour

Hot processing loops should not repeatedly allocate.

Operations should permit reusable engine-owned or caller-controlled destination
and workspace storage where appropriate.

### 2.5 Correctness before optimisation

Optimised implementations require a reference implementation or another clear
correctness oracle.

For finite-neighbourhood operations:

```text
whole-image result
        ≈
region/streamed result with sufficient context
```

within an explicitly defined numerical tolerance.

Region or tile boundaries must not introduce artificial discontinuities.

## 3. Processing terminology

These concepts are deliberately distinct.

### Provider tile

A unit supplied by an external service such as XYZ, TMS or WMTS.

This is an I/O concept.

### Cache block

A storage unit chosen by the engine.

This is a caching concept.

### Region

An arbitrary rectangular area requested from an image or processing stage.

### Window

A normally zero-copy view into an image/raster region.

Generic mechanics belong to `raster-d`.

### Processing tile

A possible scheduler work unit.

It must not automatically equal a provider tile or cache block.

### Halo / context

Input samples outside the requested output region that are required by a
neighbourhood operation.

Generic dependency/halo mechanics belong to `raster-d`; an image operation
defines its semantic neighbourhood requirement.

## 4. Region-first image processing

Desired processing flow:

```text
consumer requests output region
             |
             v
 image operation determines dependencies
             |
             v
 required input region + halo
             |
             v
       source/cache request
```

Fixed source tiles must not become an accidental restriction of the public
processing API.

Whether the higher-level image pipeline becomes demand-driven, explicitly
staged or graph-based remains research.

## 5. Source independence

Image algorithms should not care whether their pixels originated from:

- an in-memory raster;
- GeoTIFF;
- Cloud Optimized GeoTIFF;
- GDAL;
- XYZ/TMS;
- WMTS;
- WMS;
- a cached mosaic;
- another processing operation.

The exact imagery source/backend API remains research.

Generic raster storage and streaming contracts remain in `raster-d`.

## 6. CPU optimisation

Image operations should support:

1. generic correctness paths for all accepted raster layouts;
2. specialised fast paths where measurements justify them.

Relevant optimisation dimensions include:

- contiguous versus strided memory;
- interleaved versus planar data;
- alignment;
- auto-vectorisation;
- explicit SIMD only where justified;
- cache blocking;
- multithreading;
- compile-time specialisation;
- hardware dispatch where justified.

LDC/LLVM auto-vectorisation should be evaluated before introducing explicit
SIMD.

## 7. GPU boundary

GPU processing is not an initial requirement.

The architecture should nevertheless avoid assumptions that prevent future GPU
buffers or compute backends.

Interactive transforms such as:

- brightness;
- contrast;
- gamma;
- saturation;
- opacity;

should eventually be possible without repeatedly rewriting entire CPU image
buffers.

## 8. Geospatial imagery metadata

Imagery may require:

- ground extent;
- geotransform;
- CRS;
- resolution / GSD;
- NoData;
- alpha/masks;
- provenance;
- acquisition metadata.

The core image representation must not require every image to be georeferenced.

CRS transformation infrastructure itself does not belong to `imagery-d`.

## 9. Boundary with raster-d

`imagery-d` consumes `raster-d`; it does not fork it.

A new abstraction belongs here only when its semantics require image-domain
knowledge.

If an abstraction is equally meaningful for DEMs, scientific grids,
GDAL windows or other non-image rasters, it is presumptively a `raster-d`
concern and requires an explicit boundary review before implementation.
