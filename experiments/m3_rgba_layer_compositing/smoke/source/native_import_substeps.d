module native_import_substeps;

// Issue #74. Research-only decomposition of public raster-d adoption/import.
// Reuses the existing FD9 LD_PRELOAD recorder, never installed/package code.
// Stage granularity is attribution evidence, not a type or RSS guarantee.
// The baseline, raw, adoption-only and import paths are separate processes.
import core.stdc.stdlib : malloc, free;
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
        comparison == "import", "case must be raw/adopt/import");
    requireStep(side == 16 || side == 256, "side must be 16 or 256");
    const size_t bytes = 4 * side * side;
    requireStep(side <= cast(size_t)ptrdiff_t.max / 4,
        "plane stride must fit ptrdiff_t");

    // One shared, non-pixel accounting baseline. No cross-case invisible
    // source fixtures: this intentionally isolates the import operation.
    prepareNativeAllocationEvents();
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
    if (comparison == "import")
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
    if (comparison == "import")
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
    if (comparison == "raw")
    {
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
    if (comparison == "raw")
    {
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
    writeln("M3 NATIVE IMPORT SUBSTEPS PASS: case=", comparison,
        " side=", side, " stages=13");
}
