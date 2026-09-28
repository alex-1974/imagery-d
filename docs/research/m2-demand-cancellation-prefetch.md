# M2.4 — Demand, Priority, Cancellation, Prefetch and Progressive Refinement

**Project:** `imagery-d`
**Milestone:** `M2 — Source / Cache / Pipeline Architecture`
**Issue:** `M2.4 — Define demand, priority, cancellation, prefetch and progressive refinement`
**Status:** Research draft — not a public API
**Date:** 2026-09-23

## 1. Purpose

M2.4 defines the request-lifecycle architecture between:

- downstream demand;
- cache lookup;
- shared in-flight production;
- source/materialization work;
- publication;
- cancellation;
- priority;
- prefetch;
- progressive refinement;
- memory admission/backpressure.

The first concrete consumer pressure remains an interactive geospatial editor,
where viewport changes can rapidly make previously requested imagery obsolete.

The architecture must remain useful outside GUI rendering and must not freeze a
specific thread pool, future type, coroutine model, actor runtime or event loop.

No spelling in this document is a frozen public D API.

---

## 2. Inputs from M2.1–M2.3

### M2.1

M2.1 separates:

    Source
    Resource
    Locator
    Revision
    Access Backend
    Read Session

and establishes that source identity, resource identity, locator and revision
must not be collapsed.

### M2.2

M2.2 defines one logical materialization attempt:

    already-determined logical input requirement
        ->
    source-specific resolution
        ->
    resident raster construction
        ->
    RasterLease!T
        ->
    retained materialization owner
        ->
    ImageView!T

It does not own scheduling policy.

### M2.3

M2.3 separates completed caches from in-flight work.

It also defines a global residency-budget direction and a shared retained
coverage model above `RasterLease!T`.

Important M2.3 invariant:

> equivalent concurrent misses should be coalescible through the same semantic
> production key.

M2.4 now defines that lifecycle.

---

## 3. Reference-system findings

### 3.1 RFC 9111 request collapsing

HTTP caching explicitly permits a cache to combine multiple equivalent incoming
requests into one forwarded request after a miss.

Architectural lesson:

> duplicate demand and one shared production are different concepts.

This is the same shape needed by decoded and transformed imagery caches.

### 3.2 OpenImageIO

OpenImageIO's ImageCache is thread-safe and shares cached image/tile work across
threads.

Reference-counted tile handles remain valid until released even if the cache is
otherwise free to evict or invalidate entries.

Architectural lesson:

> consumers retain completed results independently from cache/in-flight control.

This reinforces the M2.3 shared-coverage ownership model.

### 3.3 libvips

libvips is demand-driven.

A downstream sink pulls only the rectangular areas needed from upstream
operations. Partial images compute requested regions on demand. The execution
system uses separate per-evaluation state and can reuse previously calculated
buffers.

Architectural lessons:

- work originates from current demand rather than eager whole-image execution;
- request geometry and execution-task geometry remain distinct;
- concurrency policy can sit outside image semantic types;
- cached calculated pixels can satisfy later demand.

### 3.4 MapLibre

MapLibre is a directly relevant interactive-map pressure case.

Its source interfaces support aborting tile loads, and its resource-provider
interface can notify a provider when a request has been cancelled because the
map no longer wants the resource.

It also distinguishes regular and low-priority resource requests.

Architectural lessons:

- viewport-driven demand is naturally revocable;
- background/prefetch work should have lower execution importance;
- cancellation is an operational lifecycle event, not source identity;
- a resource provider may need to abort expensive work after downstream demand
  disappears.

### 3.5 Cooperative cancellation primitives

C++ `std::stop_token` models cancellation as a shared stop state that can be
queried or observed.

GIO's `GCancellable` similarly supports thread-safe cooperative cancellation
and explicitly documents cancellation/completion race considerations.

Architectural lesson:

> cancellation should be modeled as a cooperative request to stop work, not as
> forcible thread termination or mutation of already-published results.

---

# Part I — Core Lifecycle Separation

## 4. Demand is not production

M2.4 introduces a strict conceptual distinction:

    Demand / Subscriber
        !=
    Shared Production

A demand represents one consumer's current interest in a semantic result.

A production represents one attempt to create a cacheable result.

Several demands may depend on one shared production.

---

## 5. Why the distinction is mandatory

Suppose three consumers request the same decoded block:

    consumer A
    consumer B
    prefetch C

All resolve to one identical `DecodedCoverageKey`.

If A cancels, cancelling the underlying work immediately would incorrectly
harm B.

Therefore:

    subscriber cancellation
        !=
    production cancellation

The production lifecycle must aggregate current interest.

---

## 6. Demand/subscriber concept

One demand conceptually carries:

    semantic production key
    request generation/context
    priority hint
    completion interest
    cancellation state
    optional freshness/deadline constraints

The exact representation remains open.

