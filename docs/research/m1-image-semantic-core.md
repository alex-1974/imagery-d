# M1 — Image Semantic Core Research

**Project:** `imagery-d`
**Branch:** `research/m1-image-semantic-core`
**Status:** Research draft — not an accepted public API or implementation contract
**Date:** 2026-09-22

## 1. Purpose

M1 researches the smallest useful image-domain abstraction above `raster-d`.

The immediate goal is not to design a convenient image API by intuition. The goal
is to establish semantic boundaries that remain valid for:

- ordinary RGB/RGBA images;
- grayscale images;
- high-dynamic-range imagery;
- remote-sensing and multispectral imagery;
- alpha and compositing;
- masks and NoData;
- planar and interleaved storage;
- cropped and streamed regions;
- later mosaics, pyramids and image-processing operations.

No production `source/imagery` tree, DUB package, public type, or dependency is
admitted by this document.

## 2. Existing project constraints

The current project architecture already establishes:

- `imagery-d` is a higher-level consumer of `raster-d`;
- generic raster representation, ownership, views, layout, regions, dependency
  mechanics and generic execution stay in `raster-d`;
- imagery-specific semantics and processing belong above that boundary;
- research findings must be deliberately promoted before implementation;
- M1 must resolve image/pixel/channel semantics, pixel-format policy,
  alpha/mask/NoData semantics and the colour-metadata boundary before a public
  image type is admitted.

The shared workspace engineering rule is also applicable: define the semantic
contract before implementation details.

## 3. Verified `raster-d` boundary

Current `raster-d` provides a representation-safe raster foundation.

Relevant verified properties include:

- `RasterView!T` exposes one or more logical planes over a resident `Region2D`;
- plane order is logical band order;
- physical plane descriptors and execution layout remain internal;
- logical planes can represent both planar and interleaved physical storage;
- a plane can have arbitrary validated signed row and sample strides;
- ROI construction reuses the same underlying descriptor block;
- `isRasterSampleType!T` is a representation-safety constraint only;
- POD pixel-like structs are allowed as raster samples, but `raster-d`
  explicitly assigns them no pixel-format, colour or radiometric semantics.

This is an important boundary result:

> `imagery-d` does not need to encode planar versus interleaved storage in its
> image semantics merely to represent RGB or other multi-channel imagery.

For example, three logical `RasterView!ubyte` planes can already address the R,
G and B components of one physically interleaved byte stream by using distinct
plane origins and a sample stride of three.

Therefore physical pixel packing and semantic pixel meaning should be treated
as separate questions.

## 4. Terminology under research

The following terms are deliberately separated for M1.

### 4.1 Sample

One stored raster element interpreted as D type `T`.

A sample is a storage-level value. By itself it does not imply:

- a colour component;
- a physical measurement;
- a display value;
- a validity state;
- a spectral wavelength;
- alpha.

Ownership: `raster-d`.

### 4.2 Plane

One logical two-dimensional raster sample field in `RasterView`.

A plane is a logical raster-storage concept. Its imagery meaning is supplied by
a higher layer.

Ownership: `raster-d` for representation; `imagery-d` for image-domain meaning.

### 4.3 Channel / band

A semantically identified image component represented by raster data.

Examples include:

- red;
- green;
- blue;
- luminance / grayscale;
- alpha / opacity;
- depth;
- near infrared;
- short-wave infrared;
- thermal bands;
- quality fields;
- custom scientific or application channels.

A channel or band must not be defined solely by its ordinal position.

Working rule:

> Channel meaning is metadata over raster representation, not raster layout.

### 4.4 Pixel

For M1, a pixel is provisionally a logical association of channel values at a
common image coordinate.

It is not assumed to be:

- a physical packed struct;
- contiguous in memory;
- represented by one raster sample;
- limited to RGB/RGBA;
- identical to one provider-format pixel encoding.

This definition remains subject to research, especially for:

- sub-sampled channels;
- spectral bands with differing resolutions;
- deep data;
- masks with different sampling;
- imagery products whose bands are separate assets.

### 4.5 Stored value

The value physically represented by the raster sample.

Examples:

- `ubyte` value 173;
- `ushort` DN 8342;
- binary16 / binary32 radiometric sample.

### 4.6 Decoded / physical value

A value obtained from a stored value by a defined transform such as:

```text
physical = scale * stored + offset
```

Examples include reflectance, radiance, temperature, height or another measured
quantity.

This transform is semantically distinct from colour-space conversion and
display adjustment.

### 4.7 Colour interpretation

The interpretation of one or more channels as colour values under a defined
colour encoding / colour space.

This is distinct from:

- physical storage layout;
- remote-sensing band identity;
- radiometric scale/offset;
- display presentation.

### 4.8 Presentation transform

A non-destructive transformation intended for display or interactive viewing,
for example:

- exposure;
- brightness;
- contrast;
- display gamma / transfer;
- saturation;
- tone mapping;
- opacity in a UI layer.

Presentation must not silently redefine the stored or radiometric data model.

## 5. Preliminary semantic stack

The current research supports the following conceptual layering:

```text
presentation / rendering intent
            |
            v
colour interpretation / colour encoding
            |
            v
channel / band meaning
            |
            v
decoded or physical value semantics
            |
            v
stored raster sample
            |
            v
raster-d layout / ownership / region / execution
```

Not every image needs every layer.

Examples:

### Ordinary PNG RGB image

```text
presentation
    |
sRGB-like colour encoding
    |
R / G / B channels
    |
integer normalized colour code values
    |
8- or 16-bit stored samples
```

### Multispectral satellite band

```text
optional visual presentation
    |
optional false-colour mapping
    |
NIR spectral band semantics
    |
reflectance or radiance
    |
scale * DN + offset
    |
stored integer sample
```

The second example demonstrates why a single closed `PixelFormat` enum is
unlikely to be a sufficient semantic foundation.

## 6. Reference-system findings

### 6.1 Halide

Halide's `Buffer` / `halide_buffer_t` is primarily a typed multidimensional
buffer representation.

It explicitly models:

- element type;
- dimensions;
- extents;
- minima;
- strides;
- host/device storage.

It can represent interleaved RGB by storage order, but this does not make RGB a
fundamental buffer semantic.

**M1 lesson:** layout and element representation can remain below image meaning.
This broadly supports the existing `raster-d` separation.

Primary references:

- https://halide-lang.org/docs/api/generated/Runtime_Buffer.html
- https://halide-lang.org/docs/structhalide__buffer__t.html

### 6.2 OpenImageIO

OpenImageIO `ImageSpec` combines image dimensions and data format with richer
image description:

- channel count;
- channel names;
- explicitly designated alpha and depth channels;
- arbitrary metadata;
- colour-space metadata such as `oiio:ColorSpace`.

OpenImageIO also documents colour-space metadata separately from alpha/depth:
colour transforms apply to colour channels, not automatically to alpha or depth.

**M1 lessons:**

- channel names and special roles are semantic metadata above sample storage;
- special channel roles need not be inferred only from names;
- colour interpretation should target colour channels rather than all channels;
- extensible metadata is necessary for format interoperability, though
  `imagery-d` should avoid making untyped metadata the core semantic model.

Primary references:

- https://openimageio.readthedocs.io/en/main/imageioapi.html
- https://openimageio.readthedocs.io/en/latest/stdmetadata.html

### 6.3 OpenEXR

OpenEXR supports an arbitrary number and combination of named image channels.
Each channel has:

- a name;
- a data type;
- x/y sampling rates.

Certain conventional names such as `R`, `G`, `B`, `A` and `Z` carry established
meanings, but arbitrary channels are first-class.

OpenEXR conventionally stores colour channels premultiplied by alpha.

**M1 lessons:**

