# M2.3 — Cache Architecture and Cache Identity

**Project:** `imagery-d`
**Milestone:** `M2 — Source / Cache / Pipeline Architecture`
**Issue:** `M2.3 — Define cache architecture and cache identity`
**Status:** Research draft — not a public API
**Date:** 2026-09-23

## 1. Purpose

M2.3 defines the cache architecture that sits between M2.1 source identity,
M2.2 resident materialization, and the later M2.4 scheduler/request lifecycle.

The goal is not merely to add an LRU map.

The architecture must answer:

- what is cached;
- what identifies a reusable cached value;
- how source revision changes invalidate reuse;
- how RAM and disk budgets interact;
- what happens when a cached raster is still in use during eviction;
- how concurrent equivalent requests avoid redundant work;
- how cache policy remains independent from processing semantics;
- how a cache hit remains semantically equivalent to a fresh materialization.

No spelling in this document is a frozen public D API.

---

## 2. Inputs from M2.1

M2.1 provisionally distinguishes:

    Source
    Resource
    Locator
    Revision
    Access Backend
    Read Session

The key identity result is:

    Source identity
        !=
    Resource identity
        !=
    Locator
        !=
    Resource revision
        !=
    cache identity

A locator is only an access route.

A Resource can move without changing semantic identity.

A Resource can also keep identity while gaining a new revision.

Therefore no cache layer may use URL/path text as its complete semantic key.

---

## 3. Inputs from M2.2

M2.2 distinguishes:

    required logical input
    fetched/decoded coverage
    retained resident logical coverage

These geometries can differ.

M2.2 also establishes:

- `RasterLease!T` is the resident raster ownership capability;
- `ImageView!T` borrows from retained ownership;
- a source/native/cache block is not a processing task;
- a retained decoded region may be a superset of an exact request;
- exact processing views may be zero-copy ROIs into retained supersets;
- already-published raster storage must not be mutated by later source
  invalidation.

M2.3 must preserve those rules.

---

## 4. Reference-system findings

### 4.1 GDAL: several caches at different layers

GDAL has multiple independent cache mechanisms.

The raster block cache stores decoded raster blocks under a global memory
budget controlled by `GDAL_CACHEMAX`.

GDAL's VSI layer can additionally cache byte/file access.

For `/vsicurl/`, GDAL uses a process-wide LRU cache for downloaded ranges.
VSI can also add a per-file RAM cache.

Architectural lesson:

> source-byte caching and decoded-raster caching solve different problems and
> should remain different cache layers.

A second lesson is negative:

> independent caches can accidentally consume the same RAM budget at once.

`imagery-d` therefore needs explicit cross-cache residency accounting rather
than assuming each cache's local limit is sufficient.

### 4.2 OpenImageIO ImageCache

OpenImageIO's ImageCache is designed to access many huge images using a bounded
tile cache.

Important properties include:

- approximate maximum memory for cached tiles;
- bounded number of open files;
- on-demand tile loading;
- autotiling of untiled images;
- thread-safe sharing;
- tile reference counting;
- invalidation when a source changes;
- held tile references surviving cache invalidation until released.

Architectural lesson:

> cache membership and object lifetime are different.

A tile can become non-reusable/evictable from the cache while an existing
consumer continues to retain it safely.

This maps naturally to the `RasterLease!T` model.

### 4.3 libvips

libvips distinguishes at least two useful forms of reuse:

- calculated pixel tile caching;
- operation-result caching for side-effect-free operations with equivalent
  arguments.

Its tile cache has its own tile geometry and maximum tile count.

Architectural lessons:

- cache block geometry is an engine/cache policy, not necessarily source
  geometry;
- deterministic transformations can be cached above decoded pixels;
- an operation cache key must include all semantically relevant operation
  arguments;
- invalidation must propagate when a mutable source/operation changes.

### 4.4 HTTP caching

HTTP caching distinguishes:

- cache key;
- freshness;
- validation;
- variant selection;
- shared versus private cache;
- partial responses;
- stale reuse.

A URI alone may be insufficient because response variation can depend on
request metadata such as fields named by `Vary`.

Authorization also constrains shared caching.

Architectural lesson:

> an imagery byte cache must not naïvely treat URL equality as proof that two
> byte responses are interchangeable.

Transport-specific cache semantics should be respected rather than re-created
poorly in the image layer.

---

## 5. Selected cache-layer direction

M2.3 should distinguish three primary reusable representation boundaries:

    L1 — Source / encoded-byte cache
    L2 — Decoded native-raster cache
    L3 — Transformed / materialized-image cache

These names are descriptive only.

M2.6 clarifies that these are **optional reuse boundaries**, not mandatory
pipeline stages.

A request may bypass any layer when appropriate:

- a generated Source may have no encoded-byte cache;
- a transformed-cache hit may bypass native decode;
- a backend may fuse decode and transform without inserting a native decoded
  entry;
- a tiny/local one-shot materialization may choose no cache insertion at all.

A separate open-session/resource pool may exist, but it is not itself one of
the three data caches.

---

## 6. Why three layers

Each cache removes a different cost.

### Source / byte cache

Avoids:

- network transfer;
- slow filesystem reads;
- repeated archive/object reads.

It stores source representation bytes or byte ranges.

### Decoded raster cache

Avoids:

- decompression;
- image-format parsing work;
- repeated native pixel decode.

It stores retained raster pixels.

### Transformed/materialized cache

Avoids:

- explicit sample conversion;
- resampling;
- reprojection when later introduced;
- mask normalization;
- other deterministic materialization transforms.

It stores already transformed processing-ready raster results.

Collapsing these layers into one cache loses control over memory, disk usage,
revision semantics and reuse opportunities.

---

## 7. Open sessions are not pixel cache entries

An open file handle, HTTP connection, GDAL dataset, decoder object or
`ReadSession` can be pooled/reused.

That pool has separate constraints such as:

- maximum handles;
- connection count;
- decoder thread-safety;
- idle timeout.

It should not be conflated with:

    source byte cache

or:

    decoded raster cache

