# ADR 0025: scalar source borrowing and complete planar publication

Date: 2026-11-24

Status: implementation candidate; numerical, resource and timing admission are separate

Related: #212, #216; ADR 0022

## Decision and measured scope

Keep the existing complete-frame Engine/worker comparisons. Add a separately
labelled view-only consumer for both AoS Float64 and planar final Float32
publication. Hashes are outside the timer. A separate untimed full consumer
validates the same fixture after view-only work; its hash is not evidence that
the timed no-op consumer materialized the frame. Actual published sample and
computed tile counts remain observable.

Instrument direct planar cache publication and callbacks, including cache hits.
The compatibility conversion adapter attributes conversion/cache and callback
time separately rather than charging both to sink. These optional profile
clocks are absent from ordinary builds. The proposed 5 ns/pixel envelope applies
only to the explicitly named 1024² scalar planar view-only phase sum. It never
silently replaces the older complete-frame budgets or qualifies their rows.

## Optional source transport

`Source.read` remains required and unchanged. Optional `readPlane` (Float64)
and `readPlane32` (Float32) synchronously lend a raster-d `RasterPlaneWindow`
covering exactly the requested source halo. The provider either calls the
consumer exactly once and returns true, or declines without a call. It must
preserve read's values/validity and keep backing bytes unchanged during the
borrow; masked sources must decline. Invalid call counts/extents fail before
output publication.

The consumer is `@safe nothrow @nogc` and cannot escape. A direct window
reference cannot escape under DIP1000; copying nested raster views still has
the documented semantic borrow obligation. No deeper static guarantee or new
raster ownership machinery is claimed. The Engine retains no provider window.

For a single basic/structural scalar feature, fuse source packing and finite
unit-domain validation into the row kernel's existing private halo carrier.
Clamp source borders outside the lane loop, read through raster-d's signed
stride row access and reduce invalid lanes without constructing a scalar
validity plane. Unsupported samples, signed negative zero, scientific ranges,
RGB, masks and mixed-family requests retain the complete Sample/Point path.
Final output validity, range and orientation masks are unchanged.
`FeaturePlanes32.tryCopyTo` supplies checked bulk placement into a caller-owned
dense frame; it validates all extents/buffers before copying any samples.

## Planar cache ownership

Once rendering completes, transfer the private producer arrays into the cache
entry and return equally sized spare/evicted arrays to the producer. Do not
copy the three planes and three masks. Validate capacity/budget and allocate
spares before commit. Unpublished computations never modify a live entry;
subsequent scratch writes cannot modify another retained entry. Metadata,
source/parameter identities and publication rounding remain unchanged.

Charge the full producer capacities and fixed metadata slots, including partial
edge tiles. Every swapped working array has the original execution-edge
capacity, so tile scratch accounting stays conservative and exact. This private
synchronous cache does not implement independently retained subscriber owners
or the different accounting contract in #74.

## Qualification

Differential tests compare Sample and Float32/Float64 plane providers over
negative row strides, partial edge tiles, NaN/Inf, negative zero and scientific
offsets. Clean cases must actually enter the borrow path. Cache tests prove
that overwriting returned scratch preserves retained pixels and invalid
exchange requests preserve committed state. Positive and negative DMD/LDC
DIP1000 probes cover the public callback/reference boundaries.

Retain baseline binaries from the measurement-only commit, identical-work
ABBA cells, complete fingerprints, zero warm thread-GC proofs, owned array
payloads and rejected cycles. Report profile clocks separately from primary
latency and classify insufficient/noisy evidence as pending. No approximation,
new CPU minimum or automatic relaxation of targets is introduced.

The packer uses validated affine row loads. raster-d 0.5.5's contiguous span
helper confuses element strides with byte sizes for float/double, as reproduced
in [raster-d #290](https://github.com/alex-1974/raster-d/issues/290). Dense and
gapped windows therefore use the correct row.load operation until upstream is
fixed. No dependency-local patch is required.
