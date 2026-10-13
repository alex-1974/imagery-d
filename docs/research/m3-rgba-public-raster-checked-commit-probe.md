# M3 RGBA — Existing public raster primitives for contextful checked compositing

**Status:** 2026-10-13 research-only feasibility investigation; **no public
API/implementation/merge admission**. All writes confined to `imagery-d`.
Pinned read-only external contracts: `raster-d v0.2.0`,
`color-d v0.2.0`. Draft PR #73 remains stacked on Draft #69.

## Concrete reviewed public capabilities

The following are from released `raster-d v0.2.0` *public source*,
not assumptions about private address arithmetic:

| API | Callback/context | Destination alias/injectivity | Per-pixel checked failure |
|---|---|---|---|
| [`zipTransformInto`](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/zip_transform_into.d) | Compile-time `@safe pure nothrow @nogc T(T,T)`, **no runtime context** | Validates both *actually reachable* source/target physical relations and destination injectivity **before writes** | **No:** callback only returns T |
| [`transformInto`](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/transform_into.d) | Compile-time pure one-value `T(T)` | Own existing raster validation | **No** runtime context/status |
| [`copyInto`](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/copy.d) | No callback; same `T` source/target | **Yes:** exact physical *copy source vs target* overlap, target injectivity, shapes before copy | `RasterCopyError` for the **copy request only**, not upstream color math |
| `RasterView.trySample`, `WritableRasterView.trySetSample` | Caller controls runtime execution, including `scope` context | Validated reachability/capability; **not** physical source/output noalias or target injectivity as a complete operation | Each sample reports `bool`; caller can classify error but late failures may leave partial pixels |
| `tryImportOwnedRaster`, `RasterLease` | Ownership/resource construction | Validates individual backing reachability/provenance | No cross-operand overlap certificate |

`raster.internal.same_type_overlap`,
`raster.internal.affine_relation`, and execution dispatch are
**package-private**; `imagery-d` must not import them or copy
their physically checked affine relation implementation.

## Feasibility proof: two independent scratch buffers + public packed copy

**Implemented as an extra test path in the existing 432-scene independent
consumer only:**
[`experiments/m3_rgba_layer_compositing/smoke/source/app.d`](
../../experiments/m3_rgba_layer_compositing/smoke/source/app.d).
No new product symbol, production DUB dependency or altered `raster-d`
surface.

For each test scene:

1. Build a **fresh** independent, owned four-plane
   `RasterLease!ubyte` scratch of *only the selected ROI*;
   build a second independent `RasterLease!SRgba8` packed scratch
   and a final independent packed destination (fresh
   `malloc`/public adoption, no reused original storage).
2. Execute `tryCompositeRgbaSourceOverPrepared` into
   the four-plane scratch using its existing classified
   `RgbaCompositeError`, checked conversion and validated
   **runtime** opacity. On an error, the final packed output has
   **not** been touched. PM/metadata/ROI preflight categories
   retain their existing behavior.
3. Convert each scratch four-plane pixel to one
   `color.SRgba8` sample **in the other independently owned
   packed scratch**, checking reads and writes. Again the final
   destination is untouched if staging fails.
4. Invoke the **public** `raster.copyInto` exactly
   **once** from packed scratch plane 0 to packed destination plane 0,
   obtaining a `RasterCopyError`. This validates final packed
   destination injectivity and the *scratch-to-destination*
   physical overlap before writing any final output pixel.
5. Compare **every final RGBA channel byte** with the
   existing direct four-plane compositor/independent 432-scene
   mathematical reference. Separately invoke an intentionally
   aliased packed scratch copy targeting itself, expect
   `RasterCopyError.sourceDestinationOverlap` and verify
   **every** source pixel is unchanged after rejection.

### What this does and does not prove

This is a **buffered/snapshot execution candidate**, not a
way to bolt an extra check onto an otherwise direct zip:
- **It does demonstrate** a public-only *single packed-plane
  final commit* with physical scratch/destination overlap
  rejection, classified **preceding** color-conversion failure
  and exact byte output in the qualified fixture set.
- **It does not demonstrate** an API that rejects physical
  overlap between the **original four-plane inputs** and the
  final destination. Those inputs are consumed before
  the commit; a possible future contract could define
  **snapshot semantics for original source/output overlap**
  instead of rejecting it. That is a **different contract**
  and needs deliberately aliased-source/final-destination
  tests, concurrent-write rules and admission.
- `copyInto` checks only the actual **packed scratch** vs
  **packed target**. It is **not** a standalone public
  physical overlap predicate for arbitrary original sources.