- a closed RGB(A)-only channel enum is insufficient;
- custom channels must remain representable;
- channel role and channel name are related but not identical concepts;
- per-channel sampling cannot be ruled out by the semantic architecture;
- alpha association is part of image semantics and cannot be guessed from the
  mere presence of an alpha channel.

Primary reference:

- https://openexr.com/en/latest/TechnicalIntroduction.html

### 6.4 GDAL

GDAL's raster model distinguishes several per-band concepts:

- sample data type;
- optional NoData value;
- optional mask band;
- optional scale and offset;
- optional unit;
- colour interpretation;
- categories/statistics and other metadata.

GDAL also allows dataset-level tuple-style NoData metadata.

**M1 lessons:**

- NoData and masks are related validity mechanisms but not identical;
- validity is distinct from alpha/transparency;
- stored value and meaningful value may differ by scale/offset;
- units belong with interpreted physical values, not raw storage alone;
- colour interpretation is metadata over a raster band, not raster layout.

Primary reference:

- https://gdal.org/en/stable/user/raster_data_model.html

### 6.5 PNG

PNG defines alpha as unassociated / non-premultiplied. Colour samples are not
stored multiplied by alpha.

**M1 lesson:** `hasAlpha == true` is semantically incomplete. Alpha association
must be known or explicitly unknown when compositing correctness depends on it.

Primary reference:

- https://www.w3.org/TR/png-3/

### 6.6 STAC EO and Raster extensions

STAC separates spectral-band description from raster-value interpretation.

EO metadata includes concepts such as:

- common band name, e.g. red or NIR;
- center wavelength;
- full width at half maximum;
- solar illumination.

Raster metadata includes:

- data type;
- NoData;
- units;
- scale;
- offset;
- spatial resolution;
- statistics.

The Raster extension explicitly describes scale/offset as a transform from
stored Digital Numbers to another value such as reflectance or radiance.

**M1 lessons:**

- spectral identity is not merely a colour-channel role;
- remote-sensing band semantics require an extensible model;
- scale/offset belongs between stored samples and physical/radiometric values;
- imagery metadata may be distributed across assets rather than packed in one
  interleaved image.

Primary references:

- https://github.com/stac-extensions/eo
- https://github.com/stac-extensions/raster

### 6.7 ICC

ICC profiles are a colour-management architecture connecting colour encodings.
Current ICC v4 and iccMAX are substantially broader than a small colour-value
math library.

**M1 lesson:** `imagery-d` should be able to preserve or reference external
colour-profile metadata without requiring M1 to implement a full colour
management system.

Primary reference:

- https://www.color.org/icc_specs2/

## 7. `raster-d` ↔ `imagery-d` responsibility matrix

| Concern | `raster-d` | `imagery-d` |
|---|---|---|
| sample representation safety | owns | consumes |
| planes / logical band storage | owns | annotates |
| strides / interleaving | owns | must not duplicate |
| ownership / leases / borrowing | owns | consumes |
| ROI / resident regions | owns | consumes |
| generic copy / conversion | owns | reuses where semantically valid |
| generic halo mechanics | owns | declares image-operation requirements |
| channel / band role | no | owns |
| pixel meaning | no | owns/researches |
| alpha semantics | no | owns |
| validity mask meaning | no | owns |
| NoData meaning | no | owns |
| radiometric scale/offset | no | owns |
| physical unit / radiometric meaning | no | owns |
| spectral-band meaning | no | owns |
| image colour encoding metadata | no | owns/integrates |
| presentation transform semantics | no | owns/integrates |
| geospatial CRS machinery | no | no; external integration |
| image-specific geospatial metadata | no | owns/integrates |

Boundary rule remains:

> If a newly discovered primitive is equally natural for DEMs, scientific
> grids and other non-image rasters, it should be evaluated as a `raster-d`
> requirement rather than implemented locally for convenience.

## 8. Provisional `color-d` boundary

