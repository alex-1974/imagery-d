/++
Share overlapping feature requests while controlling their priority and
cancellation. Submit work through `FeatureRequests` and let the caller advance
it cooperatively. Subscribers receive one complete requested result, even when
evaluation uses smaller internal tiles.
+/
module imagery.analysis.feature_requests;

import imagery.analysis.feature_regions : Engine, Feature, MemoryMetrics, Sink, Source,
    TileIdentity, Value, Provenance, describeTileKernel, FeatureConfiguration;
import imagery.analysis.feature_parameters : isTileFeatureParameter;
import raster.region : Region2D;

@safe:

/++
 Prioritize cooperative tile work; `.init` selects background.
+/
enum RequestPriority {
    /++ Queue behind visible-priority requests. +/
    background,
    /++ Prefer this subscriber’s visible-region work. +/
    visible }
/++
 Receive a request Exception synchronously during pump. The callback may retain the exception; it must not reenter pump.
+/
alias RequestFailure = void delegate(Exception) @safe;

/// Submit and pump from one event loop. Multiple subscribers can be pending
/// for the same tile. Source reads and callbacks run synchronously on the pump.
final class FeatureRequests
{
    private struct Job
    {
        bool active;
        TileIdentity key;
        Source source;
        ulong order;
        FeatureConfiguration configuration;
    }

    private struct Subscriber
    {
        ulong token;
        size_t job;
        RequestPriority priority;
        Sink success;
        RequestFailure failure;
    }

    /++
     Maximum number of pending distinct tile jobs.
    +/
    enum maxJobs = 32;
    /++
     Maximum number of pending independently cancellable subscribers.
    +/
    enum maxSubscribers = 128;
    /++
     Largest submitted tile width/height in pixels.
    +/
    enum maxTileEdge = 256;
    /++
     Logical cache reservation limit in bytes.
    +/
    enum cacheBudgetBytes = 16 * 1024 * 1024;

    private Job[maxJobs] jobs;
    private Subscriber[maxSubscribers] subscribers;
    private Engine engine;
    private ulong sequence;
    private bool pumping;
    private size_t executedCount;

    /++
     Number of jobs executed by this queue, rather than the number of subscribers notified.

     Returns:
     Number of distinct jobs executed, independently of subscriber count.
    +/
    size_t executed() const { return executedCount; }
    /++
     Snapshot of the queue’s underlying engine storage/work counters.

     Returns:
     Snapshot of logical memory and work counters.
    +/
    MemoryMetrics metrics() const { return engine.metrics; }

/++
     Submit a single tile of up to 256×256 pixels. A zero token means
                    queue capacity was reached and the caller may retry.

          Params:
           source = Input data; its sample model, units and lifetime follow the operation contract above.
           region = Source-pixel rectangle to process.
           feature = Analytical operation to evaluate.
           priority = Visible or background request priority.
           success = Synchronous callback receiving completed borrowed tiles.
           failure = Synchronous callback receiving a request Exception.

          Returns:
          A nonzero cancellable subscriber token, or zero when queue capacity is exhausted.

     Throws:
     Exception for invalid source identity, region, callbacks, feature or parameters before queue mutation. A full queue is reported by token zero, not an exception.
    +/
    ulong submit(Source source, Region2D region, Feature feature,
        RequestPriority priority, Sink success, RequestFailure failure)
    {
        return submitConfigured(source,region,feature,FeatureConfiguration.init,priority,success,failure);
    }

/++
     Queue typed local/path/ridge/line/Gabor/shadow settings. Parameters are
                    copied at submit time and validated before queue mutation or reads.
                    Equal canonical identities coalesce, including explicit defaults;
                    different parameter identities do not share a job. Dedicated CLAHE is
                    excluded. One complete requested tile is published per subscriber even
                    when Engine subdivides it to preserve its scratch budget.

          Params:
           source = Input data; its sample model, units and lifetime follow the operation contract above.
           region = Source-pixel rectangle to process.
           feature = Analytical operation to evaluate.
           parameters = Explicit typed feature settings; see their type for supported units and ranges.
           priority = Visible or background request priority.
           success = Synchronous callback receiving completed borrowed tiles.
           failure = Synchronous callback receiving a request Exception.

          Returns:
          A nonzero cancellable subscriber token, or zero when queue capacity is exhausted.

     Throws:
     Exception for invalid source identity, region, callbacks, feature or parameters before queue mutation. A full queue is reported by token zero, not an exception.
    +/
    ulong submit(P)(Source source,Region2D region,Feature feature,P parameters,
        RequestPriority priority,Sink success,RequestFailure failure)
    if(isTileFeatureParameter!P)
    {
        const configuration=FeatureConfiguration.create(feature,parameters);
        return submitConfigured(source,region,feature,configuration,priority,success,failure);
    }

