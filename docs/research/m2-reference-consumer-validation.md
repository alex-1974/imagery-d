# M2.6 — Reference-System and Consumer Validation Matrix

**Project:** `imagery-d`
**Milestone:** `M2 — Source / Cache / Pipeline Architecture`
**Issue:** `M2.6 — Validate source/cache/pipeline model against reference systems and consumer cases`
**Status:** Research synthesis draft — not a public API
**Date:** 2026-09-23

## 1. Purpose

M2.6 validates the combined M2.1–M2.5 architecture against mature reference
systems and concrete imagery workloads.

The goal is not to find systems that merely resemble the proposed design.

The goal is to identify:

- contradictions;
- missing concepts;
- accidental coupling;
- abstractions that are too broad;
- abstractions that are too narrow;
- implementation-policy decisions that have leaked into semantics.

M2.6 does not freeze public D type names.

---

## 2. Architecture under test

The M2 architecture currently proposes:

    ImageryProduct
        |
        v
    Source / Resource model
        |
        v
    explicit product/component selection
        |
        v
    target image contract
        |
        v
    compatibility / materialization planning
        |
        v
    cache + in-flight lookup
        |
        v
    source-native materialization
        |
        v
    explicit transforms
        |
        v
    shared retained resident coverage
        |
        v
    RasterLease!T
        |
        v
    retaining materialization owner
        |
        v
    borrowed ImageView!T

Cross-cutting concepts include:

    Resource revision
    provenance
    cancellation
    priority
    cache budgets
    progressive refinement
    validity
    target-grid identity

---

# Part I — Reference-System Matrix

## 3. GDAL

### Relevant evidence

GDAL separates several responsibilities that M2 also separates:

- VSI abstracts local, memory, archive and network byte access;
- `/vsicurl/` provides random remote range access;
- `/vsicurl_streaming/` represents a materially different sequential access
  capability;
- the global raster block cache is distinct from VSI byte caching;
- `RasterIO` can window, convert sample type and resample;
- dataset/file-handle pools are separately bounded;
- cache and I/O behavior can be tuned independently.

GDAL also demonstrates a risk:

> one convenient backend call can combine several semantic transformations.

### M2 result

**PASS, with one caution.**

M2's separation of:

    AccessBackend
    Decoder
    native decoded cache
    explicit type conversion
    explicit resampling

is stronger semantically than exposing `RasterIO` behavior directly.

That is desirable.

### Required M2 constraint

A GDAL adapter may fuse operations for performance, but it must execute an
already-resolved imagery-d semantic plan.

It must never allow GDAL defaults to decide:

- target type;
- resampler;
- NoData/validity interpretation;
- grid choice.

---

## 4. GDAL multi-cache pressure

GDAL has:

- a global raster block cache;
- VSI caches;
- `/vsicurl/` range caching;
- open-dataset pools with separate memory/handle constraints.

### M2 result

**STRONG PASS for global budget direction.**

M2.3 correctly identifies that independent caches compete for the same process
RAM.

A local per-cache limit alone is not enough.

### M2 refinement

The imagery-d budget controller should treat backend-owned memory as:

    externally accounted / estimated overhead

when it cannot directly control it.

The global residency budget cannot necessarily be mathematically exact for
foreign libraries.

It should distinguish:

    controlled imagery-d residency
    known backend reservations/limits
    observed external overhead

rather than claiming complete process-RSS control.

---

## 5. OpenImageIO ImageCache

### Relevant evidence

OpenImageIO ImageCache:

- accesses very large sets of images with bounded tile memory;
- manages open file handles separately;
- is thread-safe;
- can virtual-tile untiled images;
- lets callers retain tile references;
- will not purge retained tile storage until references are released;
- permits invalidation while old retained tiles remain valid;
- can distinguish cached tile pixel type from on-disk type;
- supports procedural/custom inputs;
- supports retry policy.

### M2 result

**STRONG PASS.**

The following M2 decisions are directly reinforced:

    cache membership != retained value lifetime

    invalidation != mutation of old value

    cache tile geometry != mandatory source-file geometry

    decoded pixel type != encoded sample type

    open session pool != decoded pixel cache

    generated source can fit same downstream cache/materialization model

### Important confirmation

M2.3's proposed shared retained coverage above `RasterLease!T` is well aligned
with OIIO's retained tile semantics.

---

## 6. OpenImageIO decoder configuration

OpenImageIO format plugins can have configuration values that change pixel
interpretation, for example orientation, alpha handling, RAW behavior or
format-specific processing.

