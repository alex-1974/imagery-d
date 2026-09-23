# M2.2 — Region Materialization Boundary with raster-d

**Project:** `imagery-d`
**Milestone:** `M2 — Source / Cache / Pipeline Architecture`
**Issue:** `M2.2 — Define region materialization boundary with raster-d`
**Status:** Research draft — not a public API
**Date:** 2026-09-23

## 1. Purpose

M2.2 defines the boundary between:

- logical imagery requests;
- source/decode/materialization semantics owned by `imagery-d`;
- resident raster storage and lifetime owned by `raster-d`.

The central question is:

> Given a logical imagery region that must become available for processing,
> which layer owns each transformation from logical request to resident
> `RasterLease!T` / `ImageView!T`?

The answer must preserve all M1 decisions and must not create a second generic
raster streaming engine in `imagery-d`.

No spelling in this document is a frozen public D API.

## 2. M1 constraints

M2.2 inherits the accepted M1 architecture:

    heterogeneous imagery product / source
                |
                | explicit selection/materialization
                v
           ImageView!T
                |
                +-- one common-grid RasterView!T
                +-- immutable image semantics
                +-- optional same-grid RasterView!ubyte validity
                |
                v
             raster-d

Important M1 invariants:

- `ImageView!T` is a processing view, not a source object;
- one processing image has one common logical grid;
- one processing image has one materialized sample type `T`;
- validity is separate from alpha and NoData;
- global/logical placement is not `RasterView.region`;
- no implicit resampling;
- no implicit common-type conversion;
- `raster-d` owns retained raster resources and view lifetimes.

## 3. M2.1 inputs

M2.1 provisionally distinguishes:

    Source
    Resource
    Locator
    Revision
    Access Backend
    Read Session

The source model can include resource-backed, resource-family and generated
sources.

A generated source may have no encoded byte Resource at all.

M2.2 must therefore define materialization independently from any assumption
that every source is a file-like byte stream.

## 4. Current raster-d production boundary

Current public `raster-d` already supplies the resident half of the boundary.

The public raster package exports, among other things:

- `Region2D`;
- `OwnedByteResource`;
- `PlaneByteLayout`;
- `tryAdoptMallocResource`;
- `tryImportOwnedRaster!T`;
- `RasterLease!T`;
- `RasterView!T`;
- `WritableRasterView!T`.

The retained ownership path is conceptually:

    malloc-compatible owned storage
        ->
    OwnedByteResource
        ->
    tryImportOwnedRaster!T
        ->
    RasterLease!T
        ->
    RasterView!T

`RasterLease!T` retains the validated raster backing.

`RasterView!T` borrows from that lease and must not outlive it.

This is the authoritative resident storage/lifetime model.

`imagery-d` must not reproduce it.

## 5. Current raster-d coordinate boundary

Production `raster.Region2D` deliberately contains geometry only.

Its owner defines the coordinate system.

Therefore the same value type may describe logical/global image regions,
resident raster regions or other rectangular spaces, provided callers never
silently mix coordinate spaces.

`RasterView.region` describes resident descriptor-space geometry.

It does not carry global image placement.

This is a deliberate raster-d invariant that M2.2 preserves.

## 6. Existing raster-d R0.3 evidence

`raster-d` R0.3 already researched the layer immediately above the resident
core.

Its research flow was:

    large logical image
        |
        | output request
        v
    operation dependency
        |
        | required input
        v
    source/cache resolution
        |
        | resident materialization
        v
    RasterLease / RasterView
        |
        v
    raster operation

The experiments proved, among other things:

- logical image size can be much larger than resident storage;
- logical requests can have non-zero origins;
- materialized `RasterView.region` can be rebased to `(0,0)`;
- output decomposition does not need to match source/provider/cache geometry;
- exact neighbourhood processing can use overlapping halo input without
  task-boundary seams;
- source dependency and border/context deficit are distinct;
- no production scheduler/cache/source API is implied.

These research types remain non-public.

`imagery-d` must use the evidence without importing experimental APIs as if they
were stable `raster-d` contracts.

## 7. External reference evidence

### GDAL RasterIO

GDAL can read an arbitrary raster window into a caller buffer.

`RasterIO` also supports output-buffer type conversion, output-buffer size
changes and resampling.

Architectural lesson:

> one backend call may combine windowing, conversion and resampling, but
> imagery-d must keep those semantic decisions separate.

For a direct/native materialization, an adapter must not accidentally invoke
implicit conversion or resampling merely because GDAL can do so conveniently.

### OpenImageIO

OpenImageIO separates custom I/O from decoders and exposes scanline/tile reads.

Architectural lesson:

> decoder-native read granularity does not have to equal the logical region
> requested by imagery-d.

A decoder may fetch complete scanlines or tiles while the higher layer exposes
an exact requested region.

### libvips

