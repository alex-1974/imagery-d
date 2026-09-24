module app;

import core.stdc.stdlib :
    malloc;

import m2_source_cache_pipeline.contract :
    CoverageCache,
    ExecutionStrategy,
    GridIdentity,
    MaterializationOwner,
    ProductionState,
    RadiometricPolicy,
    RequestEnvelope,
    ResamplingPolicy,
    ResolvedMaterializationPlan,
    RevisionStrength,
    SampleKind,
    SamplingGeometry,
    SharedProduction,
    SharedResidentCoverage,
    SourceSnapshot,
    SubscriberState,
    ValidityPolicy,
    makeProductionKey,
    tryRelativeRegion;

import raster :
    OwnedByteResource,
    PlaneByteLayout,
    RasterLease,
    Region2D,
    tryAdoptMallocResource,
    tryImportOwnedRaster;


/++
    Canonical semantic value for the tiny raster fixture.
+/
private
ubyte semanticValue(
    size_t x,
    size_t y
)
@safe
pure
nothrow
@nogc
{
    return cast(ubyte)(
        y * 10
        + x
        + 1
    );
}


/++
    Materializes one tiny retained raster.

    Both execution strategies deliberately produce the same semantic result
    through different loop shapes.
+/
private
RasterLease!ubyte materializeFixture(
    size_t width,
    size_t height,
    ExecutionStrategy strategy,
    ref size_t materializationCount
)
{
    const byteLength =
        width * height;

    auto memory =
        cast(ubyte*) malloc(
            byteLength
        );

    assert(memory !is null);


    final switch (strategy)
    {
        case ExecutionStrategy.unfused:
        {
            foreach (y; 0 .. height)
            {
                foreach (x; 0 .. width)
                {
                    memory[
                        y * width + x
                    ] = semanticValue(
                        x,
                        y
                    );
                }
            }

            break;
        }


        case ExecutionStrategy.fused:
        {
            foreach (index; 0 .. byteLength)
            {
                const y =
                    index / width;

                const x =
                    index - y * width;

                memory[index] =
                    semanticValue(
                        x,
                        y
                    );
            }

            break;
        }
    }


    OwnedByteResource resource;

    assert(
        tryAdoptMallocResource(
            memory,
            byteLength,
            resource
        )
    );


    RasterLease!ubyte lease;


    PlaneByteLayout[1] planes =
    [
        PlaneByteLayout(
            0,
            width,
            1
        )
    ];


    const result =
        tryImportOwnedRaster!ubyte(
            resource,
            planes[],
            Region2D(
                0,
                0,
                width,
                height
            ),
            lease
        );


    assert(result.ok);

    ++materializationCount;

    return lease;
}


/++
    Canonical resolved plan used by the identity probes.
+/
private
ResolvedMaterializationPlan canonicalPlan()
@safe
pure
nothrow
@nogc
{
    return ResolvedMaterializationPlan(
        SourceSnapshot(
            11,
            101,
            RevisionStrength.strong,
            9001
        ),
        1001,
        1002,
        2,
        GridIdentity(
            100,
            200,
            4,
            3,
            10,
            10,
            SamplingGeometry.area
        ),
        SampleKind.u8,
        RadiometricPolicy.rawStored,
        ResamplingPolicy.nearest,
        ValidityPolicy.explicitMask
    );
}


/++
    ProductionKey contains semantic identity only.
+/
private
void testKeyIdentity()
{
    auto plan =
        canonicalPlan();


    const requestA =
        RequestEnvelope(
            plan,
            ExecutionStrategy.unfused,
            100,
            7
        );

    const requestB =
        RequestEnvelope(
            plan,
            ExecutionStrategy.fused,
            -20,
            999
        );


    const keyA =
        makeProductionKey(
            requestA.semantic
        );

    const keyB =
        makeProductionKey(
            requestB.semantic
        );


    /*
     * Execution strategy, priority and generation are not identity.
     */
    assert(keyA == keyB);


    /*
     * Revision is identity.
     */
    auto changed =
        plan;

    ++changed.snapshot.revisionValue;

    assert(
        keyA
        != makeProductionKey(
            changed
        )
    );


    /*
     * Grid identity is identity.
     */
    changed =
        plan;

    ++changed.grid.originX;

    assert(
        keyA
        != makeProductionKey(
            changed
        )
    );


    /*
     * Materialized sample representation is identity.
     */
    changed =
        plan;

    changed.sampleKind =
        SampleKind.f32;

    assert(
        keyA
        != makeProductionKey(
            changed
        )
    );


    /*
     * Radiometric semantics are identity.
     */
    changed =
        plan;

    changed.radiometric =
        RadiometricPolicy.physical;

    assert(
        keyA
        != makeProductionKey(
            changed
        )
    );


    /*
     * Resampling semantics are identity.
     */
    changed =
        plan;

    changed.resampling =
        ResamplingPolicy.bilinear;

    assert(
        keyA
        != makeProductionKey(
            changed
        )
    );


    /*
     * Validity semantics are identity.
     */
    changed =
        plan;

    changed.validity =
        ValidityPolicy.none;

    assert(
        keyA
        != makeProductionKey(
            changed
        )
    );


    /*
     * Ordered product-component selection is identity.
     */
    changed =
        plan;

    changed.componentA =
        plan.componentB;

    changed.componentB =
        plan.componentA;

    assert(
        keyA
        != makeProductionKey(
            changed
        )
    );
}