because closing a session does not necessarily invalidate already cached bytes
or decoded pixels.

OpenImageIO explicitly separates open-file management from tile-memory
management.

---

# Part I — Source / Encoded-Byte Cache

## 8. Source-byte cache purpose

The source cache stores encoded representation data before image decoding.

Examples:

- complete small remote object;
- HTTP byte range;
- COG header/IFD ranges;
- TIFF compressed tile payload;
- local slow-filesystem read block;
- archive member bytes;
- service response body.

The source cache does not know image-channel semantics.

---

## 9. Source-byte cache key inputs

A source-byte cache key must derive from the concrete representation being
cached.

Conceptually it can require:

    Resource identity
    Resource revision / validator state
    representation variant identity
    byte range or object-part identity
    cache namespace / security partition where required

It must not be simply:

    URL string

---

## 10. Revision binding

When a strong Resource revision is available:

    ResourceId + strong Revision

forms the safe basis for immutable byte reuse.

A new revision naturally produces a new cache identity.

Old cache entries may remain until evicted if they are still referenced or
useful for provenance/reproducibility.

They must not be silently relabeled as the new revision.

---

## 11. Weak revisions

When only a weak revision is known:

- reuse may require validation;
- persistence may require conservative policy;
- the cache must not claim immutable byte identity.

Examples:

- Last-Modified;
- weak ETag;
- mtime + size heuristic.

A weakly validated entry can still be useful, but its reuse rules differ from a
content-addressed immutable object.

---

## 12. Unknown revision

Unknown revision is a valid state.

Safe policies may include:

- reuse only within one validated/open session;
- protocol-defined freshness;
- explicit revalidation before reuse;
- application-configured offline/stale policy;
- no persistent cross-run reuse.

The architecture must not fabricate a revision token merely to make keying
convenient.

---

## 13. HTTP cache semantics

When the Access Backend is HTTP, standard HTTP caching semantics should be used
where practical.

The imagery layer should not ignore:

- `Cache-Control`;
- freshness;
- validators;
- `Vary`;
- authorization/private-cache constraints;
- partial-content semantics.

An HTTP library/backend may therefore own much of the source-byte cache logic.

M2.3 only requires that the resulting bytes be associated with a coherent
Resource snapshot.

---

## 14. Credentials are not key material

Raw credentials, bearer tokens, signed secrets and authorization headers must
not be embedded into persistent imagery cache keys.

However, access context can affect representation visibility.

Therefore a cache may require a non-secret:

    security partition / cache namespace

to prevent unsafe cross-user or cross-account reuse.

This concept is operational.

It is not Source or Resource semantic identity.

---

## 15. Signed URLs

Temporary signed URLs are especially unsuitable as persistent cache identity.

The signature can change while the underlying Resource revision remains the
same.

A stable Resource/Revision identity should be preferred.

Where unavailable, transport cache policy may conservatively scope reuse to the
signed locator's valid context.

---

## 16. Byte-range cache entries

For range-readable Resources a cache entry may represent:

    ResourceSnapshot
    +
    byte interval [offset, offset + length)

The range cache must not combine ranges from different revisions into one
logical response.

Adjacent range coalescing is an optimization, not semantic identity.

---

## 17. Overlapping byte ranges

Two cached byte ranges may overlap.

M2.3 does not require one exact implementation.

Possible policies include:

- fixed-size cache chunks;
- exact fetched ranges;
- coalesced extents;
- transport-library-managed cache.

The important invariant is that returned bytes correspond exactly to the
requested Resource snapshot.

---

## 18. Source-cache disk persistence

Encoded bytes are the strongest initial candidate for a persistent disk cache.

Reasons:

- encoded payload is compact relative to decoded pixels;
- format decoding can be repeated later;
- strong content hashes/immutable versions can make entries naturally durable;
- source bytes preserve original representation.

Persistent disk caching still needs:

- atomic writes;
- integrity metadata;
- versioned key schema;
- size accounting;
- eviction;
- security namespace;
- stale/revalidation rules.

---

## 19. Content-addressed byte entries

When a trusted strong content hash exists, a persistent blob store can use the
hash as physical blob identity.

But the semantic index still needs:

    Source/Resource snapshot
        ->
    content blob

because semantic Resource identity is not the same as byte content identity.

This enables safe deduplication without collapsing semantic provenance.

---

## 20. Source-cache failure entries

Negative responses such as:

- 404;
- temporary network failure;
- timeout;

should not initially become durable imagery cache entries.

HTTP itself permits caching some negative responses, but retry/failure policy
belongs primarily to M2.4/backend semantics.

A short-lived negative/in-flight suppression table may later be useful.

It should not be confused with the data cache.

---

# Part II — Decoded Native-Raster Cache

## 21. Decoded-cache purpose

The decoded cache stores raster pixels after format decoding but before
higher-level transforms such as explicit cross-grid resampling.

Typical value:

    retained logical coverage
    +
    RasterLease!T
    +
    source/revision snapshot
    +
    native-grid/sample/plane interpretation needed for safe reuse

This is the primary bridge to M2.2.

---

## 22. Decoded cache unit is not provider tile

A cache may choose convenient block geometry.

The cache block:

    != source/provider tile
    != processing task
    != output request

It may happen to align with source blocks when that is efficient.

That is policy, not an API invariant.

---

## 23. Why exact-request caching is insufficient

Caching every arbitrary user request exactly can fragment the cache.

Example:

    request A = (100,100,501,401)
    request B = (101,100,501,401)

These overlap almost completely but produce different exact keys.

A decoded cache should therefore be able to use canonical/cache-policy coverage
blocks or retained supersets.

M2.3 does not freeze block dimensions.

---

## 24. Canonical decoded coverage

One promising direction is:

    selected source/grid level
        ->
    deterministic cache-block decomposition

Example only:

    256 x 256 logical cache blocks

A request resolves to the covering block set.

The block dimensions remain configurable/benchmarked policy.

This improves:

- exact cache keying;
- deduplication;
- concurrent request coalescing;
- predictable memory accounting.

