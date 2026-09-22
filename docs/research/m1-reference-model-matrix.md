# M1.2 — Reference Model Matrix and Consumer-Case Evaluation

**Project:** `imagery-d`
**Branch:** `research/m1-image-semantic-core`
**Status:** Research evidence — not an accepted API or implementation contract
**Date:** 2026-09-22
**Parent research:** `docs/research/m1-image-semantic-core.md`

## 1. Purpose

This document expands M1.2 of the image-semantic-core research.

It compares mature image, raster, scientific-array and remote-sensing models against the current `imagery-d` boundary and evaluates the three provisional image-abstraction families from the parent M1 document:

```text
A  Annotated RasterView
B  Channel-oriented ImageView
C  Image description + raster bindings
```

The goal is not to copy an external API. The goal is to determine which semantic distinctions have survived in mature systems, which shortcuts create ambiguity, and which concepts are required by real consumers.

No public `imagery-d` type is admitted by this document.

`color-d` is an independent project. This research does not prescribe its API or roadmap and does not decide that `imagery-d` will depend on it.

## 2. High-level reference matrix

| System | Core data model | Channel semantics | Heterogeneous channel type | Different channel sampling/grid | Alpha model | Mask / NoData | Colour metadata | Region/lazy model |
|---|---|---|---|---|---|---|---|---|
| TIFF 6.0 | samples + TIFF fields | `PhotometricInterpretation` + `ExtraSamples` | per-component sample description | planar/chunky storage, not different image grids | associated and unassociated explicitly distinguished | transparency/mask concepts distinct from associated alpha | photometric/colorimetry tags | file-format concern |
| PNG 3 | rectangular reference image | fixed Gray/RGB(+A) or indexed semantics | constrained by image type | common grid | explicitly unassociated; linear opacity | transparency may also use `tRNS` | cICP/ICC/sRGB/chromaticity/gamma | streamable format |
| OpenEXR | arbitrary named channels | names + conventions + header attributes | yes | yes, x/y sampling per channel | colour conventionally premultiplied | arbitrary auxiliary channels | `colorInteropID`, chromaticities, attributes | scanline/tiled I/O |
| OpenImageIO | `ImageSpec` + pixels | names + designated alpha/depth + metadata | yes | format-oriented | designated alpha channel | arbitrary metadata | colour-space metadata | ROI/cache infrastructure elsewhere |
| OpenCV | `Mat` dimensions + depth + channel count | mostly external to `Mat` | one element-depth model | common matrix grid | operation conventions | not a core `Mat` semantic | assumed by conversion operation | ROI/header views |
| libvips | width × height × bands + format + interpretation | global `VipsInterpretation`, generic multiband fallback | one format per image | common grid | operationally significant | not a GDAL-style validity model | interpretation + ICC metadata | strong demand-driven region model |
| GDAL | dataset + raster bands | per-band interpretation/metadata | per-band model | classic dataset common raster size | alpha as band interpretation; mask separate | explicit NoData and mask | per-band interpretation/table | block/window I/O |
| STAC EO/Raster | product/item/assets + band metadata | spectral identity + per-band raster metadata | product/asset level | yes | not primary | explicit NoData metadata | rendering separable | catalogue/product model |
| GeoTIFF 1.1 | TIFF + orthogonal georeferencing tags | inherits TIFF | inherits TIFF | inherits TIFF grid | inherits TIFF | inherits TIFF/GDAL conventions | TIFF remains responsible | georeferencing orthogonal |
| xarray | labeled arrays / Dataset variables | names, dimensions, coords, attrs | yes across variables | yes across variables | application-defined | application-defined | application-defined | backend-dependent |
| Sentinel-2 | multiple spectral/derived assets | band identity + spectral purpose | product-level | yes: 10/20/60 m | not central | quality/classification/mask products | true-colour is derived | inherently multi-resolution |

## 3. TIFF 6.0

TIFF separates storage organization from semantic interpretation. `PlanarConfiguration` describes whether components are packed per pixel or stored in separate component planes, while `PhotometricInterpretation` describes what those components mean.

Therefore:

```text
storage organization != photometric meaning
```

`ExtraSamples` exists because the number of stored samples must not be inferred from photometric interpretation alone. TIFF also explicitly distinguishes associated alpha (premultiplied colour) from unassociated alpha, and distinguishes fractional alpha/coverage from clipping-style masks.

M1 consequence:

```text
layout != channel meaning
alpha != validity mask
alpha association must be explicit
```

Primary source:

- TIFF Revision 6.0:
  https://www.itu.int/itudoc/itu-t/com16/tiff-fx/docs/tiff6.pdf

