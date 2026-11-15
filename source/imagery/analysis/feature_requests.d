/++ Bounded, cooperative scheduling of overlapping requests for fixed feature tiles. +/
module imagery.analysis.feature_requests;

import imagery.analysis.feature_regions : Engine, Feature, MemoryMetrics, Sink, Source,
    TileIdentity, Value, Provenance, describeTileFeature, tileIdentity;
import raster.region : Region2D;

@safe:

enum RequestPriority { background, visible }
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
    }

    private struct Subscriber
    {
        ulong token;
        size_t job;
        RequestPriority priority;
        Sink success;
        RequestFailure failure;
    }

    private Job[32] jobs;
    private Subscriber[128] subscribers;
    private Engine engine;
    private ulong sequence;
    private bool pumping;
    private size_t executedCount;

    size_t executed() const { return executedCount; }
    MemoryMetrics metrics() const { return engine.metrics; }

    /// Submit a single tile of up to 256×256 pixels. A zero token means
    /// queue capacity was reached and the caller may retry.
    ulong submit(Source source, Region2D region, Feature feature,
        RequestPriority priority, Sink success, RequestFailure failure)
    {
        const descriptor = describeTileFeature(feature);
        if (!source.identity.length || !source.revision.length || source.read is null ||
            success is null || failure is null || region.empty ||
            region.width > 256 || region.height > 256 ||
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

        const key = tileIdentity(source, region, feature);
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
            jobs[job] = Job(true, key, source, sequence + 1);
        }
        const token = ++sequence;
        subscribers[slot] = Subscriber(token, job, priority, success, failure);
        return token;
    }

    /// Drop one subscriber. Drop queued work if it has no remaining subscribers.
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

    /// Compute one tile. Visible subscribers take precedence, then FIFO.
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
        Value[] output;
        Provenance origin;
        Exception failure;
        ++executedCount;
        try
            engine.run(job.source, job.key.tile, job.key.feature, edge,
                (Region2D tile, scope const(Value)[] values, Provenance provenance) {
                    output = values.dup;
                    origin = provenance;
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
