# ADR 0003 — M2 Source / Cache / Pipeline Architecture

**Status:** Accepted
**Date:** 2026-09-24
**Project:** `imagery-d`
**Milestone:** `M2 — Source / Cache / Pipeline Architecture`
**Decision scope:** Source, resource, materialization, cache and request-lifecycle architecture and promotion gate

## 1. Context

M1 established the image-semantic core of `imagery-d`.

Its accepted processing model is:

    heterogeneous imagery product / description
                |
                | explicit selection / conversion / resampling
                v
           ImageView!T
                |
                +-- one common-grid RasterView!T
                +-- immutable image semantics
                +-- optional same-grid RasterView!ubyte validity
                |
                v
             raster-d

M1 deliberately did not answer how real imagery reaches that processing view.

Real imagery may be:

- local or remote;
- represented by one object or many resources;
- tiled or scanline-oriented;
- random-access or sequential;
- directly decodable or generated procedurally;
- immutable, versioned, weakly versioned or revision-unknown;
- homogeneous or heterogeneous in sample type, grid and resolution;
- cached at encoded, decoded or transformed stages;
- requested concurrently by multiple consumers;
- obsolete or cancelled while work is still running.

M2 was created to answer the next architectural question:

> How does `imagery-d` resolve heterogeneous imagery sources into bounded,
> retained, typed processing views without duplicating `raster-d`, conflating
> identity with location, or freezing a scheduler/cache implementation into
> the public API?

The M2 research sequence produced:

- a source/resource/access model;
- a region materialization boundary with `raster-d`;
- a layered cache architecture;
- request, cancellation, priority and progressive-result semantics;
- a product-to-typed-`ImageView` materialization model;
- validation against mature reference systems and concrete consumer cases;
- a focused DMD/LDC contract experiment against the real `raster-d`
  ownership and ROI boundary.

This ADR synthesizes those results and records the M2 promotion decision.

---

## 2. Decision summary