/++
    Equal semantic demand coalesces into one shared production.
+/
private
void testSingleFlightAndCancellation()
{
    const plan =
        canonicalPlan();

    const key =
        makeProductionKey(
            plan
        );


    /*
     * One cancellation must not kill a production that still has an
     * interested subscriber.
     */
    SharedProduction production;


    const first =
        production.subscribe(
            key
        );

    const second =
        production.subscribe(
            key
        );


    assert(first != size_t.max);
    assert(second != size_t.max);
    assert(first != second);

    assert(
        production.productionStarts
        == 1
    );

    assert(
        production.state
        == ProductionState.running
    );


    assert(
        production.cancel(
            first
        )
    );

    assert(
        production.subscriberState(
            first
        ) == SubscriberState.cancelled
    );

    assert(
        production.subscriberState(
            second
        ) == SubscriberState.waiting
    );

    assert(
        production.state
        == ProductionState.running
    );


    assert(
        production.publish()
    );

    assert(
        production.state
        == ProductionState.published
    );

    assert(
        production.subscriberState(
            first
        ) == SubscriberState.cancelled
    );

    assert(
        production.subscriberState(
            second
        ) == SubscriberState.delivered
    );

    assert(
        production.subscriberTerminal(
            first
        )
    );

    assert(
        production.subscriberTerminal(
            second
        )
    );


    /*
     * Re-cancelling or re-publishing cannot produce a second terminal
     * outcome.
     */
    assert(
        !production.cancel(
            first
        )
    );

    assert(
        !production.cancel(
            second
        )
    );

    assert(
        !production.publish()
    );


    /*
     * If every subscriber cancels before publication, production may stop.
     */
    SharedProduction allCancelled;


    const a =
        allCancelled.subscribe(
            key
        );

    const b =
        allCancelled.subscribe(
            key
        );


    assert(
        allCancelled.cancel(
            a
        )
    );

    assert(
        allCancelled.state
        == ProductionState.running
    );

    assert(
        allCancelled.cancel(
            b
        )
    );

    assert(
        allCancelled.state
        == ProductionState.stopped
    );

    assert(
        !allCancelled.publish()
    );


    /*
     * Completion wins when publication linearizes first.
     */
    SharedProduction publishFirst;


    const publishedSubscriber =
        publishFirst.subscribe(
            key
        );


    assert(
        publishFirst.publish()
    );

    assert(
        !publishFirst.cancel(
            publishedSubscriber
        )
    );

    assert(
        publishFirst.subscriberState(
            publishedSubscriber
        ) == SubscriberState.delivered
    );


    /*
     * Cancellation wins when cancellation linearizes first.
     */
    SharedProduction cancelFirst;


    const cancelledSubscriber =
        cancelFirst.subscribe(
            key
        );


    assert(
        cancelFirst.cancel(
            cancelledSubscriber
        )
    );

    assert(
        cancelFirst.state
        == ProductionState.stopped
    );

    assert(
        !cancelFirst.publish()
    );

    assert(
        cancelFirst.subscriberState(
            cancelledSubscriber
        ) == SubscriberState.cancelled
    );
}


/++
    Different execution plans may satisfy one semantic production key.
