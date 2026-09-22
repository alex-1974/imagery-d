# ADR 0002 — M1 Image Semantic Core

**Status:** Accepted
**Date:** 2026-09-22
**Project:** `imagery-d`
**Milestone:** `M1 — Image Semantic Core`
**Decision scope:** Image semantic core architecture and promotion gate

## 1. Context

`imagery-d` is the higher-level image and remote-sensing library above
`raster-d`.

The repository was deliberately re-established as a research/architecture
project after the generic raster foundation was separated into `raster-d`.

M1 was created to answer a prerequisite question before production image APIs
were admitted:

> What is the smallest correct image-semantic abstraction above a generic
> raster, and where must that abstraction stop?

The M1 research sequence produced and validated:

- image-semantic terminology and invariants;
- a comparison against mature reference systems;
- an explicit boundary with `raster-d`;
- an explicit consumer-side boundary with `color-d`;
- a common-grid `ImageView!T` semantic contract;
- a DMD/LDC lifetime and ROI experiment;
- a separate product boundary for heterogeneous imagery.

This ADR synthesizes those results and records the M1 promotion decision.

---

## 2. Decision summary

M1 accepts the following architecture:

    heterogeneous imagery product / description
                |
                | explicit selection / conversion / resampling
                v
           ImageView!T
                |
                +-- one common-grid RasterView!T
                +-- immutable image semantics
                +-- optional same-grid RasterView!ubyte validity
                |
                v
             raster-d