## 4. PNG Third Edition

PNG is deliberately narrow: grayscale, RGB, indexed colour, and optional alpha.

Its alpha semantics are nonetheless useful evidence:

- alpha is a linear fraction of opacity;
- transfer/gamma processing does not apply to alpha;
- PNG stores unassociated/straight alpha;
- colour-space metadata is separate from channel storage.

M1 consequence:

```text
R/G/B identity
+
colour encoding
+
alpha semantics
```

are separate pieces of information.

Primary source:

- https://www.w3.org/TR/png-3/

## 5. OpenEXR

OpenEXR strongly challenges a simplistic packed-pixel model.

It supports:

- arbitrary named channels;
- different per-channel sample types (`HALF`, `FLOAT`, `UINT`);
- independent x/y sampling rates;
- conventional premultiplied alpha;
- scene-linear HDR conventions where values may legitimately exceed 1.0.

This is stronger than planar versus interleaved layout:

```text
same image file
    does not imply
same sample lattice or sample type for every channel
```

This does not prove the first processing `ImageView` must support every such case directly. It may instead prove that a broader product/file-description abstraction is needed above a homogeneous processing view.

Primary sources:

- https://openexr.com/en/latest/TechnicalIntroduction.html
- https://openexr.com/en/latest/SceneLinear.html

## 6. OpenImageIO

`ImageSpec` separates:

- dimensions;
- channel count;
- default pixel format;
- optional per-channel formats;
- channel names;
- designated alpha and depth channels;
- additional metadata.

This supports:

```text
sample storage
+
channel descriptors
+
special semantic roles
+
extensible metadata
```

Channel name and special role are related but not identical. OpenImageIO explicitly recommends respecting designated alpha/depth channels instead of assuming a fixed ordinal position.

Primary sources:

- https://openimageio.readthedocs.io/en/v3.1.14.0/imageioapi.html
- https://openimageio.readthedocs.io/en/v2.3.19.0/imageoutput.html

## 7. OpenCV

OpenCV is useful partly as a counterexample.

A `cv::Mat` knows depth, channel count, dimensions and strides, but does not intrinsically distinguish RGB from BGR, XYZ, normals, spectral data, or unrelated vector components.

Colour semantics are supplied to operations such as `cvtColor()` by an explicit conversion code.

M1 lesson:

> `ImageView` should not merely be `RasterView + channel count` and leave semantic meaning to call-site convention.

Primary sources:

- https://docs.opencv.org/4.13.0/d3/d63/classcv_1_1Mat.html
- https://docs.opencv.org/4.13.0/d8/d01/group__imgproc__color__conversions.html

## 8. libvips

libvips is especially relevant because its execution architecture overlaps with the goals of `imagery-d` and `raster-d`.

A libvips image has width, height, bands, one band format, coding and interpretation. It also provides a generic multiband interpretation.

Its strongest evidence for this project is the demand-driven region model: partial images compute requested rectangular regions on demand, allowing long pipelines without full intermediate images resident in memory.

This strongly validates:

```text
semantic image abstraction
    must not imply
whole-image residency
```

libvips also demonstrates that colour transforms can operate on colour-bearing bands while passing extra bands through, which argues for explicitly identifying the channel subset to which colour semantics apply.

Its convenience inference of alpha from interpretation/band count is useful in that ecosystem but should not become an M1 invariant.

Primary sources:

- https://www.libvips.org/API/8.17/how-it-works.html
- https://www.libvips.org/API/8.17/class.Image.html
- https://www.libvips.org/API/8.18/enum.Interpretation.html
- https://www.libvips.org/API/current/libvips-colour.html
- https://www.libvips.org/API/current/type_func.Image.composite.html

## 9. GDAL raster model

GDAL raster bands carry independent semantics including:

- data type;
- optional NoData;
- optional mask;
- scale and offset;
- unit;
- colour interpretation;
- statistics/categories.

This strongly supports a per-channel/band semantic descriptor over raw planes.

The stored-versus-physical distinction is explicit:

```text
physical = scale * stored + offset
```

NoData and mask are separate mechanisms. GDAL also supports dataset-level tuple-style NoData.

M1 consequence:

```text
band identity
value transform
unit
NoData
mask
colour interpretation
```

must remain distinguishable.

Primary source:

- https://gdal.org/en/stable/user/raster_data_model.html

## 10. STAC EO and Raster

STAC models remote-sensing products and assets rather than forcing all meaning into one in-memory image.

EO metadata includes:

- common band name;
- centre wavelength;
- FWHM;
- solar illumination.

Raster metadata includes:

- NoData;
- unit;
- scale;
- offset;
- spatial resolution;
- point-versus-area sampling.

Scale and offset explicitly map stored Digital Numbers to physical quantities such as reflectance or radiance.

Presentation is separately describable, supporting:

```text
source/band semantics != presentation recipe
```

A NIR band remains NIR even when a false-colour renderer maps it to display red.

Primary sources:

- https://github.com/stac-extensions/eo
- https://github.com/stac-extensions/raster
- https://github.com/stac-extensions/render

## 11. GeoTIFF 1.1

GeoTIFF provides a particularly useful architecture boundary.

The OGC standard states that GeoTIFF georeferencing tags are orthogonal to the TIFF raster-data description. GeoTIFF does not redefine TIFF colour spaces or storage semantics.

It also distinguishes raster samples representing an area/cell from point samples.

That distinction is relevant to DEMs and scientific grids as well as imagery. Under the existing workspace boundary rule, this is therefore presumptively **not image-specific**.

M1 action:

```text
record as potential raster-d or geospatial-raster metadata requirement
do not implement locally
do not interrupt raster-d without a concrete consumer need
```

Primary source:

- https://docs.ogc.org/is/19-008r4/19-008r4.html

## 12. xarray

xarray is not an image engine, but its separation between one `DataArray` and a `Dataset` of variables is useful architectural evidence.

A `Dataset` can group variables with different dtypes and dimensions while sharing coordinates where applicable.

M1 lesson:

> Do not turn the first `ImageView` into a general scientific-dataset framework. A broader product abstraction can exist separately.

Primary sources:

- https://docs.xarray.dev/en/latest/api/dataarray.html
- https://docs.xarray.dev/en/latest/api/dataset.html

## 13. Sentinel-2 as a concrete product consumer

Sentinel-2 is a direct real-world counterexample to the idea that one remote-sensing product is always one common-grid multichannel image.

The MSI has 13 spectral bands:

```text
4 bands at 10 m
6 bands at 20 m
3 bands at 60 m
```

Level-2A products also include derived rasters such as aerosol optical thickness, water vapour, scene classification and true-colour imagery, with outputs available at several resolutions.

Therefore:

```text
one acquisition/product
    does not imply
one native band grid
```

Primary sources:

- https://sentiwiki.copernicus.eu/web/s2-mission
- https://sentiwiki.copernicus.eu/web/s2-products

## 14. Candidate A — Annotated RasterView

Conceptually:

```text
ImageView!T
    RasterView!T
    ImageDescriptor
```

### C1 — interleaved 8-bit RGB

Excellent fit. `RasterView!ubyte` already hides interleaving behind logical planes.

### C2 — planar 16-bit RGBA

Excellent fit. Physical plane organization remains in `raster-d`; image metadata identifies colour channels and alpha association.

### C3 — grayscale + validity mask

Good fit only if validity binding is explicit. A key unresolved point is whether a validity mask with a different sample type can be attached without turning the core into a channel-collection framework.

### C4 — scaled NIR band

Excellent fit. One channel descriptor can carry band identity, scale, offset, unit, spectral semantics and NoData.

### C5 — multispectral data

Excellent only when the represented channels share one common raster grid and one materialized sample type.

It intentionally does not natively represent a multi-resolution Sentinel-2 product.

### C6 — custom channels

Excellent if names/identifiers are extensible and standardized roles are optional.

### C7 — cropped/streamed region

Excellent. Semantic metadata can remain stable while only the `RasterView` region changes.

### C8 — alpha convention round-trip

Excellent if alpha association is explicit.

### A conclusion

Candidate A is now the strongest candidate for the first **common-grid processing image view**.

It is not sufficient as a universal imagery-product model.

## 15. Candidate B — Channel-oriented ImageView

Conceptually:

```text
ImageView
    ChannelView[]
        Raster binding
        ChannelDescriptor
```

B naturally handles heterogeneous channel types, grids and validity rasters.

That flexibility comes with serious risks:

- duplication of `raster-d` ownership/view machinery;
- weaker shared-coordinate invariant;
- repeated reconciliation of extents, grids, lifetimes and types;
- harder common RGB(A) hot paths;
- drift from image view toward general product container.

B fits native multi-resolution products better than A, but that is evidence it may be solving the **product problem inside the image-view type**.

### B conclusion

Do not use B as the default first `ImageView`.

Retain the underlying idea for a higher product/binding layer if needed.

## 16. Candidate C — Description + raster bindings

Conceptually:

```text
ImageDescription
    ChannelDescription[]
    ColourDescription?
    ValidityDescription?

bindings
    semantic channel -> raster resource/view
```

