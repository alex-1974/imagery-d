# M1.2 — imagery-d / raster-d Boundary

**Project:** `imagery-d`
**Milestone:** M1 — Image Semantic Core
**Issue:** M1.2 — Define imagery-d boundary with raster-d
**Status:** Research synthesis; no API handback required yet
**Date:** 2026-09-22

## 1. Purpose

Define the responsibility boundary between `imagery-d` and the independently
developed generic raster foundation `raster-d`.

The objective is to ensure that the first `imagery-d` image abstraction adds
only image-domain semantics and does not rebuild generic raster storage,
ownership, region or execution machinery.

This document also records candidate requirements that may belong in
`raster-d` if a concrete consumer later proves them to be generally reusable.

## 2. Verified current raster-d direction

Current `raster-d` documentation and production code establish a generic raster
foundation with no mandatory image, colour, radiometric or geospatial-image
meaning.

The current public/core model includes:

- representation-safe raster sample type `T`;
- `Region2D`;
- logical multi-plane raster representation;
- `PlaneDescriptor`;
- retained backing resources;
- `RasterLease!T`;
- read-only `RasterView!T`;
- lease-bound `WritableRasterView!T`;
- zero-copy ROI;
- signed row and sample strides;
- planar and pixel-interleaved layouts;
- multiple physical resources per backing;
- multiple logical planes sharing one physical resource;
- generic reduction/copy/conversion operations;
- package-internal execution-layout classification.

`raster-d` intentionally does not assign image meaning to logical planes.

Its own documentation explicitly places image/pixel-format, colour,
radiometric, image-filter and imagery-specific metadata concerns above the
generic raster layer.

## 3. Core boundary principle

The current strongest boundary is:

    raster-d
        owns generic raster representation and execution capability

    imagery-d
        owns image-domain semantics attached to that representation

Operationally:

    physical resources
        |
        v
    RasterLease!T
        |
        v
    RasterView!T
        |
        | imagery-d semantic layer
        v
    image channels / value interpretation / alpha / validity / colour binding

`imagery-d` should not introduce another storage/view model merely to make
raster data feel image-like.

## 4. raster-d responsibilities

The following are established or presumptive `raster-d` responsibilities.

### 4.1 Sample representation

`raster-d` defines which D types may safely be interpreted as raw resident
raster samples.

This is a representation-safety contract only.

It does not define:

- colour;
- radiometry;
- alpha;
- normalized range;
- spectral meaning;
- NoData.

### 4.2 Plane representation

`RasterView!T` exposes ordered logical planes.

Plane order is logical band order at the raster layer, but no image-domain
meaning is assigned to those bands.

### 4.3 Physical layout

`raster-d` owns:

- row stride;
- sample stride;
- planar storage;
- interleaved storage;
- padded rows;
- negative traversal;
- arbitrary validated affine layouts.

This means `imagery-d` must not need separate semantic core types merely for:

    planar RGB
    interleaved RGB

Both can already be represented through logical raster planes.

### 4.4 Ownership and lifetime

`raster-d` owns:

- retained resources;
- backing validation;
- lease lifetime;
- read/write capability;
- descriptor lifetime;
- exact-once resource release.

An `ImageView` must not invent another pixel-storage ownership system.

### 4.5 Regions and ROI

`RasterView.tryRoi()` already provides:

- O(1) subviews;
- no pixel copy;
- shared stable descriptors;
- preserved lifetime relation.

An image ROI should reuse this mechanism.

Image semantics may be retained/shared above the raster ROI, but the image
layer should not rebuild physical ROI mechanics.

### 4.6 Generic execution

Execution layout, Mir adapters, physical-range logic, alias analysis and
specialized execution paths remain internal to `raster-d`.

`imagery-d` operations should express image semantics and then use generic
raster capabilities rather than exposing or copying execution machinery.

### 4.7 Generic raster operations

Operations that are meaningful without image semantics belong presumptively to
`raster-d`.

Current examples include:

- strict numeric reduction;
- same-type raster-plane copy;
- exact `ubyte -> float` conversion.

A future generic operation should enter `raster-d` only when it is reusable by
non-image rasters.

## 5. imagery-d responsibilities

### 5.1 Channel and band semantics

`imagery-d` owns the meaning attached to raster planes, such as:

- red;
- green;
- blue;
- alpha;
- grayscale;
- NIR;
- SWIR;
- thermal;
- depth;
- custom channels;
- quality/classification values.

A raster plane remains a raster plane even when no known image role is
assigned.

### 5.2 Pixel semantics

`imagery-d` may define a logical pixel as the association of selected channels
at one common image coordinate.

This does not imply a packed physical pixel struct.

### 5.3 Stored-value interpretation

`imagery-d` owns image/radiometric interpretation such as:

    physical = scale * stored + offset

and associated image-domain units/quantity meaning where appropriate.

The raw sample remains a `raster-d` concern.

### 5.4 Alpha semantics

`imagery-d` owns:

- which channel is alpha;
- source alpha association metadata;
- distinction from masks and NoData.

General colour/compositing mathematics may later come from `color-d`.

### 5.5 Validity and NoData semantics

`imagery-d` owns the image meaning of:

- per-band NoData;
- tuple/pixel-level NoData;
- explicit validity masks;
- quality masks where image-domain interpretation is required.

The underlying mask raster storage remains generic raster data.

### 5.6 Colour binding

`imagery-d` owns mapping between image channels and colour components.

Raster plane order alone must not imply RGB.

### 5.7 Image-domain operations

Operations belong in `imagery-d` when their contract depends on image meaning,
for example:

- colour transforms across image channels;
- exposure/display transforms;
- radiometric normalization;
- image filters with image semantics;
- image-quality analysis;
- false-colour composition;
- imagery mosaics and pyramids.

Generic region/halo/storage execution should still be reused from `raster-d`.

## 6. Important verified compatibility: planar and interleaved images

Current `raster-d` can represent pixel-interleaved RGB using three logical
planes over one physical resource.

Conceptually:

    plane R:
        base = stream + 0
        sampleStride = 3

    plane G:
        base = stream + 1
        sampleStride = 3

    plane B:
        base = stream + 2
        sampleStride = 3

The same semantic plane order can also describe three independent planar
resources.

Therefore:

    image channel semantics
        do not need to know
    physical planar/interleaved organization

This is one of the strongest reasons for making the first `ImageView!T` a
semantic wrapper over `RasterView!T`.

## 7. Common-grid ImageView compatibility

