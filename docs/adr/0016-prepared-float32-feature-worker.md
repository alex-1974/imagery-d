# ADR 0016 — Prepared float32 feature planes

Status: implemented and locally qualified candidate; integration in progress.

## Decision

#195 is implemented as an explicit `Float32FeatureWorker` in the opt-in
`imagery.analysis.feature_worker32` module. The existing `Engine` preserves its
float64 output and cache contract. Pixel working samples may be float32 or
float64; calculations remain float64, with explicit float32 publication.

The worker evaluates one prepared feature family on many bounded tiles. It
owns output planes, finite/validity masks and family-specific scratch; setup
prepares nondefault Gabor weights once. Evaluation is `@safe nothrow @nogc`.
It accepts raster-d's callback-scoped `RasterPlaneWindow` with signed row/sample
strides, plus an optional binary mask. The complete halo must already exist in
the working tile, including the caller's source-edge extension. No generic
raster view, pointer-validation or ownership machinery is reimplemented.

The caller declares raw measurement versus normalized linear luminance.
Luminance-specific heuristics require the latter domain. RGB transfer remains
owned by color-d; callers prepare and share a luminance working plane. Encoded
RGB-only oklab/clipping/underexposure/visibility and global/fitted/CLAHE operations
keep their existing interfaces. The worker supports the remaining tiled scalar
analysis families and typed local/path/ridge/line/Gabor/shadow parameters.

## Output and precision

Three float32 numeric planes, validity, orientation validity and a separate
float32 range-failure mask replace stored per-pixel `Value` records. Existing
kernel `Value` temporaries are register results, not output arrays. Separable
windows, compound morphology and shared path DAGs publish through statically
specialized output policies; the original float64 engine uses its own policy.

A finite valid double result is converted at publication. If any channel's
conversion is nonfinite, all numeric channels are zero, validity is zero and
rangeFailure is one. Mathematical invalidity/NoData keeps rangeFailure zero.
Underflow to zero is normal quantization; orientation validity is cleared if
strength becomes zero. Consumers must use the orientation mask, including for
numeric angle channels that contain an otherwise rounded kernel value.

Path direction aggregation retains a double scalar accumulator per output.
This prevents a nonrepresentable strong direction from being replaced by a
weaker representable direction, while allowing a genuinely better finite
winner to restore representability. Profile range failure persists across its
required radii. Scientific callers needing wider output range or precision use
the float64 engine. No existing float64 result is silently narrowed.

## Lifetime, validation and failure

The worker is noncopyable and requires serial use. Every input coordinate is
proved inside the supplied window by core/capacity/halo validation before
raster-d's unchecked data-plane loads. Finite/mask checks run once on the
expanded tile, rather than on every kernel tap. Input windows and rows are
never retained beyond evaluation. Input storage must remain stable during a
call and must not alias the worker's output buffers.

The result contains readonly views of worker-owned GC arrays. Views are
logically invalidated by the next successful evaluation or prepare; copy pixel
data when a retained snapshot is required. Failed evaluations preserve preceding
published buffers. The `out` result itself resets to `.init`, as required by D.

Preparation validates arguments, allocates a candidate and replaces preceding
state only on success. Invalid setup throws `Exception`. Evaluation returns
`FeatureWorkerError`, whose `.init` is `notAttempted`, rather than allocating an
exception inside raster-d's `nothrow @nogc` callback. Per-sample missing/range
conditions are reported by masks, not by failing the complete tile. This setup
versus evaluation distinction is deliberate and matches the scoped callback
contract. No new production `@trusted` boundary is introduced.

## Qualification

The independent consumer compares all supported default features on scalar
float32/float64 and RGB-derived double luminance with masks, NaN, source-edge
padding, negative row/sample strides, interleaved sample spacing and padding.
It reuses workers for smaller interior ROIs and checks exact float conversions
of the float64 engine results. Nondefault parameters, metadata identity, failed
setup/evaluation, range loss, tiny strength, directional overflow and maximum
prepared payload are separate tests. Actual callback dispatch and every
successful evaluation allocate zero bytes; the function types enforce this.

The benchmark compares an independently compiled delegate-sampling float64 AoS
reference with prepared SoA workers on identical double working planes/halos.
It includes each tile's finite preparation, arithmetic and output stores, and
excludes setup, input generation and checksum traversal. Window/path comparisons
also include the previously admitted shared algorithms; their entire speed
difference is not attributed solely to dispatch or storage format.

See the dated feature-program receipt for final observed errors, measurements,
compiler matrix and remaining integration work. No stable API freeze follows.
