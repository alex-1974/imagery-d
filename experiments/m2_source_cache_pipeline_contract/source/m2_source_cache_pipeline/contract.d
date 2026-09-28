/++
    Minimal M2 source/cache/pipeline contract model.

    Research experiment only.

    This module deliberately models only the semantic and lifecycle properties
    required by the M2 architecture gate. It is not a proposed production API.
+/
module m2_source_cache_pipeline.contract;

import raster :
    RasterLease,
    Region2D;


/++
    Strength of the revision identity represented by a source snapshot.

    The experiment needs only enough structure to prove that revision identity
    participates in semantic production identity.
+/
enum RevisionStrength : ubyte
{
    unknown,
    weak,
    strong
}


/++
    Sampling interpretation used as part of target grid identity.
+/
enum SamplingGeometry : ubyte
{
    point,
    area
}


/++
    Materialized sample representation.

    Deliberately bounded to the two representations required by this spike.
+/
enum SampleKind : ubyte
{
    u8,
    f32
}


/++
    Radiometric interpretation requested by the semantic plan.
+/
enum RadiometricPolicy : ubyte
{
    rawStored,
    physical
}


/++
    Explicit resampling semantics.

    `none` means that no resampling is permitted/required for the result.
+/
enum ResamplingPolicy : ubyte
{
    none,
    nearest,
    bilinear
}


/++
    Explicit validity semantics.
+/
enum ValidityPolicy : ubyte
{
    none,
    explicitMask,
    nodataDerived
}


/++
    Two intentionally different execution strategies.

    Execution strategy must not enter ProductionKey when both strategies
    satisfy the exact same resolved semantic plan.
+/
enum ExecutionStrategy : ubyte
{
    unfused,
    fused
}


/++
    Stable source/resource/revision identity for one resolved input.

    Locators, URLs, file descriptors and open sessions are deliberately absent.
+/
struct SourceSnapshot
{
    ulong sourceId;
    ulong resourceId;

    RevisionStrength revisionStrength;
    ulong revisionValue;
}


/++
    Semantic target-grid identity.

    Integer fields keep this contract experiment free from unrelated
    floating-point identity questions.
+/
struct GridIdentity
{
    size_t originX;
    size_t originY;

    size_t width;
    size_t height;

    uint resolutionX;
    uint resolutionY;

    SamplingGeometry sampling;
}


/++
    Concrete semantic materialization plan.

    The pair of component IDs is a deliberately bounded fixture. It tests
    ordering as part of identity without pretending to define the final
    heterogeneous product representation.
+/
struct ResolvedMaterializationPlan
{
    SourceSnapshot snapshot;

    ulong componentA;
    ulong componentB;
    ubyte componentCount;

    GridIdentity grid;

    SampleKind sampleKind;
    RadiometricPolicy radiometric;
    ResamplingPolicy resampling;
    ValidityPolicy validity;
}


/++
    Production identity derived only from the resolved semantic plan.

    Priority, generation/epoch and execution strategy are intentionally absent.
+/
struct ProductionKey
{
    SourceSnapshot snapshot;

    ulong componentA;
    ulong componentB;
    ubyte componentCount;

    GridIdentity grid;

    SampleKind sampleKind;
    RadiometricPolicy radiometric;
    ResamplingPolicy resampling;
    ValidityPolicy validity;
}


/++
    Request-local execution metadata.

    These fields may alter scheduling or implementation choice but not result
    identity.
+/
struct RequestEnvelope
{
    ResolvedMaterializationPlan semantic;

    ExecutionStrategy execution;

    int priority;
    ulong generation;
}


/++
    Derives the semantic production key.

    This is intentionally a structural key rather than merely a hash so the
    experiment cannot hide identity mistakes behind hash collisions.
+/
ProductionKey makeProductionKey(
    const ref ResolvedMaterializationPlan plan
)
@safe
pure
nothrow
@nogc
{
    return ProductionKey(
        plan.snapshot,
        plan.componentA,
        plan.componentB,
        plan.componentCount,
        plan.grid,
        plan.sampleKind,
        plan.radiometric,
        plan.resampling,
        plan.validity
    );
}


/++
    Subscriber lifecycle for the deterministic single-flight experiment.
+/
enum SubscriberState : ubyte
{
    unused,
    waiting,
    delivered,
    cancelled
}


/++
    Shared production lifecycle.

    `.init == idle` is deliberate.
+/
enum ProductionState : ubyte
{
    idle,
    running,
    published,
    stopped
}


/++
    Small deterministic shared-production state machine.

    It models single-flight and cancellation semantics without introducing
    threads, locks, worker pools or a general scheduler.
+/
struct SharedProduction
{
    enum size_t maxSubscribers = 8;

    ProductionKey key;
    ProductionState state;

    SubscriberState[maxSubscribers] subscribers;

    size_t subscriberCount;
    size_t waitingSubscribers;

    size_t productionStarts;


    /++
        Subscribes one request to this production.

        The first subscriber starts exactly one production.

        Later equal-key subscribers join that production.

