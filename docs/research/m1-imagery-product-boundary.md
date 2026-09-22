# M1.6 — Imagery Product Boundary for Heterogeneous Data

**Project:** `imagery-d`
**Milestone:** `M1 — Image Semantic Core`
**Issue:** `M1.6 — Define imagery-product boundary for heterogeneous data`
**Status:** Provisional architecture boundary — not a public API freeze
**Date:** 2026-09-22

## 1. Purpose

This document defines where the validated common-grid `ImageView!T` abstraction
ends and where a broader imagery-product / resource-description layer must
begin.

It builds on:

- `docs/research/m1-image-semantic-core.md`;
- `docs/research/m1-reference-model-matrix.md`;
- `docs/research/m1-raster-d-boundary.md`;
- `docs/research/m1-color-d-boundary.md`;
- `docs/research/m1-image-view-contract.md`;
- `experiments/m1_5_image_view_contract/`.

M1.5 established a deliberately narrow processing abstraction:

    ImageView!T
        =
    one common-grid RasterView!T
        +
    borrowed immutable image semantics
        +
    optional same-grid RasterView!ubyte validity

M1.6 defines what must remain outside that abstraction.

The central rule is:

> Heterogeneous imagery must not be forced into one `ImageView!T` merely to
> obtain one convenient top-level type.

---

## 2. Reference evidence

Several mature systems demonstrate that one logical imagery product may contain
data that cannot naturally be represented by one homogeneous common-grid raster.

### 2.1 OpenEXR

OpenEXR supports arbitrary named channels.

Each channel independently has:

- a name;
- a data type;
- an x sampling rate;
- a y sampling rate.

Supported channel data types include:

- HALF;
- FLOAT;
- UINT.

A single OpenEXR image can therefore contain, for example:

    R,G,B,A : HALF
    Z       : FLOAT
    objectId: UINT

OpenEXR also permits subsampled channels, for example:

    Y  : sampling 1 x 1
    RY : sampling 2 x 2
    BY : sampling 2 x 2

Multipart OpenEXR adds another level: multiple image parts can have different
data windows, layouts and image/deep-image kinds.

Conclusion:

> physical file identity does not imply one sample type, one grid or one
> processable `ImageView!T`.

### 2.2 Sentinel-2

Sentinel-2 MSI products contain 13 spectral bands distributed across three
native spatial resolutions:

    10 m: 4 bands
    20 m: 6 bands
    60 m: 3 bands

The native product therefore contains related spectral data whose grids differ.

Conclusion:

> product membership does not imply common native resolution.

### 2.3 xarray

An xarray `Dataset` can hold multiple variables with different:

- dtypes;
- dimensionality;
- dimensions.

Variables that share a dimension name are aligned within one shared coordinate
system, but the Dataset itself is broader than one homogeneous array.

Conclusion:

> a useful higher-level collection abstraction does not require one universal
> element type or one universal array shape.

### 2.4 STAC

STAC models an Item as an atomic collection of inseparable data and metadata and
allows an Item to expose multiple Assets.

Asset roles identify purposes such as:

- data;
- metadata;
- overview;
- thumbnail.

EO/raster metadata describe band-specific properties such as:

- spectral identity;
- data type;
- scale;
- offset;
- NoData;
- units;
- spatial resolution.

Conclusion:

> one product/item may bind multiple independently addressable resources with
> different roles and raster semantics.

---

## 3. M1.6 selected direction

The first imagery product abstraction should be **descriptive and relational**.

It should describe:

- which resources/components belong together;
- what each component means;
- which native grid each component uses;
- what native/sample representation it has;
- how components are related;
- which outputs are derived from which inputs;
- which component combinations may be explicitly materialized as
  `ImageView!T`.

It should **not** itself require all raster data to be resident.

