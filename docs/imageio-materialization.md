# Explicit native-plane and RGB materialization

The default configuration exposes imageio's decoded-region contract through
`imagery.io`. imagery-d validates image semantics and orchestrates conversion;
imageio owns decoding/technical source facts, color-d owns color mathematics,
and raster-d owns retained sample storage. `no-io` retains policy descriptors
without admitting the decoder adapter.

## Supported production candidate

The #174/#175 candidate accepts explicit u8 component planes and independently
specified component mapping, geometry and output policies:

```d
alias Model = YCbCrModel!(Bt601Video, 0, 1, 2);
alias Spec = ValidatedMaterializationSpec!(
    Model, BilinearUpsampling, LinearFloatOutput!float);
OwnedRgbMaterialization!float published;
auto status = tryMaterializeRgbOwned!Spec(region, maxResultBytes, published);
```

This operation is `@safe`, synchronous and serial. It writes directly into one
interleaved three-plane raster-d owner. Float32/float64 results preserve finite
extended **encoded-sRGB** values. `LinearFloatOutput` is a historical numeric
storage name; it does not request transfer decoding. `ClippedUbyteOutput` clips
encoded channels to [0,1] and uses color-d's nearest-byte quantizer, with upper
byte at exact half steps. No intermediate component byte image or RGB array is
allocated by the direct owned path. The array-returning `materializeRgb!Spec`
has the same mathematics and explicitly allocates a GC array instead.

## Preflight and source facts

Before output allocation, the adapter validates:

- nonempty region, checked origin/dimension arithmetic and component count;
- every plane's dimensions, row stride and actual byte span (final-row padding
  is not required), plus origin arithmetic;
- known, supported, nonconflicting sample geometry, including denominators,
  positive factors and crop phase, even for equal-sized planes;
- complete unique Y/Cb/Cr roles and the caller's explicit indices, including
  duplicate/out-of-range mappings;
- source-model agreement, independently known matrix/range/transfer/primaries,
  unsigned eight-bit representation and the exact color-d policy;
- matching numeric output/clipping policy and checked output payload/budget.

BT.601 and BT.709 matrices, full and video ranges are accepted with known sRGB
transfer and sRGB/BT.709 primaries. BT.601 primaries or linear transfer are
rejected: this adapter does not silently substitute a primary/transfer
conversion. The matrix and range must match the caller's policy, and its bit
depth must be eight. Unknown or unsupported source samples are not inspected
as if they were u8. NaN/Infinity cannot occur in admitted u8 input; malformed
geometry is rejected before sampling. The separate scalar `convertYCbCr`
retains color-d's extended/IEEE behavior.

Missing, unsupported and conflicting facts have distinct errors. Native access
remains available when geometry or color metadata cannot authorize conversion.
In particular, ordinary JPEG 4:2:0/4:2:2 does **not** supply enough declared
siting/range/transfer/primaries merely because it has three planes. The adapter
does not infer those facts from component dimensions, JFIF or brightness.

## Source coordinates and clamping

For one source axis, imageio's public helper defines:

```
sampleCenter(origin, i, factor, cropOffset) = (origin + i)*factor + cropOffset
```

The separate `geometry.centerOffset` is added in reference-grid units. Thus a
target reference-grid sample `t = region.origin + outputIndex` uses:

```
sourceIndex = (t - centerOffset - cropOffset)/factor - plane.origin
```

There is no additional `+0.5/-0.5` convention. Integer division/differences
are formed before converting large unsigned origins to float64, preserving
small relative positions even around 2^63. Center/crop offsets are exact
rationals at the boundary and converted to float64 for interpolation.

This candidate admits each rational phase within plus/minus one source-cell
spacing on its axis. Larger translations belong in integer storage origins;
they return `unsupportedGeometry` rather than losing phase to cancellation
between huge floating terms. Zero denominators/factors return `invalidGeometry`.
Unknown siting is never replaced by a guessed centered grid. Native access
preserves even unsupported geometry for inspection.

Nearest rounds index ties toward the larger sample; bilinear retains fractional
component values in float64 until color conversion. Edges clamp to the **supplied
plane buffer**, whose logical origin is the plane's source-plane coordinate.
If a cropped result must match sampling the whole image, the caller supplies
the necessary neighbour/halo samples. An imageio ROI decoder that returns only
the crop is not an implicit halo provider. Whole/ROI equivalence is qualified
when both requests have the same required source samples.

This deliberately corrects the earlier implicit half-pixel mapping. Zero-phase
samples at reference positions 0 and 2 now select the right sample at the
nearest tie at position 1. A centered phase must be declared explicitly (factor
2 uses center offset 1/2). Old ROI origins were also incorrectly treated as
reference-grid rather than source-plane coordinates. These are numerical bug
fixes, not byte-compatibility claims for the former unqualified materializer.

## Native copying and inspection

`materialize(region, nativePlanes, maxResultBytes)` copies validated native u8
buffers with their independent dimensions, strides, roles, sampling geometry,
crop offsets and source color description/origin. It does not interpret color
or require known geometry. Only the necessary span through the final visible
sample is copied; final-row trailing padding is not part of that span.

`visitNativePlanes` validates storage and invokes a synchronous read-only
inspection callback without copying. imagery-d retains neither source samples
nor callback. This is **not** a new retained raster owner: the caller controls
source lifetime. DIP1000 rejects retaining the scoped callback, but does not
prevent retention of every slice nested in `ImageRegion`. Consumers must not
keep borrowed data past its actual owner's lifetime; GC-managed and externally
borrowed slices must not be confused. An independently retainable result uses
the copy/owned APIs. No private raster-d backing or substitute refcount is used.