M2 accepts the following conceptual architecture:

    ImageryProduct
        |
        +-- ProductComponent
        |
        `-- Source
                |
                +-------------------------------+
                |                               |
                v                               v
        resource-backed                  generated/direct
                |                               |
        ResourceDescriptor                      |
                |                               |
        Locator / AccessBackend                 |
                |                               |
            ReadSession                         |
                |                               |
             Decoder                            |
                |                               |
                +---------------+---------------+
                                |
                                v
                    native region materialization
                                |
                                v
                         RasterLease!T
                                |
                imagery-side logical coverage
                                |
                                v
                   ResolvedMaterializationPlan
                                |
                        explicit transforms
                                |
                                v
                      retaining result owner
                                |
                                v
                         ImageView!T borrow

Completed work may be reused through independent cache boundaries:

    L1  encoded/source bytes
    L2  decoded native raster coverage
    L3  transformed/materialized result

These are optional reuse boundaries.

They are not mandatory pipeline stages.

Concurrent equal semantic demand may be coalesced through one shared
production:

    Subscriber A ─┐
    Subscriber B ─┼──> semantic Production Key ──> Shared Production
    Prefetch C   ─┘

Subscriber lifetime, production lifetime, cache membership and raster lifetime
remain separate concepts.

The current M2 architecture is accepted.

The production package/API gate is **not** opened yet.

Specifically:

- do **not** treat the experimental M2 type names as public API;
- do **not** create a production scheduler or general DAG;
- do **not** freeze cache implementation types;
- do **not** freeze source/backend/session type names;
- do **not** freeze `ProductionKey`, `SharedProduction`,
  `SharedResidentCoverage`, `MaterializationOwner` or `SourceSnapshot`
  as production names;
- do **not** admit a production source/cache framework solely because the
  architecture experiment passed.

A production package surface still requires one concrete image-domain
vertical slice with:

- a real consumer requirement;
- explicit source/materialization semantics;
- correctness oracle;
- memory/residency contract;
- failure semantics;
- benchmark workload;
- DMD correctness evidence;
- LDC optimized-performance evidence.

---

## 3. Accepted terminology

### 3.1 Source

A Source is a stable imagery-side capability or origin from which imagery can
ultimately be materialized.

A Source is broader than one file, URL or encoded object.

A Source may expose:

- one fixed Resource;
- a family of Resources selected from a request;
- no encoded Resource at all for generated/direct imagery.

Examples:

    COG Source
        -> one concrete Resource

    WMTS Source
        -> resource family selected by tile request

    generated Source
        -> direct materialization

Source identity is not a locator.

### 3.2 Resource

A Resource is one concrete addressable representation or encoded object.

Examples include:

- one TIFF object;
- one COG object;
- one EXR object;
- one tile selected from a tile-service resource family;
- one object-store object.

A Resource is not equivalent to its current URL or filesystem path.

### 3.3 Locator

A Locator is an operational route by which one Resource may currently be
reached.

Examples include:

- path;
- URL;
- object key;
- mirror endpoint.

A Locator is not stable semantic Resource identity.

A Resource may have multiple Locators.

Signed URLs and other ephemeral access routes must not become durable
Resource identities.

### 3.4 SourceId

Stable identity of the imagery-producing Source capability.

### 3.5 ResourceId

Stable identity of one concrete Resource representation.

The following distinctions are accepted:

    SourceId != ResourceId
    ResourceId != ResourceRevision
    ResourceId != Locator

### 3.6 Resource revision

Revision identifies the observed encoded representation state associated with
a Resource.

Revision knowledge may be:

- strong;
- weak;
- unknown.

Potential strong evidence includes:

- verified content digest;
- immutable object/version identifier;
- a provider guarantee that supplies equivalent strong identity.

Potential weak evidence includes:

- weak ETag;
- Last-Modified;
- filesystem modification metadata;
- size plus weak timestamp metadata.

An HTTP ETag is not assumed to be a universal content hash.

Unknown revision is a valid state and must not be silently represented as
strong identity.

### 3.7 AccessBackend

AccessBackend is the technical mechanism that understands how to access a
Locator.

Examples may eventually include:

- local filesystem access;
- HTTP range access;
- object-store access;
- memory-backed access.

The term Provider is deliberately avoided for this role because imagery
metadata ecosystems such as STAC use provider terminology for organizational
or provenance meaning.

### 3.8 ReadSession

A ReadSession is an ephemeral access capability created through an
AccessBackend.

It may describe capabilities such as:

- known size;
- sequential access;
- random range access;
- seekability;
- concurrent reads;
- observed revision;
- cancellation integration.

A ReadSession is operational state.

It is not Source or Resource identity.

### 3.9 Decoder

Decoder interprets an encoded representation.

Decoder responsibilities remain separate from:

- Source identity;
- Resource identity;
- access transport;
- cache identity;
- image-domain semantic selection.

### 3.10 Source snapshot

A source snapshot identifies the concrete source/resource state used by one
materialization.

A materialization must not silently mix incompatible revisions.

For multi-resource products, the resolved result may require a composite
snapshot containing multiple resource identities/revisions.

### 3.11 Logical coverage

Logical coverage records where one resident raster coverage belongs in the
imagery/source coordinate system.

It remains above `raster-d`.

`RasterView.region` is resident descriptor-space geometry and must not be
reinterpreted as global/source placement.

### 3.12 TargetImageContract

`TargetImageContract` is the conceptual caller request for the semantic output.

It describes what result is required.

It does not describe how that result is executed.

The final public type name is not frozen by this ADR.

### 3.13 ResolvedMaterializationPlan

`ResolvedMaterializationPlan` is the conceptual fully resolved semantic
definition of one requested result.

It includes the decisions that determine result identity, such as:

- selected ordered components;
- concrete source/resource snapshot;
- target grid;
- target sample representation;
- radiometric interpretation;
- explicit conversion semantics;
- explicit resampling semantics;
- validity semantics.

The name is accepted as architectural terminology.

Its final production representation and public visibility are not frozen.

### 3.14 ExecutionPlan

ExecutionPlan describes how one already-defined semantic result is produced on
the current machine and through the current backends.

Possible execution details include:

- fused versus unfused transforms;
- block/chunk geometry;
- cache lookup strategy;
- task decomposition;
- memory reservations;
- backend-specific access strategy.

ExecutionPlan may not change result semantics.

### 3.15 Production key

Production key means the semantic identity used to identify equal in-flight or
completed semantic work.

The architectural concept is accepted.

The concrete experimental `ProductionKey` struct is not a production API
decision.

### 3.16 Subscriber

A Subscriber is one consumer waiting for a result from shared production.

Subscriber lifetime is separate from shared-production lifetime.

### 3.17 Shared production

Shared production is one execution of semantic work that may satisfy multiple
Subscribers requesting the same semantic production key.

The concept is accepted.

The experimental state-machine type is not accepted as production API.

### 3.18 Asset

Asset is retained as product/metadata vocabulary where an upstream imagery
model uses that term.

M2 does not introduce Asset as a second core access-identity layer parallel to
Resource.

An adapter may preserve:

- an upstream asset name;
- roles;
- media/type hints;
- provenance metadata;
- relationships to Product Components.

It may then associate that metadata with one or more Resources or with Source
selection as required by the upstream model.

The architecture does not assume the universal identity:

    Asset == Resource

Resource identity and Resource revision remain explicit even when an upstream
format describes the representation as an Asset.

### 3.19 Provider

Provider is not the technical access abstraction in M2.

Where upstream product metadata uses Provider for organizational, acquisition
or provenance meaning, that meaning may be preserved as metadata.

The technical access role is named AccessBackend.

This avoids conflating:

    who/what provided the imagery

with:

    how bytes or source data are accessed

M2 therefore does not define a generic technical `Provider` interface.

### 3.20 Product Component

A Product Component is one semantically selectable part of a heterogeneous
Imagery Product.

A component may carry image-domain meaning such as:

- spectral/channel role;
- quality or classification role;
- native grid/resolution;
- candidate representation relationships.

A Product Component may resolve through a Source and one or more concrete
representations.

Component identity and ordered component selection participate in a resolved
materialization plan when they affect the requested result.

A Product Component is not itself a resident raster and is not automatically
one Resource.

---

## 4. Source and Resource relationship

The accepted source model is:

    Source
      ├─ fixed Resource
      ├─ request-selected Resource family
      └─ generated/direct materialization

The architecture must support all three forms.

A design requiring every Source to map to exactly one encoded Resource is
rejected.

A design requiring every Source to pass through byte access and a Decoder is
also rejected because generated/procedural imagery may have no encoded byte
Resource.

---

## 5. Identity model

Identity is layered.

At minimum:

    Source identity
        |
        v
    Resource identity
        |
        v
    Resource revision
        |
        v
    decoded representation identity
        |
        v
    transformed/materialized semantic identity

Location is not identity.

The following are therefore rejected as standalone durable identity:

- URL;
- filesystem path;
- file descriptor;
- pointer address;
- open session;
- cache slot;
- worker/task identity.

Locator normalization may improve operational reuse.

It does not create semantic Resource identity.

---

## 6. Provenance versus access

Provenance and access are separate concerns.

A Source or Product may record:

- producer;
- mission;
- acquisition;
- provider organization;
- processing lineage;
- generator semantics.

Access machinery instead answers:

> How can the selected representation currently be read?

The architecture must not use access backend identity as provenance identity.

---

## 7. Access capability and access efficiency

Semantic capability is distinct from efficient access capability.

A Source may semantically support an arbitrary logical region even when its
underlying representation requires:

- full decode;
- sequential scanning;
- coarse block reads;
- inefficient range amplification.

Therefore source/backend descriptions may expose non-semantic capability or
cost hints such as:

- natural block size;
- sequential-only;
- sequential-preferred;
- random-access available;
- range-read efficiency;
- available overviews;
- full-decode-only;
- concurrent-read capability.

These hints may guide ExecutionPlan.

They do not change TargetImageContract semantics.

---

## 8. Region materialization boundary

The accepted materialization boundary is:

    downstream semantic/output intent
              |
              v
    operation determines required logical input
              |
              v
    materialization request
      - source/component
      - selected grid
      - logical region
      - materialized type/policy
              |
              v
    source-specific resolution
      - resources
      - tiles
      - reads
      - decoder-native geometry
      - revision consistency
              |
              v
    decoded owned resident storage
              |
              v
         raster-d import
              |
              v
         RasterLease!T
              |
              v
    imagery-side retained materialization
              |
              v
         ImageView!T borrow

The operation determines which logical input is required.

The source materializer determines how that logical requirement becomes
resident.

Those responsibilities must not be conflated.

---

## 9. Coordinate-space separation

At least these coordinate spaces may exist:

1. logical source/image coordinates;
2. source-native fetch coordinates;
3. resident raster descriptor coordinates;
4. processing-view-local coordinates.

They must not be silently conflated.

In particular:

    RasterView.region

does not encode global/source logical placement.

Imagery-side retained materialization metadata must preserve the logical
coverage separately.

---

## 10. Exact and superset materialization

A source or decoded cache may satisfy a request with:

- exact coverage;
- a containing/superset coverage.

A containing decoded coverage may serve an exact request through a
zero-copy `RasterView.tryRoi` borrow when geometry and semantics permit it.

The M2 experiment mechanically validated:

    logical coverage:
        Region2D(10, 20, 4, 3)

    requested logical region:
        Region2D(11, 21, 2, 1)

    resident relative ROI:
        Region2D(1, 1, 2, 1)

without a second source materialization.

Logical-to-resident translation belongs above `raster-d`.

Resident ROI mechanics remain owned by `raster-d`.

---

## 11. Materialization success semantics

Materialization success is transactional by default.

A successful result represents one coherent resolved snapshot.

The architecture must not publish a partially complete semantic result as if
it were the requested complete result.

A source/resource revision mismatch during one materialization is not silently
merged.

It requires resolution as a different/new snapshot or failure/retry according
to later policy.

Invalid region requests are rejected rather than silently clipped unless a
higher semantic operation explicitly defines clipping behavior.

Border/halo policy belongs to operation semantics, not source access.

---

## 12. raster-d ownership boundary

`raster-d` remains the owner of generic resident raster representation and
lifetime mechanics.

The accepted boundary is:

    imagery-d
      - source identity
      - resource identity/revision
      - logical source placement
      - image semantics
      - materialization planning
      - cache semantics
      - request lifecycle

            |
            v

    raster-d
      - retained raster backing
      - RasterLease!T
      - RasterView!T
      - physical layout
      - planes
      - strides/interleaving
      - resident Region2D
      - ROI mechanics
      - generic raster operations

M2 does not introduce a second raster-storage ownership system.

---

## 13. raster-d changes

The M2 contract experiment completed against the existing public
`raster-d` baseline:

    a073b3ad6b541fcd8421ed304722feaa47e9083b

No `raster-d` API extension was required for the validated M2 contracts.

Potential future hand-backs remain conditional on concrete evidence, including:

- arbitrary retained-resource adoption with custom release/deleter semantics;
- public multi-resource raster import;
- promoted generic dependency/halo execution machinery;
- a generic logical-placement wrapper if a non-image raster consumer proves
  that requirement.

This ADR does not request those changes.

---

## 14. Cache architecture

M2 accepts three conceptually independent cache/reuse boundaries:

    L1 — encoded/source bytes
    L2 — decoded native raster coverage
    L3 — transformed/materialized result

They are optional reuse boundaries.

They are not required stages through which every request must pass.

A given source or workload may use:

- none;
- one;
- two;
- all three.

A session/resource/decoder pool is operational reuse.

It is not automatically a data cache.

---

## 15. L1 encoded/source cache

L1 identity must derive from Resource snapshot plus encoded representation or
range identity.

URL/path alone is insufficient.

Persistent encoded caches should prefer representations whose identity and
revision semantics can be validated.

When writing persistent encoded objects, publication should be atomic where
practical:

    temporary write
        ->
    validation
        ->
    atomic publish

Credentials and transient signed-access tokens must not become semantic cache
keys.

---

## 16. L2 decoded native-raster cache

L2 stores decoded native raster coverage.

Its identity may include:

- source/resource snapshot;
- decoder semantic identity;
- native grid identity;
- decoded sample representation;
- logical/native coverage;
- decode-affecting validity normalization.

A decoded cache block is not automatically:

- one provider tile;
- one source object;
- one processing task;
- one operation dependency region.

Those geometries remain distinct.

A decoded cache may classify a lookup as:

- exact;
- covering;
- multi-coverage;
- miss.

The first architecture may assemble multi-coverage results into one retained
raster when the processing `ImageView!T` model requires one common
`RasterView!T`.

---

## 17. L3 transformed/materialized cache

L3 identity derives from the full semantic result definition.

It may therefore include:

- upstream composite snapshot;
- operation/materialization semantic version;
- transformation parameters;
- target grid;
- target sample representation;
- radiometric semantics;
- resampling semantics;
- validity semantics;
- requested coverage.

Execution strategy is excluded only when different execution strategies are
guaranteed to be semantically equivalent.

---

## 18. Cache membership versus raster lifetime

The following invariant is accepted:

    cache membership != raster lifetime

A decoded resident coverage may be retained independently by:

- cache membership;
- one or more delivered materialization owners;
- in-flight execution.

Evicting a cache entry removes only the cache's retain.

It must not revoke an already delivered immutable materialization.

The M2 experiment validated this against the real `RasterLease!ubyte`
ownership model.

---

## 19. Resident ownership model

Conceptually:

    decoded cache
        |
        v
    shared resident coverage
        |
        +-- logical coverage
        +-- source/revision snapshot
        +-- accounting metadata
        `-- RasterLease!T
                |
                +-- retained by cache
                `-- retained by delivered materialization

The architectural concept of shared retained coverage is accepted.

The concrete experimental `SharedResidentCoverage!T` type name and storage
layout are not frozen.

---

## 20. Production identity

The resolved semantic materialization plan defines production identity.

Conceptually:

    TargetImageContract
            |
            v
    ResolvedMaterializationPlan
            |
            +----> semantic Production Key
            |
            v
        ExecutionPlan

The following are semantic identity when they affect the requested result:

- selected component identity and order;
- source/resource revision snapshot;
- target grid;
- target sample representation;
- radiometric semantics;
- explicit conversion semantics;
- resampling semantics;
- validity semantics.

---

## 21. Non-key execution metadata

The following are not semantic production identity by themselves:

- request priority;
- request generation/epoch;
- subscriber identity;
- worker identity;
- queue placement;
- fused versus unfused execution;
- cache block size;
- task decomposition.

They may influence ExecutionPlan.

They must not split otherwise identical semantic production unless they change
the result contract.

The M2 experiment mechanically validated that priority, generation and two
different execution strategies did not alter the semantic production key.

---

## 22. Single-flight

Equal in-flight semantic work may be coalesced.

The accepted model is:

    Subscriber A ─┐
    Subscriber B ─┼──> Production Key K ──> one Shared Production
    Prefetch C   ─┘

The shared production is keyed by semantic result identity.

It is not keyed by subscriber identity.

The M2 experiment validated that two equal-key subscribers caused one
production start.

---

## 23. Subscriber cancellation

Subscriber cancellation and production cancellation are separate.

Cancelling one Subscriber:

- terminates that Subscriber's interest;
- does not revoke a result already published to another Subscriber;
- does not stop shared production while another interested Subscriber still
  requires the result.

When all interested Subscribers cancel before publication, policy may stop the
production if stopping remains useful and possible.

---

## 24. Cancellation linearization

For one Subscriber, delivery and cancellation are mutually exclusive terminal
outcomes.

Conceptually there is a publication/cancellation ordering point:

    cancellation first
        -> Subscriber cancelled

    publication first
        -> Subscriber delivered

A delivered immutable result is not retroactively revoked by later
cancellation.

The M2 deterministic state-machine experiment validated these semantics.

It did not attempt to validate synchronization primitives or thread races.

---

## 25. Cooperative cancellation

Cancellation is cooperative.

The architecture does not require unsafe forced worker/thread termination.

A codec or backend may contain non-cancellable work.

In that case a cancelled request may still allow internal work to finish while
suppressing delivery, and policy may decide whether the completed result is
eligible for cache admission.

Future implementation evidence should measure:

- cancellation latency;
- bytes transferred after cancellation;
- compute work after cancellation;
- reservation-release latency;
- time spent in non-cancellable sections.

---

## 26. Priority

Priority is execution policy.

It is not semantic result identity.

A shared production may derive effective priority from its current interested
Subscribers.

Priority may rise when a high-priority Subscriber joins.

It may fall when that Subscriber leaves, subject to implementation policy.

No public priority scheduler is selected by this ADR.

---

## 27. Generation and obsolescence

Interactive consumers may associate requests with a generation or epoch.

Generation expresses current consumer relevance.

It is not source/resource revision.

Therefore:

    request generation != Resource revision

Generation may allow obsolete work to be deprioritized or cancelled.

It must not become semantic cache identity unless it actually changes requested
result semantics.

---

## 28. Prefetch

Prefetch uses ordinary semantic production/cache identity.

Prefetch is not a second result model.

It normally differs through:

- lower priority;
- weaker immediacy;
- cancellation/obsolescence policy.

A later foreground request for the same semantic production may reuse or join
prefetch work.

---

## 29. Progressive results

Progressive presentation is represented as complete immutable stages.

It is not represented by mutating one already-published semantic result in
place.

Each stage must identify what it actually represents, for example:

- overview grid;
- reduced resolution;
- lower-quality representation;
- full-detail representation.

Distinct semantic stages require distinct semantic identity when their result
contracts differ.

---

## 30. Memory admission and cache accounting

Cache and execution memory are bounded-resource concerns.

A future implementation must distinguish at least:

- evictable residency;
- pinned/delivered residency;
- in-flight reservations;
- imagery-controlled overhead;
- known configured external/backend budgets;
- estimated or observed foreign-library overhead.

The same backing allocation must not be double-counted merely because several
retains refer to it.

Persistent/disk caches must likewise have an explicit configured budget or
other explicit bounded-retention policy.

Unbounded persistent-cache growth is not an accepted default.

Persistent entries must remain subject to the Resource identity/revision and
staleness rules defined by this architecture.

M2 accepts the need for memory admission before expensive production.

It does not freeze a specific allocator, accounting class, disk-cache format
or eviction policy.

---

## 31. Cache/block geometry

Source blocks, cache blocks and processing tasks are distinct concepts.

Cache geometry is performance policy.

It may depend on:

- source-native block geometry;
- request shapes;
- halo/dependency expansion;
- decode amplification;
- RAM budget;
- transport latency/bandwidth;
- transform cost.

It is not part of image semantics.

---

## 32. Product-to-ImageView bridge

A heterogeneous Product is not itself an `ImageView!T`.

The accepted bridge is:

    Product
      |
      v
    select ordered components
      |
      v
    inspect candidate representations
      |
      v
    TargetImageContract
      |
      v
    resolve representations and revisions
      |
      v
    compatibility analysis
      |
      v
    ResolvedMaterializationPlan
      |
      +-- selected ordered components
      +-- composite source snapshot
      +-- target grid
      +-- target sample representation
      +-- radiometric semantics
      +-- conversion semantics
      +-- resampling semantics
      +-- validity semantics
      |
      v
    semantic production key
      |
      v
    ExecutionPlan
      |
      v
    native materializations
      |
      v
    explicit deterministic transforms
      |
      v
    retained common-grid result
      |
      v
    ImageView!T borrow

---

## 33. Compatibility classes

Resolution of Product components may distinguish cases such as:

- direct compatibility;
- sample-type conversion required;
- grid transformation required;
- both sample and grid transformation required;
- semantic normalization required;
- unsupported.

These distinctions are semantic planning information.

They must not be replaced by hidden convenience conversions.

---

## 34. Explicit target grid

The target grid is explicit.

Grid equality is not merely equal width and height.

Grid identity may include:

- resolution;
- origin;
- alignment;
- sampling geometry;
- geographic/logical placement.

The architecture must not silently choose:

- finest available grid;
- coarsest available grid;
- first component grid;
- first decoded resource grid

as universal policy.

---

## 35. Explicit sample representation and radiometry

Target sample representation is explicit.

Stored sample and physical/radiometric value remain distinct as established by
M1.

Therefore:

    raw DN != physical value

unless the resolved semantics explicitly establish equivalence.

Sample conversion, scale/offset application and physical-value conversion are
not implicit merely because a target `T` exists.

---

## 36. Explicit resampling

Resampling is explicit semantic policy.

Different resampling rules may be required for different component roles.

Examples include differences between:

- continuous radiometric values;
- categorical classification;
- validity/quality masks.

The materialization architecture must not apply one hidden universal
resampling policy.

---

## 37. Explicit validity

Validity remains distinct from:

- alpha;
- NoData metadata;
- quality;
- classification.

A source quality/classification component is not automatically attached as the
processing validity mask.

Validity derivation must be explicit.

If validity is attached to one `ImageView!T`, it must satisfy the common-grid
contract before binding.

---

## 38. Composite snapshots

A materialized result may depend on multiple Resources.

Its resolved semantic identity therefore may require a composite snapshot.

Per-resource coherence is mandatory.

Product-wide atomic coherence may be claimed only when the source/product
system actually provides such a guarantee.

The architecture must not invent cross-resource atomicity.

---

## 39. Generated sources

Generated or procedural Sources are first-class.

Their semantic snapshot may derive from:

- SourceId;
- generator semantic version;
- generator parameters;
- snapshots of upstream dependencies.

They need not invent fake encoded Resources merely to pass through the
resource-backed path.

---

## 40. Failure semantics

Failures must preserve semantic distinctions.

Examples include:

- access failure;
- missing Resource;
- unsupported representation;
- revision mismatch;
- decode failure;
- invalid requested region;
- unsupported conversion;
- unsupported resampling;
- cancellation;
- memory-admission failure.

A future public API may group or expose these differently.

This ADR does not freeze an error enum.

---

## 41. Retry semantics

Retry is execution/access policy.

Transient access failure may be retried without changing semantic production
identity when the same resolved snapshot remains valid.

A discovered different Resource revision is not merely another retry attempt.

It represents a different source snapshot and therefore potentially a
different semantic production key.

Backoff policy is not frozen by this ADR.

---

## 42. No hidden scheduler

M2 does not authorize a hidden global scheduler.

The architecture should expose independent work in a form that callers or a
future execution layer can parallelize.

The imagery semantic API must not require one process-global worker pool.

No scheduler becomes public API solely because caching and single-flight need
coordination.

---

## 43. No public general DAG

M2 does not select a general public DAG abstraction.

A resolved materialization may internally depend on finite child
materializations.

That implementation fact does not require exposing a graph API to imagery
callers.

If later concrete operations prove a reusable DAG requirement, that decision
must be made independently.

---

## 44. Reference-system validation

The M2 architecture was pressure-tested against the architectural patterns of:

- GDAL/VSI and GDAL caching;
- OpenImageIO/ImageCache;
- libvips;
- Cloud Optimized GeoTIFF and HTTP range access;
- xarray/Dask;
- MapLibre-style interactive tile demand;
- OpenEXR;
- STAC product/resource metadata.

The comparison was used to test responsibilities and failure modes.

Their APIs are not copied into `imagery-d`.

No reference-system finding required reopening the accepted M1 image semantic
core.

---

## 45. Consumer-case validation

M2 was tested conceptually against at least:

1. local large GeoTIFF;
2. remote COG viewport;
3. WMTS/tile service;
4. generated source;
5. mixed-resolution Sentinel-2-style product;
6. heterogeneous OpenEXR-style channels;
7. finite-neighbourhood/halo operation;
8. changed source while an older view remains displayed;
9. concurrent duplicate requests;
10. memory pressure with active delivered views;
11. request spanning cache blocks;
12. untiled scanline source;
13. full-image-only decoder;
14. stale offline cache;
15. cancellation during non-cancellable codec work;
16. progressive overview-to-detail presentation;
17. primary and quality resources resolved independently;
18. two different execution strategies producing one semantic result.

These cases did not require:

- heterogeneous `ImageView!T`;
- source/cache state inside `RasterView`;
- provider tiles as processing units;
- a second raster owner;
- public scheduler;
- public general DAG;
- implicit sample conversion;
- implicit resampling.

---

## 46. Mechanical contract experiment

M2 includes:

    experiments/m2_source_cache_pipeline_contract/

The experiment was validated locally on 2026-09-24 against:

    imagery-d pre-experiment HEAD:
        2c43f23329c9b5d70b31cde1d7fba362f0335a68

    raster-d:
        a073b3ad6b541fcd8421ed304722feaa47e9083b

    DMD:
        2.111.0

    LDC:
        1.41.0

    LDC frontend:
        DMD 2.111.0

    DUB:
        1.40.0

The experiment passed under both DMD and LDC.

It validated:

- semantic production-key boundaries;
- equal-key single-flight;
- subscriber cancellation/publication semantics;
- cache eviction preserving delivered `RasterLease` lifetime;
- covering logical coverage serving an exact ROI without rematerialization;
- semantic equivalence across different execution strategies.

The validating experiment commit is:

    046b3b6
    experiment: validate M2 source cache pipeline contract

---

## 47. Experimental types are not public API

The M2 experiment contains deliberately minimal research-only types such as:

- `SourceSnapshot`;
- `GridIdentity`;
- `ResolvedMaterializationPlan`;
- `ProductionKey`;
- `RequestEnvelope`;
- `SharedProduction`;
- `SharedResidentCoverage`;
- `CoverageCache`;
- `MaterializationOwner`.

Their presence proves architectural properties.

It does not freeze:

- names;
- layout;
- visibility;
- templates;
- ownership representation;
- error representation;
- module placement;
- public versus package-private status.

Production API design must be driven by a concrete admitted capability.

---

## 48. Rejected alternatives

### 48.1 Source equals file/URL

Rejected.

A Source may represent:

- a Resource family;
- generated imagery;
- multiple alternative representations.

Location is not identity.

### 48.2 Resource identity equals locator

Rejected.

Paths and URLs may change independently of semantic Resource identity.

### 48.3 Every Source must expose encoded bytes

Rejected.

Generated/direct Sources are valid.

### 48.4 Decoder owns source identity

Rejected.

Decode mechanics and imagery identity are separate.

### 48.5 Global placement stored in RasterView.region

Rejected.

`RasterView.region` remains resident descriptor-space geometry.

### 48.6 imagery-d duplicates raster ownership

Rejected.

`RasterLease!T` remains the raster ownership primitive.

### 48.7 Cache eviction invalidates delivered views

Rejected.

Cache membership and retained raster lifetime are separate.

### 48.8 Provider tile equals processing task

Rejected.

Source, cache and processing geometries are independent.

### 48.9 Priority is part of semantic cache key

Rejected.

Priority is execution policy.

### 48.10 Generation/epoch is source revision

Rejected.

Consumer obsolescence and source revision are different concepts.

### 48.11 Cancellation of one subscriber cancels all

Rejected.

Shared production may still serve other interested Subscribers.

### 48.12 Progressive result mutates published image in place

Rejected.

Progressive stages are complete immutable results with explicit identity.

### 48.13 Execution strategy defines result identity

Rejected.

Different execution strategies may share semantic identity when they are
semantically equivalent.

### 48.14 Hidden automatic target-grid selection

Rejected.

Grid choice is semantic policy.

### 48.15 Hidden automatic sample/radiometric conversion

Rejected.

Conversion semantics are explicit.

### 48.16 Hidden automatic resampling

Rejected.

Resampling semantics are explicit.

### 48.17 Quality/classification automatically means validity

Rejected.

Validity binding is explicit.

### 48.18 Public global scheduler in M2

Rejected.

No evidence requires it.

### 48.19 Public general DAG in M2

Rejected.

No evidence requires it.

### 48.20 Mandatory three-level cache pipeline

Rejected.

L1/L2/L3 are optional reuse boundaries.

---

## 49. Responsibility matrix

| Concern | imagery-d | raster-d | Backend/decoder implementation |
|---|---|---|---|
| image/product semantics | owns | no | no |
| Source identity | owns | no | no |
| Resource identity/revision | owns model | no | observes/provides evidence |
| Locator | owns association | no | consumes |
| access capabilities | interprets | no | provides |
| encoded byte access | coordinates | no | owns mechanism |
| decode implementation | coordinates | no | owns mechanism |
| logical source placement | owns | no | may report native geometry |
| target semantic grid | owns | no | no |
| radiometric semantics | owns | no | may expose encoded metadata |
| resampling semantics | owns | generic kernels may later assist | may optimize |
| raster storage lifetime | no | owns | supplies/adopts storage |
| physical layout/strides | no | owns | provides import metadata |
| resident ROI | composes | owns | no |
| source/cache identity | owns | no | no |
| cache policy | owns imagery-side policy | no | may have independent internal cache |
| request lifecycle | owns imagery-side semantics | no | cooperates |
| scheduler | not public/frozen | no | implementation choice |
| provenance | owns image/product model | no | may supply metadata |

---

## 50. Source/request/cache lifecycle

The accepted high-level lifecycle is:

    downstream demand
        |
        v
    TargetImageContract
        |
        v
    resolve Product / Source / Resource snapshot
        |
        v
    ResolvedMaterializationPlan
        |
        v
    derive semantic Production Key
        |
        +------ completed cache lookup
        |
        +------ existing in-flight production
        |
        `------ create/admit new production
                    |
                    v
             source/backend access
                    |
                    v
                 decode
                    |
                    v
           RasterLease!T coverage
                    |
            optional cache retain
                    |
                    v
          explicit semantic transforms
                    |
                    v
          retained materialization
                    |
                    v
             ImageView!T borrow