Conceptually:

    Imagery Product Description
        |
        +-- resource / asset A
        |     +-- component A0
        |     +-- component A1
        |
        +-- resource / asset B
        |     +-- component B0
        |
        +-- resource / asset C
        |     +-- component C0
        |
        +-- relationships
        +-- native grid descriptions
        +-- semantic metadata
        `-- provenance / derivation

Materialization is a separate operation:

    selected compatible component(s)
        |
        | explicit decode / conversion / resampling if required
        v
    ImageView!T

---

## 4. Product != ImageView

The distinction must be explicit.

### ImageView

An `ImageView!T` is:

- a processing view;
- resident or otherwise currently materialized through `raster-d`;
- homogeneous in sample type `T`;
- common-grid;
- directly traversable as raster data;
- suitable for ROI and image operations.

### Imagery Product

An imagery product is:

- a description of related imagery resources/components;
- potentially heterogeneous;
- potentially multi-resolution;
- potentially multi-asset;
- potentially only partially materialized;
- suitable for discovery, selection, binding and provenance.

Therefore:

    ImageryProduct
        is not
    ImageView!Variant

and:

    ImageryProduct
        is not
    vector<ImageViewBase>

A product may have no currently materialized image views at all.

---

## 5. Product != file

One file may contain multiple logical product components.

OpenEXR is the decisive example.

A single file can contain:

- channels with different sample types;
- channels with different sampling rates;
- multiple parts;
- regular and deep parts.

Therefore an imagery product must not use:

    one file == one image

as a structural invariant.

Likewise, one imagery product may span several files or network assets.

Therefore:

    resource identity
        !=
    image identity
        !=
    product identity

---

## 6. Product != asset

An asset/resource is one addressable source object.

It may contain:

- one raster band;
- several raster bands;
- several OpenEXR channels;
- several OpenEXR parts;
- metadata;
- an overview;
- a mask;
- a quality raster;
- a thumbnail.

Therefore an asset is a source/resource boundary, not necessarily a processing
image boundary.

A single asset may yield several `ImageView!T` materializations.

Several assets may also be combined explicitly into one `ImageView!T`.

---

## 7. Product component

M1.6 needs a concept smaller than a product but semantically richer than a raw
file.

The provisional concept is a **product component**.

A product component is one semantically identifiable raster-like member whose
native representation can be described independently.

Examples:

- Sentinel-2 B04 at 10 m;
- Sentinel-2 B05 at 20 m;
- OpenEXR `Z` FLOAT channel;
- OpenEXR RGB HALF channel group;
- one quality/classification raster;
- one cloud mask;
- one derived NDVI raster.

The final public name is not decided.

Possible later names include:

    ProductComponent
    RasterComponent
    ImageryComponent
    BandResource
    RasterAssetMember

M1.6 deliberately freezes none of these.

---

## 8. Component identity must be stable

A product component needs a stable identity inside its product.

This identity must not depend only on:

- array index;
- filename;
- human-readable title;
- channel order.

Reasons:

- assets may be reordered;
- resources may be replaced;
- multiple resources may expose similarly named bands;
- derived products need stable provenance references.

A stable product-local identifier should therefore exist conceptually.

Example:

    "B04"
    "quality_scl"
    "exr.part0.Z"
    "derived.ndvi"

The concrete identifier type remains open.

---

## 9. Native representation description

Each product component should preserve its native representation separately.

Conceptually this includes:

- source/resource reference;
- source subresource selector;
- native sample type;
- channel/band semantics;
- native sampling/grid reference;
- stored-value interpretation;
- NoData/validity information;
- optional colour role/binding;
- optional source metadata.

This is a description.

It does not imply the component has already been decoded into a
`RasterView!T`.

---

## 10. Sample type belongs to the component/materialization boundary

Different components may have different native sample types.

Therefore sample type is not a product-wide invariant.

Example:

    component R,G,B
        native type = HALF

    component Z
        native type = FLOAT

    component objectId
        native type = UINT

A later materialization may choose:

    decode HALF RGB -> float ImageView

while preserving:

    Z -> float ImageView
    objectId -> uint ImageView

No runtime `Variant` is required inside the validated `ImageView!T`.

---

## 11. Grid identity belongs to the component

Different components may use different native grids.

The product layer therefore needs to describe grid identity/equivalence.

At M1.6 this does **not** require freezing a complete geospatial grid API.

The minimum semantic requirement is:

> Two components must not be treated as common-grid unless their grid
> relationship has been explicitly established.

Conceptually a component refers to:

    nativeGrid = GridRef / GridDescription

The exact representation is deferred.

Possible grid properties eventually include:

- width / height;
- sampling step;
- origin;
- pixel alignment;
- point-vs-area semantics;
- geotransform;
- CRS;
- level/resolution identity.

Not all belong in `imagery-d` core.

The product layer may retain an opaque or higher-level grid reference until the
workspace settles the general geospatial-raster boundary.

---

## 12. No implicit grid equality

Two components with equal width and height are not automatically on the same
grid.

Likewise:

    same CRS
        !=
    same raster grid

and:

    same resolution
        !=
    same origin/alignment

and:

    same physical footprint
        !=
    same sample locations

Therefore common-grid compatibility must be established explicitly.

This is critical before grouping components into one `ImageView!T`.

---

## 13. No implicit resampling

This is the strongest product-layer invariant.

If two selected product components have different native grids:

    materialize common image

must require an explicit resampling policy.

The product abstraction must never silently choose:

- nearest;
- bilinear;
- cubic;
- average;
- mode;
- any other resampling method.

It must also not silently choose:

- target resolution;
- target origin;
- target extent;
- target CRS.

Those are operation-level decisions.

---

## 14. No implicit sample conversion

Likewise, combining components with different native types must not silently
select a common output type.

For example:

    HALF RGB + FLOAT Z + UINT object ID

does not imply:

    convert everything to float

A consumer may explicitly request such a conversion where meaningful.

Discrete identifiers/classifications often must remain integer/categorical.

---

## 15. No implicit semantic conversion

Product materialization must also avoid silently applying:

- scale/offset;
- colour-space conversion;
- radiometric normalization;
- NoData replacement;
- alpha conversion;
- gamut clipping.

Each operation must be explicit or defined by a named materialization policy.

---

## 16. Compatible component grouping

The product layer may identify subsets of components that can be materialized
together without resampling.

A group is compatible for one `ImageView!T` when at least:

1. all selected components resolve to one common processing grid;
2. the materialized sample type is one `T`;
3. each selected component maps to one primary raster plane;
4. the resulting channel semantics are valid;
5. any attached validity raster uses the same processing grid.

This grouping may be discovered dynamically.

It should not require a persistent product-level "image" object for every
possible combination.

---

## 17. Materialization is explicit

The product layer should conceptually support:

    select components
        |
        v
    determine compatibility
        |
        +-- directly compatible
        |       -> decode/materialize ImageView!T
        |
        `-- incompatible
                -> require explicit transform policy
                   (resample / convert / compose)
                        |
                        v
                   ImageView!T

