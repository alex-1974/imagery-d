# Bounded registered RGBA8 mosaic

`imagery.mosaic.multiresolution` is an opt-in candidate for #148 and the RGBA8
display portion of #144. It assembles a caller-supplied target ROI from up to
16 registered image pyramids. It connects the existing overview selector,
decoded raster views, explicit resampling and #147 contributor normalization.
It is available in both DUB configurations. Existing nearest-tile and two-RGB
overlap entry points retain their original contracts.

## Registration and input

Each source declares immutable identity/revision, common grid identity, ordered
overview dimensions, regular tile dimensions, straight alpha association and a
versioned quality policy. Every overview and source covers the **same complete
logical extent**, with compatible axis direction and pixel-cell alignment.
The common grid identifier asserts that registration; it does not prove it.
Reprojection, arbitrary affine warps, partial footprint geometry, acquisition
ranking and file/HTTP decoding remain with the caller.

Axes are positive and at most 2^30, tile axes at most 256, and source count
1..16. The explicit bounds permit exact unsigned/signed 64-bit coordinate
products and bound scratch independently of the dataset dimensions. Tile indices
are zero-based at each level. Edge tiles have `min(tileSize, remaining)` shape.
The source returns four encoded-sRGB byte planes plus an optional separate
one-plane binary validity view. Nonzero mask bytes mean valid; an empty mask
means every pixel is valid. Planar/interleaved data and signed strides are
accepted through raster-d, with no raw memory layout assumptions.

The provider is synchronous: `ready` invokes its scoped consumer exactly once
with valid shapes; `missing` invokes it zero times. Other states, malformed
shapes, repeated callbacks and inconsistent statuses fail the job. The consumer
copies only the tile's intersection with the current block's sampling footprint
into engine-owned memory. Views and plane windows
expire with the callback; no provider raster lease is retained. Providers must
bound/release their own decode storage. The engine cannot bound a provider that
loads the entire dataset internally. Inputs and their metadata must remain
unchanged for the duration of the call; callbacks must not retain the consumer.

## Sampling

The full target grid determines overview selection and sampling, even when the
materialized ROI is tiny. The coarsest adequate level is selected independently
for each source. If no level is adequate, nearest/bilinear select the finest
and record `avoidsUndersampling=false`. Area rejects enlargement on either axis.

For target coordinate `x`, selected source width `S` and target width `T`:

| Filter | Horizontal rule (vertical rule is analogous) |
|---|---|
| Nearest | `floor((x+1/2)*S/T)`; center ties select the right sample |
| Bilinear | Interpolate around `(x+1/2)*S/T-1/2`, clamp to `[0,S-1]` |
| Area | Integrate source pixel cells over `[x*S/T,(x+1)*S/T)` |

Integer rational coordinates determine indices and overlap numerators, so
rounding cannot select an extra cell at a boundary. Fractions and channel
accumulation use float64. Bilinear drops zero-fraction neighbours. Area visits
only positive cell overlaps. Every positive contributor must be valid; one
missing or masked tap excludes that source sample. NoData is not interpolated
across or renormalized away. Filtering fetches any neighbouring tiles it needs;
callers do not supply or guess a halo.

ROI coordinates always refer to the full target grid. Output owners contain
only `region.width * region.height` pixels. Sampling and spatial quality use
global coordinates, making independently requested partitions byte-identical
for stable tile data and pointwise quality providers, regardless of cache history
and layout. A quality provider must return the same factors at a global pixel
independently of the requested block/ROI partition or callback order.

## Color, alpha and quality

The input declaration is specifically **straight encoded-sRGB RGBA8**.
Unspecified/unknown or premultiplied association is rejected rather than guessed.
color-d supplies sRGB decoding, linear premultiplication, unpremultiplication,
encoding and byte quantization. Filtering works on linear premultiplied RGB and
alpha. Hidden RGB under zero alpha cannot create colored fringes.

Each source supplies constant `QualityContributor` factors or a scoped quality
reader for bounded, one-row target blocks. The latter fills factors for the
resampled sample in global coordinates, and is identified by policy/revision.
Every returned factor is validated, even on excluded records. A false provider
return or malformed factor fails the complete job. Sampling validity then
excludes unavailable observations before `tryQualityWeights` normalizes the
remaining masses. Zero/excluded factors avoid unnecessary image reads.

The result is a **conditional normalized mixture**, not source-over and not
geometric union coverage. Relative coverage, quality and preference determine
source influence; weighted opacity is accumulated separately. A valid transparent
sample participates without becoming NoData. All-transparent eligible samples
produce valid transparent black. No eligible sample produces NoData transparent
black, distinguished by the separate validity byte. No pixel value is a sentinel.