But it must not become processing geometry.

---

## 25. Source-native decoded coverage

Some formats naturally decode one source block efficiently.

In such cases using source-native tile/strip geometry as decoded cache units may
be optimal.

M2.3 should permit adapters to propose native block geometry.

The higher cache contract still treats it as cache coverage, not processing
semantics.

---

## 26. Decoded-cache key dimensions

A decoded cache key needs enough information to guarantee equivalent pixels.

Conceptually:

    SourceId / component selection
    Resource snapshot / revision dependency
    source subimage / part / level
    native grid identity
    decoded channel/plane selection
    materialized sample type T
    decoder-affecting configuration
    logical cache coverage
    relevant validity/NoData normalization mode, if already applied

Not every adapter uses every field.

The key must include every choice that can change decoded pixel values or their
semantic interpretation.

---

## 27. Decoder configuration is key material

Some decoder options change output pixels.

Examples can include:

- RAW demosaic settings;
- orientation handling;
- selected subimage;
- selected MIP/overview;
- channel subset;
- alpha association normalization;
- special format-specific interpretation.

Such settings must either:

- be fixed by the Source/adapter contract;
- or participate in the decoded cache identity.

They must not be invisible mutable global state.

---

## 28. Metadata-only differences

Metadata that does not affect decoded pixel values may not need to duplicate
pixel cache entries.

But if the resulting ImageView semantic interpretation differs, the
materialization binding may still need a distinct higher-level identity.

This suggests separating:

    pixel backing identity

from:

    complete materialized image semantic identity

where profitable.

Do not force the decoded pixel cache to duplicate bytes solely because product
metadata differs.

---

## 29. Decoded-cache value

The strongest current conceptual value is:

    SharedResidentCoverage!T
        source snapshot
        logical coverage
        grid identity
        RasterLease!T
        resident byte accounting
        decode-affecting identity

The name is provisional.

It is an imagery-level retaining object above `RasterLease`.

It does not replace raster-d ownership.

---

## 30. Why a shared resident coverage object helps

M2.2 left an open question:

> Does resident superset ownership belong to a materialization owner, the
> decoded cache, or a shared coverage object?

M2.3 favors:

> a shared retaining coverage object.

The decoded cache retains one reference.

A materialization owner can retain another.

Both ultimately retain the same `RasterLease!T`.

This cleanly separates:

- cache membership;
- raster lifetime;
- exact request views.

---

## 31. Eviction versus lifetime

Eviction means:

> the cache no longer promises this object as a reusable resident entry.

Eviction does **not** mean:

> invalidate all existing users.

If a materialization owner still retains the coverage object, its raster pixels
remain valid.

This matches the OpenImageIO tile-reference model.

---

## 32. Cache eviction sequence

Conceptually:

    cache entry
        holds SharedResidentCoverage
            holds RasterLease

Consumer:
    MaterializationOwner
        holds same SharedResidentCoverage

Evict:
    remove key -> coverage mapping
    drop cache's retain

If consumer still retains:
    pixels remain alive

After final retain disappears:
    RasterLease destruction releases backing

No raw pointer invalidation is needed.

---

## 33. Invalidation versus eviction

These operations must be distinct.

### Eviction

Policy-driven removal to recover cache capacity.

The source may still be perfectly current.

### Invalidation

Correctness-driven declaration that an entry must not satisfy future lookups.

Example:

- Resource revision changed;
- transform implementation version changed;
- source metadata needed for interpretation changed.

Invalidation removes future reuse eligibility.

Held materializations still remain valid snapshots of their old state.

---

## 34. Versioned invalidation

When keys contain strong ResourceRevision identity, revision changes naturally
create new keys.

The old version can simply stop being selected as current.

This is preferable to mutating old cache objects.

Conceptually:

    Resource A @ revision 1 -> old cache entry
    Resource A @ revision 2 -> new cache entry

Both can coexist while old consumers finish.

---

## 35. Weak/unknown revision invalidation

When revision identity is weak or unknown, the cache needs explicit validation
or generation tracking.

Possible mechanisms:

- backend validation epoch;
- session generation;
- explicit invalidate(Source/Resource);
- freshness expiry;
- application refresh event.

M2.3 does not freeze one mechanism.

The important rule is that weak identity cannot silently obtain strong reuse
semantics.

---

## 36. Cache hit types

A decoded lookup may produce:

### Exact hit

Requested cache block equals stored coverage.

### Covering hit

Stored resident coverage contains the requested exact region.

### Multi-entry hit

Several cache entries together cover a requested region.

### Miss

Required pixels are absent or invalid.

M2.3 should not force every request to be copied into one exact buffer solely
because it spans several cache entries.

The later materializer may assemble when one contiguous ImageView is required.

---

## 37. Zero-copy covering hit

A covering hit is especially valuable.

If cached coverage C contains request R:

    C retains RasterLease!T
    R maps to a RasterView ROI

The materialization owner retains C and exposes a borrowed exact ImageView ROI.

No pixel copy is required.

---

## 38. Multi-entry result

An M1 `ImageView!T` currently wraps one primary `RasterView!T`.

Therefore a request covered by several disconnected cache entries cannot be
represented directly as one ImageView without either:

- assembling into one resident RasterLease;
- introducing a later higher-level segmented view abstraction;
- changing the processing contract.

M2.3 should not change M1 for cache convenience.

The initial correctness path may assemble when necessary.

---

## 39. Decoded cache and validity

Primary pixels and normalized validity may be cached:

- together as one materialization unit;
- or separately when reuse patterns differ.

The key must ensure they correspond to compatible source/grid semantics.

M2.3 should not force source-native quality masks into the M1 validity normal
form unless that normalization has explicitly occurred.

---

# Part III — Transformed / Materialized Cache

## 40. Transform-cache purpose

The third layer stores deterministic results above native decode.

Examples:

- `ushort` -> `float` conversion;
- explicit scale/offset application;
- native grid -> target grid resampling;
- normalized validity;
- band composition;
- future color/presentation transforms where appropriate;
- expensive derived materialization.