At each stage:

- semantic identity remains explicit;
- source revision coherence is preserved;
- cache reuse does not alter semantics;
- execution policy does not silently alter semantic identity;
- cancellation applies to Subscriber interest separately from immutable
  published results.

---

## 51. Production API promotion decision

M2 accepts the architecture.

M2 does **not** yet admit a general production source/cache/pipeline framework.

The reason is evidentiary rather than architectural.

The research now answers:

> What responsibilities and invariants must such a system preserve?

It does not yet answer, with production evidence:

> Which smallest concrete public API is justified by a real image-domain
> vertical slice?

The focused experiment intentionally excluded:

- real HTTP;
- COG range access;
- WMTS;
- real image codecs;
- filesystem/disk cache;
- persistent cache validation;
- real cancellation latency;
- real concurrency synchronization;
- real memory-admission pressure;
- real resampling;
- cross-grid transformation;
- production performance benchmarks.

Therefore the architectural model is accepted while concrete production API
shape remains gated.

---

## 52. Requirements for first production admission

Before opening a production `source/imagery/**` surface, the project should
select one concrete vertical capability and define:

1. consumer requirement;
2. input/source class;
3. semantic output contract;
4. source/resource/revision behavior;
5. region/residency behavior;
6. correctness oracle;
7. failure/cancellation behavior where applicable;
8. memory budget and residency accounting;
9. benchmark scene/workload;
10. DMD correctness matrix;
11. LDC optimized benchmark/codegen evidence.