Output is straight encoded-sRGB RGBA8, with nearest-byte alpha. If quantized
alpha is zero, RGB is canonical zero. Convex LDR accumulation can round by ulps
outside its mathematical `[0,alpha]` range; it is bounded to that range before
unpremultiplication. This is not an HDR/gamut-mapping policy. Independent
references allow adjacent bytes only at an actual quantizer half boundary;
same-build partitions and layouts must match exactly.

## Memory, execution and failure

`maxResultBytes` covers exactly five bytes per ROI pixel: an RGBA owner and a
separate validity owner. Checked preflight prevents multiplication overflow.
`maxWorkBytes` covers four raw tile-cache slots and fixed-capacity block buffers:

```
4 * max(tileWidth*tileHeight) * 5
+ sources * min(ROI.width,256) * min(ROI.height,16)
    * (sizeof(LinearSample) + sizeof(QualityContributor))
+ sources * (sizeof(QualityContributor) + sizeof(double))
```

On the qualified 64-bit compilers, the maximum is **6,029,952 bytes**, below
8 MiB, independent of source/target dimensions. These are engine pixel/scratch
payloads; raster/allocator metadata, bounded stack state, O(source count)
immutable provenance and provider-owned decode memory are outside that number.
The formula and measured counters are deliberately not a total-RSS promise.
Malloc scratch is deterministically freed on every exit. Output uses raster-d
retained leases; copying a completed frame retains its two owners. There are
no whole-canvas descriptors, tile arrays or retained dataset owners.

`maxSourceSamples` bounds positive filter taps and preflights potentially huge
area footprints. `maxTileReads` bounds provider calls, including missing tiles.
The LRU cache has four slots. Small 256-by-16 target blocks reuse source tiles
vertically before switching to the next source. Only their needed source
rectangles are copied; the cache checks those rectangles before reusing a tile
entry. A new block needing another part of the same tile may call the provider
again. Real decode/IO latency therefore remains part of consumer qualification;
the provider may use its own explicitly bounded decoded-tile cache. Work remains synchronous and
serial; no hidden threads or shared mutable globals are introduced. Callers can
schedule independent frames themselves; raster-d lease refcounts are non-atomic.

Cancellation is cooperative, polled at blocks, area/bilinear source rows,
before provider reads and immediately before publication. A provider must
implement its own cancellation for a long decode. There is no partial frame
publication. Every returned failure preserves the prior frame, owners and
provenance, as does a thrown exception. Callback `Exception`s map to
`callbackException`; `Error`s propagate. Allocation failure is explicit where
malloc/raster adoption can report it. An immutable metadata allocation can throw
an allocation Error without replacing the prior frame.

`MosaicError.init` is `notAttempted`; `MosaicFilter.init` is unspecified, source
and request defaults are incomplete, and `MosaicFrame.init` is empty. A metrics
default is a zero receipt, not proof of success. The `out` metrics parameter
resets on entry and reports attempted work even on failure. Source provenance
is copied before callbacks and includes selected index/dimensions/adequacy,
tile geometry, policy identities and constant factors. The frame records target,
ROI, filter and `registered-rgba8-linear-premultiplied-conditional-v1`.
Source/policy revisions must encompass validity, registration and all provider
data versions. This metadata does not itself identify library/build revisions;
persist those separately when reproduction across builds matters.

## Reproducing qualification

```
dub build --root=tests/feature_program --compiler=dmd-2.111.0 --build=debug
python tools/verify-mosaic.py tests/feature_program/feature-program-oracle
API_PROBE_CONFIG=no-io DC=dmd-2.111.0 bash tools/verify-api-probes.sh
dub build --root=tests/feature_program --compiler=ldc-1.43.0 --build=release
python tools/verify-mosaic.py tests/feature_program/feature-program-oracle
taskset -c 0 tests/feature_program/feature-program-oracle --mosaic-bench
taskset -c 0 tests/feature_program/feature-program-oracle --mosaic-bench-fractional
```

The test-only Python reference uses exact rational cells and independent sRGB
transfer equations. It checks 19 cases with three different pyramids, non-power
reductions, enlargement, spatial qualities, masks, missing tiles and alpha.
The D consumer additionally proves exact partition/layout equality, ownership
across replacement, failure rollback, budget boundaries, final-poll cancellation
and a 2^30-by-2^30 logical source serving a 2-by-2 viewport from one tile.
Compile probes reject retention of either borrowed pixels or the consumer.
Performance receipts state measured scope; 60 fps is a target, not an API claim.
See the [dated qualification and throughput receipt](benchmarks/mosaic-2026-11-22.md)
for recorded errors, compiler gates, copy reduction and the outstanding display gate.