A demand does not own the source pixels being produced.

---

## 7. Shared production concept

A shared production conceptually carries:

    semantic production key
    lifecycle state
    interested subscribers
    effective priority
    admission/residency reservation
    underlying source/materialization attempt
    completion result or failure

One production exists only for one exact semantic production key.

---

## 8. Production key

The production key should normally be identical to the corresponding cache
production identity.

Examples:

    SourceByteKey
    DecodedCoverageKey
    TransformKey

Priority, requester identity and viewport generation are **not** key fields if
they do not change the resulting pixels.

This is essential for coalescing.

---

## 9. Subscriber state

A minimal conceptual subscriber state machine is:

    waiting
       |
       +--> delivered
       |
       `--> cancelled

A subscriber should have one terminal outcome.

The exact callback/future representation is deferred.

---

## 10. Production state

A minimal conceptual production state machine is:

    queued
      |
      v
    admitted
      |
      v
    running
      |
      +--> completed(result)
      |
      +--> failed(error)
      |
      `--> stopped(no result)

A production is not "cancelled" merely because one subscriber cancels.

`stopped` means the shared production itself ended without a publishable
result.

---

## 11. Publication linearization point

M2.4 needs one conceptual publication point.

Before publication:

- cancellation may still prevent the production from exposing a result;
- intermediate buffers may be discarded;
- cache insertion has not committed.

After publication:

- a complete immutable result exists;
- cache publication may be complete;
- consumers that receive it retain independent ownership;
- later cancellation cannot revoke that result.

This is the key cancel-vs-complete race boundary.

---

## 12. Cancel versus complete race

A subscriber and shared production can race.

Example:

    thread A: subscriber cancel
    thread B: production completes

M2.4 should not pretend there is no race.

The contract must instead define one of two outcomes for that subscriber:

    cancel wins
        -> subscriber observes cancelled

or:

    delivery wins
        -> subscriber receives complete result

Both are acceptable if the implementation has one well-defined atomic/
serialized transition.

What is forbidden:

- double callback;
- delivered result followed by cancellation invalidating it;
- partially published result;
- leaked ownership.

---

## 13. Shared completion after one subscriber cancels

If production completes for remaining subscribers:

- cache publication may proceed;
- cancelled subscriber is detached;
- remaining subscribers receive the result.

The result does not contain requester-specific cancellation state.

---

## 14. Last-subscriber cancellation

When the final interested subscriber withdraws, the shared production becomes
orphaned.

Possible policies:

    stop immediately if practical
    finish if nearly complete / useful
    finish if cache-admission policy wants the result

M2.4 should permit policy choice.

One hard rule:

> orphaned partial state is never published as a complete cache entry.

---

# Part II — Cooperative Cancellation

## 15. Cancellation is cooperative

M2.4 should not require killing worker threads.

A cancellation request should propagate to cancellable boundaries such as:

- waiting in queue;
- network request;
- range read;
- decoder loop;
- transform loop;
- allocation wait;
- dependency child wait.

Each implementation layer should stop at safe interruption points.

---

## 16. Non-cancellable operations

Some underlying libraries or codecs may not support interruption once an
operation starts.

That is acceptable as a capability limitation.

The scheduler can still:

- detach cancelled subscribers;
- avoid publishing unwanted partial state;
- suppress downstream work;
- discard the result if no longer useful.

Cancellation therefore means:

> stop as soon as safely practical.

It does not guarantee instantaneous resource reclamation.

---

## 17. Cancellation capability

Sources/adapters may expose operational capability such as:

    cancellable before open
    cancellable during network I/O
    cancellable during decode
    non-cancellable decode section

The exact capability API remains open.

M2.6 adds that cancellation is not merely a boolean feature.

For interactive consumers, useful performance evidence includes:

    cancellation observation latency
    bytes/work performed after cancellation
    time until memory reservation is released
    frequency/length of non-cancellable sections

Cancellation responsiveness should therefore be benchmarkable/observable where
practical.

This is planning/execution metadata, not image semantics.

---

## 18. Cancellation checkpoints

Long-running pure-D transforms should include bounded cancellation checkpoints.

Examples:

- between cache blocks;
- between scanline groups;
- between transform tiles;
- before allocating the next large buffer.

Avoid per-pixel cancellation checks if profiling shows they damage hot-loop
performance.

Cancellation responsiveness is an execution tradeoff.

---

## 19. Cancellation and ownership

Cancel-before-publication:

    intermediate ownership is released normally
    no ImageView is published

Cancel-after-publication:

    published owner/lease remains valid
    caller may drop its retain
    cache may independently retain result

Cancellation never mutates `RasterLease` backing.

---

## 20. Reusing cancellation objects

M2.4 should prefer one cancellation state per demand/operation lifetime rather
than resetting and reusing mutable cancellation state.

This mirrors common cooperative-cancellation guidance and avoids stale-race
confusion.

