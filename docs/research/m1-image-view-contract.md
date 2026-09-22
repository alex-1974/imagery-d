# M1.5 — First Common-Grid ImageView Contract

**Project:** `imagery-d`
**Milestone:** `M1 — Image Semantic Core`
**Issue:** `M1.5 — Model first common-grid ImageView contract`
**Status:** Provisional semantic contract — not a public API freeze
**Date:** 2026-09-22

## 1. Purpose

This document models the smallest useful first processing-image abstraction for
`imagery-d`.

It builds on:

- `docs/research/m1-image-semantic-core.md`;
- `docs/research/m1-reference-model-matrix.md`;
- `docs/research/m1-raster-d-boundary.md`;
- `docs/research/m1-color-d-boundary.md`.

The goal is to make the semantic contract concrete enough that it can be tested
with D lifetime/layout experiments before production API is created.

The goal is **not** to freeze final public names.

---

## 2. Selected direction

The current leading model is:

    common-grid image
        =
    one primary RasterView!T
        +
    immutable image semantics
        +
    optional same-grid validity raster

Conceptually:

    Image owner / lease ?
        |
        +-- primary RasterLease!T
        +-- immutable semantic descriptor
        +-- optional validity RasterLease!ubyte
        |
        v
    ImageView!T
        |
        +-- primary RasterView!T
        +-- borrowed immutable semantics
        `-- optional validity RasterView!ubyte

Names remain provisional.

The critical point is architectural:

> `ImageView!T` is a semantic composition of existing raster capabilities, not
> a second raster storage system.

---

## 3. Core invariant

A first `ImageView!T` represents one **common logical 2D sampling grid**.

All primary semantic channels represented directly by the view:

- use one materialized sample type `T`;
- share one `RasterView!T`;
- share the same logical 2D grid;
- share the same resident region;
- map one-to-one to the logical planes of that raster view.

Therefore the first model deliberately does **not** natively represent:

- channels with different native sample types;
- channels with different native sampling rates;
- multi-resolution imagery products;
- unrelated source assets;
- implicit resampling relationships.

Those belong to the M1.6 imagery-product boundary.

---

## 4. Decision D1 — channel index equals raster plane index

For the first processing image abstraction:

    image channel i
        describes
    RasterView plane i

This is a strong simplification.

It means the semantic descriptor does not need another arbitrary channel-to-
plane remapping table.

### Why

`raster-d` already provides ordered logical planes independent of physical
layout.

For example, pixel-interleaved RGB can already appear logically as:

    plane 0 = R
    plane 1 = G
    plane 2 = B

even though all three planes address one shared physical byte stream with
different base offsets and a sample stride of 3.

Planar RGB can expose the same logical plane order while using three physical
resources.

The image layer therefore gains nothing by inserting another mapping.

### Consequence

The semantic descriptor must have exactly one channel descriptor for every
primary raster plane.

At validated construction:

    channelDescriptorCount == primaryRaster.planeCount

must hold.

### Deferred

A future channel-selection/reordering view may be useful.

It is not required for the first M1 contract.

If later required, it should be introduced by a concrete consumer rather than
built into every `ImageView`.

---

## 5. Decision D2 — physical layout remains invisible to image semantics

Image semantics must not distinguish:

- planar;
- pixel-interleaved;
- padded;
- negative-stride;
- arbitrary validated raster layout.

Those are already represented by `raster-d`.

Therefore these two images are semantically equivalent at the image layer:

    planar RGB

and:

    interleaved RGB

when their logical channel sequence and semantic descriptor are equivalent.

The image layer may eventually request execution fast paths, but it must not
encode physical layout into the semantic type system.

---

## 6. Decision D3 — descriptor semantics are immutable

Image semantics associated with a published view are immutable.

A view operation such as ROI must not mutate:

- channel identity;
- spectral metadata;
- stored-value interpretation;
- colour binding;
- alpha association;
- NoData policy.

This gives the desired relationship:

    root image view
        |
        +-- ROI A
        +-- ROI B
        `-- nested ROI
              |
              `-- all borrow the same semantic descriptor

Only the represented raster region changes.

### Why

Most image semantics are properties of the channel set, not of one requested
resident rectangle.

Copying or rebuilding descriptors for every ROI would add allocations and
create consistency risk without adding meaning.

---

## 7. Decision D4 — ImageView does not own pixel storage

The raster ownership rule remains unchanged:

    RasterLease!T
        retains pixel resources

    RasterView!T
        borrows pixel resources

An `ImageView!T` must not create an independent pixel owner.

The image layer may require a higher-level retained owner to keep:

- the primary `RasterLease!T`;
- immutable image metadata;
- an optional validity-mask lease;

alive together.

That higher-level owner is conceptually analogous to:

    ImageLease!T ?

but this name is not accepted yet.

The important semantic rule is:

> The higher image owner may retain raster leases, but it must not duplicate
> raster resource ownership semantics.

---

## 8. Decision D5 — semantic metadata has an owner distinct from the view

Arbitrary channel metadata cannot safely be assumed to fit inline inside a
small view.

Examples include:

- arbitrary channel names;
- spectral metadata;
- units;
- optional colour profile identity;
- multiple colour bindings;
- per-channel NoData/value semantics.

Therefore M1 should assume:

    immutable semantic metadata owner
        |
        v
    borrowed semantic descriptor
        |
        v
    ImageView

The exact ownership mechanism remains an implementation decision.

Possible later implementations include:

- metadata stored inside a retained image owner;
- immutable reference-counted metadata;
- another lifetime-safe retained block.

M1 does not require choosing between them yet.

### Required property

Creating an ROI must not allocate or clone semantic metadata.

---

## 9. Decision D6 — intrinsic channel semantics and colour binding are separate

A channel descriptor describes the channel itself.

Colour binding describes how a set of channels participate in a colour tuple.

These are not the same concept.

### Example: remote sensing

Intrinsic channels:

    B08 = near infrared
    B04 = red spectral band
    B03 = green spectral band

A false-colour presentation may define:

    display R <- B08
    display G <- B04
    display B <- B03

The source channel identities do not change.

### Example: ordinary RGB

Channels may simply be:

    channel 0
    channel 1
    channel 2

with a colour binding declaring:

    red   <- channel 0
    green <- channel 1
    blue  <- channel 2
    encoding = sRGB

This avoids requiring the channel descriptor itself to encode all colour-space
semantics.

---

## 10. Channel descriptor contract

The exact D fields remain undecided.

Semantically, a channel descriptor must be able to preserve:

### 10.1 Identity

At minimum:

- optional interoperable/source name;
- unknown/custom identity without data loss.

Examples:

    R
    G
    B
    A
    Z
    B08
    velocity.x
    custom_vendor_channel

A name must not automatically imply a standardized semantic role.

### 10.2 Intrinsic semantic information

When known, a channel may describe intrinsic meaning such as:

- spectral band identity;
- depth;
- classification;
- measurement quantity;
- custom/unknown.

The design must not require all channels to fit a closed enum.

### 10.3 Stored-value interpretation

A channel may carry stored-value interpretation such as:

    physical = stored * scale + offset

with optional:

- unit;
- quantity semantics;
- stored NoData.

### 10.4 Extensibility

Unknown metadata must not be converted into a false standardized meaning.

The general rule remains:

> Preserve unknown semantics without pretending to understand them.

---

## 11. Colour binding contract

Colour semantics apply to an explicit ordered subset of channels.

Conceptually:

    ColourBinding
        component channels:
            R -> channel i
            G -> channel j
            B -> channel k

        encoding:
            image colour-encoding descriptor

The exact representation is open.

### Required properties

A colour binding must:

- refer only to valid primary channel indices;
- preserve component order explicitly;
- not infer RGB from channel count;
- not infer RGB from names alone;
- permit grayscale/one-component colour models;
- permit no colour binding at all;
- preserve metadata that current `color-d` cannot yet interpret.

### Cardinality

M1 does not need to freeze whether one image may carry exactly one or multiple
colour bindings.

However, the internal model must not make multiple bindings impossible.

OpenEXR-style auxiliary colour groups are one reason to avoid a hard one-only
assumption.

---

## 12. Alpha contract

Alpha is a relationship, not merely another unnamed channel.

Conceptually:

    AlphaBinding
        channel = i
        association =
            straight
            premultiplied
            unknown

Potentially the binding is associated with one colour tuple.

### Required rules

- alpha channel identity is explicit;
- straight and premultiplied are distinct;
- unknown association is representable;
- alpha must not be inferred from four-channel shape;
- alpha must not be silently reinterpreted as validity;
- codec/source convention must survive a round trip when known.

Examples:

    PNG
        straight / unassociated

    TIFF
        may explicitly encode associated or unassociated alpha

    OpenEXR
        conventionally premultiplied

The mathematical implementation of alpha/compositing belongs to `color-d`
when that dependency becomes appropriate.

---

## 13. Validity is separate from alpha

The first contract keeps these distinct:

    alpha
        compositing / coverage semantics

    validity mask
        whether a sample/pixel is usable as data

    NoData
        semantic convention identifying missing data

    quality/classification
        additional domain information

An adapter may explicitly derive one from another for a specific operation.

The core must not silently equate them.

---

## 14. Decision D7 — normalized validity raster is separate from primary data

The strongest current M1 candidate for explicit validity is:

    primary image:
        RasterView!T

    optional validity:
        RasterView!ubyte

The validity raster:

- shares the same logical 2D grid;
- is separate from alpha;
- may contain one or more logical mask planes;
- uses `0` for invalid;
- uses non-zero for valid;
- may conventionally use `255` for fully valid.

This closely follows the established GDAL mask model.

GDAL represents masks as `UInt8` raster bands with zero meaning invalid and
non-zero meaning valid, usually 255 for valid samples.

### Why fixed `ubyte`

A fixed processing representation avoids making every image operation generic
over both:

    T
    MaskT

It also handles the important case:

    image data = float
    validity   = byte/bit source

without making primary `ImageView!T` heterogeneous.

### Source representation

A codec/source may store validity as:

- one bit per pixel;
- packed flags;
- byte mask;
- generated NoData mask;
- some other representation.

The source adapter may normalize that representation into a streamed
`RasterView!ubyte` validity view.

This is a processing representation, not a claim about original file storage.

### Memory concern

A byte mask costs one byte per resident sample.

Because `raster-d` is region/stream oriented, this does not require a full
logical-image mask to reside in memory.

If benchmarks later show a compelling need for packed masks in hot processing,
that becomes a separate optimization question.

---

## 15. Validity-mask plane binding

The first contract should support at least:

    no explicit mask

    one dataset/image-wide mask plane

    per-channel mask planes

A separate validity raster can represent both shared and per-channel validity
because it may itself have multiple logical planes.

Conceptually:

    primary channels:
        0  R
        1  G
        2  B

    validity planes:
        0  shared RGB validity

or:

    validity planes:
        0  validity for R
        1  validity for G
        2  validity for B

The semantic descriptor defines which validity plane applies to which primary
channel or channel group.

The exact binding structure remains open.

---

## 16. Same-grid requirement for validity

An attached validity raster must describe the same processing grid as the
primary image view.

At construction/ROI time:

    primary.width  == validity.width
    primary.height == validity.height

and their represented local coordinate origin must be aligned.

No implicit resampling or offset correction occurs inside `ImageView`.

If a source mask is on another grid, it must be explicitly transformed before
it becomes the validity attachment of a common-grid image view.

---

## 17. NoData remains metadata, not mandatory materialized mask

A NoData sentinel does not require immediate creation of a validity raster.

For example:

    channel 0:
        stored NoData = -9999

may remain a stored-value semantic policy.

An operation may:

- test the sentinel directly;
- request/materialize a normalized validity mask;
- propagate NoData according to operation-specific semantics.

Therefore:

    NoData metadata
        !=
    always-materialized mask

This avoids unnecessary mask allocation for operations that can cheaply process
the stored convention directly.

---

## 18. Tuple/pixel-level NoData

Some datasets define validity over a tuple of channel values rather than one
independent sentinel per channel.

M1 must preserve that possibility.

Conceptually:

    pixel invalid when:
        channel 0 == a
        AND channel 1 == b
        AND channel 2 == c

This is not representable as three unrelated per-channel sentinels.

The semantic descriptor must therefore distinguish:

- per-channel NoData;
- tuple/image-level NoData;
- explicit validity mask.

Exact API remains open.

---

## 19. Decision D8 — no implicit normalization

The first image view stores the actual materialized raster sample type `T`.

Creating an `ImageView!ubyte` does not silently turn:

    0..255

into:

    0.0..1.0

Likewise:

    uint16 reflectance DN

does not silently become physical reflectance.

Scale/offset/normalization are semantic transforms.

They must be explicit at operation/materialization boundaries.

This preserves the distinction between:

    generic raster type conversion
    radiometric decoding
    colour encoding conversion
    presentation transform

---

## 20. Decision D9 — no implicit clipping

Image semantics do not imply that floating-point data lie in `[0,1]`.

Valid examples include:

- scene-linear HDR;
- intermediate colour transformations;
- radiometric data;
- negative/out-of-gamut colour intermediates.

Therefore:

> `ImageView!float` must never imply normalized or display-bounded values.

Any clipping or gamut operation is explicit.

---

## 21. Decision D10 — global placement is not part of the first resident ImageView

`raster-d` deliberately distinguishes:

    logical/global dataset placement
        !=
    resident RasterView region

M1 preserves that boundary.

The first `ImageView!T` describes a resident/common-grid processing view.

It does not reinterpret `RasterView.region` as global imagery coordinates.

Higher-level product/source/task metadata may associate the resident image view
with global placement.

This avoids privately recreating a generic logical-raster coordinate model in
`imagery-d`.

---

## 22. Conceptual lifetime model

A useful conceptual model is:

    retained image owner
        |
        +-- owns/retains primary RasterLease!T
        +-- owns immutable semantic metadata
        +-- optionally retains validity RasterLease!ubyte
        |
        +-----------------------------+
        |                             |
        v                             v
    ImageView!T                   ImageView ROI
        |                             |
        +-- RasterView!T              +-- RasterView!T ROI
        +-- metadata borrow            +-- same metadata borrow
        `-- validity view?             `-- validity ROI?

The owner name is intentionally not frozen.

### Required lifetime invariants

1. `ImageView` does not outlive its primary raster lease.
2. `ImageView` does not outlive semantic metadata.
3. If validity is attached, it does not outlive the validity raster lease.
4. ROI preserves all three relations.
5. ROI does not allocate pixel or semantic metadata.
6. Copying a view does not independently retain physical resources unless the
   final API deliberately chooses retained view semantics.

The preferred direction remains lease-bound borrowing, matching `raster-d`.

---

## 23. ROI contract

For:

    image.tryRoi(relativeRegion)

success requires the requested region to be contained in the primary raster
view.

If explicit validity is attached, the same relative ROI is applied to the
validity raster.

Result:

    child.primary
        = parent.primary.tryRoi(region)

    child.validity
        = parent.validity.tryRoi(region), if present

    child.semantics
        = parent.semantics

No channel metadata changes.

No colour binding changes.

No alpha association changes.

No scale/offset changes.

No implicit coordinate-system reinterpretation occurs.

---

## 24. Empty regions

The underlying `raster-d` model permits empty regions.

M1 should not invent a contradictory image-level prohibition without a concrete
consumer reason.

Therefore an empty `ImageView` may be valid if:

- the primary raster view is valid;
- any attached validity view represents the corresponding empty region;
- semantic descriptors remain structurally valid.

Individual image operations may reject empty inputs if their contract requires
non-empty data.

---

## 25. Writable capability

Writable image semantics are not required to freeze M1.5.

The eventual direction should mirror `raster-d`:

    read-only image view
        wraps read-only RasterView

    writable image view
        wraps WritableRasterView

Writability must not imply:

- uniqueness;
- non-aliasing;
- thread exclusivity;
- semantic descriptor mutability.

Semantic metadata should normally remain immutable even when samples are
writable.

Operations that change channel meaning should produce/update a new validated
semantic description rather than mutate shared metadata casually.

---

## 26. Packed pixel types

`raster-d` may represent POD aggregate sample types.

M1 does not need to forbid that.

However, the first image contract does not automatically decompose one aggregate
sample into semantic colour channels.

If:

    RasterView!PackedRGB

has one logical raster plane, then M1 sees one raster plane unless an explicit
adapter exposes the components as logical planes.

For ordinary interleaved RGB byte storage, the preferred raster representation
is already:

    RasterView!ubyte
        plane 0 = R byte stream
        plane 1 = G byte stream
        plane 2 = B byte stream

using strides.

Therefore packed aggregate pixels are not required to solve common RGB/RGBA
storage.

---

## 27. Construction validation

Before publishing a common-grid image view, validation should establish at
least:

### Primary raster

- primary `RasterView!T` is already valid according to `raster-d`;
- plane count is positive unless a future explicit zero-channel object is
  justified.

### Channel semantics

- descriptor count equals primary plane count;
- every channel descriptor corresponds to exactly one primary plane;
- all channel references are in range;
- unknown/custom channel meaning is permitted.

### Colour bindings

- all referenced channel indices are valid;
- component ordering is explicit;
- no encoding is inferred from channel count;
- unsupported colour metadata can be preserved.

### Alpha

- alpha channel reference is valid;
- alpha association is explicit when known;
- alpha is not silently treated as validity.

### Validity

If an explicit validity raster exists:

- it is a valid `RasterView!ubyte`;
- it represents the same local 2D region/grid as the primary view;
- every validity binding references an existing mask plane;
- zero means invalid;
- non-zero means valid.

### NoData

- stored NoData policies reference valid channels;
- tuple-level policies reference valid channel sets;
- NoData is not automatically converted to alpha.

### General

- no construction step performs implicit resampling;
- no construction step performs implicit colour conversion;
- no construction step performs implicit radiometric normalization;
- no construction step performs implicit clipping.

---

## 28. Consumer case C1 — interleaved sRGB RGB

Input storage:

    RGBRGBRGB...

Raster layer:

    RasterView!ubyte
        plane 0: R stream, sampleStride 3
        plane 1: G stream, sampleStride 3
        plane 2: B stream, sampleStride 3

Image semantics:

    3 channel descriptors
    colour binding:
        R -> 0
        G -> 1
        B -> 2
        encoding -> sRGB metadata

Validity:

    none

Result:

**PASS.**

No image-level interleaving type is required.

---

## 29. Consumer case C2 — planar RGBA

Raster layer:

    RasterView!ushort
        plane 0 R
        plane 1 G
        plane 2 B
        plane 3 A

Image semantics:

    colour binding RGB -> 0,1,2
    alpha channel -> 3
    association -> straight or premultiplied

Result:

**PASS.**

Physical planar storage remains invisible above `raster-d`.

---

## 30. Consumer case C3 — grayscale + explicit validity

Primary:

    RasterView!float
        plane 0 = grayscale/measurement

Validity:

    RasterView!ubyte
        plane 0 = shared validity

Binding:

    mask plane 0 applies to primary channel 0

Result:

**PASS.**

This is the main reason to allow a fixed-type validity sidecar rather than
requiring every image plane to have the same semantic purpose.

---

## 31. Consumer case C4 — scaled NIR band

Primary:

    RasterView!ushort
        plane 0 = B08 / NIR

Channel semantics:

    name
    spectral identity
    optional wavelength metadata
    scale
    offset
    unit
    optional stored NoData

Colour binding:

    none required

Result:

**PASS.**

A valid image channel need not be a display colour component.

---

## 32. Consumer case C5 — common-grid multispectral image

Primary:

    RasterView!ushort
        N logical planes
        one common grid

Each plane receives one semantic channel descriptor.

Colour binding may be absent.

A presentation may later select bands for RGB.

Result:

**PASS.**

---

## 33. Consumer case C6 — arbitrary/custom channels

Channel:

    name = vendor/application identifier
    standardized meaning = unknown

The view preserves it without inventing a role.

Result:

**PASS.**

---

## 34. Consumer case C7 — ROI / streamed resident region

Parent:

    primary RasterView region
    optional validity region
    immutable semantics

Child:

    primary ROI
    matching validity ROI
    same semantic descriptor

Result:

**PASS**, provided a D lifetime experiment verifies the intended borrow graph.

---

## 35. Consumer case C8 — alpha round trip

Two otherwise identical four-channel images:

    image A:
        alpha = straight

    image B:
        alpha = premultiplied

The image descriptor retains the difference.

Result:

**PASS.**

---

## 36. Consumer case C9 — heterogeneous OpenEXR channel types

Example:

    R,G,B,A = HALF
    Z       = FLOAT
    ID      = UINT

One `ImageView!T` cannot preserve all native sample types.

Result:

**EXPECTED NON-FIT.**

This is not a failure of the common-grid image view.

A future product/file description may bind several processing views, or an
explicit conversion may materialize a common type.

No `raster-d` change is required.

---

## 37. Consumer case C10 — OpenEXR subsampled chroma

Example:

    Y  sampling 1x1
    RY sampling 2x2
    BY sampling 2x2

The channels do not share one native grid.

Result:

**EXPECTED NON-FIT.**

Explicit resampling/materialization is required before they become one
common-grid `ImageView`.

---

## 38. Consumer case C11 — Sentinel-2 native resolutions

Example:

    B02 10 m
    B05 20 m
    B01 60 m

Result:

**EXPECTED NON-FIT.**

These belong to a broader imagery product until an explicit common-grid
resampling step occurs.

---

## 39. Consumer case C12 — false-colour composite

Source:

    NIR
    Red
    Green

Presentation:

    display R <- NIR
    display G <- Red
    display B <- Green

The source channel descriptors remain unchanged.

A presentation operation may produce:

- a new materialized RGB `ImageView`;
- or a higher-level presentation binding.

Result:

**PASS.**

Intrinsic band identity and display mapping remain separate.

---

## 40. Consumer case C13 — TIFF associated vs PNG straight alpha

Both may materialize into the same primary raster shape:

    RasterView!ubyte with 4 planes

The semantic descriptor differs:

    TIFF image:
        association = associated/premultiplied

    PNG image:
        association = straight

Result:

**PASS.**

Storage shape does not erase alpha semantics.

---

## 41. Consumer case C14 — float image + byte/bit source validity

Primary:

    RasterView!float

Source mask:

    bit-packed / byte / generated from NoData

Processing validity:

    RasterView!ubyte

Result:

**PASS**, after explicit source normalization when needed.

This avoids introducing:

    ImageView!(T, MaskT)

into every operation.

---

## 42. Consumer case C15 — scene-linear HDR

Primary:

    RasterView!float

Colour binding:

    scene-linear/linear-light metadata

Samples may contain:

    values > 1
    potentially valid negative intermediates

No automatic clipping occurs.

Result:

**PASS.**

---

## 43. Consumer case C16 — point versus area sampling

This semantic distinction is relevant to images, DEMs and scientific grids.

The first resident `ImageView` does not claim ownership of it.

Result:

**DEFERRED BY BOUNDARY.**

The information may be preserved by higher-level source/product/geospatial
metadata until a generic ownership decision is justified.

---

## 44. Operations and semantic propagation

Every image-domain operation must explicitly define how semantics propagate.

Examples:

### ROI

    preserve descriptor unchanged

### Pure sample copy

    preserve descriptor unchanged

### Exact storage conversion

    may preserve channel identity
    must update stored-value representation semantics

### Radiometric decode

    preserve channel identity
    update value interpretation
    usually remove consumed scale/offset

### Colour-space conversion

    preserve non-colour channels as defined by the operation
    update colour binding/encoding
    preserve or explicitly transform alpha correctly

### False-colour composition

    do not mutate source descriptors
    create a new output colour binding/image

### Resampling

    preserve intrinsic channel meaning
    update grid-related higher metadata explicitly
    never happen implicitly during ImageView construction

### Channel removal/reordering

    requires a new validated semantic descriptor
    not part of plain ROI

---

## 45. Semantic descriptor must not become a metadata dump

The semantic descriptor should contain information needed to interpret and
process the current image.

It should not automatically absorb all:

- file-format tags;
- EXIF;
- acquisition provenance;
- arbitrary source metadata;
- catalog metadata;
- product relationships.

Those may exist in higher source/asset/product objects.

This keeps the hot processing abstraction small enough to reason about.

---

## 46. Relationship to color-d

M1.5 remains independent of unstable `color-d` public names.

The image descriptor may state:

    selected channels form a colour tuple
    with colour encoding metadata X

A later execution adapter may create `color-d` values or call `color-d`
operations.

This preserves the M1.3 boundary:

    imagery-d
        owns channel-to-colour binding

    color-d
        owns general colour mathematics

---

## 47. Relationship to raster-d

M1.5 does not request new raster storage primitives.

It directly reuses:

- `RasterLease!T`;
- `RasterView!T`;
- `WritableRasterView!T` later;
- `Region2D`;
- multi-plane representation;
- signed strides;
- ROI;
- generic raster execution.

The optional validity sidecar is itself another ordinary raster view.

This is composition, not duplication.

---

## 48. Non-goals

The first common-grid image view does not attempt to solve:

- image codecs;
- source/provider API;
- arbitrary multi-asset products;
- mixed sample types in one primary view;
- different native channel resolutions;
- CRS transformation;
- georeferencing core;
- pyramid ownership;
- mosaic ownership;
- GPU textures;
- full ICC colour management;
- final presentation/rendering;
- channel-selection view API;
- final writable image API;
- public API stabilization.

---

## 49. Required D experiment before promotion

Before this model can be promoted, a focused D experiment should verify the
lifetime and allocation assumptions.

Suggested research experiment:

    experiments/m1_5_image_view_contract/

It should model only enough types to prove the contract.

### E1 — metadata lifetime

Verify that an image view cannot escape the semantic metadata owner.

### E2 — primary raster lifetime

Verify that the image view cannot escape the primary raster lease.

### E3 — validity lifetime

When validity is attached, verify that the image view cannot escape the
validity raster lease.

### E4 — ROI

Verify nested ROI remains valid while all owners live and cannot escape them.

### E5 — no semantic allocation on ROI

Demonstrate that ROI changes raster-region values only and shares semantic
metadata.

### E6 — no mask allocation on mask-free image

The optional validity path must have zero resident-mask cost when unused.

### E7 — descriptor/channel validation

Reject mismatched channel-descriptor and plane counts.

### E8 — validity-grid validation

Reject primary/validity extent mismatch.

### E9 — DMD/LDC

Compile all positive and negative lifetime probes with the workspace-supported
DMD and LDC toolchains.

This should remain research code until M1 closes.

---

## 50. Provisional conceptual shape

The following is **pseudocode**, not a proposed final D API:

    ImageOwner!T
    {
        primaryRasterLease
        immutableSemantics
        optionalValidityLease
    }

    ImageView!T
    {
        primaryRasterView
        borrowedSemantics
        optionalValidityView
    }

    ImageSemantics
    {
        channelDescriptors[]
        colourBindings[]
        alphaBindings[]
        validityBindings[]
        storedValuePolicies[]
    }

The final implementation may collapse or rename these concepts.

What must survive is the separation of responsibilities.

---

## 51. M1.5 acceptance invariants

The model should not be promoted unless all of the following remain true:

1. One primary `ImageView!T` has one common logical 2D grid.

2. Primary channel `i` describes primary raster plane `i`.

3. Physical planar/interleaved layout remains entirely a `raster-d` concern.

4. The view does not own pixel storage.

5. Semantic metadata is immutable for the lifetime of published views.

6. ROI shares semantics without cloning them.

7. Arbitrary/custom channels are preservable.

8. Colour binding is explicit and independent of channel count/name guessing.

9. Alpha channel and alpha association are explicit.

10. Alpha, validity mask and NoData remain distinct.

11. Explicit validity may use a separate same-grid `RasterView!ubyte`.

12. A validity source may be normalized to the byte-mask processing form.

13. NoData does not force eager mask materialization.

14. Stored values are not implicitly normalized.

15. Floating-point values are not implicitly clipped.

16. Heterogeneous channel types are not forced into one `ImageView!T`.

17. Different native channel grids are not forced into one `ImageView!T`.

18. Resampling is never implicit.

19. Global logical placement is not confused with resident raster coordinates.

20. No current `color-d` public API is required to construct a valid image view.

---

## 52. Remaining M1.5 open questions

The semantic direction is now narrow enough that only a few implementation
questions remain.

### Q1 — exact semantic-owner representation

Need D lifetime experiment.

### Q2 — validity binding cardinality

The contract should support shared and per-channel masks, but the final compact
representation is not chosen.

### Q3 — NoData representation

Need a precise typed representation for:

- integer sentinels;
- floating sentinels;
- NaN-based policy;
- tuple-level NoData.

### Q4 — colour-binding cardinality

One or multiple bindings should be tested against real OpenEXR-style cases
before freezing.

### Q5 — metadata allocation strategy

Construction-time allocation is acceptable if it is not repeated in hot
region/ROI processing.

This should be measured rather than assumed.

---

## 53. M1.5 conclusion

The first useful `imagery-d` processing abstraction can remain substantially
smaller than a universal image/product container.

The strongest current contract is:

    ImageView!T
        =
    one common-grid RasterView!T
        +
    one immutable semantic description of those planes
        +
    optional same-grid UInt8 validity raster

with a higher retained owner keeping the required raster leases and semantic
metadata alive.

This model solves ordinary RGB/RGBA, radiometric single/multiband imagery,
streaming ROI, explicit alpha, NoData and a different-type validity mask without
duplicating `raster-d` or depending prematurely on `color-d`.

It deliberately rejects heterogeneous native channel types and multi-resolution
products as one `ImageView`.

Those are product-level concerns.

The next action should be a **small lifetime/contract experiment**, not
production `source/imagery` implementation.