It is not mandatory for every operation.

---

## 41. Transform cache is potentially explosive

The number of possible transformed variants can be much larger than the number
of source/decoded blocks.

Dimensions can include:

- target sample type;
- target grid;
- target resolution;
- resampler;
- border policy;
- band selection;
- scale/offset policy;
- validity policy;
- operation parameters.

Therefore transformed caching must be selective and budgeted.

It should not default to "cache every intermediate."

---

## 42. Transform key principle

A transformed cache key must identify the complete deterministic result
contract.

Conceptually:

    upstream snapshot identity
    +
    transform identity/version
    +
    canonical transform parameters
    +
    target grid identity
    +
    target sample type
    +
    output logical coverage

If any value that can affect pixels is omitted, reuse is unsafe.

---

## 43. Upstream identity

A transform key must depend on the exact upstream snapshot.

For source-derived transformations this ultimately includes Resource revision.

Therefore when the source revision changes:

    old transformed key
        !=
    new transformed key

No recursive in-place invalidation of every downstream object is necessary if
keys are correctly versioned.

---

## 44. Transform implementation version

The same named operation may change behavior across library versions.

For a persistent transformed cache, the transform identity may therefore need:

- operation semantic version;
- implementation/algorithm revision;
- schema version;
- numerical mode where relevant.

This is especially important for cross-process/disk persistence.

An in-memory cache scoped to one process can often use a simpler identity.

---

## 45. Canonical parameter representation

Transform keys require deterministic parameter identity.

Avoid:

- pointer addresses;
- object identity;
- locale-sensitive string formatting;
- unordered-map iteration order.

Prefer canonical structured values or a canonical serialization from which a
hash can be derived.

The hash is an index optimization.

The semantic key is the structured contract.

---

## 46. libvips operation-cache lesson

libvips caches side-effect-free operations by operation plus arguments.

This demonstrates the value of deterministic operation reuse.

`imagery-d` should not immediately create a generic workflow-DAG operation
cache.

M2.3 should initially restrict transformed caching to explicit materialization
stages whose semantic identity is understood.

---

## 47. Presentation caches

Display-oriented transforms can change very frequently during interactive work.

Examples:

- brightness/contrast;
- false-color selection;
- tone mapping;
- colormap.

These may be better suited to short-lived viewport/render caches rather than
the persistent scientific/materialization cache.

M2.3 records the distinction but does not design rendering-cache policy.

---

# Part IV — Budgeting and Eviction

## 48. One process, several RAM consumers

A major architecture risk is local cache limits that sum to an excessive total.

Potential RAM consumers include:

- source byte cache;
- decoded raster cache;
- transformed cache;
- pinned raster materializations;
- in-flight decode buffers;
- decoder/session buffers;
- application/render state.

Therefore M2.3 should define a global imagery residency budget framework.

M2.6 adds an accounting boundary:

> imagery-d can strictly govern only memory whose admission/lifetime it
> controls.

Foreign libraries may maintain internal caches, decoder buffers or allocator
overhead that imagery-d cannot account byte-for-byte.

The budget model should therefore distinguish:

    imagery-d controlled residency
    configured/known backend budgets
    observed or estimated external overhead

It may support an application-level process-memory target, but must not claim
perfect control over total RSS when foreign allocators are involved.

---

## 49. Global budget plus layer targets