### M2 result

**PASS.**

M2.3/M2.5 correctly require all output-affecting decoder configuration to be
either:

- fixed by the adapter/source contract;
- or part of decoded/materialized identity.

### Additional caution

A decoder's default behavior is part of no stable imagery-d semantic contract.

Adapters should request deterministic behavior explicitly where possible.

---

## 7. libvips

### Relevant evidence

libvips is demand-driven.

Requested output regions pull required input regions through operations.

`VipsRegion` represents prepared rectangular pixel regions.

`tilecache` caches computed pixel regions under configurable cache geometry and
eviction policy.

### M2 result

**STRONG PASS.**

This supports:

    output request
        !=
    input dependency
        !=
    source/provider geometry
        !=
    cache tile geometry
        !=
    scheduler task geometry

M2.2 and raster-d R0.3 already use the same separation.

### Important architectural lesson

Demand-driven execution does not require semantic image objects themselves to
contain scheduler state.

M2.4 correctly keeps request/scheduler state outside `ImageView!T`.

---

## 8. Cloud Optimized GeoTIFF

### Relevant evidence

COG relies on:

- tiled/reduced-resolution TIFF organization;
- GeoTIFF metadata;
- HTTP range access;
- partial retrieval of only needed parts of large imagery.

### M2 result

**STRONG PASS.**

COG validates the Resource-backed Source model:

    Source
        ->
    Resource
        ->
    Locator
        ->
    range-capable backend
        ->
    decoder-native fetches
        ->
    logical materialization

It also validates that:

    requested logical region
        !=
    fetched byte ranges
        !=
    decoded source blocks

### Revision requirement

M2.1's coherent ResourceRevision requirement remains necessary when one image
materialization uses multiple HTTP ranges.

---

## 9. xarray

### Relevant evidence

`xarray.Dataset` represents heterogeneous named variables rather than forcing
them into one common array.

Variables can differ in dtype and dimensions.

Backends can expose lazy reads.

Decoding options such as mask-and-scale can change the values presented to the
caller.

### M2 result

**STRONG PASS for Product != ImageView.**

M2 should keep:

    heterogeneous product/container
        !=
    homogeneous typed processing image

M2.5's explicit raw versus scaled/physical materialization choice is also
reinforced.

---

## 10. xarray + Dask

### Relevant evidence

Dask-backed xarray supports larger-than-memory computation through chunks and
lazy task execution.

Chunk size has major performance consequences.

On-disk chunk geometry and processing chunk geometry can align for efficiency
but need not be identical.

Rechunking can be expensive.

### M2 result

**PASS with an important refinement.**

M2 correctly separates source/provider/cache/processing geometry.

However:

> canonical cache decomposition is not purely an LRU implementation detail.

Its geometry can materially affect I/O amplification, task count, memory
working set and transform cost.

### Required M2 refinement

Cache-block/chunk geometry remains non-semantic, but it is a first-class
performance policy informed by:

    source-native block geometry
    expected request geometry
    operation dependency/halo
    RAM budget
    network latency/bandwidth
    transform cost

No universal fixed block size should be assumed.

---

## 11. Dask task graphs

Dask represents lazy operation dependencies explicitly as task graphs.

### M2 result

**NO NEED TO COPY THE GENERAL DAG MODEL.**

M2.5 introduces real multi-source dependencies:

    transformed production
        waits for
    multiple native productions

M2.4 also requires cancellation/priority propagation.

This means imagery-d needs the *ability to represent internal dependencies*.

It does not yet imply a public general-purpose DAG framework.

### Refined rule

M2 may require:

    one production
        has finite required child productions

without introducing:

    public arbitrary workflow graph API

This is a useful middle ground.

---

## 12. MapLibre

### Relevant evidence

MapLibre is an important concrete interactive-map consumer.

Its resource-provider model supports:

- externally handled resource requests;
- cancellation when the map no longer wants a resource;
- checking cancellation before expensive work;
- completing or releasing retained request handles.

### M2 result

**STRONG PASS.**

This validates:

    viewport demand is revocable

    cancellation belongs to request lifecycle

    result lifetime is distinct from request lifetime

    resource work should check cancellation before expensive operations

### M2 refinement

Cancellation responsiveness should be measurable as a performance/UX
characteristic, not merely boolean capability.

---

## 13. OpenEXR

### Relevant evidence

OpenEXR supports:

- arbitrary named channels;
- HALF/FLOAT/UINT channel types;
- x/y channel sampling rates;
- multipart files;
- deep data.

