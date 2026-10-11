# M3 research — Image I/O to imagery semantic interoperability

**Status:** Proposed research contract; **not** an accepted ADR or production API.  
**Scope:** `imagery-d` only. External `imageio-d`, `raster-d`, `color-d` and `proj-d` are independent repositories and are not modified by this document.  
**Date:** 2026-10-11

## 1. Question and intended result

How can an image operation consume decoded pixels from PNG, JPEG, TIFF, EXR,
a remote image source, a generated image, or a prior operation **without knowing
which decoder or transport supplied the values**?

The candidate answer is a **shared in-process raster representation and an
explicit image-semantic contract**, not a mandatory common physical pixel
layout, new pixel owner, binary file format, or dependency on `imageio-d`.

`raster-d` already supplies validated typed resident raster representation,
planes, strides, ownership and ROI. `imagery-d` attaches image semantics
when a concrete operation requires them. A consumer or integration adapter
mediates any decoder metadata mapping.

    resource / generated producer
       -> decode or native materialization (if applicable)
       -> retained typed raster representation (raster-d)
       -> explicit image-semantic interpretation
       -> common-grid image processing view (imagery-d)
       -> image-domain operation

The last two stages must work unchanged if the first two were replaced by
an in-memory raster created without any file or decoder.

## 2. Authority and accepted constraints

This proposal **preserves**, and does not silently amend:

- [M1 ADR 0002](../adr/0002-image-semantic-core.md): one common-grid
  `RasterView!T`, borrowed immutable image semantics, optional same-grid
  `RasterView!ubyte` validity; the view does not own raster storage;
  primary channel i describes raster plane i in the first normal form.
- [M2 ADR 0003](../adr/0003-source-cache-pipeline-architecture.md):
  Product/Component/Source/Resource/Locator/Revision distinctions;
  explicit native-to-target compatibility and materialization;
  source logical coverage distinct from resident raster coordinates;
  no universal decoder, scheduler, cache, or public source API yet.
- [M3 color-d consumer evidence](../../experiments/m3_color_d_srgb_consumer/RESULTS.md):
  explicit RGB binding, planar/interleaved semantic equivalence, ROI
  equivalence, caller-owned output, and no `raster-d` or `color-d`
  provider API changes. Its production-admission verdict remains
  **deferred**.
- `raster-d` public root import: `RasterLease!T`, `RasterView!T`,
  `WritableRasterView!T`, `Region2D`, `PlaneByteLayout`,
  `tryImportOwnedRaster` and the supported owned-resource import path.

M1/M2 architectural concepts are accepted; the final public names and
metadata carrier layout **remain unfrozen** until a consumer-backed M3
production admission. No `dub.sdl` or production `source/imagery` tree
is authorised by this research document.

## 3. Two distinct contracts, not one new data format

### 3.1 Numeric resident storage: `raster-d`

A successful typed resident materialization should provide, or be adaptable
to, a valid `RasterLease!T` retaining the memory and a derived
`RasterView!T` borrow. Existing raster descriptors provide:

- resident region and plane count;
- sample type `T`;
- validated byte layout/strides and component access;
- planar, interleaved, padded and other supported layouts;
- zero-copy ROI where geometry permits;
- independent backing lifetime through the lease.

There is **no** requirement to repack all decoded RGB images into `RGB8[]`,
nor to convert planar data to interleaved (or vice versa). A packed or
compressed representation that cannot legally be viewed as samples of
`T` requires an explicit decode/unpack step first. Byte order,
alignment and valid sample representation must be resolved rather than
reinterpreting arbitrary encoded bytes.

The existing `raster-d` types are the canonical in-memory numerical
representation; this is **not** a request for a second storage abstraction.

### 3.2 Semantic interpretation: `imagery-d`

For the first common-grid normal form, imagery needs an immutable
interpretation associated with the raster planes, as applicable:

- ordered channel descriptions, including unknown/custom channels;
- stored versus physical/radiometric value interpretation, scale/offset
  and units where known;
