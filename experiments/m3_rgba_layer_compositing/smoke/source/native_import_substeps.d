module native_import_substeps;

// Issue #74. Research-only decomposition of public raster-d adoption/import.
// Reuses the existing FD9 LD_PRELOAD recorder, never installed/package code.
// Stage granularity is attribution evidence, not a type or RSS guarantee.
// The baseline, raw, adoption, direct-GC-range and import paths are separate processes.
import core.memory : GC;
import core.stdc.stdlib : calloc, malloc, free;
import object : destroy;
import std.conv : to;
import std.stdio : writeln;
import std.string : startsWith;
import color : SRgba8;
import raster :
    OwnedByteResource, PlaneByteLayout, RasterLease, Region2D,
    tryAdoptMallocResource, tryImportOwnedRaster;
import native_allocation_events :
    prepareNativeAllocationEvents, nativeAllocationStage,
    nativePixelAllocationIntent, nativeAllocationTouch;
import owned_generation_delivery : GenerationAccounting;

private void requireStep(bool condition, string detail)
{
    if (!condition)
        throw new Exception("native import substeps: " ~ detail);
}

// The stage numbers deliberately retain the same meaning in all modes.
// 1 baseline; 2 scratch malloc; 3 adopt scratch; 4 import scratch;
// 5 scratch view+retain; 6 packed malloc; 7 adopt packed;
// 8 import packed; 9 packed view+retain; 10 retire scratch;
// 11 retire original packed; 12 retire final packed; 13 terminal.
// The scratch import has FOUR byte planes; the packed import has ONE
// SRgba8 plane, matching the established independent M3 controls.
void runNativeImportSubsteps(string[] args)
{
    string comparison;
    size_t side = 16;
    foreach (arg; args)
    {
        if (arg.startsWith("--case="))
            comparison = arg[7 .. $];
        else if (arg.startsWith("--side="))
            side = to!size_t(arg[7 .. $]);
        else
            requireStep(false, "unknown command-line argument");
    }
    requireStep(comparison == "raw" || comparison == "adopt" ||
        comparison == "gc-range" || comparison == "import",
        "case must be raw/adopt/gc-range/import");
    requireStep(side == 16 || side == 256, "side must be 16 or 256");
    const size_t bytes = 4 * side * side;
    requireStep(side <= cast(size_t)ptrdiff_t.max / 4,
        "plane stride must fit ptrdiff_t");

    // One shared, non-pixel accounting baseline. No cross-case invisible
    // source fixtures: this intentionally isolates the import operation.
    prepareNativeAllocationEvents();
    // The public raster-d backing is 80 B on pinned 64-bit v0.2.0.
    // RasterBacking is package(raster): match the audited 80-byte scan range
    // with two separately allocated, zeroed foreign-memory carriers, NOT
    // by importing or constructing its private representation. Build these
    // in every case BEFORE trace stage 1 to equalize glibc allocator state.
    // The effect being tested is GC range registration, not carrier malloc.
    static assert(size_t.sizeof == 8);
    enum size_t scanBytes = 80;
    void* scratchScan = calloc(1, scanBytes);
    void* packedScan = calloc(1, scanBytes);
    requireStep(scratchScan !is null && packedScan !is null,
        "pretrace conservative GC scan carriers");
    ubyte* scratchRaw;
    ubyte* packedRaw;
    OwnedByteResource scratchToken, packedToken;
    RasterLease!ubyte scratchLease, scratchCopy;
    RasterLease!SRgba8 packedLease, packedCopy;

    nativeAllocationStage(1);
    auto baseline = new GenerationAccounting(8 * bytes + 4096);
    requireStep(baseline.active == 0 && baseline.charged == 0,
        "accounting baseline");

    nativeAllocationStage(2);
    nativePixelAllocationIntent(1, bytes);
    scratchRaw = cast(ubyte*)malloc(bytes);
    requireStep(scratchRaw !is null, "scratch malloc");

    nativeAllocationStage(3);
    if (comparison != "raw")
        requireStep(tryAdoptMallocResource(scratchRaw, bytes, scratchToken),
            "scratch public adoption");

    nativeAllocationStage(4);
    if (comparison == "gc-range")
        GC.addRange(scratchScan, scanBytes);
    else if (comparison == "import")
    {
        PlaneByteLayout[4] planes;
        foreach (channel; 0 .. 4)
            planes[channel] = PlaneByteLayout(channel,
                cast(ptrdiff_t)(4 * side), 4);
        requireStep(tryImportOwnedRaster!ubyte(
            scratchToken, planes[], Region2D(0, 0, side, side),
            scratchLease).ok, "four-plane public scratch import");
        requireStep(!scratchToken.ownsResource, "scratch token consumed");
    }

    nativeAllocationStage(5);
    if (comparison == "import")
    {
        {
            scope auto view = scratchLease.view();
            requireStep(view.planeCount == 4, "scratch borrow");
        }
        scratchCopy = scratchLease;
        requireStep(scratchCopy.view().planeCount == 4,
            "scratch retain");
    }

    nativeAllocationStage(6);
    nativePixelAllocationIntent(2, bytes);
    packedRaw = cast(ubyte*)malloc(bytes);
    requireStep(packedRaw !is null, "packed malloc");

    nativeAllocationStage(7);
    if (comparison != "raw")
        requireStep(tryAdoptMallocResource(packedRaw, bytes, packedToken),
            "packed public adoption");

    nativeAllocationStage(8);
    if (comparison == "gc-range")
        GC.addRange(packedScan, scanBytes);
    else if (comparison == "import")
    {
        const PlaneByteLayout[1] planes =
            [PlaneByteLayout(0, cast(ptrdiff_t)(4 * side), 4)];
        requireStep(tryImportOwnedRaster!SRgba8(
            packedToken, planes[], Region2D(0, 0, side, side),
            packedLease).ok, "one-plane public packed import");
        requireStep(!packedToken.ownsResource, "packed token consumed");
    }

    nativeAllocationStage(9);
    if (comparison == "import")
    {
        {
            scope auto view = packedLease.view();
            requireStep(view.planeCount == 1, "packed borrow");
        }
        packedCopy = packedLease;
        requireStep(packedCopy.view().planeCount == 1,
            "packed retain");
    }

    nativeAllocationStage(10);
    if (comparison == "raw" || comparison == "gc-range")
    {
        if (comparison == "gc-range")
            GC.removeRange(scratchScan);
        // External C volatile touch keeps both malloc blocks observable in
        // optimized LDC until after the packed allocation; never optimize
        // away the scratch in the control arm.
        nativeAllocationTouch(cast(void*)scratchRaw, bytes);
        free(scratchRaw);
    }
    else if (comparison == "adopt")
        destroy(scratchToken);
    else
    {
        scratchLease = RasterLease!ubyte.init;
        requireStep(scratchCopy.view().planeCount == 4,
            "scratch remains owned after initial release");
        scratchCopy = RasterLease!ubyte.init;
    }
    scratchRaw = null;

    nativeAllocationStage(11);
    if (comparison == "import")
    {
        packedLease = RasterLease!SRgba8.init;
        requireStep(packedCopy.view().planeCount == 1,
            "packed survives first owner release");
    }

    nativeAllocationStage(12);
    if (comparison == "raw" || comparison == "gc-range")
    {
        if (comparison == "gc-range")
            GC.removeRange(packedScan);
        nativeAllocationTouch(cast(void*)packedRaw, bytes);
        free(packedRaw);
    }
    else if (comparison == "adopt")
        destroy(packedToken);
    else
        packedCopy = RasterLease!SRgba8.init;
    packedRaw = null;

    nativeAllocationStage(13);
    requireStep(!scratchToken.ownsResource && !packedToken.ownsResource,
        "no remaining adoption tokens");
    requireStep(scratchLease.view().planeCount == 0 &&
        scratchCopy.view().planeCount == 0 &&
        packedLease.view().planeCount == 0 &&
        packedCopy.view().planeCount == 0, "no remaining lease owners");
    requireStep(baseline.active == 0 && baseline.charged == 0,
        "accounting baseline unchanged");
    nativeAllocationStage(0);
    // Two equal pretrace allocations are freed after the recorder stopped.
    // Touch via an opaque C symbol so optimizing LDC cannot silently erase
    // the matching carrier allocations in the control arms.
    nativeAllocationTouch(scratchScan, scanBytes);
    nativeAllocationTouch(packedScan, scanBytes);
    free(scratchScan);
    free(packedScan);
    writeln("M3 NATIVE IMPORT SUBSTEPS PASS: case=", comparison,
        " side=", side, " stages=13");
}