Preferred direction:

    global RAM hard/operational budget
        |
        +-- source-cache soft target
        +-- decoded-cache soft target
        +-- transformed-cache soft target
        +-- in-flight reservation
        `-- pinned live residency accounting

Per-layer values are policy targets.

The global budget prevents independent caches from each believing all available
RAM is theirs.

---

## 50. Hard limit caveat

A library cannot forcibly reclaim bytes still retained by active consumers.

Therefore a "hard" RAM limit can only strictly govern:

- new cache insertion;
- new materialization admission;
- evictable cache bytes;
- in-flight reservations.

Already-pinned published materializations may temporarily keep process
residency above a target.

This must be observable rather than hidden.

---

## 51. Residency categories

At minimum, accounting should distinguish:

### Evictable cache-owned bytes

No external consumer requires the entry.

### Pinned live bytes

Raster backing is retained by active materialization/view owners.

### In-flight reserved bytes

Memory expected/allocated for ongoing decode/transform work.

### Metadata/overhead

Cache tables, descriptors, semantic metadata and bookkeeping.

A robust implementation should avoid double-counting the same raster backing
just because several references retain it.

---

## 52. Accounting lifetime

The strongest model is to attach one accounting token to the shared physical
resident coverage owner.

That token records the physical resident cost exactly once.

Cache and materialization references share the same owner.

When cache membership disappears but a consumer remains:

    class changes:
        cache-owned -> externally pinned

but physical bytes are not counted twice.

When the final retain disappears:

    accounting token releases resident bytes

This is an imagery-level accounting layer, not a replacement for RasterLease
ownership.

---

## 53. RasterLease byte cost

`RasterLease!T` itself does not currently expose a generic public total backing
byte-cost query.

A materializer/cache knows the allocations it created and can retain accounting
metadata alongside the lease.

For externally adopted buffers, the adoption/materialization bridge similarly
knows or must establish the retained byte cost.

No raster-d API change is immediately required solely for accounting.

---

## 54. In-flight reservation

Large decode/transform operations can temporarily require memory before a cache
entry exists.

Without reservation, several workers could all pass the cache budget check and
allocate concurrently.

M2.3 should leave room for:

    reserve expected bytes
        ->
    allocate/decode
        ->
    commit actual resident cost
        or
    release reservation on failure

M2.4 will own scheduling/backpressure behavior around this mechanism.

---

## 55. Eviction and cache-geometry policy

The public architecture should not freeze one eviction algorithm.

Possible internal policies include:

- LRU;
- segmented LRU;
- frequency-aware policy;
- cost-aware policy;
- source-local priorities;
- viewport-aware hints.

The semantic cache contract only requires:

- correctness-safe eviction;
- deterministic lifetime behavior;
- budget observability.

M2.6 also makes cache/chunk geometry an explicit first-class performance
policy.

Cache-block geometry may be informed by:

    source-native block/chunk geometry
    expected request shapes
    operation dependency / halo size
    decode amplification
    RAM budget
    network latency and bandwidth
    transform cost

It remains non-semantic:

    cache block
        !=
    provider/source block
        !=
    processing task

No universal fixed block size should be assumed.

Both eviction and cache-geometry policies should be benchmark-driven.

---

## 56. Cost-aware eviction

Not all cache bytes have equal recomputation cost.

Examples:

- cheap generated tile;
- remote COG block with high latency;
- expensive resampled result.

A future eviction score may account for:

    bytes
    recency
    frequency
    recomputation cost
    network cost

M2.3 records this as policy space.

No cost formula is frozen.

---

## 57. Disk budget

Persistent source-cache storage needs its own disk budget.

Disk eviction may use different policy from RAM.

Important distinction:

    disk cache eviction
        need not affect
    currently retained decoded RasterLease

and:

    RAM decoded eviction
        need not delete
    persistent encoded source blob

Each layer is independently reusable.

---

## 58. Cache directory/versioning

Persistent cache layout should be versioned.

A future disk cache must be able to reject/clear incompatible metadata schemas
without confusing old entries with valid new ones.

The cache schema version is separate from Source/Resource semantic identity.

---

## 59. Atomic persistence

Persistent cache insertion should be transactional.

Preferred pattern:

    write temporary object
        ->
    verify length/hash if applicable
        ->
    atomically publish metadata/blob

A crash must not turn a partial download into a valid cache hit.

---

## 60. Integrity

For strong content-addressed entries, verify hash before publication.

For validator-based entries, store enough revision/length metadata to detect
obvious inconsistency.

Integrity policy belongs especially to persistent cache, where corrupted data
can survive process restart.

---

# Part V — Concurrency and Duplicate Work

## 61. Cache and in-flight work are distinct

A cache contains completed reusable values.

An in-flight table contains work currently being produced.

These are different concepts.

M2.3 defines the equivalence key needed by both.

M2.4 owns task/cancellation lifecycle.

---

## 62. Cache stampede problem

If ten requests concurrently miss the same decoded block, naïve behavior
launches ten identical decodes.

Desired direction:

    first miss
        -> creates in-flight production

    equivalent later misses
        -> join/watch same production

    success
        -> one cache publication

This is request coalescing / single-flight behavior.

HTTP caching itself recognizes request collapsing as a useful cache behavior.

---

## 63. Coalescing key

Concurrent work can only be coalesced when the complete semantic production key
matches.

For decoded raster:

    same source snapshot
    same component/grid/level
    same decode-affecting options
    same materialized type
    same cache coverage

For transformed result:

    same complete transform key

"Looks like the same URL" is insufficient.

---

## 64. Cancellation interaction

If several callers share one in-flight production:

- one caller cancelling must not necessarily cancel shared work;
- work may be cancelled when all interested consumers withdraw;
- a completed shared result may still enter cache even if one caller cancelled,
  depending on policy.

M2.4 must define the exact lifecycle.

M2.3 only requires that cache publication happen once and only for a complete
valid result.

---

## 65. Failure coalescing

If shared in-flight production fails, waiting callers may observe the same
attempt failure.

That does not automatically mean the failure should become a long-lived cache
entry.

Retry policy remains M2.4/backend territory.

---

# Part VI — Cache Identity Model

## 66. Cache keys should be typed/structured concepts

Avoid one universal cache key string.

Different layers need different identity dimensions.

Conceptually:

    SourceByteKey
    DecodedCoverageKey
    MaterializedTransformKey

Each can produce a stable hash for table lookup.

The structured key remains the semantic definition.

---

## 67. SourceByteKey concept

Possible fields:

    security/cache namespace
    ResourceId
    ResourceRevision / validation state
    representation variant
    byte range / object-part identity

Transport-specific backends may instead delegate to a standards-compliant
transport cache.

---

## 68. DecodedCoverageKey concept

Possible fields:

    SourceId
    Resource snapshot identity
    product component/subimage/part
    native grid/level
    channel selection
    decoder semantic configuration
    materialized sample type
    logical cache coverage

This key identifies pixel backing.

Image-semantic bindings that do not alter pixels may be layered above it.

---

## 69. TransformKey concept

Possible fields:

    upstream pixel/snapshot identity
    transform operation identity/version
    canonical parameters
    target grid
    target sample type
    validity policy
    output logical coverage

This key identifies a deterministic transformed pixel result.

---

## 70. Key hashing

A cryptographic hash may be useful for:

- persistent filenames;
- compact table keys;
- integrity/content addressing.

But key equality semantics should be defined before hashing.

Never design:

    hash first
        ->
    invent semantics later

The same cache-key schema must canonicalize equivalent inputs identically.

---

## 71. Source identity is not enough

Two requests to the same Source can legitimately yield different cached values
because of:

- Resource revision;
- tile coordinate;
- MIP/overview level;
- channel/component selection;
- materialized type;
- transform parameters.

SourceId is therefore one field, not the whole key.

---

## 72. Resource revision is not enough

Two Resources with the same byte content can still have different semantic
roles.

Conversely, the same Resource revision can be decoded differently through
different explicit configurations.

Cache identity is a composition of identity + revision + interpretation +
coverage.

---

# Part VII — Invalidation and Refresh

## 73. Current-pointer versus snapshot entries

A Source/Product may have a concept of "current revision."

Cache entries should represent immutable snapshots.

A separate current index may map:

    ResourceId
        ->
    current known Revision

Refresh updates that pointer.

It does not mutate an old cached snapshot.

---

## 74. Explicit invalidation event

An application/backend may learn:

    Resource R changed

The cache should mark old entries ineligible for future "current" lookup.

Pinned old entries remain valid as snapshots.

This preserves deterministic view lifetime.

---

## 75. Invalidation scope

Invalidation can target different layers.

### Source bytes

When the Resource revision changes.

### Decoded pixels

When upstream Resource snapshot or decoder semantics change.

### Transformed result

When upstream snapshot, transform identity or parameters change.

Correct versioned keys can make downstream invalidation mostly an index/reach-
ability problem rather than in-place mutation.

---

## 76. Global cache flush

A global clear operation may be useful for:

- testing;
- memory pressure;
- user action;
- debugging.

Its semantics should be:

> remove reusable cache references and stale indices as allowed.

It must not invalidate active published materializations.

---

## 77. Offline stale use

An application may intentionally permit stale cached imagery while offline.

That is a higher-level explicit policy.

A result should remain marked with the actual cached Resource revision and
freshness/staleness information.

Do not pretend stale data are current.

---

# Part VIII — Relation to M2.2 Ownership

## 78. SharedResidentCoverage resolves the ownership question

M2.2 asked whether retained superset ownership belongs to:

- materialization owner;
- decoded cache;
- shared retained object.

M2.3's provisional answer is:

    shared retained coverage object

with independent references held by cache and materializations.

This is the cleanest match to RasterLease semantics and reference-system
evidence.

---

## 79. Conceptual ownership graph

    DecodedCache
        |
        | retain
        v
    SharedResidentCoverage!T
        |
        +-- logical coverage
        +-- source/revision snapshot
        +-- grid/decode identity
        +-- resident accounting token
        `-- RasterLease!T
                |
                v
          raster-d backing

    MaterializationOwner!T
        |
        | retain
        +--------------------> same SharedResidentCoverage!T
        |
        `-- semantic metadata / exact request mapping
                |
                v
            ImageView!T

No type name is frozen.

---

## 80. Cache miss path

Conceptually:

    lookup DecodedCoverageKey
        |
        +-- hit
        |    -> retain shared coverage
        |
        `-- miss
             -> M2.4 in-flight production
             -> M2.2 source materialization
             -> SharedResidentCoverage
             -> atomically publish in cache
             -> retain for requester