A `VipsRegion` represents a small rectangular part of an image and can be
prepared on demand without requiring the whole image in memory.

libvips operator generation works backward from the requested output region:
an operation computes the corresponding input region and requests it.

Architectural lesson:

> output request, operation dependency, and materialized input region are
> separate concepts.

This strongly matches the existing raster-d R0.3 evidence.

## 8. Materialization is not dependency derivation

M2.2 makes a strict distinction:

    operation dependency
        !=
    source materialization

An image operation answers:

> What logical input is required to produce this logical output?

A source materializer answers:

> Make this already-determined logical input region resident.

For identity/direct source access:

    required input == requested output

For a radius-1 neighbourhood operation:

    requested output
        -> operation dependency
        -> expanded logical input
        -> source materialization

M2.2 therefore must not put neighbourhood radius, border policy or filter
semantics into the Source API.

## 9. Generic dependency mechanics

`raster-d` R0.3 demonstrated generic dependency/halo geometry.

Those concepts are not yet production API.

M2.2 should not duplicate them into production `imagery-d` merely to move
forward.

For M2 research, imagery-d may discuss requested output region, required input
region and context deficit conceptually.

When a concrete production operation requires a reusable generic dependency
type, that requirement can justify promotion or a handback to `raster-d`.

Until then no cross-repository API issue is required.

## 10. Coordinate spaces

At least four coordinate spaces may appear during materialization.

### Logical source/image coordinates

The requested region in the selected source/grid.

Example:

    Region2D(1733, 911, 1021, 769)

This region may have a non-zero origin.

### Source-native fetch coordinates

A decoder/backend may internally fetch TIFF tiles, scanlines, JPEG-aligned data,
COG blocks, WMTS tiles or other source-native units.

These are I/O/decode details.

### Resident raster coordinates

The decoded `RasterLease!T` owns resident storage described by `RasterView`.

A resident raster may be rebased to:

    Region2D(0, 0, width, height)

or may represent a larger resident coverage from which an ROI is exposed.

### Exposed processing-view coordinates

An exact processing `ImageView!T` may be a borrowed ROI into a larger retained
resident raster.

Its view geometry is still resident descriptor-space geometry.

Logical/global placement remains separate metadata.

## 11. Logical placement must remain explicit

A materialization result must retain the mapping between logical imagery space
and resident pixels.

It must never infer:

    logical x = RasterView.region.x

or:

    logical y = RasterView.region.y

A conceptual result therefore needs metadata equivalent to:

    logical coverage
    +
    retained resident raster
    +
    mapping between the two

The exact D type remains open.

## 12. Exact-request versus superset materialization

A source may materialize exactly the requested region:

    logical request:     (1733, 911, 100, 80)
    resident coverage:   exact same logical pixels
    RasterView region:   (0, 0, 100, 80)

This is the simple R0.3 experimental path.

But efficient real sources may naturally produce a superset.

Example:

    logical request:     (1733, 911, 100, 80)

    decoded source block coverage:
                         (1728, 896, 256, 256)

    exposed image:
                         exact requested 100 x 80 ROI

M2.2 must permit this.

Otherwise provider tiles or decoder blocks would accidentally become the
processing API.

## 13. Resident coverage

M2.2 therefore needs the concept:

    resident logical coverage

This is the logical-image region represented by one retained resident
materialization.

It is higher-level metadata.

It does not belong inside `RasterView`.

A lease may retain more resident pixels than the exact processing request.

## 14. Exposed request view

When resident coverage is a superset, imagery-d may expose the exact request as
a zero-copy ROI into the retained raster.

Conceptually:

    resident lease
        covers logical C

    requested logical region R
        where R subset C

    exposed ImageView
        = ROI corresponding to R within C

This preserves source-native efficient reads, exact processing-request semantics
and zero-copy subviews where possible.

## 15. Materialized owner concept

M1 already showed that a useful image owner will eventually need to retain:

- primary `RasterLease!T`;
- immutable semantic metadata;
- optional validity `RasterLease!ubyte`.

M2.2 adds source/materialization state such as:

- logical resident coverage;
- exposed logical request;
- source/revision snapshot;
- provenance needed to identify the materialization.

Conceptually:

    MaterializedImage!T
        owns/retains:
            primary RasterLease!T
            image semantics owner
            optional validity RasterLease!ubyte
            logical coverage mapping
            source/revision snapshot

        exposes:
            borrowed ImageView!T

The final type name and public shape remain deferred.

## 16. View lifetime publication rule

An `ImageView!T` cannot safely be published independently from the objects it
borrows.

A successful materialization must therefore first establish all retained
ownership.

Publication order is conceptually:

    acquire / decode
        ->
    construct owned raster resource
        ->
    import into RasterLease
        ->
    retain semantics / validity
        ->
    establish logical-to-resident mapping
        ->
    publish owning materialization result
        ->
    caller borrows ImageView