### M2 result

**STRONG PASS.**

This validates the M1/M2.5 boundary:

    file
        !=
    homogeneous image

and:

    selected product channels
        may require
    type/grid compatibility analysis

It also validates preserving unknown/custom channel semantics.

---

## 14. STAC

### Relevant evidence

STAC separates:

- Item identity;
- Asset dictionary keys;
- Asset `href`;
- Asset roles;
- collection/provider metadata.

### M2 result

**PASS.**

This supports:

    semantic product/resource identity
        !=
    locator

and reinforces avoiding `Provider` as the name of the low-level technical
access abstraction.

---

# Part II — Consumer Validation Matrix

## 15. Consumer C1 — Local large GeoTIFF

### Scenario

A multi-gigabyte local TIFF is larger than desirable RAM residency.

User requests a small viewport.

### Expected path

    Source
        -> local Resource
        -> file Locator
        -> native metadata probe
        -> decoded cache lookup
        -> decoder reads needed source blocks
        -> retained coverage
        -> exact ROI ImageView

### Result

**PASS.**

No whole-image residency required.

No global coordinates required inside `RasterView`.

No production scheduler semantics leak into image view.

---

## 16. C2 — Remote COG interactive viewport

### Scenario

User pans and zooms over a large HTTP COG.

### Required properties

- HTTP range access;
- reduced-resolution levels;
- byte-range reuse;
- decoded-block reuse;
- request cancellation;
- priority promotion;
- bounded RAM;
- source revision consistency.

### Result

**PASS.**

M2.1–M2.4 cover the required architecture.

### Performance requirement added

The future benchmark corpus must measure at least:

    source bytes transferred
    number of HTTP requests
    decoded pixels
    cache hit rate
    time-to-first-visible-result
    cancellation waste
    peak controlled residency

---

## 17. C3 — WMTS / tile service

### Scenario

A logical layer is represented by a tile service rather than one persistent
file.

### Expected path

    Source
        + logical/tile request
        -> concrete tile Resource(s)
        -> HTTP access
        -> decode
        -> cache/materialization

### Result

**PASS.**

This confirms the M2.1 Source-above-Resource split.

### Important rule

URL templates remain locator recipes.

They are not Source identity and not final cache identity.

---

## 18. C4 — Generated source

### Scenario

Deterministic procedural imagery used for tests or a derived source node.

### Result

**PASS.**

Generated sources can bypass:

    Resource
    Locator
    AccessBackend
    Decoder

while converging on the same:

    retained RasterLease
        ->
    materialization owner
        ->
    ImageView

This confirms that the byte-access path must remain optional.

---

## 19. C5 — Sentinel-2 mixed-resolution product

### Scenario

Request B04/B8A/B11 as one float physical-reflectance image.

### Requirements

- multiple source components;
- multiple native grids;
- explicit target grid;
- explicit resampling;
- scale/offset;
- composite Resource snapshot;
- transformed cache identity.

### Result

**PASS.**

M2.5 is sufficient conceptually.

### Remaining dependency

The exact target-grid descriptor remains intentionally unresolved.

This must not block M2 if ADR 0003 records the semantics required of that
future type without freezing its implementation.

---

## 20. C6 — OpenEXR heterogeneous channels

### Scenario

One file contains HALF RGB, FLOAT depth and subsampled channels.

### Result

**PASS.**

M2.5 can:

- select only compatible channels;
- require conversion;
- require grid normalization;
- reject deep/flat incompatibility.

No pressure exists to make `ImageView!T` heterogeneous.

---

## 21. C7 — Neighbourhood filter with halo

### Scenario

A 3x3 image operation is decomposed into many tasks.

### Requirements

- derive halo before source materialization;
- overlapping source input;
- no processing seams;
- bounded residency;
- cache reuse across overlapping halo.

### Result

**PASS.**

raster-d R0.3 already supplies experimental correctness evidence.

### Cross-library conclusion

Generic dependency/halo semantics still belong in raster-d if promoted.

imagery-d owns image-operation semantics that instantiate the generic
dependency.

No immediate raster-d issue is required.

---

## 22. C8 — Source changes while old view is displayed

### Scenario

A file or remote Resource changes after one decoded result is already visible.

### Result

**PASS.**

Architecture behavior:

    old materialization
        retains old snapshot / RasterLease

    current Resource index
        advances to new revision

    future lookup
        does not reuse invalid old snapshot as current

No active pixels are mutated.