Only the API required by that proven vertical slice should be admitted.

The project should not first implement a speculative universal source/cache
framework and search for consumers afterwards.

---

## 53. M2 issue closure mapping

### M2.1 — Define source / resource / provider model

Evidence:

- `docs/research/m2-source-resource-access-model.md`
- commit `a09031a`

Accepted result:

- Source and Resource are distinct;
- Source may be fixed-resource, resource-family or generated/direct;
- Asset remains product/metadata vocabulary rather than a second core
  access-identity layer;
- Provider remains provenance/organizational vocabulary rather than the
  technical access abstraction;
- Product Component remains a semantic product-selection concept rather than
  resident raster storage;
- SourceId, ResourceId, revision and Locator remain distinct;
- access backend/session and decoder remain operational concerns.

Status:

    research-complete

### M2.2 — Define region materialization boundary with raster-d

Evidence:

- `docs/research/m2-region-materialization-boundary.md`
- commit `a09031a`
- M2 contract experiment
- commit `046b3b6`

Accepted result:

- logical source placement remains in `imagery-d`;
- resident ownership and ROI remain in `raster-d`;
- `RasterLease!T` is reused directly;
- no second raster owner is introduced.

Status:

    validated

### M2.3 — Define cache architecture and cache identity

Evidence:

- `docs/research/m2-cache-architecture.md`
- commit `a09031a`
- M2 contract experiment
- commit `046b3b6`

