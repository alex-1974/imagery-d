module owned_payload_budget;

// Research-only arithmetic preflight for candidate B's known pixel payload.
// This is NOT a malloc reservation, allocator, or full-memory admission API.
// Kept in the independently built DUB consumer; no production imagery surface.
import raster : Region2D;

enum OwnedPayloadStatus : ubyte
{
    admissible,
    invalidRegion,
    unsupportedRowStride,
    arithmeticOverflow,
    insufficientPayloadBudget
}

struct OwnedPayloadPlan
{
    size_t pixels;
    size_t fourPlaneBytes;
    size_t packedBytes;
    size_t peakPayloadBytes;
    size_t retainedPayloadBytes;
}

// Return an inert plan on ALL failures. Only admissible publishes sizes.
// Additional import metadata, retention elsewhere, foreign allocations,
// cache eviction and actual reservation remain external and unproven.
OwnedPayloadStatus tryPlanOwnedRgbaPayload(
    Region2D roi, size_t availablePayloadBytes,
    out OwnedPayloadPlan plan
) @safe pure nothrow @nogc
{
    if (roi.width == 0 || roi.height == 0 ||
        roi.width > size_t.max - roi.x ||
        roi.height > size_t.max - roi.y)
        return OwnedPayloadStatus.invalidRegion;

    // Both the four-ubyte interleaved scratch and packed SRgba8 use
    // byte-addressed row stride = 4 * width, cast to ptrdiff_t.
    if (roi.width > cast(size_t)ptrdiff_t.max / 4)
        return OwnedPayloadStatus.unsupportedRowStride;

    if (roi.width > size_t.max / roi.height)
        return OwnedPayloadStatus.arithmeticOverflow;
    const size_t pixels = roi.width * roi.height;

    // During packing, four-plane scratch and packed result coexist:
    // 4 * pixels + 4 * pixels = 8 * pixels.
    if (pixels > size_t.max / 8)
        return OwnedPayloadStatus.arithmeticOverflow;

    const size_t bytes = pixels * 4;
    const size_t peak = pixels * 8;
    if (peak > availablePayloadBytes)
        return OwnedPayloadStatus.insufficientPayloadBudget;

    plan = OwnedPayloadPlan(pixels, bytes, bytes, peak, bytes);
    return OwnedPayloadStatus.admissible;
}

// Called in the independent default/debug/release consumer matrix, rather
// than hiding all checks behind D's optional unittest compilation mode.
void checkOwnedPayloadBudgetContract() @safe pure nothrow @nogc
{
    OwnedPayloadPlan plan;
    assert(tryPlanOwnedRgbaPayload(
        Region2D(5, 7, 16, 16), 2048, plan)
        == OwnedPayloadStatus.admissible);
    assert(plan.pixels == 256 &&
           plan.fourPlaneBytes == 1024 &&
           plan.packedBytes == 1024 &&
           plan.peakPayloadBytes == 2048 &&
           plan.retainedPayloadBytes == 1024);

    // Exact capacity succeeds; a deficit of even one byte rejects before
    // ANY memory allocation is attempted by this pure preflight.
    plan = OwnedPayloadPlan(999, 999, 999, 999, 999);
    assert(tryPlanOwnedRgbaPayload(
        Region2D(5, 7, 16, 16), 2047, plan)
        == OwnedPayloadStatus.insufficientPayloadBudget);
    assert(plan == OwnedPayloadPlan.init);

    // The old 3-buffer path's peak must not be misrepresented as this
    // candidate's full resident result plus external pinned-cache overhead.
    assert(tryPlanOwnedRgbaPayload(
        Region2D(71, 91, 256, 256), 524_288, plan)
        == OwnedPayloadStatus.admissible);
    assert(plan.pixels == 65_536 &&
           plan.fourPlaneBytes == 262_144 &&
           plan.packedBytes == 262_144 &&
           plan.peakPayloadBytes == 524_288 &&
           plan.retainedPayloadBytes == 262_144);

    plan = OwnedPayloadPlan(1, 1, 1, 1, 1);
    assert(tryPlanOwnedRgbaPayload(
        Region2D(0, 0, 0, 1), size_t.max, plan)
        == OwnedPayloadStatus.invalidRegion);
    assert(plan == OwnedPayloadPlan.init);

    assert(tryPlanOwnedRgbaPayload(
        Region2D(size_t.max, 0, 2, 1), size_t.max, plan)
        == OwnedPayloadStatus.invalidRegion);
    assert(plan == OwnedPayloadPlan.init);

    assert(tryPlanOwnedRgbaPayload(
        Region2D(0, 0, cast(size_t)ptrdiff_t.max / 4 + 1, 1),
        size_t.max, plan) == OwnedPayloadStatus.unsupportedRowStride);
    assert(plan == OwnedPayloadPlan.init);

    assert(tryPlanOwnedRgbaPayload(
        Region2D(0, 0, cast(size_t)ptrdiff_t.max / 4, 10),
        size_t.max, plan) == OwnedPayloadStatus.arithmeticOverflow);
    assert(plan == OwnedPayloadPlan.init);

    // No hidden state or allocation: subsequent valid plans are unchanged.
    assert(tryPlanOwnedRgbaPayload(
        Region2D(5, 7, 16, 16), 2048, plan)
        == OwnedPayloadStatus.admissible);
    assert(plan == OwnedPayloadPlan(256, 1024, 1024, 2048, 1024));
}