No partially-owned image view is published.

## 17. Source-session lifetime

A source `ReadSession` should normally be allowed to end after decoding if the
published raster owns independent resident storage.

Thus:

    ReadSession lifetime
        need not equal
    RasterLease lifetime

If a future zero-copy adapter publishes raster storage that aliases a mapped
file, decoder-owned memory or external buffer, then `RasterLease` must retain
the corresponding external ownership obligation.

The view must never borrow indirectly from an already-destroyed source session.

## 18. Source revision snapshot

One materialization should be associated with one coherent source/resource
snapshot.

For resource-backed sources this may include:

- SourceId;
- ResourceId;
- observed ResourceRevision;
- component selection;
- decoder/representation information where required for provenance.

This snapshot is higher-level metadata.

It must not be embedded into `RasterView`.

## 19. Revision consistency

If a materialization requires several reads/ranges:

    read A
    read B
    read C

they must not silently come from different resource revisions.

The materializer/backend layer must either establish consistency, detect a
revision mismatch, or explicitly report that consistency could not be
guaranteed.

A corrupt mixed-revision resident image must not be published as success.

## 20. Transactional success

The default M2.2 materialization contract should be transactional.

Success means:

> the requested logical materialization is complete according to the declared
> semantics and all published retained storage is valid.

Failure means:

> no successful materialized image is published.

This prevents consumers from interpreting a half-decoded image as complete.

## 21. Partial availability

Some future interactive use cases may deliberately accept degraded or partial
imagery.

Examples:

- missing remote tiles;
- progressive decode;
- incomplete render;
- offline cache gaps.

That behavior must be explicit.

M2.2 does not make partial success the default.

M2.4 will research progressive/cancellation semantics.

## 22. Empty logical requests

Empty geometry is valid at the raster-geometry level.

But a source materialization of an empty request does not need resident pixel
storage.

Provisional M2.2 rule:

    empty materialization request
        -> successful no-work / empty outcome
        -> no dummy allocation required

This avoids allocating a fake byte resource merely to construct an empty lease.

## 23. Invalid requests

Invalid logical request geometry must be rejected before source access,
allocation, pointer arithmetic or decoder calls.

A request outside the selected logical extent must not be silently clipped by
the generic materializer.

Clipping may be a deliberate higher-level operation or border policy.

## 24. Context deficit

For neighbourhood dependencies, mathematical input may extend beyond the valid
logical image.

`raster-d` R0.3 showed that clipping alone loses important information.

Therefore:

    valid logical input
        !=
    complete mathematical dependency

M2.2 consumes the valid materializable input.

Border/context-deficit interpretation remains operation semantics.

The source materializer must not silently choose clamp, mirror, wrap, zero or
constant fill.

## 25. Native-grid materialization first

M2.2 should define direct/native-grid materialization only.

That means the selected logical request and resident materialization refer to
one already-selected source grid.

Cross-grid materialization belongs to M2.5.

This keeps M2.2 from accidentally absorbing reprojection, resampling,
pyramid-level selection policy or mixed-resolution product composition.

## 26. No implicit sample conversion

Direct M2.2 materialization should request/produce one explicitly selected
materialized type.

A backend such as GDAL may be capable of conversion in the same read call.

That convenience must not make conversion implicit.

If stored/native and output sample type differ, the conversion must be part of
an explicit materialization policy owned by M2.5 or a later concrete adapter
contract.

## 27. No implicit resampling

GDAL `RasterIO` can resample when source window and output buffer sizes differ.

M2.2 must not use that feature accidentally.

For a direct/native materialization:

    logical source extent size
        ==
    logical output sample grid size

unless an explicit transform policy says otherwise.

## 28. Provider/source tile independence

Provider or codec blocks are an I/O fact.

They do not define processing tasks, image operation region size, cache block
size or scheduler work size.

A 100 x 80 requested processing region may be served from one or several
source tiles and exposed as an exact processing view.

## 29. Cache independence

M2.2 defines materialization semantics, not cache policy.

A request may be satisfied by fresh decode, decoded cache, source-byte cache,
transformed cache or generated data.

The semantic result must not depend on which path supplied the pixels.

M2.3 decides cache layers, keys and budgets.

## 30. Scheduler independence

M2.2 defines one materialization attempt.

It does not decide priority, worker thread, async/future type, cancellation
scheduling, retries, prefetch or duplicate-request coalescing.

M2.4 owns those execution-policy questions.

## 31. Concurrency capability

Materialization code must not assume one opened decoder/session can be used
concurrently.

For example, GDAL documents that ordinary raster-band methods are not generally
thread-safe when invoked concurrently on the same dataset instance.

Concurrency may require separate sessions, backend serialization, per-thread
decoder state or another adapter-specific strategy.

M2.4 will determine how a scheduler consumes that capability.