    private ulong submitConfigured(Source source,Region2D region,Feature feature,
        FeatureConfiguration configuration,RequestPriority priority,Sink success,RequestFailure failure)
    {
        const descriptor = describeTileKernel(feature);
        if (!source.identity.length || !source.revision.length || source.read is null ||
            success is null || failure is null || region.empty ||
            region.width > maxTileEdge || region.height > maxTileEdge ||
            region.x > source.width || region.width > source.width - region.x ||
            region.y > source.height || region.height > source.height - region.y ||
            (!source.rgb && descriptor.rgbOnly) ||
            (priority != RequestPriority.visible && priority != RequestPriority.background) ||
            sequence == ulong.max)
            throw new Exception("Invalid feature tile request");

        size_t slot = subscribers.length;
        foreach (i, ref subscriber; subscribers)
            if (subscriber.token == 0)
            {
                slot = i;
                break;
            }
        if (slot == subscribers.length)
            return 0;

        const key = configuration.identity(source,region,feature);
        size_t job = jobs.length, free = jobs.length;
        foreach (i, ref candidate; jobs)
        {
            if (candidate.active && candidate.key == key)
            {
                job = i;
                break;
            }
            if (!candidate.active && (!pumping || i != running) && free == jobs.length)
                free = i;
        }
        if (job == jobs.length)
        {
            if (free == jobs.length)
                return 0;
            job = free;
            jobs[job] = Job(true, key, source, sequence + 1,configuration);
        }
        const token = ++sequence;
        subscribers[slot] = Subscriber(token, job, priority, success, failure);
        return token;
    }

/++
     Drop one subscriber. Drop queued work if it has no remaining subscribers.

     Params:
      token = Subscriber token returned by submit; zero has no active subscription.

     Returns:
     True when an active subscriber was removed; false for zero or an unknown token.
    +/
    bool cancel(ulong token)
    {
        if (token == 0)
            return false;
        foreach (ref subscriber; subscribers)
            if (subscriber.token == token)
            {
                const job = subscriber.job;
                subscriber = Subscriber.init;
                foreach (ref other; subscribers)
                    if (other.token && other.job == job)
                        return true;
                if (!pumping || job != running)
                    jobs[job] = Job.init;
                return true;
            }
        return false;
    }

    private size_t running;

/++
     Compute one tile. Visible subscribers take precedence, then FIFO.

     Returns:
     True when one queued job was processed; false when the queue has no runnable job.

     Throws:
     Exception for The feature queue is already pumping.
    +/
    bool pump()
    {
        if (pumping)
            throw new Exception("The feature queue is already pumping");
        size_t selected = jobs.length;
        RequestPriority priority;
        foreach (ref subscriber; subscribers)
            if (subscriber.token &&
                (selected == jobs.length || subscriber.priority > priority ||
                (subscriber.priority == priority && jobs[subscriber.job].order < jobs[selected].order)))
            {
                selected = subscriber.job;
                priority = subscriber.priority;
            }
        if (selected == jobs.length)
            return false;

        const job = jobs[selected];
        pumping = true;
        running = selected;
        scope (exit)
        {
            jobs[selected] = Job.init;
            pumping = false;
        }
        const edge = job.key.tile.width > job.key.tile.height ?
            job.key.tile.width : job.key.tile.height;
        // A large halo may make Engine emit several smaller processing tiles.
        // Subscribers still receive their complete bounded request exactly once.
        auto output=new Value[job.key.tile.width*job.key.tile.height];
        Provenance origin;
        Exception failure;
        ++executedCount;
        try
            job.configuration.run(engine,job.source, job.key.tile, job.key.feature, edge,
                (Region2D tile, scope const(Value)[] values, Provenance provenance) {
                    foreach(y;0..tile.height) {
                        const start=(tile.y-job.key.tile.y+y)*job.key.tile.width+tile.x-job.key.tile.x;
                        output[start..start+tile.width]=values[y*tile.width..(y+1)*tile.width];
                    }
                    origin = provenance;
                    origin.extent=job.key.tile;
                });
        catch (Exception error)
            failure = error;

        // Retire the job before calling subscribers. Reentrant submissions
        // cannot join an already completed result.
        jobs[selected].active = false;
        scope (exit)
            foreach (ref subscriber; subscribers)
                if (subscriber.token && subscriber.job == selected)
                    subscriber = Subscriber.init;
        Exception callbackFailure;
        foreach (ref subscriber; subscribers)
            if (subscriber.token && subscriber.job == selected)
            {
                auto callback = subscriber;
                subscriber = Subscriber.init;
                try
                {
                    if (failure is null)
                        callback.success(job.key.tile, output, origin);
                    else
                        callback.failure(failure);
                }
                catch (Exception error)
                    if (callbackFailure is null)
                        callbackFailure = error;
            }
        if (callbackFailure !is null)
            throw callbackFailure;
        return true;
    }
}

/// Submit configured statistics and publish the complete requested tile once.
unittest
{
    import imagery.analysis.feature_parameters : LocalStatisticsParams;
    import imagery.analysis.feature_regions : Sample;
    Source source;
    source.identity="queue-example";source.revision="1";source.grid="pixels";
    source.band="scalar";source.unit="1";source.width=source.height=8;
    source.read=(Region2D r,scope Sample[] values) {
        foreach(ref value;values)value=Sample(1,[0,0,0],true);
    };
    auto queue=new FeatureRequests;size_t samples;
    const token=queue.submit(source,Region2D(0,0,8,8),Feature.localStatistics,
        LocalStatisticsParams(1,5),RequestPriority.visible,
        (Region2D r,scope const(Value)[] values,Provenance origin){samples+=values.length;},
        (Exception error){throw error;});
    assert(token!=0 && queue.pump() && samples==64 && !queue.pump());
}