The exact API is deferred.

M1.6 only requires the architecture to preserve this separation.

---

## 18. Materialization may be lazy/region-based

A product should not require whole-resource decoding.

The established `raster-d` architecture is region-first and supports bounded
resident windows.

Therefore a future product materializer should be able to request:

    product component subset
    +
    requested region
    +
    target processing grid
    +
    output sample type
    +
    explicit transform policy

and obtain a bounded resident processing view.

This preserves the workspace rule:

> RAM is a budget, not a dataset-size limit.

---

## 19. Native product description may outlive materialized views

Product metadata is naturally longer-lived than any one processing ROI.

Therefore:

    product description
        may remain retained

while:

    ImageView ROI
        is short-lived / lease-bound

A product should not need to hold every `RasterLease` permanently.

Source/cache/provider layers may materialize and release region-specific raster
leases as needed.

---

## 20. Resource descriptor vs resident raster

The product layer should distinguish:

    source/resource descriptor
        persistent description of where/how data can be obtained

from:

    RasterLease!T
        retained resident decoded raster representation

This prevents accidental whole-product residency.

A remote asset, COG, JPEG2000 band, OpenEXR part or generated raster may remain
described without being resident.

---

## 21. Multi-asset products

Sentinel-style products demonstrate:

    one logical product
        ->
    several raster assets

The product layer therefore needs an asset/resource collection.

Each resource may have:

- identifier;
- URI/source handle;
- media/format information;
- role(s);
- metadata;
- component declarations.

Exact source-I/O abstractions are outside M1.

The product layer should not hard-code HTTP/file/GDAL access.

---

## 22. One asset may expose multiple components

OpenEXR demonstrates the inverse:

    one asset
        ->
    several heterogeneous channels/parts/components