---

## 23. C9 — Concurrent duplicate requests

### Scenario

Several visible render tasks require one decoded block simultaneously.

### Result

**PASS.**

M2.4 single-flight architecture provides:

    one ProductionKey
    one shared production
    multiple subscribers

Priority donation can promote prefetch/background work.

---

## 24. C10 — Memory pressure with active views

### Scenario

The cache wants to evict blocks still displayed by active consumers.

### Result

**PASS.**

M2.3 correctly distinguishes:

    cache membership
        from
    retained lifetime

Cache removes its reference.

Consumer retain keeps the `RasterLease` alive.

---

## 25. C11 — Request spans several cache blocks

### Scenario

Exact desired ImageView requires pixels from four decoded coverage objects.

### Result

**PASS, but exposes an explicit cost.**

M1's current ImageView has one primary RasterView.

The initial architecture therefore may assemble into one contiguous/logically
single resident raster.

### Decision

Do **not** introduce a segmented ImageView in M2 solely to avoid this copy.

Measure first.

A later segmented-view proposal requires concrete benchmark evidence.

---

## 26. C12 — Untiled scanline image

### Scenario

A large JPEG or scanline-oriented file has poor small-random-window behavior.

### Result

**PASS.**

The architecture can represent:

    sequential / coarse-grained source capability

without pretending arbitrary region access is cheap.

Virtual cache tiles may still be useful, as demonstrated by OIIO.

### Requirement

Source/decoder capability metadata should distinguish:

    semantic support for region materialization
        from
    cost/efficiency of region materialization

---

## 27. C13 — Full-image-only decoder

### Scenario

A format/decoder must decode the whole image even for a small request.

### Result

**PASS.**

The Source can still satisfy the request.

Its cost profile is poor, but semantics remain valid.

### Important rule

Bounded-residency is an architectural goal, not a false promise that every
format supports efficient bounded decoding.

---

## 28. C14 — Stale offline cache

### Scenario

Remote source is unavailable; a persistent cache contains an older snapshot.

### Result

**PASS only with explicit policy.**

The cached snapshot can be returned only when the caller/application explicitly
allows stale/offline data.

Actual source revision/freshness must remain visible in provenance/status.

---

## 29. C15 — Cancellation during non-cancellable codec work

### Scenario

Viewport request disappears while foreign codec is inside a blocking decode.

### Result

**PASS with best-effort semantics.**

Subscriber detaches.

Codec work may finish.

Complete result may be discarded or cache-admitted according to policy.

No thread is force-killed.

---

## 30. C16 — Progressive overview to detail

### Scenario

Display lower-resolution imagery quickly, then replace with final detail.

### Result

**PASS.**

Each stage is a complete immutable materialization with its own semantic key.

The request/subscriber layer defines refinement ordering.

No existing RasterLease is mutated.

---

## 31. C17 — Independent primary and quality Resources

### Scenario

Primary spectral data and quality mask are in separate Resources/revisions.

### Result

**PASS.**

M2.5 composite upstream snapshots and validity policy cover this.

Product-level atomic coherence may or may not be available.

That limitation is represented rather than fabricated.

---

## 32. C18 — Same semantic output via two execution strategies

### Scenario

Target output contract is fixed:

    float
    target grid G
    bilinear resampling

Strategy A:

    decode native
    cache native
    resample in imagery-d

Strategy B:

    GDAL adapter fuses decode + conversion + resampling

Both produce the same defined output contract.

### Result

**ARCHITECTURAL GAP FOUND.**

M2.5 currently describes the target and compatibility plan, but M2 should
explicitly distinguish:

    semantic materialization plan
        from
    execution strategy

This is required so that:

- cache/production identity depends on semantics;
- optimization strategy can change without changing result identity;
- provenance can record execution details without poisoning semantic reuse;
- different adapters can satisfy the same target contract.

---

# Part III — Required New Distinction

## 33. Target contract versus resolved semantic plan

A `TargetImageContract!T` expresses what the caller wants.

A **Resolved Materialization Plan** conceptually records how the selected
product components semantically satisfy that target.

It contains decisions such as:

    selected ordered components
    selected concrete representations/snapshots
    target grid
    target T
    required conversion semantics
    required radiometric semantics
    required resampling semantics
    required validity semantics
    source dependency footprints

It does **not** specify:

    worker thread
    cache hit/miss
    GDAL versus native implementation
    exact temporary buffers
    fused versus unfused execution
    task partition sizes

No type name is frozen.

---