C cleanly supports:

- product metadata independent of residency;
- heterogeneous types;
- different native grids;
- multiple assets;
- deferred materialization;
- Sentinel-2-style products;
- OpenEXR file/channel descriptions.

As the first processing image abstraction, however, it is too broad and risks pulling M2 source/pipeline architecture into M1.

### C conclusion

Candidate C is the strongest model for a **future imagery-product/description layer**, not for the first processing image abstraction.

## 17. Emerging two-level model

The evidence now supports a stronger hypothesis.

### Level 1 — common-grid image view

Provisional concept:

```text
ImageView!T
    |
    +-- RasterView!T
    |
    `-- image semantics
          channel descriptors
          colour binding/description
          alpha description
          validity/NoData description
          value interpretation
```

Candidate invariant:

> Every primary channel represented directly by one `ImageView!T` shares the same logical 2D sample grid and materialized raster sample type `T`.

### Level 2 — imagery product / description

Future concept only:

```text
ImageryProduct ?
    |
    +-- one or more image/raster assets
    +-- potentially different sample types
    +-- potentially different grids/resolutions
    +-- spectral/product metadata
    +-- relationships / derived products
    `-- provenance
```

Names are not accepted.

This split preserves a strong and cheap processing invariant without pretending that Sentinel-2, heterogeneous OpenEXR or scientific products natively fit one `RasterView!T`.

## 18. Consequence for `Pixel`

M1.2 strengthens the decision not to make a packed pixel struct the semantic foundation.

For a common-grid image, a pixel can remain a logical association of relevant channel samples at one coordinate. Those samples need not be physically contiguous.

For a multi-grid product, `pixel` may not have one unambiguous cross-band meaning until explicit resampling.

Therefore:

> A public `Pixel` value type is not currently required to define the first `ImageView`.

## 19. Consequence for channel identity

A robust channel descriptor likely needs two separable concepts:

```text
human/interchange name
optional standardized semantic role
```

Examples:

```text
name = "R"          role = red colour component
name = "B08"        role = near-infrared spectral band
name = "velocity.x" role = custom / unspecified
name = "A"          role = alpha
```

A closed enum alone is insufficient because arbitrary channels must be preserved.

A free-form string alone is insufficient because operations need reliable semantic predicates.

Provisional requirement:

> Unknown channel semantics must round-trip without pretending to understand them.

## 20. Consequence for colour binding

Colour interpretation should refer to an explicit subset/order of channels.

Conceptually:

```text
colour description
    components -> [channel 0, channel 1, channel 2]
    encoding   -> external/typed colour semantics
```

Do not assume the first three channels are RGB.

False-colour presentation must be able to map intrinsic spectral bands to display components without mutating intrinsic band identity.

`color-d` integration remains undecided.

## 21. Consequence for alpha

Alpha must be explicit rather than inferred from channel count.

Required information is likely to include:

```text
alpha channel index
association:
    straight
    premultiplied
    unknown
semantic meaning:
    opacity / coverage
```

Codec adapters may know the source convention and must preserve it.

Examples:

```text
PNG      -> straight/unassociated
OpenEXR  -> conventionally premultiplied
TIFF     -> either, explicitly tagged
```

## 22. Consequence for validity and NoData

A single `mask` channel role is insufficient.

The external models support:

```text
per-channel NoData sentinel
tuple/pixel-level NoData
explicit validity mask
quality/classification raster
alpha/coverage
```

These mechanisms may interact but must not be silently substituted.

Highest-value open question:

> Does the first common-grid `ImageView!T` bind only same-`T` validity data, or may a validity mask use a separate raster/sample type?

## 23. Consequence for stored and physical values

The distinction is strongly supported by GDAL and STAC.

Conceptually:

```text
stored = raster sample

physical = stored * scale + offset
```

with optional unit and quantity semantics.

Consequences:

1. NoData comparison may occur in stored-value space.
2. Algorithms must state whether they consume stored or physical values.
3. Colour/display transformation is not radiometric decoding.
4. Materializing physical values into float storage is an execution strategy, not the semantic definition.

## 24. Consequence for point-versus-area sampling

GeoTIFF and STAC both expose whether values represent point samples or cell/area samples.

Because this distinction is meaningful for DEMs and scientific grids, it is presumptively not owned by `imagery-d`.

Action:

```text
record as possible raster-d / geospatial-raster consumer requirement
do not implement locally
do not interrupt raster-d until a concrete need exists
```

## 25. Updated candidate assessment