## 32. Decoder-native read granularity

A decoder may support arbitrary windows, scanlines, tiles or full-image decode
only.

M2.2 must permit all of these while preserving bounded-residency goals where
the format allows them.

A full-image-only decoder is not semantically invalid. It simply has a less
favorable materialization capability/cost profile.

## 33. Required versus fetched versus retained geometry

M2.2 should preserve three different geometries:

    required logical input
        operation semantic requirement

    fetched/decoded logical coverage
        source/decoder work actually performed

    retained resident logical coverage
        pixels currently backed by RasterLease

These may be equal but need not be.

The concepts must not be collapsed.

## 34. Materialization accounting

M2.2 should leave room for instrumentation such as:

- requested logical pixels;
- fetched source bytes;
- decoded source pixels;
- retained resident bytes;
- resident coverage;
- decode count;
- materialization count.

These are useful for M2.3/M2.6 and benchmarks.

They are not image semantics and need not live in the public image view.

## 35. Primary and validity materialization

An M1 `ImageView!T` may include optional same-grid `RasterView!ubyte` validity.

M2.2 must allow primary and validity to arise from different source paths.

Before publication as one ImageView:

    primary processing grid
        ==
    validity processing grid

If not, explicit transformation is required.

## 36. Validity ownership

If validity is materialized, its resident storage must have independent
retained lifetime.

Conceptually the owning result may contain:

    RasterLease!T primary
    RasterLease!ubyte validity

The M1 image view then borrows from both.

Neither view may outlive its corresponding lease.

## 37. Source-native mask mismatch

A source mask may be bit-packed, categorical, differently typed or on another
grid.

M2.2 does not force it directly into the `ubyte` validity sidecar.

Normalization into M1 validity is an explicit image materialization step.

Cross-grid normalization belongs to M2.5.

## 38. Resident storage allocation

For ordinary decode into new storage, a practical initial path is:

    determine resident shape/type/layout
        ->
    allocate owned buffer
        ->
    decoder writes into buffer
        ->
    transfer ownership to raster-d
        ->
    RasterLease!T

This gives a clean publication barrier and keeps raw memory ownership inside the
raster lifetime model after import.

## 39. Current raster-d public ownership limitation

Current public `raster-d` supports a safe retained import after an
`OwnedByteResource` exists.

The public raw adoption helper specifically accepts `malloc/free` compatible
storage:

    tryAdoptMallocResource()

Internally, raster-d can represent arbitrary release callbacks/resources, but
the generic raw adoption path is package-internal.

Therefore a separate `imagery-d` package cannot currently adopt arbitrary
decoder-owned buffers with a custom release callback through the public API.

This is not yet a blocker.

Many decoders/backends can write into caller-provided storage.

## 40. Future ownership handback candidate

A concrete future adapter may demonstrate a need for:

- arbitrary externally-owned retained resource adoption;
- custom deleter/context;
- read-only mapped storage;
- multiple independently-owned plane resources;
- zero-copy decoder buffers.

If copying into an imagery-d-allocated buffer is measurably unacceptable, this
would be a generic raster ownership requirement.

That would justify a targeted `raster-d` issue and architecture review.

M2.2 does not request such API expansion speculatively.

## 41. Public one-resource import

The current public `tryImportOwnedRaster!T` imports one owned physical byte
resource whose layout may expose multiple logical planes.

This already supports important cases such as pixel-interleaved RGB and planar
bands stored within one allocation.

It does not by itself expose a public import path for several independently
owned allocations into one `RasterLease`.

This is a future handback candidate only when a concrete imagery adapter proves
the need.

## 42. Buffer ownership versus cache ownership

M2.3 resolves the earlier ownership question through a shared retaining
coverage object above `RasterLease!T`.