## 34. Semantic plan versus execution plan

M2.6 introduces the explicit distinction:

    semantic plan
        = what result means / which transformations define it

    execution plan
        = how this machine produces that result now

The semantic production/cache key is derived from the semantic plan.

The execution plan may depend on:

    available cache entries
    source capabilities
    adapter capabilities
    RAM pressure
    CPU count
    network conditions
    benchmark-tuned block sizes

Changing execution strategy must not change the semantic result.

---

## 35. Why this distinction matters

Without it, one of two bad outcomes appears:

### Too much in cache key

If execution details are part of identity:

    fused GDAL result
        !=
    unfused imagery-d result

even when pixels are semantically guaranteed equivalent.

Reuse becomes unnecessarily fragmented.

### Too little planning

If all planning is deferred to execution:

backend defaults can silently choose semantics.

The resolved semantic plan prevents both failures.

---

# Part IV — Cache-Layer Clarification

## 36. Three cache layers are reuse boundaries

M2.3 currently describes:

    source / encoded-byte cache
    decoded native-raster cache
    transformed/materialized cache

M2.6 confirms those are useful distinctions.

But they must not be interpreted as a mandatory linear pipeline.

---

## 37. Requests may bypass layers

Examples:

### Generated source

    Source
        -> generated RasterLease

No encoded-byte cache is involved.

### Complete transformed-cache hit

    request
        -> transformed cache hit
        -> ImageView

No source or decoded lookup may be necessary.

### Decoder fusion

    Resource
        -> fused decode/resample output
        -> transformed result

A native decoded cache insertion may be skipped.

### Tiny local image

The engine may choose no caching at all.

---

## 38. Refined cache rule

Cache layers describe:

> semantically distinct reusable representation boundaries.

They do not require:

> every request must materialize every intermediate representation.

This clarification should be incorporated into M2.3 before closure.

---

# Part V — Performance-Policy Findings

## 39. Cache block geometry is first-class policy

Dask, OIIO, libvips and GDAL all show that chunk/block geometry matters greatly
for performance.

Therefore M2 should explicitly treat cache geometry as a policy informed by:

    source block/chunk geometry
    request shapes
    halo/dependency sizes
    decode amplification
    memory budget
    I/O latency
    transform cost

But it remains non-semantic.

---

## 40. Source preferred geometry

M2.1/M2.2 Source/decoder capabilities should be able to expose hints such as:

    natural block width/height
    strip height
    preferred sequential direction
    overview levels
    expensive random access
    full-decode-only

These are planning hints.

They do not define image semantics.

---

## 41. Scheduler task geometry

Task partitioning can differ again from cache geometry.

For example:

    source tile: 512 x 512
    decoded cache block: 256 x 256
    transform task: 1024 x 128
    requested viewport: 1437 x 821

This must remain legal if dependencies and memory budgets are satisfied.

---

# Part VI — Failure and Consistency Validation

## 42. Access failure separation

Reference systems reinforce M2.1/M2.2's layered failure model.

Transport, decode, compatibility, transform and resident-construction failures
must remain distinguishable enough for:

- retry policy;
- diagnostics;
- fallback;
- user-visible error reporting.

Result:

**PASS.**

---

## 43. Revision consistency

COG/range access and mutable source caches reinforce:

> one materialization must not silently mix Resource revisions.

Result:

**PASS.**

---

## 44. Product-level consistency

Reference systems do not provide a universal answer for atomic multi-Resource
product snapshots.

Therefore M2.5 is correct to represent:

    per-resource coherence
        separately from
    known product-level coherence

Result:

**PASS.**

---

# Part VII — Cancellation and Concurrency Validation

## 45. Subscriber/production split

MapLibre request cancellation and HTTP cache request collapsing both support the
M2.4 distinction.

Result:

**STRONG PASS.**

---

## 46. Priority

Priority changes urgency but not pixels.

Result:

**PASS.**

It remains outside cache/production semantic identity.

---

## 47. Child dependency propagation

A transformed production may need many decoded child productions.

Priority and cancellation need to propagate to those children.

Result:

**PASS with bounded dependency-set abstraction.**

No general public DAG is required yet.

---

## 48. Thread-safety capability

OIIO and GDAL both demonstrate that concurrency assumptions vary by object and
backend.

Result:

**PASS.**

M2.1/M2.2 capability discovery remains necessary.

---

# Part VIII — Progressive and Partial Results

## 49. Immutable refinement stages

Reference systems do not provide evidence that imagery-d should mutate already
published raster backing to refine quality.

