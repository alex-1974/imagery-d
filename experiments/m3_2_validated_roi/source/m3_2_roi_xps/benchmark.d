module m3_2_roi_xps.benchmark;

import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln;
import m3_2_channel_metadata.contract : IntrinsicChannel;
import m3_2_retained_metadata.contract : BorrowedSemanticImage;
import m3_2_verified_roi.contract : ValidatedImmutableImage;
import raster : RasterView, Region2D;

/*
 * pragma(inline, false) creates a visible, inspectable call boundary.
 * These wrappers exercise identical ROI shape and descriptor lookups.
 * The direct raster control has no intrinsic semantics to validate,
 * so it is a lower-bound/control, NOT semantic-equivalent image validation.
 */
pragma(inline, false)
private size_t rasterControl(
    scope RasterView!float source,
    Region2D region,
    scope immutable(IntrinsicChannel)[] metadata,
    size_t selected
)
@safe nothrow @nogc
{
    bool ok;
    auto roi = source.tryRoi(region, ok);
    if (!ok)
        return 0;
    return roi.planeCount + roi.width * 7 + roi.height
        + metadata[selected].semanticId;
}

pragma(inline, false)
private size_t conservativeControl(
    scope BorrowedSemanticImage source,
    Region2D region,
    size_t selected
)
@safe nothrow @nogc
{
    bool ok;
    auto roi = source.tryRoi(region, ok);
    if (!ok)
        return 0;
    return roi.channelCount + roi.width * 7 + roi.height
        + roi.intrinsic[selected].semanticId;
}

pragma(inline, false)
private size_t validatedControl(
    scope ValidatedImmutableImage source,
    Region2D region,
    size_t selected
)
@safe nothrow @nogc
{
    bool ok;
    auto roi = source.tryRoi(region, ok);
    if (!ok)
        return 0;
    return roi.channelCount + roi.width * 7 + roi.height
        + roi.intrinsic[selected].semanticId;
}

private struct Batch
{
    ulong elapsedNs;
    size_t checksum;
}

private Batch runBatch(
    size_t which,
    size_t channels,
    size_t iterations,
    size_t ordinal,
    scope RasterView!float source,
    scope BorrowedSemanticImage conservative,
    scope ValidatedImmutableImage validated,
    scope immutable(IntrinsicChannel)[] meanings
)
{
    // The last operand is intentionally based on runtime iteration +
    // ordinal, not on static/compile-time channel metadata constants.
    const Region2D[8] windows = [
        Region2D(0, 0, 3, 2),
        Region2D(1, 0, 3, 2),
        Region2D(2, 0, 3, 2),
        Region2D(3, 0, 3, 2),
        Region2D(0, 1, 3, 2),
        Region2D(1, 1, 3, 2),
        Region2D(2, 2, 3, 2),
        Region2D(4, 3, 3, 2)
    ];

    size_t checksum = 0;
    StopWatch watch;
    watch.start();
    foreach (i; 0 .. iterations)
    {
        const index = (i * 17 + ordinal) % channels;
        const window = windows[(i + ordinal) % windows.length];
        size_t contribution;
        final switch (which)
        {
            case 0:
                contribution = rasterControl(
                    source, window, meanings, index
                );
                break;
            case 1:
                contribution = conservativeControl(
                    conservative, window, index
                );
                break;
            case 2:
                contribution = validatedControl(
                    validated, window, index
                );
                break;
        }
        checksum += contribution;
    }
    watch.stop();
    return Batch(cast(ulong)watch.peek.total!"nsecs", checksum);
}

/++
    Paired three-path control-plane benchmark. No pixel operation is
    included; every path performs the same ROI shape + metadata lookup,
    and runtime checksums are equal. Reversed and rotating order controls
    drift. Source metadata and raster are created before timing.
+/
void runXpsRoiBenchmark(
    scope RasterView!float source,
    scope BorrowedSemanticImage conservative,
    scope ValidatedImmutableImage validated,
    scope immutable(IntrinsicChannel)[] meanings,
    size_t channels,
    size_t iterations,
    size_t rounds,
    size_t warmups
)
{
    assert(channels > 0 && meanings.length == channels);
    assert(iterations > 0 && rounds > 0);

    // Validate the three observably equivalent paths before warm-up.
    auto direct = runBatch(
        0, channels, 64, 0, source, conservative, validated, meanings
    );
    auto checkedPath = runBatch(
        1, channels, 64, 0, source, conservative, validated, meanings
    );
    auto immutablePath = runBatch(
        2, channels, 64, 0, source, conservative, validated, meanings
    );
    if (direct.checksum == 0 ||
        direct.checksum != checkedPath.checksum ||
        direct.checksum != immutablePath.checksum)
    {
        import core.stdc.stdlib : exit;
        exit(2);
    }

    foreach (cycle; 0 .. warmups)
    {
        foreach (kind; 0 .. 3)
        {
            auto warmed = runBatch(
                kind, channels, iterations, cycle,
                source, conservative, validated, meanings
            );
            if (warmed.checksum == 0)
            {
                import core.stdc.stdlib : exit;
                exit(3);
            }
        }
    }

    foreach (round; 0 .. rounds)
    {
        size_t[3] totals;
        size_t[3] checksum;
        size_t[3] order;
        // Alternating/reversed cycle with three rotations yields six
        // balanced permutations. All modes use the *same* ordinal.
        foreach (slot; 0 .. 3)
        {
            const offset = (round / 2) % 3;
            order[slot] = round % 2 == 0
                ? (offset + slot) % 3
                : (offset + 3 - slot) % 3;
        }
        foreach (slot; 0 .. 3)
        {
            const mode = order[slot];
            auto sample = runBatch(
                mode, channels, iterations, round + warmups,
                source, conservative, validated, meanings
            );
            totals[mode] = cast(size_t)sample.elapsedNs;
            checksum[mode] = sample.checksum;
            writeln("roi_xps,", channels, ",", round, ",", slot, ",",
                mode == 0 ? "raster_only"
                    : mode == 1 ? "revalidated_image"
                    : "verified_immutable_image",
                ",", iterations, ",", sample.elapsedNs, ",",
                sample.checksum);
        }

        if (checksum[0] == 0 ||
            checksum[0] != checksum[1] ||
            checksum[0] != checksum[2])
        {
            import core.stdc.stdlib : exit;
            exit(4);
        }
    }
}