Legacy `materialize!Spec` component results still contain imageio u8 `ImagePlane`
storage. Their interpolation is explicitly rounded to bytes. `Spec.output`
selects RGB output representation; it does not turn this legacy component
carrier into float planes. Resampled component descriptors are regenerated as
unit-spacing, zero-offset target-grid planes rather than preserving stale
source sampling geometry.

`materializeUbyte` and `materializeUshort` safely copy compact planar/interleaved
decoded data with checked products, byte length, layout and explicit budget.
The u16 raw adapter expects native-host-order bytes and performs no byte-order
or numeric conversion. It is separate from the u8 YCbCr interpretation path.

## Ownership, budget and failure

`maxResultBytes` covers exactly `3*width*height*sizeof(Sample)` for direct RGB.
The algorithm uses O(1) working state beyond that output, and O(width*height)
sampling time. Source/decoder memory, allocator/raster metadata and fixed-size
provenance are separate. This is not a promise that an upstream JPEG decoder
uses bounded ROI memory: the released decoder's full/fallback/indexed behavior
remains observable and under its own contract.

The typed owned operation publishes only a completed candidate. Every returned
failure or thrown exception preserves the prior owner, metadata and retained
aliases. Raster adoption/metadata failure releases the candidate normally.
Allocator exhaustion can return `allocationFailure`; unhandled runtime Errors
may propagate without replacing the prior result. There are no hidden workers,
schedulers or shared mutable state. Keep descriptors/source bytes unchanged
during a call; raster-d lease counts are non-atomic.

`OwnedRgbMaterialization.init` is empty. Legacy materialization result fields
now initialize to `notAttempted`, without renumbering historical error members;
`.init.ok` is false. Array/result-wrapper failures return empty result storage.
The historical byte wrapper preserves its coarse raster error and additionally
records the detailed `sourceError`. New code should consume the structured
typed-owned status directly.

The owned result copies the original source description, reference-grid origin,
Y/Cb/Cr plane mapping, sampling factors, center/crop offsets and source-plane
origins. It retains no decoder sample arrays. The coordinate recipe is
`imageio-sampleCenter-plus-geometry-v1`. File/source identity and revision,
geospatial registration/CRS/transform, bands/units, alpha/validity and provider
policy provenance still belong to the consumer handoff (#145). Copying technical
metadata does not invent missing geospatial facts.

## Qualification

`tests/materialization` imports public APIs as an ordinary default-configuration
DUB consumer. `tools/verify-materialization.py` independently creates 19-by-13
JPEG 420/422 fixtures with Pillow and invokes imageio's released plane/ROI
decoders. Raw unknown metadata must be rejected by RGB conversion while native
copy/inspection succeeds. A separate, explicitly labelled test-provider
declaration supplies known geometry/color for positive conversion tests; those
facts are never attributed to the raw JPEG decoder.

193 cases / 20,991 pixels cover four matrix/range combinations, nearest/bilinear,
float/double/byte output, padded planes, nonzero and huge origins, independent
X/Y phases, equal-size shifted planes, reordered roles and odd-origin JPEG ROIs.
The independent reference uses rational coordinates and YCbCr equations.
Whole/ROI, array/direct-owned equivalence, source metadata preservation, budget
rollback, retained owners and structured error paths have executable probes.
The consumer also opens a GDAL-produced single-band GeoTIFF, requests a visible
9-by-7 region, materializes its samples and assembles a Dunia-style handoff:
source/revision/grid, EPSG:32633, source/ROI transform, extent, first sample
center, 2 m GSD, explicit intensity-band role/unit, absent alpha and separately
derived NoData validity. The fixture consumer owns the north-up PixelIsArea
interpretation; no CRS code is added to imagery-d. GDAL independently confirms
the metadata and pixels, including the invalid sample. Poisoning/releasing the
decoder buffer leaves the retained raster unchanged. This supplies a concrete
#145 contract fixture; it does not claim a deployed Dunia tool or human review.

A second, ordinary three-band GDAL TIFF is retained as an explicit **decoder
blocker**: released imageio-d 0.1.1 returns `unsupportedLayout` because its
initial layout gate tests scalar BitsPerSample before loading the multi-value
BitsPerSample tag. The adapter does not patch the foreign parser, rewrite the
file to a nonstandard tag or silently fall back to GDAL decoding. This blocks
complete RGB-TIFF production/display acceptance in #174/#175/#146. The
single-band positive fixture and RGB negative fixture are separately named and
checked, so one cannot conceal the other.

The isolated upstream fix is [imageio-d PR #26](https://github.com/alex-1974/imageio-d/pull/26),
commit `ea65f51f11f415491ee5ebe78f3594b1cdc3b9fd`. It resolves uniform
component depths during inspection, handles inline integer values in either
TIFF header/byte order, and corrects interleaved pixel-stride metadata. DMD and
LDC pass the complete RGB handoff using an explicit temporary path dependency:

```
python tools/verify-imageio-candidate.py /path/to/imageio-checkout --compiler=ldc-1.43.0
```

This does not change global DUB registrations, repository defaults or release
tags. The fixed dependency still requires integration/release qualification.
See the [dated receipt](https://github.com/alex-1974/imagery-d/blob/v0.4.0/docs/benchmarks/materialization-2026-11-22.md) for exact errors,
compiler gates and native timings.