Result:

**PASS for immutable-stage model.**

This remains the safer default.

---

## 50. Partial spatial coverage

A mosaic with missing tiles is not automatically equivalent to a complete image.

Result:

**PASS for explicit partial/validity semantics.**

M2 should not weaken ordinary successful materialization to mean "whatever
pixels happened to arrive."

---

# Part IX — Architecture Corrections Required Before M2 Closure

## 51. Correction A — add Resolved Materialization Plan

M2.5 should explicitly add:

    TargetImageContract
        ->
    ResolvedMaterializationPlan
        ->
    ExecutionPlan

where:

    TargetImageContract
        = desired semantics

    ResolvedMaterializationPlan
        = selected product snapshot + exact semantic transforms

    ExecutionPlan
        = current cache/backend/scheduling strategy

Only the first two contribute to semantic result identity.

---

## 52. Correction B — cache layers are optional reuse boundaries

M2.3 should state explicitly:

> L1/L2/L3 are conceptual reuse boundaries, not mandatory stages that every
> materialization must instantiate.

---

## 53. Correction C — global budget scope

M2.3 should avoid implying exact control over total process RAM when foreign
libraries maintain internal caches/buffers.

Refine terminology to:

    imagery-d controlled residency budget

plus:

    configured/observed backend memory

The application can aim at total process budget but cannot always account every
foreign allocator byte exactly.

---

## 54. Correction D — cache geometry as planning policy

M2.3/M2.4 should record cache/chunk geometry as a first-class performance policy
rather than a hidden implementation constant.

It remains outside semantic identity.

---

## 55. Correction E — internal finite dependency sets

M2.4/M2.5 should acknowledge that one production may depend on several child
productions.

This is sufficient for current needs.

Do not introduce a general public DAG abstraction.

---

## 56. Correction F — materialization capability cost

M2.2 should distinguish:

    can materialize arbitrary logical region

from:

    can efficiently materialize arbitrary logical region

A scanline/full-decode codec can satisfy the semantic request while having a
poor random-window cost profile.

---

# Part X — Decisions That Survived Validation

## 57. Source and Resource remain separate

**ACCEPT.**

Tile services and generated sources make this necessary.

---

## 58. Resource identity and Locator remain separate

**ACCEPT.**

STAC, redirects, signed URLs and mirrors support this.

---

## 59. Revision remains separate from Resource identity

**ACCEPT.**

Mutable local/remote resources and caches require it.

---

## 60. AccessBackend and Decoder remain separate

**ACCEPT.**

GDAL VSI and OIIO custom I/O support this architecture.

---

## 61. ImageView remains resident processing view

**ACCEPT.**

No reference/consumer pressure requires source/cache/scheduler state inside it.

---

## 62. RasterLease remains resident ownership boundary

**ACCEPT.**

No new raster ownership layer is justified.

---

## 63. Logical placement remains above RasterView

**ACCEPT.**

raster-d R0.3 and large-image materialization cases support it.

---

## 64. Provider/cache/task geometry remain separate

**ACCEPT.**

GDAL, OIIO, libvips and Dask all reinforce this.

---

## 65. Three conceptual cache representation layers

**ACCEPT, WITH CLARIFICATION.**

They are optional reuse boundaries, not mandatory pipeline stages.

---

## 66. Shared retained coverage object

**ACCEPT as M2 architecture direction.**

It cleanly separates cache membership from RasterLease lifetime.

Exact D type remains unfrozen.

---

## 67. Subscriber versus shared production

**ACCEPT.**

Required for correct cancellation and duplicate-work coalescing.

---

## 68. Cooperative cancellation

**ACCEPT.**

No architecture should depend on forcible thread termination.

---

## 69. Explicit target image contract

**ACCEPT.**

Required for heterogeneous product materialization.

---

## 70. No implicit conversion/resampling

**ACCEPT.**

Backend fusion is allowed only after semantics are explicit.

---

## 71. Composite upstream snapshot

**ACCEPT.**

Multi-Resource product materialization requires it.

---

## 72. Immutable progressive stages

**ACCEPT.**

No need to mutate published RasterLease backing.

---

# Part XI — Reference Matrix Summary

## 73. Compact matrix