Colour mathematics remains a peer dependency candidate:

    imagery-d
        |
        +------> raster-d
        |
        `------> color-d   (future, when a concrete operation requires it)

The current M1 semantic architecture is accepted.

The production package/API gate is **not** opened yet.

Specifically:

- do **not** create the production `dub.sdl` yet;
- do **not** create a production `source/imagery/**` public API yet;
- do **not** freeze public `ImageView`, channel-descriptor, NoData, validity,
  colour-binding or product type names yet.

The next milestone is M2 research.

The first production package surface remains gated on the repository's existing
admission rule: a concrete image-domain capability must be selected and its
correctness, memory and benchmark contract must be defined.

---

## 3. Accepted terminology

The following concepts are distinct and must remain distinct.

### 3.1 Sample

One stored raster value of type `T`.

A sample is a representation concept.

It does not by itself imply:

- colour;
- alpha;
- radiometry;
- validity;
- spectral meaning.

### 3.2 Raster plane

One logical plane exposed by `RasterView!T`.

Plane order is a raster representation order.

The image layer may assign image-channel meaning to that order.

### 3.3 Image channel / band

One semantic image quantity associated with one primary raster plane in the
first common-grid model.

Examples include:

- red;
- green;
- blue;
- alpha;
- grayscale;
- NIR;
- SWIR;
- thermal;
- depth;
- quality/classification;
- custom/unknown channels.

A spectral band is not automatically a colour component.

### 3.4 Pixel

A logical association of channel samples at one common image coordinate.

A logical pixel is not required to be represented physically as one packed D
struct.

### 3.5 Stored value

The raw materialized raster sample.

### 3.6 Physical / radiometric value

A value obtained from stored representation according to image-domain value
semantics, for example:

    physical = stored * scale + offset

Stored and physical values are distinct semantic layers.

### 3.7 Colour interpretation

The mapping from selected image channels to a colour tuple and colour encoding.

Colour interpretation is distinct from:

- intrinsic spectral identity;
- raw storage layout;
- presentation.

### 3.8 Presentation

A display-oriented selection or mapping, such as:

- RGB selection;
- false-colour mapping;
- tone mapping;
- display rescale.

Presentation must not mutate intrinsic channel identity.

### 3.9 Alpha

A compositing/coverage relationship associated with an explicitly identified
channel.

Alpha association may be:

- straight/unassociated;
- premultiplied/associated;
- unknown.

Alpha is not validity.

### 3.10 Validity mask

A representation of whether data are usable for a given operation.

The validated M1 processing normal form is a separate same-grid
`RasterView!ubyte`:

    0       = invalid
    non-zero = valid

A validity mask is not alpha.

### 3.11 NoData

Metadata or a semantic convention identifying absent/invalid observations.

NoData may be:

- per-channel;
- tuple/pixel-level;
- represented by a stored sentinel;
- represented through NaN policy;
- converted into a materialized validity mask when an operation requests it.

NoData is not necessarily a materialized mask.

### 3.12 Quality / classification

Domain data such as scene classification, confidence or cloud-quality flags.

Quality/classification may be used to derive validity for a particular
operation, but is not inherently a boolean validity mask.

---

## 4. Accepted semantic layering

M1 accepts the following separation:

    presentation / rendering intent
                |
                v
       colour interpretation
                |
                v
       channel / band meaning
                |
                v
    decoded / physical value semantics
                |
                v
         stored raster sample
                |
                v
    raster-d layout / ownership / execution

No layer may be silently collapsed into another.

In particular:

    sample != channel
    plane != channel meaning
    pixel != packed storage struct
    stored value != physical value
    alpha != mask
    mask != NoData
    spectral band != colour component
    colour interpretation != presentation

---

## 5. raster-d boundary

`raster-d` owns generic raster representation and execution mechanics.

Accepted `raster-d` responsibilities include:

- raster sample representation safety;
- logical planes;
- physical resources;
- row/sample strides;
- planar/interleaved/custom layout;
- signed strides;
- backing validation;
- ownership and leases;
- read-only and writable raster capabilities;
- resident regions;
- zero-copy ROI;
- generic copy/conversion/reduction;
- generic execution-layout classification;
- generic region/dependency/halo mechanics.

`imagery-d` must not duplicate those responsibilities.

The dependency direction is:

    imagery-d
        |
        v
     raster-d

The reverse dependency is not allowed.

---

## 6. imagery-d boundary

`imagery-d` owns semantics that exist because the raster is being treated as an
image, remote-sensing observation or imagery product.

Accepted responsibilities include:

- channel/band identity;
- logical pixel meaning;
- stored-to-physical interpretation;
- scale/offset/unit image semantics;
- alpha channel identity and source association;
- image validity meaning;
- image NoData semantics;
- colour-component binding;
- image colour-encoding metadata;
- false-colour mapping;
- image-domain processing;
- imagery-product/resource semantics;
- imagery-specific provenance and source relationships.

---

## 7. color-d boundary

`color-d` is developed independently.

M1 accepts the following consumer-side boundary.

`color-d` owns general colour mathematics, including its independently selected
public representation for:

- colour-space value types;
- encoded versus linear-light RGB;
- explicit colour-space conversion;
- gamut mathematics;
- straight versus premultiplied alpha values;
- compositing mathematics;
- colour interpolation;
- perceptual colour operations.

`imagery-d` owns:

- which image channels participate in colour;
- channel-to-colour-component binding;
- image colour-encoding metadata;
- alpha-channel identity;
- preservation of image colour metadata;
- application of colour operations over raster regions.

M1 does not require a `color-d` dependency.

No `color-d` API is frozen or prescribed from `imagery-d`.

---

## 8. Accepted common-grid ImageView model

M1 accepts the following semantic model:

    ImageView!T
        =
    one common-grid RasterView!T
        +
    borrowed immutable image semantics
        +
    optional same-grid RasterView!ubyte validity

The name `ImageView!T` remains provisional at the public-API level, but the
semantic decomposition is accepted.

### 8.1 Common-grid invariant

All primary channels represented directly by one processing image view:

- share one logical 2D grid;
- share one materialized sample type `T`;
- are represented by one `RasterView!T`.

### 8.2 Plane/channel mapping

For the first model:

    image channel i
        describes
    primary raster plane i

No arbitrary remapping table is required in the core processing view.

Channel selection/reordering may be added later only for a concrete consumer.

### 8.3 Layout neutrality

Image semantics are independent from whether primary data are:

- planar;
- pixel-interleaved;
- padded;
- negative-stride;
- otherwise valid under `raster-d`.

### 8.4 Metadata immutability

Published image semantics are immutable for the lifetime of the view.

ROI shares semantic metadata rather than cloning or mutating it.

### 8.5 Non-owning view

The image view does not own pixel storage.

`RasterLease!T` continues to retain primary raster resources.

A future higher-level image owner may retain:

- the primary raster lease;
- immutable semantic metadata;
- optional validity raster lease.

That higher owner must not duplicate raster ownership semantics.

---

## 9. Validity decision

The accepted processing-side validity representation is:

    primary:
        RasterView!T

    optional validity:
        RasterView!ubyte

with:

    0        = invalid
    non-zero = valid

The validity raster:

- uses the same processing grid as the primary image view;
- remains separate from alpha;
- may be absent;
- may be derived explicitly from source masks or NoData;
- does not imply source storage was originally byte-based.

This representation is a processing normal form.

It is not a claim about file/storage encoding.

---

## 10. NoData decision

M1 accepts that NoData is semantic metadata and does not automatically require a
materialized validity raster.

A later operation may choose to:

- test a stored sentinel directly;
- materialize a validity mask;
- combine multiple NoData rules;
- derive validity from quality data.

The final typed representation of NoData remains a later API decision.

This is not a blocker to the semantic architecture.

---

## 11. Colour binding decision

Colour applies to an explicit ordered subset of channels.

The architecture must not infer RGB merely from:

- plane count;
- channel count;
- names;
- physical interleaving.

A colour binding must preserve component order explicitly.

A false-colour presentation may map non-visible spectral channels to display
components without changing their intrinsic semantic identity.

The final public colour-binding type remains deferred.

---

## 12. Alpha decision

Alpha is represented semantically as an explicit channel relationship.

The image layer must preserve:

- alpha channel identity;
- straight/premultiplied/unknown association.

The image layer must not infer alpha only from:

- four channels;
- channel names;
- file format after decoding.

Alpha association survives materialization and ROI.

The mathematical representation used by `color-d` remains independently owned
by `color-d`.

---

## 13. Radiometric/value decision

The image layer distinguishes:

    stored representation
        ->
    physical/radiometric interpretation
        ->
    colour/presentation interpretation

Creating an `ImageView!ubyte` does not imply normalization to `[0,1]`.

Creating an `ImageView!float` does not imply values are bounded to `[0,1]`.

No implicit clipping is permitted.

Scene-linear HDR and extended intermediate values must remain representable.

---

## 14. Coordinate decision

`raster-d` distinguishes:

    global/logical dataset placement
        !=
    resident RasterView region
        !=
    physical plane strides

M1 preserves that boundary.

The first common-grid image view is a resident/processing view.

It does not reinterpret `RasterView.region` as global image coordinates.

Global placement remains a higher-level concern until a generic raster or
geospatial-raster abstraction is justified.

---

## 15. Product boundary

M1 accepts a separate higher product/description layer for heterogeneous data.

The product layer may describe:

- several source resources/assets;
- several components;
- different native sample types;
- different native grids/resolutions;
- masks and quality data;
- derived rasters;
- provenance and derivation relationships.

The product layer does not require whole-product residency.

A product is distinct from:

- one file;
- one asset;
- one raster view;
- one processing image.

The relationship is:

    product description
        |
        | explicit selection/materialization
        v
    typed common-grid ImageView!T

---

## 16. Heterogeneous data decision

The following do not belong directly inside one first-generation
`ImageView!T`:

- OpenEXR channels with different sample types;
- OpenEXR channels with different x/y sampling;
- deep OpenEXR variable sample counts;
- Sentinel-2 bands on 10 m / 20 m / 60 m native grids;
- arbitrary multi-asset heterogeneous products.

These are product-level concerns.

They require explicit materialization decisions before they become a
common-grid processing image.

---

## 17. No implicit resampling

This is a hard architecture invariant.

If selected components do not share one native grid, `imagery-d` must not
silently choose:

- nearest-neighbour;
- bilinear;
- cubic;
- averaging;
- mode;
- target resolution;
- target origin;
- target extent;
- target CRS.

Resampling requires an explicit operation/policy.

---

## 18. No implicit sample conversion

Likewise, heterogeneous native sample types do not imply an automatic common
type.

Examples such as:

    HALF RGB
    FLOAT depth
    UINT object id

must remain semantically distinct until a consumer explicitly requests a
conversion/materialization.

Categorical/identifier data must not be coerced merely to make one convenient
container.

---

## 19. Quality and mask decision

Product-level quality/classification data remain independent components.

They are not automatically M1 validity masks.

A source mask on another grid is not automatically attachable to a
common-grid `ImageView`.

Explicit alignment/materialization is required first.

---

## 20. Lifetime decision

M1 accepts the lease-bound borrowing model inherited from `raster-d`.

The M1.5 experiment mechanically verified under both:

- DMD 2.111.0;
- LDC 1.41.0, DMD frontend 2.111.0, LLVM 19.1.7;

that an experimental image view can safely borrow:

- primary `RasterView!T`;
- immutable semantic metadata;
- optional validity `RasterView!ubyte`;

while preserving all relationships through ROI.

Compile-negative probes confirmed rejection under `@safe` DIP1000 when a view
or ROI attempts to outlive:

- the primary raster lease;
- semantic metadata;
- the validity raster lease;
- the corresponding transitive ROI borrow.

This establishes the viability of the selected lifetime architecture.

---

## 21. ROI decision

ROI is an image-semantic transformation layered on generic raster ROI.

For a valid image view:

    child.primary
        = parent.primary ROI

    child.validity
        = parent.validity ROI, if present

    child.semantics
        = same immutable semantic descriptor

ROI:

- does not clone pixel storage;
- does not clone semantic metadata;
- does not alter channel meaning;
- does not alter alpha association;
- does not alter scale/offset;
- does not reinterpret global coordinates.

The M1.5 experimental ROI path compiled as `@nogc`.

---

## 22. Streaming decision

No image-semantic abstraction may require whole-image residency.

M1 remains compatible with the `raster-d` region-first model.

Future image operations must be expressible over bounded resident regions where
their semantics permit it.

For finite-neighbourhood operations:

    output region
        ->
    operation-defined dependency/halo
        ->
    generic raster region materialization

Image operations define semantic neighbourhood needs.

Generic dependency/halo mechanics remain `raster-d` responsibilities.

---

## 23. Responsibility matrix

| Concern | raster-d | imagery-d | color-d |
|---|---|---|---|
| sample representation safety | owns | consumes | — |
| backing/resources | owns | consumes | — |
| strides/interleaving | owns | layout-neutral | — |
| leases/lifetime | owns | composes | — |
| ROI mechanics | owns | preserves image semantics | — |
| generic raster execution | owns | consumes | — |
| channel identity | — | owns | — |
| spectral-band identity | — | owns | — |
| logical pixel meaning | — | owns | — |
| stored -> physical interpretation | — | owns | — |
| alpha channel identity | — | owns | — |
| straight/premultiplied math | — | preserves source state | owns |
| validity meaning | generic storage only | owns image semantics | — |
| NoData meaning | — | owns | — |
| colour-component binding | — | owns | — |
| colour-space value types | — | consumes later | owns |
| colour conversion math | — | applies to image regions later | owns |
| product/resources/components | — | owns | — |
| global raster placement | generic candidate above resident core | must not redefine privately | — |
| point-vs-area semantics | generic/geospatial candidate | preserves when encountered | — |
| quality/classification imagery semantics | — | owns | — |
| image filters | generic mechanics only | owns | colour primitives only |
| mosaics/pyramids | generic primitives only | owns imagery semantics | — |

---

## 24. Rejected alternatives

### 24.1 Monolithic PixelFormat enum

Rejected as the semantic core.

Reason:

- collapses storage, channel meaning, colour, alpha and value interpretation;
- does not scale to arbitrary/custom channels;
- poorly represents remote-sensing data;
- pressures the API toward a closed taxonomy.

Format-specific adapters may still use enums internally.

### 24.2 RGB/RGBA-specific core image type

Rejected.

Reason:

- remote-sensing channels are not inherently colour;
- arbitrary channel count is required;
- `raster-d` already handles multi-plane layout generically.

### 24.3 Per-channel physical storage in ImageView

Rejected.

Reason:

- duplicates `raster-d`;
- complicates ownership/lifetime;
- risks embedding product heterogeneity into the hot processing abstraction.

### 24.4 Heterogeneous Variant-based ImageView

Rejected.

Example rejected direction:

    ImageView
    {
        Variant[] planes;
        Grid[] grids;
    }

Reason:

- loses typed hot loops;
- infects operations with runtime type dispatch;
- conflates product description with processing view;
- weakens the validated M1.5 model.

### 24.5 Normalize everything to float

Rejected as an implicit rule.

Reason:

- categorical/identifier data may be integer;
- exact source semantics matter;
- conversion is an operation, not a container invariant.

### 24.6 Force all product bands to one grid

Rejected.

Reason:

- introduces hidden resampling;
- discards native-resolution semantics;
- violates Sentinel-2/OpenEXR evidence.

### 24.7 Alpha as validity

Rejected.

Reason:

- compositing semantics differ from data usability.

### 24.8 NoData as always-materialized mask

Rejected.

Reason:

- unnecessary residency/work;
- direct sentinel testing may be valid;
- tuple-level and operation-specific validity exist.

### 24.9 Embed global logical placement into RasterView/ImageView

Rejected for M1.

Reason:

- `raster-d` deliberately keeps resident and global coordinates separate;
- the need is generic to non-image rasters too.

### 24.10 Make color-d API part of M1 image semantics

Rejected.

Reason:

- `color-d` remains independently evolving;
- image semantic validity does not require current colour-math type names;
- premature coupling would freeze two research APIs.

---

## 25. Correctness requirements promoted from M1

Future implementation must preserve these invariants.

1. Physical raster layout does not determine image meaning.

2. Unknown/custom channels remain representable.

3. Channel semantics are not inferred solely from names.

4. Colour semantics are not inferred solely from channel count.

5. Alpha is explicit.

6. Alpha, validity and NoData remain distinct.

7. Stored and physical/radiometric values remain distinct.

8. No implicit normalization.

9. No implicit clipping.

10. No implicit resampling.

11. No implicit common-type coercion for heterogeneous products.

12. ROI preserves semantic identity.

13. A processing image view does not require whole-image residency.

14. Product description does not require all product assets resident.

15. Heterogeneous product semantics do not leak into the first common-grid
    processing view.

---

## 26. Cross-library handback status

### 26.1 raster-d

No immediate `raster-d` API change is required by M1.

Potential future generic candidates are recorded but not yet justified for
handback:

- global logical dataset placement;
- point-versus-area sampling;
- generic validity/mask association.

A `raster-d` issue should be opened only when a concrete non-image-reusable need
is demonstrated.

### 26.2 color-d

No immediate `color-d` issue is required by M1.

Current consumer needs are already aligned with the `color-d` research
direction:

- encoded versus linear RGB;
- explicit conversion;
- extended values;
- alpha distinction;
- correct compositing;
- compact value types.

A cross-repository issue should be opened only for a concrete missing general
colour capability.

---

## 27. M1.4 reference validation result

The selected model has been pressure-tested against:

- TIFF / GeoTIFF;
- PNG;
- OpenEXR;
- OpenImageIO;
- OpenCV;
- libvips;
- GDAL;
- STAC EO / Raster / presentation concepts;
- xarray;
- Sentinel-2.

The decisive pressure cases included:

- planar/interleaved RGB;
- explicit alpha association;
- float image + byte/bit validity;
- per-channel scale/offset;
- arbitrary/custom channels;
- heterogeneous OpenEXR channel types;
- OpenEXR per-channel subsampling;
- Sentinel-2 native multi-resolution bands;
- false-colour presentation;
- scene-linear HDR;
- point-versus-area sampling.

No evidence requires weakening the selected common-grid processing image model.

---

## 28. Promotion gate

M1 is promoted at the **architecture level**.

This means the following decisions are now durable project constraints unless a
later ADR explicitly supersedes them:

- `imagery-d -> raster-d` dependency direction;
- image semantics above raster representation;
- common-grid homogeneous typed processing view;
- separate optional UInt8 validity sidecar;
- immutable shared semantic metadata across ROI;
- separate heterogeneous product/description layer;
- no implicit resampling/type conversion;
- independent `color-d` boundary.

M1 promotion does **not** mean the public D API is frozen.

---

## 29. Production package decision

### Decision: NOT YET

Do not yet create:

    dub.sdl

for the production `imagery-d` package, and do not yet create:

    source/imagery/**

as a public production API.

### Reason

The repository's existing admission policy requires more than a semantic model.

Before the first production package surface is admitted, the project still
requires:

1. a selected concrete image-domain capability/consumer;
2. a mathematical/semantic operation contract;
3. correctness/reference strategy;
4. memory/streaming contract;
5. benchmark plan;
6. DMD/LDC verification plan.

Those belong to the M2/M3 sequence.

### Consequence

Research experiments remain allowed under:

    experiments/

and durable architecture/research documents remain allowed under:

    docs/

M1 does not authorize speculative package scaffolding merely because the
semantic research succeeded.

---

## 30. What M2 may research

M2 may now rely on the accepted M1 boundaries while researching:

- source/backend contracts;
- product resource descriptors;
- source identity/provenance;
- decoded/compressed cache policy;
- visible-region priority;
- cancellation;
- prefetching;
- progressive refinement;
- typed materialization from heterogeneous products;
- relationship to `raster-d` region/streaming contracts.

M2 must not reopen M1 invariants casually.

If new source/cache research contradicts an M1 invariant, the conflict requires
an explicit architecture review.

---

## 31. What M3 must establish before production admission

Before the first public package surface, M3 should select one concrete operation
family and establish:

- consumer need;
- exact semantic contract;
- reference implementation or independent oracle;
- expected numerical behavior;
- whole-image versus region/streamed equivalence rule;
- memory contract;
- allocation expectations;
- benchmark scenes;
- DMD correctness matrix;
- LDC performance/codegen matrix.

Only after that evidence exists should the project revisit creation of
production `dub.sdl` and `source/imagery/**`.

---

## 32. M1 issue closure mapping

The M1 issues can be closed with the following evidence.

### M1.1 — Establish image semantic core invariants

Evidence:

- `docs/research/m1-image-semantic-core.md`
- commit `449c310`

Status:

    research-complete

### M1.2 — Define imagery-d boundary with raster-d

Evidence:

- `docs/research/m1-raster-d-boundary.md`
- commit `839f0d2`

Status:

    research-complete

### M1.3 — Define imagery-d boundary with color-d

Evidence:

- `docs/research/m1-color-d-boundary.md`
- commit `7b1482d`

Status:

    research-complete

### M1.4 — Validate semantic model against reference systems and consumer cases

Evidence:

- `docs/research/m1-reference-model-matrix.md`
- commit `c47d833`

Status:

    research-complete

### M1.5 — Model first common-grid ImageView contract

Evidence:

- `docs/research/m1-image-view-contract.md`
- commit `0be0201`
- `experiments/m1_5_image_view_contract/`
- commit `9334790`

Status:

    closed / validated

### M1.6 — Define imagery-product boundary for heterogeneous data

Evidence:

- `docs/research/m1-imagery-product-boundary.md`
- commit `d099d73`

Status:

    research-complete

### M1.7 — Synthesize M1 architecture decision and promotion gate

Evidence:

- this ADR

Status after ADR commit:

    complete

---

## 33. Final decision

M1 has established a coherent semantic architecture for `imagery-d`.

The project now has a stable architectural answer to:

> What is an image above `raster-d`?

For the first processing abstraction:

> An image is a common-grid typed raster view plus explicit immutable image
> semantics and optional same-grid validity.

The project also has a stable answer to:

> What happens when real imagery is more heterogeneous than that?

> It remains in a higher product/resource description until explicit
> materialization decisions create one or more typed common-grid processing
> views.

M1 therefore closes as an architecture milestone.

The next project phase is M2.

Production package/API creation remains gated and is not authorized by this ADR.