The current leading M1 hypothesis is:

    ImageView!T
        |
        +-- RasterView!T
        |
        `-- immutable/shared image semantics

This fits the existing raster contract well if the first image abstraction
requires:

- one common logical 2D sampling grid;
- one materialized sample type `T`;
- one ordered set of logical raster planes.

`raster-d` does not need to understand:

- channel names;
- channel roles;
- alpha;
- colour encoding;
- radiometric scale/offset;
- image NoData semantics.

## 8. Coordinate-space boundary

This is the most important non-obvious boundary.

`raster-d` explicitly distinguishes:

    global/logical dataset placement
        !=
    resident RasterView region
        !=
    physical plane strides

A `RasterView` represents resident storage coordinates.

A large logical image may request:

    global region:
        (100000, 200000, 512, 512)

while the materialized resident `RasterView` uses:

    resident region:
        (0, 0, 512, 512)

This prevents huge logical coordinates from contaminating physical pointer
arithmetic.

### M1 consequence

The first `ImageView!T` should not silently reinterpret
`RasterView.region` as global image coordinates.

Image semantics attached to a resident view must distinguish:

- resident raster coordinates;
- any higher-level logical image placement.

### Ownership question

Global logical placement is not clearly image-specific.

It is equally relevant to:

- DEMs;
- scientific grids;
- streamed GDAL windows;
- generic large raster datasets.

Therefore `imagery-d` should not claim a general logical-raster coordinate
system as its private abstraction merely because images need it.

### Current action

No `raster-d` API change is requested yet.

For M1, the first `ImageView!T` can remain resident/common-grid only.

Global/product placement should remain a higher-layer concern until a concrete
operation proves what generic raster abstraction is actually required.

## 9. Heterogeneous sample types

Current `RasterView!T` has one sample type `T`.

OpenEXR and multi-asset remote-sensing products demonstrate that one broader
image/product may contain channels with different sample types.

This does **not** currently justify changing `raster-d`.

M1's preferred split is:

    ImageView!T
        homogeneous materialized processing view

    future ImageryProduct / description
        may bind several RasterView!T instances with different T

This preserves a simple generic raster core and avoids introducing runtime
sample-format dispatch without a proven generic raster consumer.

### Current action

No handback.

## 10. Different sampling grids / resolutions

One `RasterView!T` represents planes over one common `Region2D`.

Remote-sensing products such as Sentinel-2 may contain bands at different
native resolutions.

Again, this does not currently justify weakening `RasterView`.

The likely model is:

    one common-grid ImageView
        after explicit selection/resampling/materialization

versus:

    broader imagery product
        retains native heterogeneous grids

Implicit resampling must not occur merely to satisfy one image type.

### Current action

No handback.

## 11. Validity-mask storage

A difficult M1 case is:

    image samples : float
    validity mask : ubyte / bit

One `RasterView!T` cannot directly contain planes of different sample type.

There are several possible solutions:

1. image validity references a separate `RasterView!MaskT`;
2. validity is represented by a separate image-semantic attachment;
3. a higher-level product/binding model connects primary data and mask raster.

This is not yet evidence that `raster-d` needs a generic masked-raster type.

Masks and validity occur outside imagery too, so a reusable generic abstraction
might eventually belong in `raster-d`, but only if another concrete raster
consumer demonstrates the same need.

### Current action

Keep as M1.5/M1.6 modelling question.

Do not open a `raster-d` issue yet.

## 12. NoData

NoData is semantic information, not physical layout.

The raster core currently does not need to know that a sample value is invalid.

This is appropriate for the M1 image-semantic layer.

However, if future generic operations require standardized validity propagation
across DEMs/scientific grids as well as imagery, the ownership boundary should
be revisited.

### Current action

No handback.

## 13. Point-versus-area sampling

GeoTIFF and STAC distinguish values representing:

- point samples;
- area/cell samples.

This semantic distinction is not image-specific.

It also matters to:

- DEMs;
- scientific grids;
- generic geospatial rasters.

Therefore `imagery-d` should not define this as an image-only property.

### Current classification

Potential generic geospatial-raster requirement.

Possible eventual homes include:

- `raster-d`, if sampling semantics are considered intrinsic to generic raster
  coordinate interpretation;
- a focused geospatial-raster metadata layer above `raster-d`, if the generic
  raster core should remain purely resident/storage-oriented.

### Current action

Record only.

Do not open a `raster-d` issue until an operation or adapter requires a durable
contract.

## 14. Georeferencing

Current `raster-d` deliberately excludes mandatory:

- CRS;
- geotransform;
- ground extent;
- GSD;
- acquisition metadata.

This remains correct.

`imagery-d` may integrate image-specific geospatial metadata, but CRS
transformation machinery should remain outside the image semantic core.

The first M1 `ImageView!T` does not need to become georeferenced by definition.

## 15. Generic conversion versus image normalization

Current `raster-d` exposes exact:

    ubyte -> float

conversion.

An image operation may instead require:

    ubyte 0..255
        ->
    normalized float 0..1

or a colour/radiometric interpretation.

These are not the same operation.

The first is representation conversion.

The second introduces semantic scaling.

Therefore:

    exact generic conversion
        belongs to raster-d

    normalized/image/radiometric conversion
        belongs above raster-d

unless a broader numeric-transform primitive is later demonstrated to be a
useful generic raster operation.

### Current action

No handback.

## 16. Halo and neighbourhood processing

`raster-d` research has already demonstrated generic region dependency and
halo/context execution.

Therefore image filters should not create a second image-specific halo engine.

An image-domain operation should specify its dependency semantics while generic
region materialization/execution remains reusable.

Example:

    imagery-d blur
        defines radius / boundary semantics

    raster-d
        provides generic dependency-region / resident-region mechanics

Exact public integration remains later work.

## 17. Writable image views

`raster-d` already separates read-only and writable raster capabilities.

An eventual writable image abstraction should preserve the same direction:

    WritableRasterView!T
        + image semantics
        ->
    writable image capability

`imagery-d` should not infer uniqueness, non-aliasing or thread exclusivity
merely from writability.

No new image-specific ownership model is required.

## 18. Packed pixel sample types

`raster-d` permits representation-safe POD sample types, including simple
pixel-like structs.

Therefore a future packed sample such as an RGB storage struct could be used as
`T`.

However, `raster-d` explicitly treats this only as physical representation.

A packed `RGB8` sample must not automatically mean:

- sRGB;
- linear RGB;
- Rec.2020;
- alpha policy;
- display encoding.

Thus:

    packed pixel storage type
        !=
    image semantic descriptor

This is consistent with both M1 and the `color-d` boundary.

## 19. Handback decision rule

Create a `raster-d` issue only when all of the following hold:

1. a concrete `imagery-d` case requires a capability;
2. the capability is meaningful for non-image rasters;
3. existing `raster-d` representation/operations cannot already express it;
4. the requirement can be stated generically;
5. the issue does not prescribe imagery-specific implementation.

Good handback:

    streamed consumers need a generic logical-to-resident region mapping
    contract that is also useful for DEM/GDAL/scientific raster consumers

Bad handback:

    imagery-d needs an RGB channel descriptor in raster-d

## 20. Current candidate handbacks

### 20.1 Global logical placement

**Classification:** generic candidate.

**Need now:** no.

`raster-d` already documents the separation, but no public higher-level type is
frozen.

### 20.2 Point-versus-area sampling

**Classification:** generic/geospatial-raster candidate.

**Need now:** no.

### 20.3 Generic validity/mask association

**Classification:** potentially generic.

**Need now:** unproven.

Do not promote based only on imagery.

### 20.4 Heterogeneous sample-type product

**Classification:** not currently a raster-core requirement.

A higher product layer is preferred.

### 20.5 Different-resolution band collection

**Classification:** product/source concern, not one RasterView concern.

No handback.

## 21. Responsibility matrix

| Concern | raster-d | imagery-d |
|---|---|---|
| sample representation safety | owns | consumes |
| resident resources | owns | consumes |
| leases / lifetime | owns | consumes |
| read/write raster capability | owns | consumes |
| planes | owns representation | assigns image meaning |
| row/sample stride | owns | must not duplicate |
| planar/interleaved storage | owns | must be layout-neutral |
| ROI | owns generic mechanics | preserves image semantics |
| execution classification | owns | hidden from image API |
| generic reduction/copy/conversion | owns | reuses |
| channel role/name | — | owns |
| spectral-band identity | — | owns |
| logical pixel meaning | — | owns |
| scale/offset/unit | — | owns image/radiometric meaning |
| alpha identity/association | — | owns image metadata |
| mask/NoData meaning | generic mechanics possible later | owns image semantics |
| colour-channel binding | — | owns |
| colour mathematics | — | integrates with color-d |
| global logical placement | generic candidate above resident view | must not redefine privately |
| point-vs-area sampling | generic/geospatial candidate | preserves if encountered |
| CRS/geotransform | not core | optional integration, not M1 core |
| neighbourhood dependency mechanics | generic research/engine concern | operation declares image-domain need |
| image filters | — | owns |
| mosaics/pyramids | generic primitives only | owns image-domain semantics |

## 22. Current dependency decision

Established:

    imagery-d -> raster-d

This is not merely a likely future direction; it is the accepted repository
architecture.

The first `imagery-d` image abstraction should therefore be designed to reuse
`RasterView!T` rather than reproduce its responsibilities.

No reverse dependency is acceptable:

    raster-d -> imagery-d
        prohibited by the domain boundary

## 23. M1.2 decision

The existing `raster-d` architecture is sufficient for the current M1 semantic
research.

No immediate change to `raster-d` is required.

The current boundary is:

> `raster-d` owns resident raster representation, ownership, geometry and
> generic execution capability; `imagery-d` owns image-domain meaning attached
> to those rasters.

The strongest current candidate remains:

    ImageView!T
        = RasterView!T
        + image semantic descriptor

subject to M1.5 modelling.

Three generic boundary questions remain deliberately unresolved:

1. global logical dataset placement;
2. point-versus-area sampling;
3. generic validity/mask association.

They should not become `imagery-d` private infrastructure, but there is not yet
enough consumer evidence to request new `raster-d` API.

## 24. Issue status recommendation

GitHub issue:

    M1.2 — Define imagery-d boundary with raster-d

can be considered research-complete for the current M1 stage once this document
is reviewed and committed.

No `raster-d` issue should be opened merely to mark completion.

Cross-repository issues should be created only when M1.5/M1.6 or later concrete
implementation work turns one of the recorded generic candidates into a real
requirement.