No exact D cancellation primitive is selected yet.

---

# Part III — Request Coalescing

## 21. Exact-key coalescing

Initial M2.4 should coalesce only exact semantic production keys.

Example:

    request A -> DecodedCoverageKey K
    request B -> DecodedCoverageKey K

One shared production K is sufficient.

---

## 22. Overlapping but non-identical requests

Two arbitrary regions may overlap heavily without having equal keys.

Do not initially build complex arbitrary-region union/coalescing logic.

Instead let the decoded-cache decomposition from M2.3 create canonical
production units.

Then overlapping viewport requests naturally join on shared cache-block keys.

This keeps coalescing deterministic.

---

## 23. Coalescing lifecycle

Conceptually:

    request
      |
      v
    cache lookup
      |
      +-- hit -> deliver retained value
      |
      `-- miss
           |
           v
      in-flight lookup
           |
           +-- production exists
           |      -> attach subscriber
           |
           `-- absent
                  -> create production
                  -> queue/admit
                  -> attach subscriber

---

## 24. Publication race between producers

There should not normally be two producers for one exact key.

If implementation races create two attempts anyway, cache publication must be
transactional.

Only one compatible complete value becomes canonical.

The other attempt is discarded or independently retained by its consumer.

Better implementations prevent duplicate production earlier.

---

## 25. Failure sharing

Subscribers attached to one production may observe the same attempt failure.

That failure is not automatically a permanent cache result.

A retry creates a new attempt for the same semantic key.

Attempt identity is operational and distinct from production key.

---

# Part IV — Priority

## 26. Priority is execution policy

Priority does not change pixel semantics.

Therefore priority must not participate in ordinary cache/production identity.

The same production can serve low- and high-priority subscribers.

---

## 27. Priority classes

M2.4 should initially prefer a small ordered set of semantic execution classes
rather than exposing arbitrary numeric priority values as public API.

Conceptual example:

    interactive-visible
    interactive-nearby
    background
    prefetch

Exact names/order remain open.

---

## 28. Effective shared-production priority

If a low-priority prefetch is already producing K and a high-priority visible
request joins K:

> the existing production should be promoted rather than duplicated.

Conceptually:

    effective priority
        = highest current interested demand

This is priority donation.

---

## 29. Priority drop

When the high-priority subscriber leaves but a low-priority subscriber remains,
the effective priority may drop.

Whether a running task is dynamically demoted depends on scheduler
implementation.

The architecture should permit it.

---

## 30. Priority is not correctness

Priority may affect:

- queue order;
- admission;
- worker selection;
- prefetch suppression.

It must not affect:

- returned pixel values;
- cache key;
- source revision semantics;
- validity interpretation.

---

## 31. Fairness

Strict priority can starve background work.

A future scheduler may need:

- aging;
- bandwidth shares;
- per-class quotas;
- bounded starvation guarantees.

M2.4 does not freeze the fairness algorithm.

It records starvation as a requirement to measure.

---

## 32. Priority inversion

A high-priority request can depend on lower-priority child/source work.

The scheduler must propagate/donate effective priority along required work.

Otherwise a visible task can wait behind background tasks it depends on.

This is especially relevant when one transformed request depends on several
decoded cache blocks.

---

# Part V — Viewport Generations and Obsolescence

## 33. Demand generation

Interactive rendering changes rapidly during pan/zoom/style changes.

A useful operational concept is a demand generation/epoch:

    viewport generation 100
    viewport generation 101
    viewport generation 102

Generation is not cache identity.

It identifies which consumer demand set is still current.

---

## 34. New generation

When a new viewport generation supersedes an old one:

- old visible subscribers may be cancelled/detached;
- shared productions still needed by the new generation continue;
- useful old completed cache entries remain reusable;
- prefetch priorities may be recomputed.

This avoids flushing useful cache data simply because the viewport changed.

---

## 35. Generation does not invalidate pixels

A cached tile/block from an older viewport generation is not stale solely
because the camera moved.

Generation tracks interest, not source revision.

Do not conflate:

    demand obsolescence
        with
    data invalidation

---

# Part VI — Prefetch

## 36. Prefetch definition

Prefetch is speculative low-priority demand intended to reduce future latency.

It is not required for correctness.

Examples:

- regions immediately outside current viewport;
- likely next pyramid level;
- neighboring source blocks;
- sequential-next chunks for a format with directional access preference.

---

## 37. Prefetch should use normal production keys

A prefetch request should resolve to the same semantic cache/production key as
a later ordinary demand for the same result.

Therefore:

    prefetch K
        + later visible request K
        -> one shared production promoted to visible priority

Do not create a separate "prefetch cache".

---

## 38. Prefetch cancellation

Prefetch is the first work to withdraw under pressure.

It should be cancellable when:

- viewport direction changes;
- global memory admission tightens;
- network/bandwidth pressure rises;
- interactive demand needs capacity.