Conceptually:

    DecodedCache
        retains
            SharedResidentCoverage!T
                +-- logical coverage
                +-- source/revision snapshot
                +-- accounting metadata
                `-- RasterLease!T

    MaterializationOwner
        independently retains
            the same SharedResidentCoverage!T

    ImageView
        borrows through the MaterializationOwner

The type name remains provisional.

This distinction is important:

    cache membership
        !=
    raster lifetime

Cache eviction drops the cache's retain.

If a materialization still retains the shared coverage, its RasterLease and
pixels remain valid until that final retain is released.

This keeps raster-d as the only resident raster ownership model while allowing
cache and consumer lifetimes to differ.

## 43. Zero-copy cache ROI

If a decoded cache contains a resident superset region, an exact requested view
may be exposed via ROI without copying.

This requires retained cache/lease lifetime, correct logical coverage mapping,
exact request containment and semantic metadata compatibility.

The cache block itself still does not become the processing-coordinate system.

## 44. Generated source boundary

A generated Source may bypass Resource, Locator, AccessBackend, ReadSession and
Decoder, but it does not bypass raster-d ownership.

Its output path remains:

    generated pixels
        ->
    owned resident raster storage
        ->
    RasterLease!T
        ->
    ImageView!T

This confirms that M2.1 Source is broader than file access while M2.2
materialization has one consistent resident endpoint.

## 45. Derived-operation source boundary

A future processing node exposed as a Source may compute its output from other
materialized images.

That must not cause M2.2 to become a general workflow graph.

At this level the node only promises:

> given a valid logical materialization request, produce a retained
> materialization or structured failure.

Dependency graph/scheduling mechanics remain elsewhere.

## 46. Full-extent dependencies

Some operations may require the complete logical input semantically.

This does not necessarily imply whole-image residency.

A full-extent reduction may process bounded chunks.

Therefore M2.2 must not encode:

    full dependency
        =>
    materialize whole source

The operation/execution strategy decides how the dependency is satisfied.

## 47. Neighbourhood example

Consider an exact 3 x 3 filter.

Requested output:

    R = (100, 100, 64, 64)

Operation dependency:

    margins = 1 on every side

Derived valid logical source input:

    S = (99, 99, 66, 66)

M2.2 begins at:

    materialize S

The source may decode a larger source-native tile coverage and retain enough
coverage containing S.

The operation receives an image view representing S plus whatever mapping is
needed to locate R inside S.

No step changes the semantic dependency merely because the provider tile was
larger.

## 48. COG example

Requested direct image region:

    R = (1733, 911, 1021, 769)

The TIFF/COG decoder may resolve this to multiple underlying tiles/range
requests.

The source/backend layer maintains ResourceRevision consistency.

The decoder writes/assembles the requested or a useful superset region into
resident raster storage.

After import, `RasterLease!T` owns decoded pixels independently from the HTTP
read session.

Logical placement remains outside `RasterView.region`.

## 49. Tile-service example

A logical region may intersect several service tiles.

M2.1 resolves the Source request to concrete tile Resources.

M2.2 may fetch/decode required tile resources and assemble an exact requested
resident raster, or retain compatible decoded tile rasters and expose/compose a
higher materialization.

The exact cache/assembly strategy belongs partly to M2.3.

The materialized image semantics must be independent of tile boundaries.

## 50. Local-file example

A TIFF local-file source receives logical request R.

An adapter opens/uses a suitable read session and decoder.

The decoder writes R into caller-owned resident storage.

That storage is imported into `RasterLease!T`.

The file may then close.

The resulting image view remains valid because its resident pixels no longer
borrow from the file handle.

## 51. External-buffer example

Suppose an external decoder returns an internally allocated buffer.

Possible initial solution:

    copy into imagery-d-owned malloc-compatible storage
        ->
    import into raster-d

Possible future optimized solution:

    transfer external ownership callback
        ->
    raster-d retained resource

The optimized path is only justified by a concrete adapter and measurement.

Correct ownership precedes zero-copy ambition.

## 52. Materialization failure categories

M2.2 should eventually distinguish broad failure layers.

### Request/geometry

- invalid logical extent;
- invalid request;
- request outside logical extent;
- incompatible component selection.

### Source/access

- source unavailable;
- access failure;
- revision mismatch;
- cancellation.

### Decode

- unsupported format/representation;
- corrupt source;
- decoder failure;
- insufficient source capability.

### Transform policy

- explicit conversion required;
- explicit resampling required;
- incompatible grid.

### Resident construction

- size/layout not representable;
- allocation failed;
- raster import failed;
- validity construction failed.

This is not yet a final D enum hierarchy.

## 53. Failure ownership

A failed materialization must have deterministic ownership outcomes.

After failure:

- no successful ImageView is exposed;
- no raw allocation is leaked;
- no source session is kept alive accidentally;
- any ownership already committed to raster-d is released through normal RAII
  if the overall result is abandoned.

Higher-level imagery-d materialization should preserve clear transactional
semantics.

## 54. Error translation

Low-level backend/decoder/raster errors should remain available for diagnostics,
but higher layers need stable materialization categories.

Do not flatten every failure into one generic error, and do not expose every
backend-specific error type as stable core imagery API.

## 55. Retry boundary

M2.2 reports one failed attempt.

It does not decide whether to retry.

Retry policy belongs to M2.4 or backend-specific policy.

A decode corruption error and a temporary HTTP timeout must remain
distinguishable enough for that layer to decide correctly.

## 56. Cancellation boundary

M2.2 must permit cancellation to interrupt expensive source/decode work.

The exact cancellation token/task model belongs to M2.4.

One hard invariant can already be accepted:

> cancellation must not invalidate a materialization that has already been
> successfully published.

## 57. Progressive publication

Progressive image quality should not mutate published RasterLease storage behind
existing views unless a future mutable contract explicitly permits it.

A safer default model is separate complete published materializations/stages
that consumers may replace.

M2.4 will research this in detail.

## 58. Threading

The semantic materialization contract should not require a specific worker
model.

Adapters may use thread-safe sessions, one session per worker, serialized
decoder access or internal multithreading.

The returned `RasterLease` semantics remain independent of how decoding was
scheduled.

## 59. Materialization capability and cost hints

M2.6 requires a distinction between:

    can materialize logical region R
        and
    can efficiently materialize logical region R

A scanline or full-decode-only source may semantically satisfy an arbitrary
logical request even when doing so requires much more work than the requested
region suggests.

A source/decoder may therefore expose planning hints such as:

- native block size;
- sequential-only access;
- preferred read order;
- arbitrary-window support;
- full-image decode requirement/cost;
- overview availability;
- range efficiency;
- concurrent-read capability.

These are execution capabilities/cost hints.

They must not change semantic request geometry or the meaning of the requested
image.

## 60. No provider-block API leakage

An imagery consumer should be able to ask:

    give me logical region R

without knowing whether the source uses WMTS tiles, COG tiles, TIFF strips,
scanline JPEG, memory or procedural generation.

This is a primary M2.2 abstraction test.

## 61. Materialization request concept

M2.6 clarifies that M2.2 consumes already-resolved semantic intent rather than
backend execution policy.

A future materialization request may conceptually contain:

    Source/component selection
    logical region
    selected/native grid identity
    requested native/materialized sample type
    source/revision constraints

Higher-level M2.5 planning owns the target-image semantics and produces a
resolved semantic materialization plan.

M2.2 then materializes the required native logical inputs.

An execution plan may choose cache hits, source blocks, fused backend calls or
temporary-buffer strategies without changing the resolved semantic plan.

M2.2 does not freeze any of these type names.

## 62. Materialization result concept

A successful future result may conceptually retain:

    source snapshot
    exposed logical request
    retained logical coverage
    primary RasterLease!T
    immutable image semantics
    optional validity RasterLease!ubyte
    mapping to exposed ImageView!T

The result owns; the ImageView borrows.

## 63. Why the result should own

Returning only a bare `ImageView!T` would force one of several bad choices:
leak source/session lifetime into the caller, use hidden global ownership, own
pixels inside ImageView, or weaken lifetime guarantees.

An explicit retaining result/owner is consistent with both M1 and raster-d.

## 64. Why RasterLease should stay visible internally

Even if a future imagery-d public API hides raw `RasterLease!T` from ordinary
image consumers, implementation architecture should continue to use it as the
single retained resident-storage capability.

That avoids parallel ownership systems.

## 65. RasterView.region must not become logical placement

It may be tempting to construct the resident raster using the logical request
origin and thereby carry placement "for free".

M2.2 rejects that as the general imagery solution.

Logical placement stays above RasterView.

## 66. A mapping is not necessarily a geotransform

The logical-to-resident relation in direct native-grid materialization can be
simple integer translation/cropping.

Do not prematurely expand M2.2 into CRS transformation, geodesy or
reprojection.

Those belong to geospatial/product/grid layers and M2.5 when materialization
changes grids.

## 67. Materialization and image semantics

The decoder/source layer may discover metadata needed for M1 image semantics:
channel identities, alpha, scale/offset, NoData, colour metadata and units.

Before the final ImageView is published, imagery-d binds that metadata to the
retained raster planes.

`raster-d` does not interpret it.

## 68. Metadata lifetime

Image semantic metadata must outlive every borrowed ImageView that references
it.

A materialization owner should therefore retain immutable metadata alongside
the raster lease.

ROI shares it.

## 69. Product metadata versus view metadata

Not all source/product metadata belongs in every ImageView.

Materialization should transfer only metadata required to interpret the
materialized processing image.

Broader acquisition/catalog/provenance metadata can remain associated with the
Source/Product/Snapshot.

## 70. Current raster-d handback status

M2.2 does **not** currently require a raster-d change.

The existing public resident core is sufficient for correctness-first
materialization through caller-owned malloc-compatible storage.

Potential future generic handbacks are:

1. public safe/trusted adoption of arbitrary external ownership callbacks;
2. public multi-resource import for independently owned planes;
3. promotion of generic dependency/halo types from R0.3;
4. possibly a generic higher-level logical-placement wrapper.

None should be requested until a concrete production consumer demonstrates the
need.

## 71. Pressure case A — exact local window

Source: local TIFF.

Request: logical native-grid region R.

Decoder: supports arbitrary region read into caller buffer.

Result: **PASS.**

No new raster-d API required.

## 72. Pressure case B — remote COG

Source: HTTP COG.

Request: logical native-grid region R.

Backend/decoder resolves range reads / TIFF blocks.

Result: **PASS.**

Revision consistency belongs to source/access layer.

Decoded resident lifetime belongs to raster-d.

## 73. Pressure case C — source-block superset

Source: tiled TIFF / decoded cache.

Request: R smaller than cached/decoded block C.

Result: **PASS.**

Retain C and expose R as zero-copy ROI with separate logical placement mapping.

This argues strongly against requiring exact-request allocation for every
materialization.

## 74. Pressure case D — neighbourhood halo

Operation requests output R and semantically requires halo-expanded input S.

Result: **PASS.**

Dependency derivation precedes M2.2.

M2.2 materializes S.

## 75. Pressure case E — external decoder-owned buffer

Decoder returns memory whose release function is owned by the foreign library.

Result: **ARCHITECTURALLY FITS, PUBLIC RASTER BRIDGE MAY BE MISSING.**

Correctness can initially be achieved by copying to raster-d-compatible owned
storage.

A zero-copy path may later require a generic raster-d ownership-adoption API.

## 76. Pressure case F — separate plane allocations

Decoder naturally yields R/G/B or spectral planes in independent allocations.

Result: **ARCHITECTURALLY FITS, CURRENT PUBLIC IMPORT MAY REQUIRE ASSEMBLY/COPY.**

`RasterBacking` can internally represent multiple resources, but the public
import path currently exposes one owned resource.

Gather concrete adapter/performance evidence before changing raster-d.

## 77. Pressure case G — validity from separate mask

Primary and mask are separate source assets.

Result: **PASS if common-grid after explicit normalization.**

Retain independent leases; image owner publishes one ImageView borrowing both.

Different-grid masks require M2.5 transform policy.

## 78. Pressure case H — generated source

No file, network resource or decoder exists.

Result: **PASS.**

Generated source fills caller-owned resident storage, transfers it to
RasterLease, and publishes normal image semantics.

## 79. Pressure case I — full-extent reduction

Operation needs global statistics but can stream bounded regions.

Result: **PASS at architecture level.**

M2.2 can materialize successive bounded logical regions.

Full semantic dependency does not force one full-image RasterLease.

## 80. Accepted M2.2 boundary

### imagery-d owns

- Source/component selection;
- logical image/grid extent;
- logical materialization request;
- source/revision snapshot;
- decoder/materialization semantics;
- source-native fetch resolution;
- image semantic metadata;
- primary/validity association;
- logical-to-resident mapping;
- exact processing-view exposure;
- explicit conversion/resampling intent.

### raster-d owns

- raster resource adoption/import;
- resident backing validation;
- retained pixel ownership;
- plane layout/strides;
- `RasterLease!T`;
- `RasterView!T`;
- writable raster capability;
- zero-copy resident ROI;
- generic raster operations;
- generic dependency/halo mechanics if/when promoted.

### M2.3 owns

- cache classes;
- cache key;
- budgets;
- eviction;
- cache reuse/deduplication.

### M2.4 owns

- scheduling;
- priority;
- cancellation mechanism;
- retries;
- prefetch;
- concurrent request coalescing;
- progressive refinement lifecycle.

### M2.5 owns

- cross-grid materialization;
- explicit resampling;
- explicit sample conversion;
- heterogeneous product compatibility/materialization.

## 81. Candidate M2.2 invariants

1. Logical request coordinates remain outside RasterView.
2. `RasterView.region` is resident descriptor-space geometry.
3. Image/provider/cache/processing coordinates must not be conflated.
4. Materialization consumes an already-determined logical input requirement.
5. Operation dependency derivation is not a source responsibility.
6. Provider tiles/codec blocks do not define processing region geometry.
7. A source may materialize a superset of the requested logical region.
8. Exact processing views may be zero-copy ROIs into retained supersets.
9. The materialization owner retains all raster/metadata lifetime needed by
   ImageView.
10. ReadSession/decoder lifetime need not extend through ImageView lifetime
    after independent raster ownership has been established.
11. One successful materialization represents one coherent source/resource
    revision snapshot.
12. Multi-read decode must not silently mix revisions.
13. No ImageView is published before ownership/lifetime invariants are complete.
14. Failure does not publish a partially valid image by default.
15. Partial/degraded results require explicit semantics.
16. Empty logical requests need not allocate resident storage.
17. Invalid requests are rejected rather than silently clipped.
18. Border policy is not source materialization policy.
19. Direct M2.2 materialization does not implicitly resample.
20. Direct M2.2 materialization does not implicitly convert sample type.
21. Primary and validity must share the processing grid before one ImageView
    binds them.
22. Cache policy does not alter materialization semantics.
23. Scheduler policy does not alter materialization semantics.
24. Generated and resource-backed sources converge on raster-d retained
    resident storage.
25. raster-d remains the only resident raster ownership model.

## 82. Rejected alternatives

### Put global origin into RasterView.region

Reject as the general imagery solution.

### Source returns bare ImageView

Reject because a view alone does not own the raster lease or semantic metadata
it borrows.

### Source API exposes provider tiles directly as processing unit

Reject because it couples algorithms to transport/codec geometry.

### Materializer computes filter halo

Reject because halo/dependency belongs to operation semantics before source
materialization.

### Always materialize exactly the requested region

Reject as a hard invariant because it prevents efficient reuse of
source-native/cached superset coverage.

### Let GDAL/OIIO silently convert/resample

Reject because backend convenience must not bypass explicit imagery-d semantic
policy.

### Keep source session alive behind every ImageView

Reject as a default because decoded resident ownership should be independent
where possible.

### Reimplement RasterLease in imagery-d

Reject because resident ownership is a raster-d responsibility.

## 83. Open questions

### Q1 — materialization owner name

Possible conceptual names:

    MaterializedImage!T
    ImageLease!T
    ImageMaterialization!T
    ResidentImage!T

No decision yet.

### Q2 — resident superset representation

Should one owner expose retained logical coverage + exact logical request +
borrowed ROI, or should cache-level ownership and request-level ownership be
separate?

M2.3 evidence is needed.

### Q3 — logical grid descriptor

M2.2 assumes one selected grid but does not freeze its representation.

M2.5 and wider geospatial architecture must inform this.

### Q4 — decoder capability query

What planning information can be known before opening/decoding?

### Q5 — ownership adapters

Which real decoder is the first case that cannot efficiently write into
caller-owned malloc-compatible storage?

### Q6 — multi-resource raster import

Will real image decoders benefit enough from independently-owned planar buffers
to justify a public raster-d multi-resource constructor?

### Q7 — dependency promotion

Which first production image operation needs the generic R0.3 dependency model?

Likely M3, not M2.

## 84. M2.2 provisional decision

The preferred architecture is:

    downstream/output intent
            |
            v
    operation computes required logical input
            |
            v
    M2.2 materialization request
        - Source/component
        - selected grid
        - logical region
        - materialized type/policy
            |
            v
    source-specific resolution
        - resources / tiles / reads
        - decoder-native fetch geometry
        - revision consistency
            |
            v
    decoded owned resident storage
            |
            v
    raster-d ownership/import
            |
            v
    RasterLease!T
            |
            +-- logical coverage metadata retained above raster-d
            +-- immutable image semantics
            +-- optional validity lease
            |
            v
    owning materialization result
            |
            v
    borrowed exact ImageView!T

This keeps source semantics, resident raster mechanics and execution policy
separate.

## 85. Cross-library conclusion

No immediate `raster-d` issue is required by M2.2.

Current raster-d is sufficient for correctness-first materialization through
caller-owned malloc-compatible buffers.

Record these future handback candidates:

- arbitrary external retained-resource adoption;
- multi-resource public raster import;
- promotion of generic dependency/halo contracts;
- generic logical-placement wrapper if a non-image consumer also needs it.

Open a raster-d issue only when a concrete adapter or production operation
demonstrates one of these requirements.

## 86. M2.2 status

M2.2 architecture has now passed M2.6 validation.

The previously open resident-superset ownership question is provisionally
resolved by M2.3:

    shared retained coverage above RasterLease
        +
    independent cache/materialization retains

M2.6 additionally confirms:

- semantic materialization capability must be separated from access cost;
- M2.2 consumes resolved semantic input requirements rather than deciding
  target-image policy;
- execution strategy may change without changing materialization semantics.

M2.2 should remain open until the focused M2 contract experiment verifies the
shared-coverage lifetime and semantic-plan/execution-plan separation.

No production materialization API is admitted yet.

## 87. M2.6 validation update

The validated boundary is now:

    TargetImageContract
        |
        v
    ResolvedMaterializationPlan
        |
        | derives source-native logical requirements
        v
    M2.2 native materialization
        |
        v
    RasterLease-backed retained coverage

while:

    ExecutionPlan

may choose cache/backend/task strategies around this boundary without changing
the semantic result.

This addition does not move target-grid selection, resampling policy or sample
conversion into M2.2.

## 88. References

Primary external references used for M2.2:

- GDAL `GDALRasterBand::RasterIO` / `ReadRaster`:
  https://gdal.org/en/stable/doxygen/classGDALRasterBand.html

- GDAL raster API tutorial:
  https://gdal.org/en/stable/tutorials/raster_api_tut.html

- OpenImageIO documentation:
  https://openimageio.readthedocs.io/

- libvips `VipsRegion`:
  https://www.libvips.org/API/current/class.Region.html

- libvips operator generation:
  https://www.libvips.org/API/current/extending.html

Project evidence used:

- `raster-d/source/raster/region.d`
- `raster-d/source/raster/backing.d`
- `raster-d/source/raster/owned_resource.d`
- `raster-d/source/raster/import_owned.d`
- `raster-d/docs/research/regions-streaming.md`
- `raster-d/experiments/r0_3_regions_streaming/`