---

## 81. Eviction path

Conceptually:

    budget pressure
        ->
    choose cache entry
        ->
    remove key/index membership
        ->
    drop cache retain

If another materialization retains the coverage:

    RasterLease remains alive
    bytes become pinned/non-cache-owned

Otherwise:

    shared coverage destructs
    RasterLease releases backing

---

## 82. Re-admission

A coverage object that was evicted but remains pinned might be eligible for
re-admission if requested again.

Implementation choices:

- rediscover pinned object through a weak index;
- treat as miss and avoid complexity;
- maintain a separate live-coverage registry.

M2.3 does not freeze this.

Correctness is unaffected; only efficiency differs.

---

# Part IX — Pressure Cases

## 83. P1 — Repeated viewport over remote COG

User pans away and back.

Desired reuse:

    source byte ranges
    +
    decoded native blocks

Potential transform reuse depends on target grid/display policy.

Result:

**PASS.**

Separate byte and decoded caches avoid repeated network and decode cost.

---

## 84. P2 — Same COG block requested concurrently

Several viewport tasks require the same decoded coverage.

Result:

**PASS if cache key and in-flight key are identical.**

One production can satisfy all callers.

M2.4 must define cancellation/join lifecycle.

---

## 85. P3 — Resource revision changes

A local/remote Source now points at Resource revision 2.

Existing cache contains revision 1.

Result:

**PASS.**

Revision 2 gets different keys.

Revision 1 entries stop satisfying current lookups but remain alive while
pinned.

No in-place pixel mutation.

---

## 86. P4 — Arbitrary request inside cached superset

Cache has C.

Request R is contained in C.

Result:

**PASS.**

Materialization owner retains C and exposes a zero-copy ROI for R.

---

## 87. P5 — Request spans four decoded cache blocks

M1 needs one `ImageView!T`.

Result:

**PASS with assembly on initial architecture.**

Cache retains the four blocks.

Materializer may assemble exact requested output into one new RasterLease.

A future segmented processing view would require independent justification.

---

## 88. P6 — Untiled source image

Source decoder naturally exposes scanlines/full image.

Result:

**PASS.**

Decoded cache may impose virtual/cache-policy blocks, similar in spirit to
OpenImageIO autotiling, if adapter capabilities support efficient production.

Otherwise full-image decode may be the unavoidable cost.

---

## 89. P7 — Same bytes, two semantic Resources

Two product Resources deduplicate to identical content hash.

Result:

**PASS.**

Persistent byte blob may deduplicate physically.

Semantic Resource IDs/provenance remain distinct.

Decoded pixels may also deduplicate only if full decode identity is equivalent.

---

## 90. P8 — Same Resource, different decoder configuration

RAW image decoded with two explicit processing configurations.

Result:

**PASS.**

Decoded cache keys differ.

No accidental reuse based solely on Resource revision.

---

## 91. P9 — Transform cache target-grid difference

Same native source is resampled to 10 m and 20 m target grids.

Result:

**PASS.**

Transform keys differ by target grid.

---

## 92. P10 — Active view while cache evicts

Cache is over budget while a UI layer still holds a materialization.

Result:

**PASS.**

Cache drops its retain.

UI/materialization retain keeps RasterLease alive.

Pixels disappear only after the final owner releases them.

---

## 93. P11 — Many active pinned views exceed cache target

User/app retains more data than the decoded-cache soft target.

Result:

**DEFINED, NOT MAGICALLY SOLVED.**

The cache can evict all its reusable references but cannot reclaim active
consumer ownership.

Accounting reports pinned live bytes.

M2.4 scheduling/backpressure may reject/delay new work if a global admission
budget would be exceeded.

---

## 94. P12 — Source byte cache plus decoded cache double memory

A COG range is held in byte cache while decoded pixels are also resident.

Result:

**PASS only with global accounting.**

Independent per-layer cache limits are insufficient as the sole RAM policy.

---

## 95. P13 — Offline stale data

Network unavailable; disk cache has older revision.

Result:

**PASS only under explicit stale/offline policy.**

Returned result carries actual revision/staleness.