---

## 39. Prefetch and cache pollution

Aggressive prefetch can evict useful current data.

M2.4 should therefore allow cache admission policy to treat prefetch results
differently.

Examples:

- lower admission probability;
- lower initial recency;
- prefetch budget cap;
- no transformed-cache admission for speculative variants.

No policy is frozen.

---

## 40. Prefetch distance

The engine should not bake one fixed geographic/pixel radius into core
semantics.

Prefetch distance may depend on:

- viewport velocity;
- zoom;
- source latency;
- block size;
- memory budget;
- network conditions.

This is application/scheduler policy.

---

## 41. No recursive prefetch explosion

A prefetched item should not automatically trigger an unbounded tree of further
prefetch.

Prefetch fanout must be explicitly bounded.

---

## 42. Sequential-source prefetch

For sequential or expensive-seek sources, prefetch may follow source-native
access order rather than viewport geometry.

This is why prefetch belongs above source capability discovery but outside image
semantics.

---

# Part VII — Admission and Backpressure

## 43. Scheduling needs budget admission

M2.3 introduced:

    global residency budget
    evictable bytes
    pinned bytes
    in-flight reservations

M2.4 must use these signals before starting memory-expensive work.

---

## 44. Admission sequence

Conceptually:

    queued production
        ->
    estimate/reserve required working memory
        ->
    evict reusable cache if useful
        ->
    if budget permits:
        admit
    else:
        wait / reject / downgrade according to policy

This prevents many workers from simultaneously allocating beyond the intended
budget.

---

## 45. Reservation is not allocation

A reservation is control-plane accounting.

It prevents over-admission.

The real allocation can still fail.

On allocation failure:

    release reservation
    report failure

---

## 46. Pinned memory pressure

If active consumers retain more memory than the target allows, the cache cannot
evict those bytes.

Scheduler options include:

- delay new background work;
- cancel prefetch;
- reduce concurrency;
- reject optional work;
- admit only visible work;
- surface resource-pressure diagnostics.

The scheduler cannot magically reclaim valid externally retained leases.

---

## 47. Queue backpressure

An unbounded queue is also a memory/latency bug.

When demand churn exceeds throughput, old queued requests should become
cancellable/replaceable rather than accumulating forever.

Interactive generation cancellation is one mechanism.

Queue limits are scheduler policy.

---

## 48. Network backpressure

Source I/O may require separate concurrency limits from CPU decode/transform.

A future scheduler may use different resource classes:

    network reads
    disk reads
    decode CPU
    transform CPU
    memory reservation

M2.4 should not assume one global worker pool is optimal.

---

# Part VIII — Progressive Refinement

## 49. Progressive refinement definition

Progressive refinement means delivering useful complete intermediate results
before the requested final-quality result is available.

Examples:

- lower-resolution overview first;
- cached stale snapshot first, then validated fresh snapshot;
- coarse resample first, then high-quality resample;
- partial-resolution imagery first, then native-resolution imagery.

Progressive refinement is not the same as publishing partially initialized
memory.

---

## 50. Immutable stages

M2.4 should prefer:

    stage A = complete immutable retained result
    stage B = another complete immutable retained result
    stage C = final complete immutable retained result

rather than mutating RasterLease backing behind existing ImageViews.

This preserves M1/raster-d lifetime semantics.

---

## 51. Stage identity

Every progressive stage must declare what it actually represents.

A coarse overview must not masquerade as the requested final native grid.

Stage metadata may include conceptually:

    request generation
    refinement level
    target/final marker
    grid/resolution identity
    source revision/freshness
    quality/completeness descriptor

Exact types remain open.

---

## 52. Cache identity of stages

If two stages have different pixels because they use different:

- grid;
- resolution;
- transform;
- source revision;

they have different cache/production identities.

Progressive delivery does not mean multiple semantic results share one cache
key.

The subscription/request layer groups them as one refinement sequence.

---

## 53. Final target

A progressive request should identify one final semantic target.

Intermediate stages are alternate complete representations useful while
waiting.

The final stage satisfies the ordinary final production key.

---

## 54. Out-of-order completion

Progressive work can complete out of order.

Example:

    stage 2 completes
    then delayed stage 1 completes

The consumer must not regress to an older stage.

Therefore a refinement sequence needs monotonic stage ordering or a replacement
rule independent of completion time.

---

## 55. Generation interaction

A stage from an obsolete viewport generation must not replace a result for a
newer viewport merely because it completes later.

Again:

    demand generation
        !=
    source revision

Both may participate in delivery filtering.

---

## 56. Progressive cancellation

When the final request is cancelled:

- future stages can be cancelled;
- already-delivered stages remain valid snapshots until released;
- useful stage results may remain in cache under their own identities.

---

## 57. Stale-while-refresh analogy

