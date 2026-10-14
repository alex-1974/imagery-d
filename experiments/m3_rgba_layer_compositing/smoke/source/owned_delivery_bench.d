module owned_delivery_bench;

// Independent microbenchmark of the per-handle control plane.
// NOT a compositing throughput test or an XPS measurement by itself.
// Both paths use genuine public RasterLease ownership; the candidate
// adds accounting participation to that same kind of retained handle.
import core.memory : GC;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln;
import raster : RasterLease;
import color : SRgba8;
import owned_delivery_token : OwnedDeliveryHandle;

enum DeliveryBenchPath : ubyte
{
    rawLeaseRetainRelease,
    deliveryRetainClose
}

private void requireBench(bool condition, string reason)
{
    if (!condition)
        throw new Exception("M3 DELIVERY BENCH: " ~ reason);
}

private void executePairs(DeliveryBenchPath path, size_t iterations,
    ref RasterLease!SRgba8 raw, ref OwnedDeliveryHandle controlled)
{
    if (path == DeliveryBenchPath.rawLeaseRetainRelease)
    {
        foreach (i; 0 .. iterations)
        {
            // The baseline retains one raster-d backing then releases it.
            RasterLease!SRgba8 temporary = raw;
            temporary = RasterLease!SRgba8.init;
        }
    }
    else
    {
        foreach (i; 0 .. iterations)
        {
            OwnedDeliveryHandle temporary;
            requireBench(controlled.tryRetain(temporary) && temporary.close(),
                "retaining and closing a controlled delivery");
        }
    }
}

void runIndependentDeliveryBenchmark(
    ref RasterLease!SRgba8 baseline,
    ref OwnedDeliveryHandle delivery,
    size_t rounds, size_t iterations, size_t warmups)
{
    requireBench(baseline.view().planeCount == 1 && delivery.live(),
        "both baseline and candidate are real live raster-backed values");
    requireBench(rounds > 0 && rounds <= 100 &&
        iterations > 0 && iterations <= 10_000_000 &&
        warmups <= 100, "bounded benchmark configuration");

    // Fixed equal-count warmup operations do not contribute to measured rows.
    foreach (unused; 0 .. warmups)
    foreach (path; [DeliveryBenchPath.rawLeaseRetainRelease,
                    DeliveryBenchPath.deliveryRetainClose])
        executePairs(path, iterations, baseline, delivery);

    size_t completed;
    writeln("experiment,round,stage,iterations,elapsed_us,",
            "thread_gc_bytes,completed_pairs");
    foreach (round; 0 .. rounds)
    foreach (order; 0 .. 2)
    {
        // Alternate order per round to expose runner drift / warmup bias.
        const path = cast(DeliveryBenchPath)((order + round) % 2);
        auto gcBefore = GC.stats().allocatedInCurrentThread;
        StopWatch watch;
        watch.start();
        executePairs(path, iterations, baseline, delivery);
        watch.stop();
        auto gcAfter = GC.stats().allocatedInCurrentThread;
        requireBench(gcAfter >= gcBefore, "GC counter monotonic");
        requireBench(iterations <= size_t.max - completed,
            "completion-count overflow");
        completed += iterations;
        writeln("m3_delivery,", round, ",",
            path == DeliveryBenchPath.rawLeaseRetainRelease
                ? "raw_raster_lease" : "owned_delivery_handle",
            ",", iterations, ",", watch.peek.total!"usecs", ",",
            gcAfter - gcBefore, ",", completed);
    }
    requireBench(delivery.live() && baseline.view().planeCount == 1 &&
        completed == 2 * rounds * iterations,
        "no retained owner or loop count lost in benchmark");
    writeln("DELIVERY-BENCH PASS: paired raw and accounted retains; ",
        "results are run-specific, not XPS evidence");
}