- explicit colour-component binding and encoded/linear colour semantics;
- separate alpha identity and straight/premultiplied/unknown association;
- distinct NoData interpretation and optional same-grid validity mask;
- explicit presentation choices, not modifications of intrinsic spectral
  channel identity.

Unknown or absent information remains **unknown**, rather than triggering
assumptions from a filename, extension, plane count, channel label or
sample type. Example: four bands do not imply RGBA, and `ushort` does
not imply normalised sRGB.

A decoder may expose format-specific metadata. An integration adapter
may map supported metadata into imagery semantics, may retain unrecognised
information separately, and must report information loss or ambiguity
where material. **Image operations must not import `imageio-d` types.**

There is currently no accepted universal `DecodedImage` or
`ImageMetadata` public carrier; both would require evidence before
freezing a new cross-library API.

## 4. Dependency and ownership boundary

The target dependency directions are:

    imageio-d (candidate) ------> raster-d <------ imagery-d
                                                     |
                                                     v
                                                  color-d

An application/adapter can depend on both `imageio-d` and
`imagery-d`, but neither library should have to import the other.

A decoder can:

1. write directly to suitable caller-controlled writable raster storage;
2. transfer compatible owned storage into a `RasterLease!T` using
   supported public `raster-d` import semantics; or
3. copy/decode into a retained raster when adoption is impossible.

The **lease owns or retains** the pixel resource; `ImageView!T` merely
borrows its view and immutable semantics. A temporary decoder buffer
must not escape as a raster view if closing its decoder invalidates the
buffer. An ownership transfer must document failure disposition, release
responsibility, and whether a copy occurs.

If a real decoder requires adoption of foreign allocations with custom
destruction semantics and existing public raster import is insufficient,
record a concrete `raster-d` consumer requirement and request an extension
**in that repository**. Do not duplicate resource ownership locally.

## 5. Heterogeneous products versus one processing view

The accepted `ImageView!T` normal form contains **one sample type and
one logical 2D processing grid** for all primary planes. It need not
describe an entire heterogeneous source product.

Examples that cannot be silently folded into one view:

- EXR channels with half, float and unsigned integer representations;
- sensor bands at different native resolutions;
- a categorical identification channel alongside physical reflectance
  that requires different conversion semantics;
- different grids/orientations or validity policies.

The M2 bridge remains:

    heterogeneous product
      -> explicit ordered component selection
      -> inspect sample/grid/value compatibility
      -> explicit conversion/resampling only if requested
      -> retained common-grid typed result
      -> ImageView!T borrow

Never perform silent type promotion, resampling, spectral remapping,
clipping, display normalisation, or colour interpretation simply to
manufacture a homogeneous image.

## 6. Region coordinates and materialization semantics

At minimum distinguish:

1. logical source/image coverage;
2. native fetch/decoder window;
3. resident raster descriptor region;
4. processing-view-local ROI.

A `RasterView.region` is **not** a global image offset. M2 retains
logical coverage separately. Mapping a requested logical region into
resident ROI must be checked; a containing resident region can be
borrowed without copying when the geometry and semantics allow it.

The image-semantic metadata attached to an ROI must not change its
channel identities, unit interpretations, alpha association or
colour binding. Validity, when materialized, uses the same processing
grid, not the same encoded file arrangement.

An invalid region must not be silently clipped. Partial read,
revision mismatch, unsupported sample representation, or incomplete
metadata required by the operation must have explicit outcomes.
A successful delivered materialization represents a coherent source
snapshot; do not expose an incomplete result as a completed one.

The I/O backend may require complete decode even for a small requested
region. The **semantic** region capability is therefore distinct from
the source's **access cost**, which must be characterized separately.

## 7. Minimal conceptual consumer flow

These names describe roles, **not accepted or implemented D APIs**:

    decoded = externalIo.decodeOrMaterialize(request)
    retainedRaster = decoded.ownedRaster
    semantics = adapter.resolveExplicitSemantics(
        decoded.nativeMetadata, consumerIntent)
    image = imagery.borrowCommonGrid(
        retainedRaster.view(), semantics, optionalValidity)
    imagery.operationInto(image, callerOwnedDestination, policy)