Offline/current-refresh workflows resemble progressive refinement:

    cached stale-but-declared result
        ->
    fresh validated result

The stale result must remain explicitly marked as stale.

This is not permission to silently substitute stale data.

---

## 58. Missing-tile mosaics

A mosaic with holes is not automatically a valid progressive stage.

If partial spatial coverage is exposed, its incompleteness must be explicit,
for example through:

- coverage metadata;
- validity;
- a partial-stage contract.

M2.4 does not make spatially incomplete images ordinary complete ImageViews by
default.

---

# Part IX — Retry

## 59. Retry is attempt policy

Retry does not change semantic production identity.

A retry is a new attempt for the same key unless source revision/freshness
resolution changes.

---

## 60. Retryable failures

Potentially retryable:

- timeout;
- transient network error;
- temporary service error;
- selected rate-limit response.

Usually not retryable without another state change:

- unsupported codec;
- invalid geometry;
- corrupt deterministic source;
- explicit authorization failure.

Failure categories from M2.1/M2.2 must remain distinguishable.

---

## 61. Backoff

Retries should generally use bounded retry count and backoff/jitter policy for
remote resources.

M2.4 does not freeze exact constants.

Interactive visible demand may have a different retry budget from prefetch.

---

## 62. Cancellation during backoff

A cancelled request should not wait out retry backoff merely to discover it is
obsolete.

Backoff waits must be cancellable.

---

## 63. Revision mismatch retry

If a multi-range read detects revision change:

    old production snapshot attempt fails

The scheduler may refresh Source/Resource current revision and create a new
production key.

Do not retry under the old revision key while silently reading the new
representation.

---

# Part X — Source/Decoder Capability Interaction

## 64. Source capability affects scheduling

M2.1/M2.2 may expose hints such as:

    random access
    sequential access
    concurrent-read safe
    range-efficient
    full-decode only
    cancellation support

M2.4 consumes these hints.

It does not redefine them.

---

## 65. Non-thread-safe decoder

If one decoder/session is not concurrently safe:

- serialize access to that session;
- or create independent sessions if allowed.

Do not add locks to image semantic types.

---

## 66. Full-decode source

If the codec must decode a complete image:

- one small logical request can imply large work;
- prefetch should be conservative;
- coalescing becomes especially valuable;
- completed full decode may seed decoded cache for many requests.

This is performance capability, not semantic failure.

---

# Part XI — Scheduler Non-Goals

## 67. No scheduler class hierarchy yet

M2.4 must not invent production types such as:

    Scheduler
    TaskGraph
    Future
    Promise
    WorkerPool

until the architecture is accepted and a concrete implementation slice needs
them.

---

## 68. No general workflow DAG

M2.4 handles materialization/request lifecycle.

It is not a general-purpose computation graph framework.

Dependencies needed by image operations may later form graph-like execution,
but that broader abstraction requires separate evidence.

---

## 69. No event-loop dependency

The architecture should work with:

- synchronous tests;
- worker threads;
- GUI event loop;
- future coroutine runtime;
- application-owned executor.

Core semantic documents should not assume one framework.

---

# Part XII — Pressure Cases

## 70. P1 — Pan away during remote tile fetch

Visible demand starts remote production K.

User pans away.

No other subscriber remains.

Expected:

- subscriber detaches/cancels;
- production requests cooperative stop;
- if transport aborts, resources release;
- no partial cache entry;
- if completion wins race, complete result may be cache-admitted by policy.

Result:

**PASS.**

---

## 71. P2 — Two viewports want same block

Two independent consumers request K.

One cancels.

Expected:

- shared production continues for remaining subscriber;
- cancelled subscriber gets no later invalidation of another consumer.

Result:

**PASS only with subscriber/production separation.**

---

## 72. P3 — Prefetch promoted to visible

Low-priority prefetch K is already running.

Viewport now needs K.

Expected:

- new visible subscriber attaches;
- existing production effective priority rises;
- no duplicate production.

Result:

**PASS.**

---

## 73. P4 — Visible request becomes prefetch-only

Visible subscriber disappears but a prefetch subscriber remains.

Expected:

- production may continue at lower effective priority;
- scheduler may demote or cancel according to pressure.

Result:

**PASS.**

---

## 74. P5 — Ten identical misses

Ten requests simultaneously miss same decoded block.

Expected:

- one in-flight production;
- ten subscribers;
- one cache publication;
- ten retained deliveries as applicable.

Result:

**PASS.**

---

## 75. P6 — Overlapping non-identical regions

Viewport requests overlap but canonical cache blocks differ.

Expected:

- coalescing occurs at shared canonical block keys;
- no arbitrary geometry union engine required.

Result:

**PASS.**

---

## 76. P7 — Cancellation while allocation waits

Production is queued for memory reservation.

Subscriber cancels before admission.

Expected:

- no allocation;
- reservation/request removed;
- production stops if no other subscribers remain.