Accepted result:

- L1/L2/L3 are optional independent reuse boundaries;
- cache identity derives from semantic/resource identity rather than location;
- cache membership is distinct from raster lifetime.

Status:

    validated

### M2.4 — Define demand, priority, cancellation, prefetch and progressive refinement

Evidence:

- `docs/research/m2-demand-cancellation-prefetch.md`
- commit `a09031a`
- M2 contract experiment
- commit `046b3b6`

Accepted result:

- Subscriber and Shared Production are distinct;
- equal semantic work may single-flight;
- cancellation is subscriber-specific;
- priority/generation are execution metadata;
- progressive results are immutable semantic stages.

Status:

    validated

### M2.5 — Define product-to-typed-ImageView materialization

Evidence:

- `docs/research/m2-product-to-image-materialization.md`
- commit `a09031a`
- M2 contract experiment
- commit `046b3b6`

Accepted result:

- TargetImageContract, ResolvedMaterializationPlan and ExecutionPlan are
  distinct conceptual layers;
- heterogeneous Products require explicit resolution;
- grid, sample, radiometric, resampling and validity semantics are explicit.

Status:

    validated

### M2.6 — Validate source/cache/pipeline model against reference systems and consumer cases

Evidence:

- `docs/research/m2-reference-consumer-validation.md`
- commit `a09031a`