- Final output is **packed `RasterView!SRgba8`**.
  No equivalent single-operation preflight exists in v0.2.0
  for an arbitrary **four separate `ubyte` output plane**
  commit. Calling `copyInto` **four times** cannot provide
  all-four-planes preflight before the first destination write.
- If any source is modified concurrently between preparation
  and commit, the materialized snapshot is not a live
  pixel-execution view; a production contract must specify
  thread/snapshot ownership. This experiment has
  only independent, single-threaded owned sources.
- The buffered test allocates **two separate, ROI-sized
  scratch buffers**, each with 4 bytes/pixel, or
  **8×ROI pixels scratch data bytes**, plus metadata,
  independently of the target and source buffers.
  (E.g. 512²: 2 MiB scratch payload; 2048²:
  32 MiB.) This is **not** a no-allocation
  `@nogc`-per-call/low-residency production path.
  The test's `malloc` allocations are native,
  and therefore invisible to GC byte accounting.
- The test uses the slower four-plane color executor,
  adds two staging loops and copies once; **no
  throughput/latency benefit is claimed**.
  The existing `zipTransformInto` LUT fast path
  remains the separately measured ~2.5×,
  fixed-0.37/narrow-encoding research reference.

### Failure and safety rule

**Do not advertise error atomicity without qualifiers.** Image
color/quantization errors that arise during preparing scratch
leave the **final packed** destination untouched, but may
partially fill internal scratch (which is discarded).
The public final `copyInto` rejects invalid layout/
physical overlaps before its first write. No general
fail-atomic guarantee for unexpected physical memory
failure, external mutation, arbitrary original alias
layouts or multiple-plane destination has been established.

The narrow proof must pass DMD 2.112.1 / 2.113.0 and
LDC 1.42.0 / 1.43.0, with the existing
432-scene oracle and compiler-negative gates.
Until exact-HEAD CI passes, describe the
code as an *implemented probe*, not a qualified result.

## Native nine-stage XPS evidence — 2026-10-13 19:57 UTC

The first [buffered packed-commit XPS measurement and qualification
report](m3-rgba-buffered-copy-xps-2026-10-13.md) is now
retained with the user-supplied checksummed archive identity.
It was compiled from research source **`80415be3...`**
against pinned raster-d/color-d **v0.2.0** with **LDC 1.43.0**.

**24/24** raw CSV SHA-256 checks pass; **108/108**
paired rounds, **972/972** nine-stage measurements,
**216** stage medians. Every tested output pixel equals
the independent original RGBA reference and no measured
current-thread GC byte delta or stderr error occurred.

For the **mixed-alpha** 512² and 1024×768 image/near-full
ROI workloads, the reusable prepared direct four-plane
stage took **106.24/108.03 ns per pixel**, while the
extra-buffered packed-copy stage took **114.45/111.10
ns per pixel**. The original direct four-plane reference
took **207.11/207.63 ns per pixel**. Buffered therefore
remains **~1.82×/~1.86× faster than original direct**,
but has **~6.05%/~4.91% paired-round overhead**
versus the prepared path. The proof covers **reused,
preallocated scratch only**, not allocation-inclusive
first calls or small viewports. Both-full-transparent
inputs behave differently and are reported separately.

The one-time 2 KiB table preparation cost was **18 µs
median** (15–38 µs). Whole **comparison-harness**
RSS was ~53.3–53.7 MiB at 512² and ~153.3–153.8 MiB
at 1024×768, including a broad independent stage
attribution oracle and three extra owned buffers;
this is not isolated product peak memory.

**Do not promote**: the public copy certifies packed
scratch/packed output disjointness/injectivity,
**not** original 4-plane input/output physical
nonoverlap or arbitrary four-plane destination
transactionality. Source snapshot semantics, late
write failures, scratch allocation cost and bounded
small-ROI repetition remain unresolved.

## Next design decision

**Two candidate contracts remain separate:**

1. **Direct, low-memory, 4-plane prepared path:**
   checked runtime opacity and image-domain status,
   caller nonoverlap precondition, possible late partial writes;
   measured ~1.9× native mixed-alpha throughput over old
   4-plane non-LUT reference.
2. **Buffered, packed-target snapshot path:**
   full color-result preparation before final target mutation,
   public `copyInto` single-plane structural/overlap preflight
   and classified copy status, but **8 bytes/pixel**
   scratch payload and additional execution passes;
   no native performance qualification yet.

Neither is equivalent to the separately verified
`zipTransformInto` fixed-opacity pure callback.

**Next scientific gate:** Once compiler tests pass,
benchmark the buffered strategy (including native
allocation, preparation and copy costs) on
real XPS with repeated small ROIs. Decide only
after profiling whether the additional memory
and failure behavior justify this optional
execution policy. No implicit `raster-d`
API design/write is authorized by this probe.