The local workspace contains a separate `color-d` project. Its exact current API
and accepted semantic contract have not yet been audited in this M1 branch, so
this section is a research hypothesis rather than a dependency decision.

Provisional separation:

### Candidate `color-d` responsibilities

General colour mathematics that is useful independently of raster imagery, for
example:

- colour-value types;
- colour-space coordinate conversion;
- transfer functions;
- perceptual colour models;
- colour difference;
- interpolation / mixing where generally defined;
- compositing mathematics if its abstraction is image-independent.

### Candidate `imagery-d` responsibilities

Application of colour semantics to image channels and raster data, for example:

- which channels form a colour tuple;
- which colour encoding describes those channels;
- mapping raster planes to colour components;
- interaction of colour channels with alpha, masks and NoData;
- image-wide / region-wide colour processing;
- streamed execution of transforms over `raster-d`;
- image metadata carrying an ICC profile or other colour description;
- presentation transforms and image-processing policy.

Required follow-up:

> Audit the current `color-d` research/design contract before deciding whether
> M1 introduces a compile-time dependency, an optional integration layer, or
> merely compatible semantic concepts.

## 9. Alpha, mask and NoData: preliminary separation

M1 should not collapse these concepts.

### Alpha

Represents opacity / coverage for compositing.

Required semantic questions include:

- associated / premultiplied?
- unassociated / straight?
- unknown association?
- one alpha channel for all colour components?
- per-component alpha ever required?
- normalized range and numeric interpretation?

### Validity mask

Represents whether a sample/pixel should participate in an operation or be
considered valid for some defined purpose.

A validity mask is not automatically opacity.

### NoData

Represents absence or invalidity through one or more encoded sample values or a
separate validity mechanism.

NoData raises questions that alpha does not:

- per-band versus pixel-tuple validity;
- NaN semantics;
- sentinel collision with valid values;
- scale/offset interaction;
- propagation through operations;
- resampling and filtering rules.

Working invariant:

```text
alpha != validity mask != NoData
```

Adapters may translate between them only under an explicit operation-specific
contract.

## 10. Pixel-format policy: current hypothesis

M1 should avoid making a monolithic `PixelFormat` enum the semantic foundation.

A type such as:

```text
RGB8
RGBA8
RGB16
RGBA16F
```

conflates several independent dimensions:

- channel roles;
- sample representation;
- numeric encoding;
- alpha presence;
- alpha association;
- colour encoding;
- sometimes storage packing/layout.

This may still be useful later as:

- a convenience descriptor;
- a codec interchange description;
- a fast-path classification;
- a predefined composition of lower-level semantic descriptors.

But it should be derivable from, or compatible with, a more orthogonal semantic
model.

## 11. Candidate image abstraction families

No candidate is accepted yet.

### Model A — Annotated RasterView

Conceptually:

```text
ImageView
    RasterView
    ImageDescriptor
```

The raster holds representation and the descriptor holds image semantics.

Advantages:

- strong reuse of `raster-d`;
- clean separation of data and meaning;
- cheap views possible;
- descriptor may be shared across ROIs.

Questions:

- lifetime of descriptor relative to raster lease;
- whether every ROI retains identical channel metadata;
- heterogeneous per-channel sample types are not directly represented by one
  `RasterView!T`;
- per-channel differing resolution/sampling may not fit one view.

### Model B — Channel-oriented ImageView

Conceptually:

```text
ImageView
    ChannelView[]
        raster plane/view reference
        ChannelDescriptor
    ImageDescriptor
```

Advantages:

- explicit channel semantics;
- heterogeneous channel metadata;
- could eventually accommodate channels from different source assets.

Risks:

- dynamic channel collections may add allocation/lifetime complexity;
- easy to accidentally rebuild raster ownership/layout abstractions;
- may complicate fast paths for common RGB data.

### Model C — Image descriptor plus raster bindings

Conceptually:

```text
ImageDescription
    ChannelDescription[]
    ColourDescription?
    ValidityDescription?
    ...

ImageBinding
    semantic channel -> raster plane/resource
```

Advantages:

- maximally separates semantics from storage;
- suitable for remote-sensing products assembled from several assets;
- descriptors could outlive any one resident region.

Risks:

- more concepts before evidence;
- may be excessive for the first useful image capability;
- requires careful avoidance of a general data-model framework.

### Current preference

Do not select A, B or C yet.

Instead, use concrete consumer cases to test which model is the smallest that
preserves required semantics without duplicating `raster-d`.

## 12. Required M1 consumer cases

Every candidate model should be tested against at least these cases.

### C1 — Interleaved 8-bit sRGB RGB

- one physical interleaved stream;
- three logical raster planes;
- R/G/B meaning;
- no alpha;
- ordinary colour image.

### C2 — Planar 16-bit RGBA

- separate physical planes;
- alpha present;
- explicit associated/unassociated state;
- colour metadata.

### C3 — Grayscale plus validity mask

- gray image channel;
- mask is validity, not opacity;
- ROI must preserve semantics.

### C4 — Integer remote-sensing band with scale/offset

- stored integer DN;
- scale and offset;
- physical unit;
- spectral meaning such as NIR;
- optional NoData.

### C5 — Multispectral product

- several bands;
- named/spectral descriptions;
- not all bands form a display colour image;
- false-colour presentation possible but not intrinsic.

### C6 — Custom channel image

- channel names unknown to `imagery-d`;
- semantics must not be destroyed merely because the core library has no enum
  value for them.

### C7 — Cropped / streamed region

- image semantics remain stable across `RasterView` ROI;
- no whole-image materialization;
- no semantic dependency on provider tiles or cache blocks.

### C8 — Alpha convention round trip

- decode PNG-style straight alpha;
- process without silently changing association;
- represent OpenEXR-style premultiplied alpha;
- conversion between conventions is explicit.

## 13. Preliminary invariants

These are research hypotheses to validate, not accepted API guarantees.

1. Physical layout must not determine semantic channel meaning.

2. A logical image channel must be identifiable independently of its physical
   plane address or interleaving.

3. Unknown/custom channel semantics must be preservable.

4. Alpha association must never be inferred solely from channel count.

5. Alpha, validity mask and NoData must remain distinct concepts.

6. Stored values and physical/radiometric values must be distinguishable.

7. Colour interpretation must apply only to the channels it semantically
   describes.

8. A spectral band must not be forced into a colour-channel abstraction.

9. Cropping/ROI must preserve image semantics without copying the underlying
   pixels merely to rebuild metadata.

10. No image abstraction may silently require whole-image residency.

11. No public image abstraction may expose `raster-d` internal execution
    machinery.

12. Convenience pixel formats must not prevent representation of imagery that
    does not fit their closed set.

## 14. Questions still open

### Q1 — What exactly is an `Image`?

Is an image:

- one raster plus semantic metadata;
- a set of channels sharing a coordinate domain;
- a product whose channels may come from separate rasters/assets;
- a view over a larger product?

M1 may need to distinguish `ImageView` from a broader future
`ImageryProduct`.

### Q2 — Must all channels share one sample type?

Current `RasterView!T` uses one `T`.

Common images often satisfy this, but OpenEXR and scientific products can have
heterogeneous channel types.

Possible outcomes:

- M1 initially requires homogeneous sample type;
- image description can represent heterogeneous source formats but materialized
  `ImageView!T` is homogeneous;
- a higher abstraction binds several raster views of different types.

Do not modify `raster-d` until a concrete consumer requirement proves that a
generic raster capability is missing.

### Q3 — Must all channels share resolution and sampling?

OpenEXR supports per-channel sampling. Remote-sensing bands may have different
spatial resolutions.

Possible separation:

- one `ImageView` requires a common sampling grid;
- a broader product groups several images/bands at differing grids.

This distinction may keep the first image abstraction small.