Accepted result:

- reference-system and consumer-case pressure testing found no contradiction
  requiring M1 reopening;
- no public scheduler, general DAG, second raster owner or implicit conversion
  model is required.

Status:

    research-complete

### M2.7 — Synthesize source/cache/pipeline architecture and promotion gate

Evidence:

- this ADR;
- M2 contract experiment;
- commit `046b3b6`.

Status after ADR commit:

    complete

---

## 54. Consequences

### Positive

The project now has an explicit answer to:

> What is a Source?

> What is a Resource?

> How is one Resource revision identified?

> Where does logical placement live?

> How is a resident raster retained?

> What determines semantic materialization identity?

> What may caches reuse?

> How can equal concurrent work be shared?

> How does cancellation interact with shared work?

> How does a heterogeneous Product become a typed common-grid ImageView?

The architecture composes with the existing `raster-d` ownership model.

No generic raster responsibility had to be duplicated.

### Cost

The architecture deliberately keeps several concepts separate that simpler
systems may collapse:

- Source;
- Resource;
- Locator;
- Revision;
- AccessBackend;
- ReadSession;
- Decoder;
- logical coverage;
- semantic materialization plan;
- execution plan;
- Subscriber;
- Shared Production;
- cache membership;
- raster lifetime.

This increases conceptual precision and implementation discipline.