It must not masquerade as current.

---

## 96. P14 — Crash during disk-cache download

Process terminates halfway through a persistent source blob.

Result:

**PASS with transactional publication.**

Partial temp object is not a valid cache hit after restart.

---

# Part X — Rejected Alternatives

## 97. One universal cache

Reject.

Encoded bytes, decoded pixels and transformed pixels have different:

- keys;
- size ratios;
- invalidation;
- persistence;
- reuse patterns.

---

## 98. URL-only key

Reject.

It ignores mirrors, signed URLs, revisions, HTTP variants and semantic source
identity.

---

## 99. SourceId-only key

Reject.

One Source can expose many Resources, revisions, tiles, levels and transforms.

---

## 100. Cache owns pixel lifetime exclusively

Reject.

Active ImageViews/materializations must survive cache eviction.

---

## 101. Eviction invalidates active views

Reject.

This would violate the lease/lifetime architecture.

---

## 102. Every request becomes its own decoded cache entry

Reject as the default.

Arbitrary overlapping request shapes lead to fragmentation and poor reuse.

---

## 103. Provider tile equals cache block

Reject as an invariant.

Useful as an optimization in some adapters, but not a semantic rule.

---

## 104. Cache block equals processing task

Reject.

Task geometry is scheduler/operation policy.

---

## 105. Cache every transform automatically

Reject.

Transform-state combinatorics can explode memory/disk usage.

---

## 106. Persistent transformed cache without algorithm version

Reject.

Library/algorithm changes could silently reuse semantically obsolete pixels.

---

## 107. Independent unlimited layer budgets

Reject.

Multiple caches compete for the same physical RAM.

---

## 108. Raw credentials in persistent key

Reject for security and stability reasons.

Use a non-secret cache namespace/partition when access context must segregate
entries.

---

## 109. Cache failure forever

Reject.

A temporary timeout is not a durable pixel result.

---

# Part XI — Candidate Architecture

## 110. Conceptual layers

    Source/Product
        |
        v
    Source/Byte Cache
        |
        v
    Decoder
        |
        v
    Decoded Native Raster Cache
        |
        v
    explicit transform/materialization
        |
        v
    Transformed Materialization Cache
        |
        v
    exact retained materialization
        |
        v
    ImageView!T

Not every request traverses every cache.

Generated Sources may bypass source bytes.

A direct native hit may bypass transformed cache.

---

## 111. Cache-control plane

A conceptual cache control plane owns:

    global RAM budget
    per-layer targets
    disk budget
    accounting
    eviction policy
    invalidation/current-revision indices
    statistics

It should not own raster pixel memory directly.

Raster memory remains retained through RasterLease-containing coverage objects.

---

## 112. Data-plane ownership

Conceptually:

    encoded cache entry
        owns encoded bytes/blob

    decoded coverage
        owns RasterLease!T

    transformed coverage
        owns RasterLease!U

    materialization owner
        retains relevant coverage
        + semantic metadata

Each layer owns only its actual representation.

---

## 113. Statistics

M2.3 should expose enough instrumentation for later benchmarks.

Useful counters include:

- cache hits/misses per layer;
- covering hits;
- bytes served from each cache;
- bytes fetched from source;
- decoded bytes/pixels;
- transform hits;
- evictions;
- invalidations;
- in-flight coalesced requests;
- pinned resident bytes;
- evictable bytes;
- peak resident bytes;
- disk-cache bytes;
- redundant source/decode work.

OpenImageIO's detailed tile/cache statistics are good precedent.

---

## 114. Observability without semantic coupling

Statistics and diagnostics must not alter cache-key semantics.

Debug tooling may expose:

- why a cache entry missed;
- which key dimension differed;
- why an entry was invalidated;
- current/pinned/evictable budget.

This will be valuable for performance analysis.

---

# Part XII — Cross-Issue Boundaries

## 115. M2.1 owns

- Source identity;
- Resource identity;
- locator;
- revision;
- access backend/session;
- provenance.

M2.3 consumes those concepts for keys.

It must not redefine them.

---

## 116. M2.2 owns

- logical materialization request;
- source/decode flow;
- resident raster construction;
- logical coverage mapping;
- retained materialization owner semantics.

M2.3 reuses completed materializations/coverages.

---

## 117. M2.4 owns

- in-flight task lifecycle;
- priorities;
- cancellation;
- retries;
- prefetch;
- request coalescing control;
- admission/backpressure scheduling.

M2.3 supplies cache/in-flight equivalence keys and budget signals.

---

## 118. M2.5 owns

- explicit sample conversion;
- resampling;
- target grid;
- heterogeneous product materialization.

M2.3 defines how deterministic results of those choices may be cached.

---

# Part XIII — Candidate Invariants

## 119. M2.3 invariants

1. Source-byte, decoded-raster and transformed caches remain distinct.

2. Open session/decoder pooling is distinct from pixel/byte caches.

3. URL/path alone is not a complete cache key.

4. SourceId alone is not a complete cache key.

5. Resource revision participates in reuse correctness.

6. Unknown revision remains representable and receives conservative reuse
   semantics.

7. Raw credentials do not become persistent cache-key material.

8. Security/access context may require non-secret cache partitioning.

9. Source-byte cache respects transport representation semantics.

10. Decoded cache identity includes every decoder choice that can affect pixel
    values.

11. Cache block geometry is cache policy, not source or processing semantics.

12. A decoded cached coverage may be a superset of an exact request.

13. Exact views may be zero-copy ROIs into cached supersets.

14. Cache membership and raster lifetime are separate.

15. Eviction drops cache ownership but does not invalidate active
    materializations.

16. Invalidation prevents future reuse but does not mutate old snapshots.

17. Strong revision changes naturally produce new keys.

18. Raster backing is counted once even when cache and consumers retain it.

19. Pinned live bytes remain observable after cache eviction.

20. New work can be admission-controlled when pinned/in-flight residency
    consumes the global budget.

21. Per-layer RAM targets operate under a global residency budget.

22. Disk and RAM budgets are separate.