Result:

**PASS.**

---

## 77. P8 — Cancellation after RasterLease publication

Result has already been published.

Expected:

- cancellation only affects subscriber retention/future work;
- existing returned owner/view remains valid.

Result:

**PASS.**

---

## 78. P9 — Non-cancellable codec call

Subscriber cancels while codec is inside a blocking non-cancellable decode.

Expected:

- cancellation state records withdrawal;
- decode may finish;
- result is discarded or cached according to policy;
- no subscriber callback is delivered after cancellation wins;
- worker/thread is not forcibly terminated.

Result:

**PASS with best-effort cancellation semantics.**

---

## 79. P10 — Pinned memory exceeds target

Several active map layers retain decoded coverage.

Expected:

- cache drops evictable entries;
- pinned bytes remain counted;
- prefetch suppressed;
- new background work delayed;
- visible work may receive remaining admission priority.

Result:

**PASS with M2.3 budget integration.**

---

## 80. P11 — Progressive overview then native detail

Viewport first receives low-resolution overview.

Later native-resolution result completes.

Expected:

- both stages are complete immutable objects;
- native stage replaces overview for presentation;
- overview may remain independently cached;
- old stage is not mutated.

Result:

**PASS.**

---

## 81. P12 — Older progressive stage completes late

Stage 2 already delivered.

Stage 1 finishes afterward.

Expected:

- monotonic stage ordering rejects visual regression;
- stage 1 may still enter its own cache if useful.

Result:

**PASS.**

---

## 82. P13 — Old viewport generation finishes late

Generation 100 task completes after generation 101 is current.

Expected:

- result may be cached;
- generation-100 subscriber delivery is suppressed if cancelled;
- generation 101 is not overwritten by old demand context.

Result:

**PASS.**

---

## 83. P14 — Revision changes during retry

Attempt for revision A detects mismatch.

Current Source resolves revision B.

Expected:

- attempt A fails;
- retry planning creates key B;
- no bytes from B are published under A.

Result:

**PASS.**

---

## 84. P15 — Shared request with different priority

One background analysis subscriber and one interactive subscriber request same
pixel result K.

Expected:

- one production K;
- effective priority reflects interactive subscriber;
- delivered pixels identical.

Result:

**PASS.**

---

# Part XIII — Candidate Lifecycle

## 85. End-to-end request flow

M2.6 clarifies that an abstract product request may need representation/revision
resolution before its final semantic production key is known.

Conceptually:

    downstream demand / target intent
        |
        v
    resolve product/source snapshot
        |
        v
    build ResolvedMaterializationPlan
        |
        v
    derive semantic production/cache key
        |
        v
    completed cache lookup
        |
        +-- hit
        |    -> retain result
        |    -> deliver subscriber
        |
        `-- miss
             |
             v
        in-flight table lookup
             |
             +-- exists
             |    -> attach subscriber
             |    -> update effective priority
             |
             `-- absent
                  -> create shared production
                  -> queue
                  -> admission/reservation
                  -> source/materialization work
                  -> complete/fail/stop
                  -> atomic cache publication if complete
                  -> notify still-interested subscribers

---

## 85a. Finite child-production dependencies

M2.5/M2.6 confirm that one transformed production may require several native
child productions.