+/
private
void testExecutionEquivalence()
{
    const plan =
        canonicalPlan();


    const requestA =
        RequestEnvelope(
            plan,
            ExecutionStrategy.unfused,
            100,
            1
        );

    const requestB =
        RequestEnvelope(
            plan,
            ExecutionStrategy.fused,
            1,
            999
        );


    assert(
        makeProductionKey(
            requestA.semantic
        )
        ==
        makeProductionKey(
            requestB.semantic
        )
    );


    size_t materializationCount;


    auto unfused =
        materializeFixture(
            plan.grid.width,
            plan.grid.height,
            requestA.execution,
            materializationCount
        );

    auto fused =
        materializeFixture(
            plan.grid.width,
            plan.grid.height,
            requestB.execution,
            materializationCount
        );


    assert(
        materializationCount
        == 2
    );


    auto unfusedView =
        unfused.view();

    auto fusedView =
        fused.view();


    assert(
        unfusedView.width
        == fusedView.width
    );

    assert(
        unfusedView.height
        == fusedView.height
    );


    foreach (y; 0 .. unfusedView.height)
    {
        foreach (x; 0 .. unfusedView.width)
        {
            ubyte a;
            ubyte b;


            assert(
                unfusedView.trySample(
                    0,
                    x,
                    y,
                    a
                )
            );

            assert(
                fusedView.trySample(
                    0,
                    x,
                    y,
                    b
                )
            );


            assert(a == b);

            assert(
                a
                == semanticValue(
                    x,
                    y
                )
            );
        }
    }
}


/++
    Cache membership and delivered lifetime are independent.

    A covering decoded result can also serve an exact logical subregion using
    raster-d ROI rather than rematerializing pixels.
+/
private
void testCacheLifetimeAndSupersetRoi()
{
    const plan =
        canonicalPlan();

    const key =
        makeProductionKey(
            plan
        );


    size_t materializationCount;


    auto produced =
        SharedResidentCoverage!ubyte(
            7001,
            Region2D(
                10,
                20,
                plan.grid.width,
                plan.grid.height
            ),
            materializeFixture(
                plan.grid.width,
                plan.grid.height,
                ExecutionStrategy.unfused,
                materializationCount
            )
        );


    assert(
        materializationCount
        == 1
    );


    CoverageCache!ubyte cache;

    cache.insert(
        key,
        produced
    );


    MaterializationOwner!ubyte owner;

    owner.coverage =
        produced;


    assert(cache.occupied);

    assert(
        cache.coverage.coverageId
        == owner.coverage.coverageId
    );


    /*
     * Drop the producer's retain. Cache and delivered owner now retain the
     * raster independently.
     */
    produced =
        SharedResidentCoverage!ubyte.init;


    /*
     * Eviction removes cache membership/retain only.
     */
    cache.evict();

    assert(!cache.occupied);


    /*
     * The delivered materialization must remain usable after eviction.
     */
    auto full =
        owner.coverage.lease.view();


    ubyte sample;

    assert(
        full.trySample(
            0,
            3,
            2,
            sample
        )
    );

    assert(
        sample
        == semanticValue(
            3,
            2
        )
    );


    /*
     * Logical coverage:
     *
     *     x = 10..13
     *     y = 20..22
     *
     * Requested logical region:
     *
     *     x = 11..12
     *     y = 21
     *
     * maps to resident relative ROI:
     *
     *     x = 1
     *     y = 1
     *     w = 2
     *     h = 1
     */
    Region2D relative;


    assert(
        tryRelativeRegion(
            owner.coverage.logicalCoverage,
            Region2D(
                11,
                21,
                2,
                1
            ),
            relative
        )
    );


    assert(
        relative
        == Region2D(
            1,
            1,
            2,
            1
        )
    );


    bool roiOk;


    auto exact =
        full.tryRoi(
            relative,
            roiOk
        );


    assert(roiOk);

    assert(exact.width == 2);
    assert(exact.height == 1);


    assert(
        exact.trySample(
            0,
            0,
            0,
            sample
        )
    );

    assert(
        sample
        == semanticValue(
            1,
            1
        )
    );


    assert(
        exact.trySample(
            0,
            1,
            0,
            sample
        )
    );

    assert(
        sample
        == semanticValue(
            2,
            1
        )
    );


    /*
     * No second source/materialization operation occurred to serve the exact
     * ROI.
     */
    assert(
        materializationCount
        == 1
    );


    /*
     * The delivered owner now drops the final experiment-level RasterLease
     * retain.

     * Actual backing destruction semantics remain raster-d's responsibility
     * and are already covered by raster-d's own RasterLease tests.
     */
    owner.clear();
}


void main()
{
    testKeyIdentity();

    testSingleFlightAndCancellation();

    testExecutionEquivalence();

    testCacheLifetimeAndSupersetRoi();
}