| Concern | GDAL | OIIO | libvips | COG | xarray/Dask | MapLibre | M2 outcome |
|---|---|---|---|---|---|---|---|
| Source/I/O abstraction | strong | strong | indirect | strong | backend-based | provider-based | accept |
| Partial region access | strong | tiles/scanlines | strong | strong | chunks | tiles/resources | accept |
| Separate cache layers | yes | image/tile | tile/op cache | transport pressure | chunks/cache | resource cache pressure | accept |
| Bounded residency | yes | strong | strong | enables | strong | required | accept |
| Cache geometry != processing | yes | yes | yes | yes | yes | yes | accept |
| Cancellation | backend dependent | limited | evaluation-dependent | transport | scheduler-dependent | explicit | subscriber/production split |
| Heterogeneous product | drivers | subimages/channels | image-centric | file-centric | strong | source-centric | keep Product separate |
| Explicit transforms | backend can fuse | configurable | ops | n/a | decode/alignment | rendering | resolved semantic plan |
| Progressive | overviews | MIP/thumbnail | demand | overviews | lazy levels possible | map-oriented | immutable stages |
| Revision/invalidation | source-specific | explicit invalidate | upstream mutation rules | HTTP validators | store-dependent | prior ETag/data | keep snapshot model |

The table is architectural evidence, not an API comparison.

---

# Part XII — Consumer Matrix Summary

## 74. Compact consumer matrix

| Consumer case | Result | Important M2 concept |
|---|---|---|
| local huge TIFF | pass | bounded native materialization |
| remote COG | pass | range access + byte/decoded cache |
| WMTS | pass | Source -> Resource family |
| generated source | pass | Source without byte Resource |
| Sentinel mixed bands | pass | explicit target contract |
| OpenEXR heterogeneous channels | pass | compatibility analysis |
| neighbourhood halo | pass | dependency before materialization |
| mutable source | pass | immutable revision snapshots |
| duplicate concurrent requests | pass | shared production |
| pinned active cache data | pass | retain != cache membership |
| multi-block ImageView | pass with assembly cost | no segmented view yet |
| untiled/sequential source | pass | capability/cost hints |
| offline stale cache | pass with explicit policy | stale is not current |
| progressive overview/detail | pass | immutable stages |
| fused vs unfused transform | gap resolved by new plan split | semantic plan != execution plan |

---

# Part XIII — Promotion-Gate Implications

## 75. No production source/cache API yet

M2.6 validates the architecture direction.

It does **not** yet justify production implementation.

Reasons:

- public type names remain intentionally unfrozen;
- target-grid type is unresolved;
- first real backend/decoder consumer is not selected;
- cache block policy needs benchmark evidence;
- lifecycle transitions are not mechanically tested yet.

---

## 76. Research experiment now justified

Unlike earlier M2 stages, M2.6 now provides enough stable semantics to justify
one focused research experiment.

The experiment should not implement networking or a full cache.

It should mechanically validate the lifecycle and identity model.

---

## 77. Proposed M2 research experiment

Suggested experiment:

    experiments/m2_source_cache_pipeline_contract/

It should use deterministic generated sources and small raster-d-backed
materializations.

No production package/source changes.

---

## 78. Experiment goals

The experiment should prove:

### Identity

- equal semantic plans produce equal production keys;
- different target type/grid/policy produces different keys;
- priority/generation do not alter keys.

### Single-flight

- two equal requests create one production;
- subscribers share the result.

### Cancellation

- one subscriber can cancel without cancelling another;
- all-subscriber cancellation can stop before publication;
- completion-vs-cancel has one terminal result.

### Lifetime

- cache eviction drops cache retain only;
- delivered materialization remains valid;
- final retain releases RasterLease.

### Superset coverage

- cached resident coverage can expose exact zero-copy ROI.

### Plan/execution separation

- two execution strategies satisfying one semantic plan produce the same
  semantic key and exact result.

---

## 79. Experiment non-goals

Do not include initially:

- real HTTP;
- GDAL;
- OpenImageIO;
- disk cache;
- thread pool benchmark;
- full scheduler;
- general DAG;
- real resampling;
- production API promotion.

The experiment is a contract test, not a prototype image engine.

---

# Part XIV — M2 Issue Closure Direction

## 80. M2.1

Architecture validated.

Can close after incorporating the Source capability/cost wording and final
terminology review.

---

## 81. M2.2

Architecture validated.

Can close after incorporating:

- shared retained coverage result from M2.3;
- semantic capability versus efficient-access capability;
- ResolvedMaterializationPlan boundary.

---

## 82. M2.3

Architecture validated with corrections.

Before closure add:

- reuse-boundary-not-mandatory-pipeline rule;
- controlled versus external backend-memory accounting;
- cache geometry as explicit performance policy.