Therefore the resource-component relation is many-to-many at the conceptual
level:

    product
        has resources

    resources
        expose components

    components
        may participate in derived/materialized images

A simple product-wide flat list may still be a convenient view, provided each
component retains its source binding.

---

## 23. Quality and classification layers

Quality data belong to the product when they describe the product's observations.

Examples:

- cloud classification;
- saturation flags;
- quality bitfields;
- scene classification;
- confidence layers.

They must not automatically become the `ImageView` validity sidecar.

A quality raster may contain richer categorical information than a boolean
valid/invalid mask.

An explicit operation may derive:

    quality/classification
        ->
    normalized validity RasterView!ubyte

for a particular processing purpose.

This preserves:

    quality data
        !=
    validity mask

---

## 24. Masks

A product may contain masks with their own:

- sample representation;
- grid;
- resolution;
- semantics.

Such a source mask is not automatically an M1.5 attached validity raster.

To attach it to one `ImageView!T`, it must first satisfy the common-grid
validity contract.

If the mask grid differs, explicit alignment/resampling is required.

---

## 25. Derived rasters

A product may include or reference derived data.

Examples:

- NDVI;
- cloud probability;
- pan-sharpened RGB;
- atmospheric-corrected reflectance;
- overview;
- resampled common-grid stack.

The product layer should preserve the distinction between:

    source/native component

and:

    derived component

without assuming the derived component is less authoritative or merely
temporary.

---

## 26. Provenance relationships

At minimum, the architecture must leave room for relations such as:

    derived B <- source A

    composite C <- source A + source B

    mask M <- quality Q with policy P

    common-grid image G <- bands B04+B03+B02 resampled to grid X

M1.6 does not define a complete provenance graph API.

It requires only that component identity and product structure do not make such
provenance impossible.

---

## 27. Product-level metadata

Some metadata belongs to the whole product rather than individual components.

Examples may include:

- acquisition time;
- platform/sensor;
- processing level;
- scene/product identifier;
- provenance;
- provider information.

This metadata should remain outside `ImageView!T` unless needed to interpret
the current processing image.

The common-grid view must remain small and processing-oriented.

---

## 28. Component-level metadata

Other metadata belongs to one component.

Examples:

- spectral wavelength;
- unit;
- scale;
- offset;
- NoData;
- native sample type;
- native grid;
- classification schema;
- quality semantics.

The product layer may preserve richer source metadata than the common-grid
`ImageView` needs.

Materialization transfers only the semantics required for the resulting
processing image.

---

## 29. Presentation metadata

Presentation is separate again.

Examples:

- RGB selection;
- false-colour mapping;
- rescale range;
- colormap;
- display gamma/tone mapping.

A product may carry recommended/default presentation metadata, but such
metadata must not mutate intrinsic component identity.

STAC's separate render/composite concepts reinforce this distinction.

---

## 30. Product-level colour concerns

A product may contain:

- colour imagery;
- non-colour spectral data;
- several colour groups;
- depth/IDs/quality data.

Therefore `color-d` remains downstream of explicit colour-component selection.

The product layer must not force every component into a colour model.

---

## 31. Deep data boundary

OpenEXR deep images store a variable number of samples per pixel.

This violates the fixed one-sample-per-plane-per-grid-cell model underlying
`RasterView!T`.

Therefore deep data is outside the first `ImageView!T`.

M1.6 should classify deep image parts as:

    product components / resources
        requiring a specialized future representation

They must not be flattened silently.

No deep-raster core is proposed in M1.

---

## 32. Pyramid / multi-resolution boundary

OpenEXR tiled mip/ripmap levels and imagery pyramids demonstrate another form of
heterogeneity.

Different levels are related representations of imagery at different
resolutions.

A product/resource may describe these levels, but one `ImageView!T` represents
one selected common grid at one time.

Selecting a pyramid level is explicit.

Combining levels is not an `ImageView` responsibility.

---

## 33. Product collection vs product

M1.6 should avoid turning the imagery product into a catalog/database.

A product is one coherently related set of imagery resources/components.

A collection of products, search index or STAC catalog belongs above it.

Thus:

    catalog / collection
        ->
    product
        ->
    resources/components
        ->
    materialized ImageView

This prevents product metadata from expanding into archive/catalog semantics.