23. Persistent cache publication is transactional.

24. Transform cache keys include the full deterministic operation contract.

25. Transform persistence requires algorithm/schema versioning.

26. Caches contain completed results; in-flight work is a separate table.

27. Equivalent concurrent misses should be coalescible through the same
    semantic production key.

28. Failed work is not automatically a durable data cache entry.

29. Cache hits must be semantically equivalent to fresh production.

30. Cache policy must not alter image-processing correctness.

---

# Part XIV — Open Questions

## 120. Q1 — decoded cache block policy

Should the first implementation use:

- fixed canonical grid blocks;
- source-native blocks;
- adaptive blocks;
- per-adapter policy?

Needs benchmarks.

---

## 121. Q2 — shared coverage owner shape

What is the smallest D type that can safely retain:

    logical coverage
    source snapshot
    RasterLease!T
    byte accounting

without becoming a second raster abstraction?

This may justify a research-only D spike after M2.4.

---

## 122. Q3 — budget controller placement

Should global memory accounting be:

- imagery-d cache-owned;
- workspace/application supplied;
- a generic reusable budget service?

Keep imagery-d needs concrete before extracting generic infrastructure.

---

## 123. Q4 — byte-cache implementation boundary

Should HTTP byte caching mostly be delegated to the HTTP backend/library while
imagery-d only caches immutable blobs?

Need concrete network stack selection.

---

## 124. Q5 — persistent decoded cache

Should decoded native rasters ever be stored on disk?

Potential advantages:

- avoid expensive decode;
- fast restart.

Costs:

- much larger than encoded source;
- serialization/layout/versioning complexity.

Do not add until workload evidence supports it.

---

## 125. Q6 — persistent transformed cache

Likely even more selective.

Need concrete high-cost transforms and stable algorithm identities.

---

## 126. Q7 — covering lookup structure

How should the decoded cache efficiently find:

    one stored coverage that contains requested R

without scanning all entries?

Possible answer depends on canonical block policy.

---

## 127. Q8 — weak revision cache lifetime

How aggressively should weakly validated local/remote entries survive across
process runs?

Needs source/backend policy evidence.

---

## 128. Q9 — stale offline semantics

Where should stale-but-usable imagery be surfaced:

- materialization metadata;
- source snapshot;
- application diagnostics?

M2.4/M2.5 interaction required.

---

## 129. Q10 — cache entry priority

Should current viewport, prefetched neighbor and background analysis use
different eviction priority classes?

M2.4 must define request priority before M2.3 freezes this.

---

# Part XV — Provisional Decision

## 130. Preferred M2.3 architecture

The strongest current direction is:

    global cache/residency budget
        |
        +-- encoded/source cache
        |     key: Resource snapshot + representation/range
        |
        +-- decoded native raster cache
        |     key: source/resource snapshot + decode identity + coverage
        |     value: shared retained coverage with RasterLease
        |
        `-- transformed materialization cache
              key: upstream snapshot + deterministic transform contract
              value: shared retained coverage with RasterLease

with:

    materialization owner
        retains shared coverage independently of cache membership
        exposes ImageView borrow

and:

    in-flight production table
        separate from completed caches
        uses the same semantic production keys
        lifecycle defined by M2.4

---

## 131. M2.2 feedback

M2.3 resolves one important M2.2 open question provisionally:

> resident superset lifetime should be represented by a shared retaining
> coverage object above `RasterLease`, with the decoded cache and active
> materializations holding independent references.

This gives correct eviction semantics without changing raster-d ownership.

M2.2 should later be updated with this result before issue closure.

---

## 132. raster-d handback status

M2.3 currently requires no new raster-d API.

Decoded-cache ownership can retain ordinary `RasterLease!T`.

Logical coverage and cache accounting remain imagery-layer metadata.

Potential handbacks from M2.2 remain unchanged:

- arbitrary external resource adoption;
- multi-resource import;
- generic dependency/halo promotion;
- generic logical-placement wrapper if independently justified.

---

## 133. M2.3 status

M2.3 architecture has now passed M2.6 validation.

M2.4 confirmed the completed-cache versus in-flight-production split.

M2.5 confirmed the major transformed-key dimensions.

M2.6 adds three final clarifications:

- L1/L2/L3 are optional reusable representation boundaries, not mandatory
  execution stages;
- cache/chunk geometry is a first-class performance policy but remains
  non-semantic;
- the residency controller strictly accounts imagery-d-controlled memory while
  foreign backend memory is configured/observed separately.

No production cache code is justified yet.

M2.3 should remain open until the focused M2 contract experiment verifies:

    shared-coverage lifetime
    eviction while consumer-retained
    exact-key single-flight
    publication after completion
    controlled residency accounting transitions

---

## 134. M2.6 validation update

The validated cache model is:

    optional source-byte reuse boundary
        |
        v
    optional decoded-native reuse boundary
        |
        v
    optional transformed-result reuse boundary

where execution may enter, leave or bypass these boundaries according to the
resolved semantic plan and current execution strategy.

The existence of a cache layer never changes the semantic result identity.

## 135. References

Primary references used for M2.3:

- OpenImageIO ImageCache:
  https://openimageio.readthedocs.io/en/v3.1.12.0/imagecache.html

- GDAL configuration and raster block cache:
  https://gdal.org/en/stable/user/configoptions.html
  https://gdal.org/en/stable/api/gdalrasterband_cpp.html

- GDAL Virtual File Systems / `/vsicurl/` caching:
  https://gdal.org/en/stable/user/virtual_file_systems.html

- libvips technical background and operation cache:
  https://www.libvips.org/API/8.17/how-it-works.html

- libvips tile cache:
  https://www.libvips.org/API/current/cpp/classVImage.html

- RFC 9111 — HTTP Caching:
  https://www.rfc-editor.org/rfc/rfc9111.html

Project evidence used:

- `docs/research/m2-source-resource-access-model.md`
- `docs/research/m2-region-materialization-boundary.md`
- M1 ADR 0002
- `raster-d` resident ownership and R0.3 region/streaming evidence