It is intentional because collapsing these distinctions causes incorrect cache
identity, stale-source behavior, lifetime coupling or hidden semantic policy.

### Deferred work

Still deferred are:

- final production module/type names;
- final Source/Resource API;
- concrete backend API;
- concrete HTTP/range implementation;
- real codec integration;
- persistent cache format;
- cache eviction algorithm;
- concurrency primitive selection;
- cancellation token representation;
- memory-admission implementation;
- resampling implementation;
- production `ImageView` representation;
- first concrete production vertical slice.

---

## 55. Final decision

M2 has established a coherent source/cache/materialization architecture for
`imagery-d`.

The project now has a stable architectural answer to:

> How does heterogeneous imagery become a retained typed processing view?

Through explicit resolution of Source, Resource and revision into a semantic
materialization plan; explicit source-specific materialization into
`RasterLease!T`; optional independent cache reuse; explicit transforms into
one requested common-grid result; and a retained owner from which
`ImageView!T` borrows.

The project also has a stable answer to:

> What determines whether two requests are the same work?

Their resolved semantic result definition, not their execution strategy,
priority, generation, worker, URL or Subscriber identity.

And:

> What happens when a cached result is evicted while a consumer still uses it?

Only cache membership ends. The delivered retained raster remains alive.

M2 therefore closes as an architecture milestone once this ADR is committed
and the corresponding issues are closed.

Production source/cache/pipeline API creation remains gated and is not
authorized solely by this ADR.