---

## 34. Ownership model

The product layer should own/retain **descriptions**, not automatically raster
storage.

Conceptually:

    ImageryProduct
        owns:
            metadata
            resource descriptors
            component descriptors
            relationships

        does not automatically own:
            all decoded pixel buffers
            all RasterLease instances
            all cache blocks

A materializer/cache may temporarily retain raster resources.

This is essential for large or remote imagery.

---

## 35. Product immutability

A published product description should preferably be immutable or versioned.

Reasons:

- stable component identifiers;
- safe sharing;
- deterministic provenance;
- predictable materialization.

Adding a derived component may therefore conceptually produce:

    new product description

or:

    explicit derived-product object

rather than mutating an in-use product graph unpredictably.

The exact API remains open.

---

## 36. Product identity and equality

M1.6 does not define global product identity.

However, product-local component identity must not be confused with semantic
equality.

Two components may represent the same spectral band but differ in:

- acquisition;
- processing level;
- grid;
- source;
- calibration;
- resolution.

Likewise two resources may contain byte-identical data but serve different
semantic roles.

---

## 37. Product component selection

Consumers should be able to select components by semantic criteria rather than
only physical source order.

Examples:

    select red, green, blue

    select B08, B04, B03

    select all 10 m spectral bands

    select cloud mask

    select source component by stable id

The exact query API is outside M1.

The product model must simply preserve enough structured semantics to make such
selection possible.

---

## 38. Compatibility check is separate from selection

Selection answers:

    which components do I want?

Compatibility answers:

    can these components become one ImageView without explicit transformation?

These must remain different operations.

A user may validly select incompatible native components.

The system must not reject the product selection merely because materialization
needs an explicit transform.

---

## 39. Product-to-ImageView bridge

The future bridge should conceptually return one of several outcomes:

    directly materializable
    needs sample-type conversion
    needs grid resampling
    needs both
    unsupported representation
    specialized representation required

Examples:

### Ordinary RGB TIFF

    directly materializable

### Sentinel-2 B04+B03+B02

All are 10 m:

    directly/common-grid materializable
    subject to source decoding

### Sentinel-2 B08+B05+B02

Native 10 m + 20 m + 10 m:

    needs explicit resampling policy

### OpenEXR RGB HALF + Z FLOAT

If RGB requested:

    materialize RGB processing image

If RGB + Z requested in one image:

    needs explicit common sample-type decision
    or remain separate views

### Deep OpenEXR part

    specialized representation required

---

## 40. `ImageView!T` remains closed under M1.6

M1.6 must not weaken the validated M1.5 contract.

Specifically, do not change `ImageView!T` to:

    ImageView
    {
        Variant[] planes;
        Grid[] perPlaneGrid;
        optional<any>...
    }

That would destroy the simplicity and performance value of the processing
abstraction.

Heterogeneity belongs above it.

---

## 41. No universal runtime sample type

The product layer may need to describe native sample types dynamically.

That does not imply the hot processing layer should use a universal runtime
sample variant.

Dynamic type description and typed materialization can coexist:

    dynamic product description
        |
        | consumer selects output T
        v
    typed ImageView!T

This is preferable to making every inner processing loop dynamically typed.

---

## 42. D-language consequence

D templates make typed materialization natural.

A future API may conceptually have:

    materialize!float(...)
    materialize!ushort(...)

or source-specific typed dispatch.

M1.6 does not prescribe this spelling.

The architecture should preserve the ability to use compile-time typed
processing after dynamic product discovery.

---

## 43. No product-level ownership duplication with raster-d

M1.6 must preserve the M1.2 boundary.

`raster-d` continues to own:

- resident resources;
- raster backing;
- leases;
- raster views;
- ROI;
- generic execution.

The product layer owns:

- descriptions;
- semantic grouping;
- component relationships;
- source bindings;
- native grid/type metadata;
- provenance.

A materializer bridges the two.

---

## 44. No product-level colour-math duplication with color-d

M1.6 must preserve the M1.3 boundary.

`color-d` continues to own general colour mathematics.

The product layer may preserve:

- colour encoding metadata;
- channel-to-colour relationships;
- recommended presentation selections.

It does not implement colour-space conversion mathematics.

---