---

## 83. M2.4

Architecture validated.

Before closure add:

- finite child-production dependency concept;
- cancellation responsiveness as measurable capability;
- resolved semantic key may become known after product resolution.

---

## 84. M2.5

Architecture validated with one important addition.

Before closure add:

    TargetImageContract
        ->
    ResolvedMaterializationPlan
        ->
    ExecutionPlan

This is the main M2.6 architecture correction.

---

## 85. M2.6

The validation matrix is complete when the corrections above are reflected in
the M2 research set and the focused lifecycle experiment is either:

- run successfully;
- or explicitly deferred by M2.7 with rationale.

The preferred path is to run it before the M2 ADR.

---

# Part XV — Candidate Architecture After Validation

## 86. Validated M2 architecture

    ImageryProduct
        |
        v
    component/source discovery
        |
        v
    TargetImageContract!T
        |
        v
    resolve representations + revisions
        |
        v
    ResolvedMaterializationPlan
        |
        | semantic identity
        +---------------------------> Production / transformed-cache key
        |
        v
    ExecutionPlan
        - cache-hit strategy
        - source blocks/chunks
        - fused/unfused adapter choice
        - task decomposition
        - memory admission
        |
        v
    shared production lifecycle
        |
        +--> source/byte reuse boundary (optional)
        |
        +--> decoded-native reuse boundary (optional)
        |
        +--> transformed reuse boundary (optional)
        |
        v
    SharedResidentCoverage!T
        |
        +-- logical coverage
        +-- source/composite snapshot
        +-- accounting
        `-- RasterLease!T
                |
                v
    retaining materialization owner
        |
        +-- exact logical request mapping
        +-- immutable image semantics
        +-- optional validity coverage/lease
        +-- broader provenance
        |
        v
    borrowed ImageView!T

Cross-cutting:

    Subscriber/Demand
        - priority
        - generation
        - cancellation

These do not alter semantic production identity.

---

# Part XVI — Final M2.6 Conclusions

## 87. Conclusion

No reference system or consumer case found a contradiction requiring M1 to be
reopened.

No evidence requires:

- heterogeneous `ImageView!T`;
- source/cache state inside RasterView;
- provider tiles as processing units;
- a second raster ownership model;
- a public general-purpose scheduler/DAG;
- implicit sample conversion;
- implicit resampling.

The combined architecture is coherent.

The principal M2.6 improvement is the explicit three-way separation:

    target contract
        ->
    resolved semantic materialization plan
        ->
    execution plan

and the clarification that cache layers are optional reusable representation
boundaries rather than mandatory processing stages.

These should become central M2 ADR concepts.

---

## 88. References

Primary reference material used for M2.6:

- GDAL configuration / block cache:
  https://gdal.org/en/stable/user/configoptions.html

- GDAL virtual file systems and `/vsicurl/`:
  https://gdal.org/en/stable/user/virtual_file_systems.html

- OGC Cloud Optimized GeoTIFF:
  https://www.ogc.org/standards/ogc-cloud-optimized-geotiff/

- OpenImageIO ImageCache:
  https://openimageio.readthedocs.io/en/latest/imagecache.html

- OpenImageIO ImageInput / custom I/O:
  https://openimageio.readthedocs.io/en/latest/imageinput.html

- libvips technical background:
  https://www.libvips.org/API/8.17/how-it-works.html

- libvips tile cache / region APIs:
  https://www.libvips.org/API/8.17/method.Image.tilecache.html
  https://www.libvips.org/API/current/method.Region.prepare_to.html

- xarray + Dask:
  https://docs.xarray.dev/en/latest/user-guide/dask.html

- Dask chunks:
  https://docs.dask.org/en/stable/array-chunks.html

- MapLibre Native resource-provider cancellation:
  https://maplibre.org/maplibre-native-ffi/guides/intercept-network-requests/

- OpenEXR Technical Introduction:
  https://openexr.com/en/latest/TechnicalIntroduction.html

- STAC:
  https://stacspec.org/
  https://github.com/radiantearth/stac-spec/blob/master/commons/assets.md

Project evidence used:

- M1 ADR 0002
- `docs/research/m2-source-resource-access-model.md`
- `docs/research/m2-region-materialization-boundary.md`
- `docs/research/m2-cache-architecture.md`
- `docs/research/m2-demand-cancellation-prefetch.md`
- `docs/research/m2-product-to-image-materialization.md`
- `raster-d/docs/research/regions-streaming.md`