The same final two lines must work with an equivalent raster constructed
in memory. If `imageio-d` returns only a neutral decoded descriptor rather
than a `RasterLease`, the adapter performs the validated import; that
provider-side packaging is not decided here.

## 8. Proposed evidence and negative contracts

These are **required experiment questions**, not claims of completed tests.

| ID | Probe | Pass condition |
|---|---|---|
| H1 | Construct equivalent planar and pixel-interleaved `RasterLease!T` fixtures | Same semantic samples and same imagery operation result; no format-specific branch in the kernel |
| H2 | Construct two provenance-labelled fixtures representing different hypothetical decoders, but identical typed samples and explicitly equal semantic interpretation | Same output bit-for-bit for the same pointwise path; source file extension and transport cannot affect the kernel |
| H3 | Retained owner, view borrow and ROI lifetime probes, including `@safe` negative compile cases | Escaping primary/validity/metadata borrows is rejected where covered by the validated M1 lifetime contract; no use-after-release or aliasing assumption |
| H4 | Heterogeneous sample types, unequal grids, missing required colour binding, and ambiguous channel identities | Explicit rejection or explicit requested materialization; never implicit reinterpretation or guessed RGB |
| H5 | Covering resident region and uneven ROIs, with separate logical placement | Whole versus partitioned result obeys the operation's declared equivalence law; logical source offsets never silently become resident offsets |
| H6 | Failure path with incompatible/expired decoder resource, partial materialization or incompatible revision | Clear failure and resource disposition; no partially published success |

H1/H2/H3/H4 should be attempted first with **synthetic
already-materialized raster data**, so correctness is independent of
actual JPEG/PNG/TIFF implementations. A later real decoder integration
is a separate cross-repository consumer test, not a prerequisite to
admitting the imagery semantic boundary.

For any image-domain arithmetic, use an independent oracle. Compile
contracts need both DMD and LDC; exact supported compiler versions
must be qualified against the dependencies actually used, not assumed
from the older `raster-d` compiler floor.

## 9. Memory and performance qualification

Record for the first concrete consumer:

- total resident source, destination, validity and temporary bytes;
- whether import is no-copy, transfer-of-ownership, or copied;
- allocations per region and per pixel;
- ROI size and whether a full-image decode was required upstream;
- explicit sample conversion/unpack/resampling costs;
- measured planar/interleaved/stride throughput against a
  `raster-d`-only control;
- DMD correctness and LDC optimized release measurements, with
  compiler versions, flags, workload, CPU and independent preflight.

No blanket zero-copy or streaming promise is justified for all codecs.
This document creates **no** new speed or allocation performance claim.

## 10. Open decisions and admission gate

Before promoting an imagery-side production type or operation, decide:

1. Which **specific** consumer capability requires the semantic view?
2. Which minimum descriptors must be retained together and for how long?
3. Can the current `raster-d` import API handle the needed ownership
   without changing generic contracts?
4. Is any metadata normalisation best owned by a consumer adapter
   instead of `imagery-d`?
5. What compatibility/failure result is visible to the consumer?
6. Which negative compile and region-equivalence tests demonstrate the
   promised lifetime and semantic invariants?

An image-native display/radiometry operation remains a candidate M3
vertical slice; this document does not select it unconditionally.

**Exit:** reviewed boundary, experimental H1–H4 evidence, measured
resource behavior, and an explicit admission/rejection ADR for the
minimal public surface. Until then, keep names and provider adapters
provisional. Do not implement a general codec API, source scheduler,
cache DAG, universal pixel format, or production image package on the
basis of this proposal alone.

## References

- `imagery-d/docs/adr/0002-image-semantic-core.md`
- `imagery-d/docs/adr/0003-source-cache-pipeline-architecture.md`
- `imagery-d/experiments/m3_color_d_srgb_consumer/RESULTS.md`
- `raster-d/source/raster/package.d`
- `raster-d/source/raster/import_owned.d`
- `imageio-d/docs/BOUNDARY.md` (independent research proposal; no dependency)