## 45. Candidate conceptual model

The following is intentionally pseudocode.

It is not a proposed stable D API.

    ImageryProduct
    {
        ProductMetadata metadata;
        ResourceDescriptor[] resources;
        ComponentDescriptor[] components;
        ProductRelationship[] relationships;
    }

    ResourceDescriptor
    {
        ResourceId id;
        source/reference;
        media/format description;
        roles;
    }

    ComponentDescriptor
    {
        ComponentId id;
        ResourceBinding source;
        NativeSampleDescription sample;
        NativeGridDescription grid;
        Channel/Band semantics;
        Value semantics;
        validity/NoData metadata;
    }

    ProductRelationship
    {
        source component ids;
        target component id;
        relationship kind;
        optional processing/provenance metadata;
    }

The exact decomposition may change substantially.

The semantic boundaries are what M1.6 intends to retain.

---

## 46. What must not be in the first product core

Avoid speculative framework growth.

M1.6 does not require:

- catalog search;
- database indexing;
- STAC serialization;
- GDAL object wrappers;
- HTTP client;
- cloud authentication;
- cache implementation;
- scheduler;
- full provenance ontology;
- workflow DAG engine;
- all possible geospatial grid types;
- all image codec metadata;
- GPU resources;
- ML dataset abstractions.

These may become consumers or adapters later.

---

## 47. Consumer case P1 — OpenEXR heterogeneous channel types

Resource:

    one OpenEXR part

Components:

    R HALF
    G HALF
    B HALF
    A HALF
    Z FLOAT
    objectId UINT

Product result:

**PASS.**

Each component preserves native type.

Compatible HALF colour components may be grouped for one typed materialization.

Z and objectId remain separately typed unless an explicit conversion is
requested.

No heterogeneous `ImageView` is needed.

---

## 48. Consumer case P2 — OpenEXR subsampled chroma

Components:

    Y  sampling 1x1
    RY sampling 2x2
    BY sampling 2x2

Product result:

**PASS.**

Components remain related but native-grid-distinct.

A common RGB image requires an explicit upsampling/conversion operation.

No implicit reconstruction occurs.

---

## 49. Consumer case P3 — OpenEXR multipart

One physical file contains:

    part 0 regular RGB
    part 1 depth
    part 2 deep compositing data

Product result:

**PASS.**

One resource exposes several components/parts.

Regular compatible parts may materialize to `ImageView`.

Deep data remains specialized/deferred.

---

## 50. Consumer case P4 — Sentinel-2 native product

Product contains:

    B02 10 m
    B03 10 m
    B04 10 m
    B08 10 m

    B05 20 m
    B06 20 m
    B07 20 m
    B8A 20 m
    B11 20 m
    B12 20 m

    B01 60 m
    B09 60 m
    B10 60 m

Product result:

**PASS.**

All bands remain one logical product without pretending they share one grid.

A 10 m RGB selection can directly form one common-grid materialization.

A mixed-resolution selection requires explicit resampling.

---

## 51. Consumer case P5 — source band + quality layer

Product:

    reflectance bands
    scene classification layer

The quality layer may have:

- different semantics;
- possibly different grid/type;
- categorical values.

Product result:

**PASS.**

The quality component is preserved independently.

An operation may explicitly derive a validity mask from it.

---

## 52. Consumer case P6 — source + derived NDVI

Product or derived product contains:

    B08
    B04
    NDVI

Relationship:

    NDVI <- function(B08, B04)

Product result:

**PASS.**

Provenance can be represented without embedding the computation engine into the
product descriptor.

---

## 53. Consumer case P7 — pre-resampled stack

A provider may expose a derived common-grid stack:

    B02/B03/B04/B05/... all resampled to 10 m

This derived resource is valid as its own component group.

The product must preserve that it is derived/resampled rather than pretending
it is native.

Result:

**PASS.**

---

## 54. Consumer case P8 — thumbnail/overview

A product may include:

    full-resolution data
    overview
    thumbnail

The thumbnail is not merely another native science band.

Resource roles/presentation semantics distinguish it.

Result:

**PASS.**

---

## 55. M1.6 invariants

The product architecture should not be promoted unless all of these remain true:

1. Product identity is distinct from file identity.