Conceptually:

    transformed production K
        |
        +-- requires decoded production A
        +-- requires decoded production B
        `-- requires decoded production C

M2.4 therefore needs internal finite dependency sets with propagation of:

- effective priority;
- cancellation/interest;
- completion/failure.

This is sufficient for current materialization needs.

It does **not** justify a public general-purpose workflow DAG or scheduler
framework.

---

## 86. Production ownership

The in-flight table retains the production control object.

Underlying work owns intermediate resources.

Completed publication transfers/retains only complete immutable result
ownership into:

- cache;
- interested subscribers/materialization owners.

The production control object can then retire.

---

## 87. Subscriber ownership

A subscriber waiting for a result does not retain the unfinished raster.

After delivery, the resulting materialization owner holds normal independent
retained ownership.

This avoids cancellation state leaking into raster lifetime.

---

# Part XIV — Candidate Invariants

## 88. M2.4 invariants

1. Demand/subscriber identity is distinct from production identity.

2. Several subscribers may share one production.

3. One subscriber cancelling does not automatically cancel shared work.

4. Shared production may stop when no useful subscribers remain, subject to
   policy.

5. Cancellation is cooperative and best-effort.

6. No forcible worker-thread termination is required.

7. Cancel-before-publication may prevent result delivery/publication.

8. Cancel-after-publication cannot invalidate an immutable retained result.

9. Cancel-vs-complete races have one terminal outcome per subscriber.

10. A subscriber is never completed twice.

11. Partial intermediate buffers are never published as complete cache values.

12. Priority is execution policy, not cache identity.

13. A higher-priority subscriber can promote existing shared production.

14. Demand generation/epoch is not source revision.

15. Viewport obsolescence does not invalidate otherwise reusable cached pixels.

16. Prefetch uses ordinary semantic production/cache keys.

17. Prefetch is lower priority and first to yield under resource pressure.

18. Prefetch does not recursively expand without explicit bounds.

19. Completed caches and in-flight production tables remain separate.

20. Exact-key concurrent misses should coalesce.

21. Arbitrary overlapping regions need not be merged if canonical cache blocks
    already provide coalescing granularity.

22. Scheduler admission observes global residency/in-flight budgets.

23. Pinned consumer-owned RasterLease memory is not reclaimable by cache
    eviction.

24. Queue growth must be bounded/revocable.

25. Progressive stages are complete immutable retained results.

26. Progressive stage identity declares actual grid/quality/revision semantics.

27. Different semantic stages have different cache keys.

28. Refinement delivery is monotonic; late lower stages must not regress output.

29. Retry attempts are operational; semantic production key is unchanged unless
    source revision/target semantics change.

30. Retry backoff is cancellable.

31. Source/decoder concurrency capability is respected by scheduling.

32. Scheduler choice does not alter pixel correctness.

33. Core imagery types do not depend on one async runtime.

34. M2.4 does not create a general-purpose workflow scheduler.

---

# Part XV — Rejected Alternatives

## 89. One request object owns one production

Reject.

It prevents duplicate-work sharing and makes cancellation of one consumer
incorrectly cancel others.

---

## 90. Cancellation flag stored in cache entry

Reject.

Cancellation is demand lifecycle, not cached-pixel state.

---

## 91. Priority included in cache key

Reject.

Priority does not change pixels and would destroy coalescing.

---

## 92. Separate prefetch cache

Reject.

Later visible demand should reuse the exact same production/cache result.

---

## 93. Hard-kill worker thread on cancellation

Reject.

Unsafe for foreign libraries, ownership invariants and RAII.

---

## 94. Publish partially initialized RasterLease

Reject.

Published raster backing is immutable/stable with respect to materialization
completion.

---

## 95. Mutate existing RasterLease for progressive refinement

Reject as default.

Publish new complete stages instead.

---

## 96. Flush cache on every viewport generation

Reject.

Demand obsolescence is not data invalidation.

---

## 97. Unlimited queue of obsolete viewport requests

Reject.

It turns interaction churn into latency/memory growth.

---

## 98. Exact arbitrary-region request coalescing first

Reject.

Canonical decoded-cache block keys already give a simpler deterministic
coalescing boundary.

---

## 99. One global worker pool assumed by public API

Reject.

Network, decode, transform and UI integration may require different execution
resources.

---

# Part XVI — Open Questions

## 100. Q1 — initial priority classes

How many are actually needed for the first OSM-editor consumer?

Likely start small.

Do not expose numerical priority until measured use cases require it.

---

## 101. Q2 — orphan completion policy

When the last subscriber cancels after expensive work is nearly complete,
should production:

- stop;
- finish and cache;
- finish only under budget;
- use source-specific cost heuristic?

Benchmark/application policy required.

---

## 102. Q3 — cancellation primitive

Should imagery-d eventually define a tiny cancellation-observer interface, use
application/executor integration, or keep cancellation entirely in an internal
scheduler layer?

Needs first implementation evidence.

---

## 103. Q4 — deadlines

Interactive UI may benefit from deadline/time-budget hints.

Do deadlines belong in demand policy or only scheduler internals?

No decision yet.

---

## 104. Q5 — progressive-stage taxonomy

Which concrete first stages matter?

Candidates:

- overview/native resolution;
- stale/fresh;
- cheap/high-quality resample.

Do not generalize until first consumer is selected.

---

## 105. Q6 — prefetch prediction

Viewport velocity and zoom trajectory are application-level signals.

How much prediction should imagery-d own versus caller-provided hints?

Likely caller supplies demand/prefetch hints; imagery-d owns execution.

Needs editor integration evidence.

---

## 106. Q7 — multi-resource shared production

A materialization may depend on several tile/source productions.

How much priority/cancellation propagation should be automatic?

Avoid general DAG design until M2.5/M3 require it.

---

## 107. Q8 — cache publication after all subscribers cancel

A completed value can still be useful.

Need policy based on:

- completion state;
- cost;
- memory budget;
- prefetch usefulness.

No semantic requirement forces one answer.

---

## 108. Q9 — admission failure surface

When memory pressure prevents admission, should visible demand:

- wait;
- fail with resource-pressure category;
- trigger application fallback/refinement stage?

Needs consumer behavior research.

---

## 109. Q10 — fairness

What starvation bounds are needed for long-running background analysis while the
user continuously pans?

Benchmark/application requirement.

---

# Part XVII — M2.3 Feedback

## 110. In-flight table is confirmed as separate

M2.4 confirms the M2.3 decision:

    completed cache
        !=
    in-flight production table

They can share semantic key definitions but have different lifecycle and
ownership.

---

## 111. Priority must not enter cache key

A prefetch and visible request for the same pixel result must converge.

Therefore priority is subscriber/production execution state only.

---

## 112. Budget controller interaction

M2.4 confirms that the M2.3 budget controller must support reservations or
equivalent admission accounting for in-flight work.

Otherwise concurrency can exceed the memory target before any cache entry
exists.

---

## 113. Shared coverage lifetime remains sound

M2.4 introduces no contradiction to the M2.3 shared retained coverage model.

Completed production can publish one shared retained coverage object to:

- decoded/transformed cache;
- still-interested subscribers.

Eviction and later cancellation do not affect other retained owners.

---

# Part XVIII — M2.4 Provisional Decision

## 114. Preferred architecture

The strongest current model is:

    Demand/Subscriber
        - one consumer's current interest
        - priority/generation/cancellation
              |
              v
    Semantic Production Key
              |
       +------+------+
       |             |
       v             v
    Cache Hit     In-flight lookup
       |             |
       |          existing production
       |             |
       |             +--> attach subscriber
       |             +--> priority donation
       |
       `--> deliver
                     or
                  create production
                     |
                     v
                  queue
                     |
                     v
              admission/reservation
                     |
                     v
          M2.2 materialization attempt
                     |
          +----------+----------+
          |                     |
          v                     v
        failure             complete immutable result
                                |
                                v
                        atomic publication
                          /             \
                         v               v
                     cache retain   subscriber retains