| Consumer case | A — Annotated RasterView | B — Channel-oriented | C — Description + bindings |
|---|---|---|---|
| C1 interleaved sRGB RGB | excellent | works, excessive | works, excessive |
| C2 planar RGBA | excellent | works | works |
| C3 gray + validity mask | good; mask binding unresolved | excellent | excellent |
| C4 scaled NIR band | excellent | excellent | excellent |
| C5 multispectral common-grid | excellent | excellent | excellent |
| C5 native multi-resolution product | fails by design | works | excellent |
| C6 custom channels | excellent with extensible descriptors | excellent | excellent |
| C7 ROI / streamed region | excellent | complex | description only |
| C8 alpha convention round-trip | excellent with metadata | excellent | excellent |
| common hot-path simplicity | excellent | weaker | not an execution model |
| avoids raster ownership duplication | excellent | highest risk | good if description-only |
| fits first M1 scope | strongest | weak | too broad |
| fits future product scope | insufficient | possible | strongest |

## 26. Provisional M1.2 synthesis

The evidence currently favours:

```text
A for the first processing image abstraction

C for a later broader imagery-product/description abstraction

B not as the default image core
```

This is not API acceptance.

More precisely, a first image view should probably represent:

```text
one common 2D sample grid
one materialized raster sample type T
one RasterView!T
one ordered semantic description of its logical planes/channels
```

It should not claim to represent every possible image file or imagery product natively.

## 27. Questions promoted to M1.3

### Q1 — Descriptor lifetime

Can `ImageView!T` cheaply carry or borrow immutable semantics while ROI changes only the raster region?

### Q2 — Channel-to-plane binding

Is the simplest initial invariant:

```text
channel index == RasterView plane index
```

sufficient?

Do not add arbitrary remapping without a concrete consumer.

### Q3 — Separate validity raster

Can an image refer to a validity mask with a different sample type without becoming candidate B?

### Q4 — NoData scope

Model:

- one sentinel per channel;
- NaN;
- tuple/pixel-level NoData;
- separate mask;
- no validity semantics.

### Q5 — Stored-value transform

Should scale/offset live directly in a channel descriptor or in a separate optional value-encoding descriptor?

### Q6 — Colour component binding

How can colour-channel relationships be represented without importing unstable `color-d` API?

### Q7 — Alpha description

Can alpha be modeled as a relationship:

```text
alpha channel index + association state
```

rather than overloading a generic channel role?

### Q8 — Product boundary

Current strongest candidate:

> `ImageView!T` requires one common logical 2D sample grid and one materialized sample type `T`.

## 28. New M1.3 pressure tests

### C9 — heterogeneous OpenEXR channels

```text
R, G, B, A : HALF
Z          : FLOAT
objectId   : UINT
```

Do not weaken `RasterView!T` merely to imitate a file container.

### C10 — OpenEXR chroma subsampling

```text
Y  sampling 1x1
RY sampling 2x2
BY sampling 2x2
```

Test whether common-grid `ImageView` requires explicit conversion/resampling first.

### C11 — Sentinel-2 native-resolution product

```text
B02 10 m
B05 20 m
B01 60 m
```

Required: no implicit resampling.

### C12 — false-colour composite

Intrinsic:

```text
NIR
Red
Green
```

Presentation:

```text
display R <- NIR
display G <- Red
display B <- Green
```

Required: presentation mapping must not mutate intrinsic band identity.

### C13 — TIFF associated vs PNG straight alpha

Both may materialize as four planes, but the semantic distinction must survive.

### C14 — validity mask with different sample type

```text
image : float
mask  : ubyte / bit
```

Test without forcing all attachments into one `RasterView!T`.

### C15 — scene-linear HDR

```text
RGB float
values may exceed 1.0
linear-light
scene-referred
```

Required: no automatic clamp merely because data are colour.

### C16 — GeoTIFF point versus area

Preserve the distinction while leaving generic ownership outside `imagery-d`.

## 29. M1.2 conclusion

The smallest promising first abstraction is not a universal image container.

It is more narrowly:

> a semantic, common-grid image view over one validated `RasterView!T`.

Its purpose is to add image meaning without taking ownership of storage, layout, raster lifetime, regions, generic execution, or multi-asset product architecture.

The strongest current distinction is:

```text
ImageView
    = processing-oriented
      common grid
      homogeneous materialized sample type
      explicit channel/image semantics

ImageryProduct / ImageDescription
    = future research
      potentially heterogeneous sample types
      potentially different grids/resolutions
      multiple assets/resources
      product relationships and provenance
```

The exact names remain undecided.

The next M1 step should be M1.3 consumer-case modelling, especially C3 and C9–C16, before any D API sketch is promoted.
