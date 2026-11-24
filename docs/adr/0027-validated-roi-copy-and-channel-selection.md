# ADR 0027: validated ROI copies and selected-channel tone mapping

Date: 2026-11-24

Status: accepted implementation decision

Related: #222, #223; documentation review #224

## Safe ROI copying

The pointer-only `PlaneWindow` cannot prove allocation bounds, alignment, sample
representation or backing lifetime. Its old `copyRoi!float` template did not
instantiate under `@safe`, even when called from `@system` code. Adding an
unchecked trusted pointer loop would hide this defect rather than establish
those preconditions.

Provide the supported overload on raster-d's validated `RasterPlaneWindow!T`,
inside `withPlane`. Read through its typed `load` operation with local coordinates;
raster-d retains responsibility for physical layout and signed strides. Validate
nonempty ROI bounds, count overflow and destination capacity before any write.
Copy values directly without image-domain conversions, allocation or retention.
The destination must be disjoint from the source. Extra destination elements
remain untouched. The supported scalar types match the existing adapters:
ubyte, ushort, float and double.

The pointer-only overload is deprecated and explicitly disabled. There was no
working call to preserve; the new overload preserves the operation name and
three-argument shape while requiring a validated input. `PlaneWindow` remains
available for numeric geometry/offset inspection. No raw copy fallback or new
project `@trusted` boundary is introduced.

Import the defining raster.data_plane type in the generic function signature,
so template arguments can be inferred. Callers can still use raster's public
facade. The public positive probe tests inferred types, named arguments,
`@safe nothrow @nogc` and DIP1000; a matching negative probe rejects the old
pointer-only spelling even from `@system` code.

## Channel selection

Brightness/contrast validates the complete request before allocation, including
settings, mask shape and channel count even when all channels are unselected.
Map only channels with an affected flag and positive mask weight. Other
channels keep their normalized original sample. Preserve float samples directly
without a double round trip, including NaN payloads, infinities and negative
zero. Unsigned samples still normalize by their type maximum on every channel.

The source and mask are borrowed and unchanged. Build a private float raster and
replace the output lease only after complete success. Returned failures retain
the prior owner. No alpha channel is inferred; the caller chooses its flags.
Selected finite samples retain the existing clipped affine mapping and mask
blend. No new performance or general allocation-recovery claim is made.

## Regression coverage

The ordinary separately compiled DUB consumer now covers:

- 64 ROI copies: four scalar types, two planes, planar/interleaved storage,
  signed row/sample strides with padding and cropped views. Include nonfinite
  bit patterns, signed zero, destination tails, malformed/empty/overflowing ROI,
  short buffers and default windows; reject before writes.
- 192 brightness cases: three input scalar types, the same eight layouts,
  masked/unmasked calls, all-unselected/all-selected and two mixed selections.
  Mask values are 0, 128 and 255; include finite samples outside [0,1]. Compare selected output to an independently
  ordered formula within two float epsilons for final rounding and blend order;
  require bit identity for preserved float samples. Check source/mask stability
  and prior output after returned validation/budget failures.

Run the DMD and LDC unittest suites, public API probes with DIP1000, the full
rendered-documentation gate, and the independent ordinary consumer in debug and
release modes. The new meaningful calls are also documented executable examples.
The consumer lock aligns mir-algorithm with its already declared ~>3.22.5 range;
no production dependency requirement is changed.