with:

    cancellation
        detaches one subscriber

and only when appropriate:

    no remaining useful subscribers
        -> cooperative stop shared production

---

## 115. Public-surface implication

M2.4 still does not justify a public scheduler API.

What is becoming stable is the architecture boundary:

- request interest is ephemeral;
- production can be shared;
- completed results are independently retained;
- cancellation is cooperative;
- priority/prefetch are execution hints;
- progressive results are immutable stages.

These semantics can later be implemented behind a small public materialization
surface.

---

## 116. D-language implication

A future D implementation should preserve:

- RAII around retained production/result state;
- explicit ownership transfer;
- thread-safe cancellation/production transitions where required;
- no GC-dependent hidden lifetime assumptions in hot/ownership-critical paths;
- typed production/cache keys;
- DMD correctness;
- LDC performance validation.

M2.4 does not yet choose:

- fibers;
- std.parallelism;
- custom threads;
- message passing;
- futures;
- coroutines;
- an external async runtime.

---

## 117. M2.4 status

M2.4 architecture has now passed M2.6 validation.

M2.5 confirmed that heterogeneous product materialization introduces additional
semantic key dimensions without changing the Subscriber/SharedProduction
separation.

M2.6 adds three refinements:

- the final production key may be known only after product/source snapshot
  resolution and construction of a ResolvedMaterializationPlan;
- one production may have a finite set of required child productions, without
  implying a general public DAG;
- cancellation responsiveness is a measurable performance characteristic, not
  merely a yes/no capability.

No production scheduler code is justified yet.

M2.4 should remain open until the focused M2 contract experiment mechanically
tests:

- exact-key single-flight;
- one-subscriber cancellation;
- all-subscriber cancellation;
- completion-vs-cancel race;
- priority donation;
- finite child-production propagation;
- cache publication;
- RasterLease lifetime after cache eviction.

---

## 118. M2.6 validation update

The validated request lifecycle begins with semantic intent rather than an
already-known key:

    Demand
        ->
    resolve snapshot / semantic plan
        ->
    ProductionKey
        ->
    cache / in-flight lifecycle

Priority, generation and subscriber identity remain outside the semantic key.

## 119. References

Primary references used for M2.4:

- RFC 9111 — HTTP Caching / collapsed forwarding:
  https://www.rfc-editor.org/rfc/rfc9111.html

- OpenImageIO ImageCache:
  https://openimageio.readthedocs.io/

- libvips technical background / demand-driven evaluation:
  https://www.libvips.org/API/8.17/how-it-works.html

- MapLibre Native resource request/provider interfaces:
  https://maplibre.org/maplibre-native-ffi/

- MapLibre GL JS source lifecycle:
  https://maplibre.org/maplibre-gl-js/docs/API/interfaces/Source/

- C++ cooperative cancellation (`std::stop_token`):
  https://en.cppreference.com/w/cpp/thread/stop_token

- GIO `GCancellable`:
  https://docs.gtk.org/gio/class.Cancellable.html

Project evidence used:

- `docs/research/m2-source-resource-access-model.md`
- `docs/research/m2-region-materialization-boundary.md`
- `docs/research/m2-cache-architecture.md`
- M1 ADR 0002
- `raster-d` R0.3 region/streaming evidence