### Q4 — Channel role representation

Options include:

- closed enum;
- enum plus custom;
- typed role families;
- name plus optional standardized role;
- extensible identifiers.

A closed enum is currently disfavoured because it cannot preserve arbitrary
OpenEXR/scientific channels or evolving remote-sensing band definitions.

### Q5 — Where does colour metadata live?

Questions include:

- one colour description per image?
- subsets of channels may have different interpretation?
- profile/reference object versus value object?
- ICC blob preservation without interpreting it?
- dependency boundary with `color-d`?

### Q6 — How is validity represented?

Need to distinguish:

- per-band sentinel NoData;
- tuple NoData;
- explicit mask;
- per-pixel validity;
- operation-specific quality masks.

### Q7 — What is the smallest first consumer capability?

M3 candidates currently include colour/display transforms, normalization,
neighbourhood filtering and image-quality analysis.

M1 should prefer a semantic core sufficient for one independently useful
operation family rather than designing for every deferred feature.

## 15. Explicit non-goals for M1

M1 does not yet design or implement:

- codec APIs;
- GDAL bindings;
- GeoTIFF/COG readers;
- XYZ/WMTS/WMS sources;
- cache policy;
- scheduling;
- GPU APIs;
- image pyramids;
- mosaics;
- full ICC colour management;
- ML inference;
- segmentation;
- an all-purpose metadata framework;
- a replacement for `raster-d` regions or views.

## 16. Research sequence

### M1.1 — terminology and boundary audit

- validate terminology against `raster-d`;
- audit `color-d`;
- classify each semantic concept by owning library.

### M1.2 — reference-model matrix

Expand the current comparison with concrete capabilities and failure modes for:

- Halide;
- OpenImageIO;
- OpenEXR;
- GDAL;
- libvips;
- OpenCV;
- TIFF/GeoTIFF;
- PNG;
- STAC EO/Raster;
- relevant remote-sensing libraries.

### M1.3 — consumer-case modelling

Model C1–C8 without production code.

For each candidate abstraction record:

- representability;
- ambiguity;
- ownership/lifetime;
- allocation needs;
- ROI/streaming behaviour;
- compatibility with `raster-d`;
- compatibility with `color-d`.

### M1.4 — disposable D sketches

Only after the semantic comparison is stable, create non-production D sketches
under `experiments/` if necessary.

Sketches are evidence only.

### M1.5 — semantic synthesis

Select the smallest model that survives the consumer cases.

Deliverables:

- accepted terminology;
- boundary matrix;
- semantic invariants;
- rejected alternatives and reasons;
- proposed public concepts;
- correctness requirements;
- promotion recommendation.

### M1 exit gate

Do not create the production image API until:

1. `raster-d` ownership is unambiguous;
2. `color-d` ownership is audited;
3. alpha/mask/NoData semantics are explicit;
4. stored/radiometric/colour/presentation layers are explicit;
5. common RGB(A) and remote-sensing cases are representable;
6. unknown/custom channels can be preserved;
7. ROI/streaming semantics require no hidden full-image copy;
8. a concrete first operation family validates the usefulness of the model;
9. an ADR or equivalent accepted design record promotes the selected model.

## 17. Current conclusion

The evidence currently favours an image semantic layer that annotates or binds
logical raster planes rather than replacing raster representation.

The strongest provisional conclusions are:

```text
sample != channel
plane  != channel meaning
pixel  != packed storage struct
alpha  != mask
mask   != NoData
stored value != physical/radiometric value
spectral band != colour component
colour interpretation != presentation transform
```

The next decision should therefore not be “which `PixelFormat` enum do we
implement?” It should be:

> What is the smallest semantic description/binding model that can attach
> channel, value, validity and colour meaning to `raster-d` views while
> preserving arbitrary layout and remaining useful for both ordinary images
> and remote-sensing imagery?

That question remains open pending the `color-d` audit and concrete modelling
of the M1 consumer cases.