        A different key or a terminal production is rejected with size_t.max.
    +/
    size_t subscribe(
        ProductionKey requestedKey
    )
    @safe
    nothrow
    @nogc
    {
        if (state == ProductionState.idle)
        {
            key = requestedKey;
            state = ProductionState.running;

            ++productionStarts;
        }
        else
        {
            if (
                state != ProductionState.running
                || key != requestedKey
            )
            {
                return size_t.max;
            }
        }


        if (subscriberCount >= subscribers.length)
        {
            return size_t.max;
        }


        const id =
            subscriberCount;

        subscribers[id] =
            SubscriberState.waiting;

        ++subscriberCount;
        ++waitingSubscribers;

        return id;
    }


    /++
        Cancels one still-waiting subscriber.

        Cancelling one subscriber does not stop production while another
        subscriber remains interested.

        When the final interested subscriber cancels before publication, the
        production becomes stopped.
    +/
    bool cancel(
        size_t subscriberId
    )
    @safe
    nothrow
    @nogc
    {
        if (subscriberId >= subscriberCount)
        {
            return false;
        }

        if (
            subscribers[subscriberId]
            != SubscriberState.waiting
        )
        {
            return false;
        }


        subscribers[subscriberId] =
            SubscriberState.cancelled;

        assert(waitingSubscribers > 0);

        --waitingSubscribers;


        if (
            waitingSubscribers == 0
            && state == ProductionState.running
        )
        {
            state =
                ProductionState.stopped;
        }

        return true;
    }


    /++
        Publishes one immutable completed result.

        Every subscriber still waiting at the publication linearization point
        becomes delivered.

        Already-cancelled subscribers remain cancelled.
    +/
    bool publish()
    @safe
    nothrow
    @nogc
    {
        if (state != ProductionState.running)
        {
            return false;
        }


        foreach (index; 0 .. subscriberCount)
        {
            if (
                subscribers[index]
                == SubscriberState.waiting
            )
            {
                subscribers[index] =
                    SubscriberState.delivered;
            }
        }


        waitingSubscribers = 0;

        state =
            ProductionState.published;

        return true;
    }


    SubscriberState subscriberState(
        size_t subscriberId
    ) const
    @safe
    pure
    nothrow
    @nogc
    {
        if (subscriberId >= subscriberCount)
        {
            return SubscriberState.unused;
        }

        return subscribers[subscriberId];
    }


    bool subscriberTerminal(
        size_t subscriberId
    ) const
    @safe
    pure
    nothrow
    @nogc
    {
        const current =
            subscriberState(
                subscriberId
            );

        return current == SubscriberState.delivered
            || current == SubscriberState.cancelled;
    }
}


/++
    Resident decoded coverage retained by imagery-d.

    The RasterLease is the actual raster-d ownership capability.

    `logicalCoverage` remains above raster-d because RasterView coordinates are
    resident descriptor-space coordinates rather than global/source logical
    coordinates.
+/
struct SharedResidentCoverage(T)
{
    ulong coverageId;

    Region2D logicalCoverage;

    RasterLease!T lease;
}


/++
    Minimal cache retain.

    Cache membership is deliberately represented separately from the retained
    RasterLease carried by the coverage.
+/
struct CoverageCache(T)
{
    bool occupied;

    ProductionKey key;

    SharedResidentCoverage!T coverage;


    void insert(
        ProductionKey newKey,
        SharedResidentCoverage!T newCoverage
    )
    {
        key =
            newKey;

        coverage =
            newCoverage;

        occupied =
            true;
    }


    void evict()
    {
        coverage =
            SharedResidentCoverage!T.init;

        key =
            ProductionKey.init;

        occupied =
            false;
    }
}


/++
    Minimal delivered-result owner.

    This is intentionally not the final imagery-d owner type.

    Its purpose is to prove that a delivered retain may outlive cache
    membership.
+/
struct MaterializationOwner(T)
{
    SharedResidentCoverage!T coverage;


    void clear()
    {
        coverage =
            SharedResidentCoverage!T.init;
    }
}


/++
    Converts a requested logical source region into a relative resident ROI.

    No clipping, resampling or implicit coordinate correction occurs.
+/
bool tryRelativeRegion(
    Region2D logicalCoverage,
    Region2D requestedLogical,
    out Region2D relative
)
@safe
pure
nothrow
@nogc
{
    relative =
        Region2D.init;


    if (
        !logicalCoverage.hasRepresentableExtent()
        || !requestedLogical.hasRepresentableExtent()
    )
    {
        return false;
    }


    if (
        requestedLogical.x < logicalCoverage.x
        || requestedLogical.y < logicalCoverage.y
    )
    {
        return false;
    }


    const relativeX =
        requestedLogical.x
        - logicalCoverage.x;

    const relativeY =
        requestedLogical.y
        - logicalCoverage.y;


    const candidate =
        Region2D(
            relativeX,
            relativeY,
            requestedLogical.width,
            requestedLogical.height
        );


    if (
        !logicalCoverage.containsRelative(
            candidate
        )
    )
    {
        return false;
    }


    relative =
        candidate;

    return true;
}