2. Product identity is distinct from resource/asset identity.

3. One resource may expose several components.

4. One product may contain several resources.

5. Components may have different native sample types.

6. Components may have different native grids/resolutions.

7. Components may have different semantics.

8. Product description does not require whole-product residency.

9. `ImageView!T` remains homogeneous and common-grid.

10. No implicit sample conversion occurs when components are combined.

11. No implicit resampling occurs when grids differ.

12. No implicit colour/radiometric transformation occurs.

13. Quality/classification layers are not automatically validity masks.

14. Source masks are not automatically M1.5 validity sidecars.

15. Derived components retain provenance/relationship to sources.

16. Dynamic product discovery can still lead to statically typed
    `ImageView!T` processing.

17. `raster-d` remains the owner of resident raster storage/lifetime.

18. `color-d` remains the owner of general colour mathematics.

19. Deep/variable-sample data are not silently flattened into `ImageView`.

20. Product metadata does not expand into catalog/database responsibilities.

---

## 56. Remaining open questions

M1.6 deliberately leaves several implementation questions for later work.

### Q1 — final product type name

`ImageryProduct` is still conceptual.

### Q2 — resource abstraction

The source/resource descriptor must eventually integrate with actual providers
without hard-coding file/HTTP/GDAL semantics.

### Q3 — grid descriptor ownership

Need coordination with broader geospatial/raster architecture before freezing:

- CRS;
- affine transform;
- point-vs-area;
- grid identity/equivalence.

### Q4 — native sample-type descriptor

The product layer needs runtime description of native sample type without
infecting typed processing loops with runtime variants.

### Q5 — component grouping

Need concrete rules/API for determining whether selected components can be
materialized directly as one `ImageView!T`.

### Q6 — provenance depth

Need a minimal useful relation model without creating a full workflow DAG.

### Q7 — source masks and validity derivation

Need concrete consumer cases before deciding how product-level masks bind to
M1.5 validity views.

---

## 57. No M1.6 production experiment required yet

Unlike M1.5, the central M1.6 result is primarily an architectural boundary.

The important claim is negative:

> heterogeneous product structure must remain outside `ImageView!T`.

This is strongly supported by external reference models and by M1.5's validated
common-grid contract.

A D experiment would be premature until M2 selects:

- concrete product type names;
- source/resource abstraction;
- grid descriptor representation.

Therefore M1.6 should not create speculative production or experiment types
solely to demonstrate that a vector of descriptors can exist.

---

## 58. M1.6 decision

The M1 boundary should be:

    Imagery product / description layer
        |
        +-- heterogeneous resources
        +-- heterogeneous components
        +-- native type descriptions
        +-- native grid descriptions
        +-- quality/mask components
        +-- derived/provenance relationships
        |
        | explicit selection/materialization
        v
    ImageView!T
        |
        +-- one common grid
        +-- one primary sample type T
        +-- immutable image semantics
        `-- optional same-grid UInt8 validity
        |
        v
    raster-d

The product layer is therefore a semantic/source description and relationship
layer above the validated processing-image view.

It does not replace `ImageView!T`.

It explains how real-world heterogeneous imagery can eventually produce one or
more typed common-grid processing views.

---

## 59. Issue status recommendation

GitHub issue:

    M1.6 — Define imagery-product boundary for heterogeneous data

can be considered research-complete once this document is reviewed and
committed.

No production product API should be introduced during M1.

The concrete product model should be deferred to M2 or another explicit future
milestone after the M1 architecture gate is complete.

---

## 60. References used for this boundary

Primary/reference material reviewed for M1.6:

- OpenEXR Technical Introduction — arbitrary channels, channel types, sampling
  rates, multipart, multiview and deep data.
- OpenEXR Reading and Writing Image Files — multipart organization.
- Sentinel-2 Products Specification Document — 13 MSI bands at native
  10 m / 20 m / 60 m resolutions.
- xarray documentation — Dataset variables may have different dtypes and
  dimensions while sharing named coordinate systems where applicable.
- STAC specification — Items and Assets.
- STAC EO/Raster/Render/Composite extensions — band metadata, asset/component
  semantics and separation of intrinsic raster data from presentation.

These references are used as architecture evidence, not as APIs to copy.
