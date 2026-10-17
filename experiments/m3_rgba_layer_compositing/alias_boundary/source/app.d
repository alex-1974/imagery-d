module app;

// Public-only ownership/alias contract probe against raster-d v0.2.0.
// No raw retyping, no second free owner, no raster.internal imports.
// The sample data are incidental: this does NOT test color compositing.
import core.stdc.stdlib : free, malloc;
import std.stdio : writeln;
import color : SRgba8;
import imagery.presentation.composite :
    DecodedRgbaLayer, ResearchPreparedRgbaContext, RgbaAssociation,
    RgbaCompositeError, RgbaEncoding, tryPrepareRgbaContext,
    tryCompositeRgbaSourceOverPrepared;
import raster :
    OwnedByteResource, OwnedRasterImportError,
    OwnedRasterResourceDisposition, PlaneByteLayout,
    RasterCopyError, RasterLease, RasterView, Region2D,
    tryAdoptMallocResource, tryCopyRasterPlane, tryImportOwnedRaster;

// Different typed leases/views must not implicitly exchange backing ownership.
static assert(!__traits(compiles, {
    RasterLease!ubyte bytes;
    RasterLease!SRgba8 pixels = bytes;
}));
static assert(!__traits(compiles, {
    RasterView!ubyte bytes;
    RasterView!SRgba8 pixels = bytes;
}));

private void require(bool condition, string message) @safe
{
    if (!condition)
        throw new Exception("M3 alias boundary: " ~ message);
}

// All borrow, copy, and token-state checks below are compile-checked @safe.
private void verifyPublicContracts(
    ref RasterLease!ubyte original, ref OwnedByteResource resource
) @safe
{
    enum size_t width = 4;
    enum size_t height = 3;
    const fullRegion = Region2D(0, 0, width, height);

    // Copying a lease of the SAME sample type retains the one shared owner.
    // It is NOT a second independent free() obligation.
    RasterLease!ubyte retained = original;
    scope auto source = original.view();
    bool writable;
    scope auto destination = retained.tryWritableView(writable);
    require(writable && source.planeCount == 4 &&
            destination.planeCount == 4,
            "two borrows of one owner did not preserve four planes");

    foreach (y; 0 .. height)
    foreach (x; 0 .. width)
    {
        const ubyte red = cast(ubyte)(10 + x + 4 * y);
        const ubyte green = cast(ubyte)(90 + x + 4 * y);
        require(destination.trySetSample(0, x, y, red) &&
                destination.trySetSample(1, x, y, green) &&
                destination.trySetSample(2, x, y, 137) &&
                destination.trySetSample(3, x, y, 255),
                "failed to initialize shared resource");
    }

    // Exactly overlapping source/destination sample addresses are rejected
    // by the PUBLIC operation before writes, even for valid shared ownership.
    RasterCopyError error;
    require(!tryCopyRasterPlane(source, 0, destination, 0, error) &&
            error == RasterCopyError.sourceDestinationOverlap,
            "same-plane original source/destination overlap was accepted");
    foreach (y; 0 .. height)
    foreach (x; 0 .. width)
    {
        ubyte red;
        ubyte green;
        require(source.trySample(0, x, y, red) &&
                source.trySample(1, x, y, green),
                "failed to read after rejected aliased copy");
        require(red == cast(ubyte)(10 + x + 4 * y) &&
                green == cast(ubyte)(90 + x + 4 * y),
                "prewrite alias rejection mutated original data");
    }

    // A different logical plane in the same physical owner is byte-disjoint.
    // The public copy operation is not overconservative about shared owners.
    error = RasterCopyError.init;
    require(tryCopyRasterPlane(source, 1, destination, 0, error) &&
            error == RasterCopyError.none,
            "disjoint planes of one owner were incorrectly rejected");
    foreach (y; 0 .. height)
    foreach (x; 0 .. width)
    {
        ubyte red;
        ubyte green;
        require(source.trySample(0, x, y, red) &&
                source.trySample(1, x, y, green) &&
                red == green &&
                red == cast(ubyte)(90 + x + 4 * y),
                "disjoint-plane copy changed incorrect samples");
    }

    // Reimporting the CONSUMED token as a packed SRgba8 owner cannot
    // manufacture a second typed lease or a second free obligation.
    const PlaneByteLayout[1] packedPlane = [
        PlaneByteLayout(0, cast(ptrdiff_t)(width * 4), 4)
    ];
    RasterLease!SRgba8 packed;
    const second = tryImportOwnedRaster!SRgba8(
        resource, packedPlane[], fullRegion, packed);
    require(!second.ok &&
            second.error == OwnedRasterImportError.emptyResource &&
            second.resourceDisposition ==
                OwnedRasterResourceDisposition.unchanged &&
            packed.view().planeCount == 0,
            "consumed token unexpectedly made a second typed owner");

}

// Issue #75: a factual alias *witness*, not an assertion of pixel
// corruption or a proposed way to perform in-place composition.
// Public raster.copyInto rejects physical overlap, but the four-plane
// imagery research compositor has no analogous prewrite overlap check.
// Using one independent RETAINED lease for the writable destination is
// memory-safe; @safe is not a semantic noalias certificate.
private void verifyImageDomainAliasWitness(
    ref RasterLease!ubyte original) @safe
{
    enum size_t w = 4, h = 3;
    const roi = Region2D(0, 0, w, h);
    RasterLease!ubyte retained = original;
    bool writable;
    {
        scope auto dest = retained.tryWritableView(writable);
        require(writable && dest.planeCount == 4,
            "real same-type retained writable alias must be available");
        require(dest.trySetSample(3, 0, 0, 128),
            "make one original pixel partially transparent");
    }
    ubyte before;
    {
        scope auto source = original.view();
        require(source.trySample(3, 0, 0, before) && before == 128,
            "read original alpha before aliased composite");
    }
    ResearchPreparedRgbaContext prepared;
    require(tryPrepareRgbaContext(0.37, prepared)
        == RgbaCompositeError.none,
        "prepare nontrivial runtime opacity");

    // Source *and* destination refer to exactly the same real backing.
    // This currently returns success rather than a physical-overlap error.
    // Exact-coordinate in-place execution may happen to produce a valid
    // output: this test proves the missing REJECTION contract only.
    {
        scope auto source = original.view();
        scope auto dest = retained.tryWritableView(writable);
        require(writable, "writable view of independently retained owner");
        require(tryCompositeRgbaSourceOverPrepared(
            prepared,
            DecodedRgbaLayer(source, RgbaEncoding.encodedSRgb,
                RgbaAssociation.straight),
            DecodedRgbaLayer(source, RgbaEncoding.encodedSRgb,
                RgbaAssociation.straight),
            roi, dest) == RgbaCompositeError.none,
            "four-plane imagery operation did not reject real physical overlap");
    }
    ubyte after;
    {
        scope auto source = original.view();
        require(source.trySample(3, 0, 0, after) && after != before,
            "accepted aliased call really modified same source backing");
    }
}

void main() @system
{
    enum size_t width = 4;
    enum size_t height = 3;
    enum size_t byteCount = width * height * 4;

    auto memory = malloc(byteCount);
    require(memory !is null, "malloc failed");

    OwnedByteResource resource;
    if (!tryAdoptMallocResource(memory, byteCount, resource))
    {
        free(memory); // Adoption failed; caller still owns memory.
        require(false, "malloc resource adoption failed");
    }

    // Four semantically separate ubyte planes in ONE malloc allocation.
    const PlaneByteLayout[4] planes = [
        PlaneByteLayout(0, cast(ptrdiff_t)(width * 4), 4),
        PlaneByteLayout(1, cast(ptrdiff_t)(width * 4), 4),
        PlaneByteLayout(2, cast(ptrdiff_t)(width * 4), 4),
        PlaneByteLayout(3, cast(ptrdiff_t)(width * 4), 4),
    ];
    const fullRegion = Region2D(0, 0, width, height);

    RasterLease!ubyte original;
    const first = tryImportOwnedRaster!ubyte(
        resource, planes[], fullRegion, original);
    require(first.ok &&
            first.resourceDisposition ==
                OwnedRasterResourceDisposition.transferredToLease,
            "first owned import did not transfer into the lease");
    require(!resource.ownsResource, "resource token not disarmed");

    verifyPublicContracts(original, resource);
    verifyImageDomainAliasWitness(original);

    writeln("M3-ALIAS-BOUNDARY PASS: same-type shared owner, ",
            "physical overlap rejected without writes, disjoint planes ",
            "allowed, consumed cross-type token rejected");
    writeln("M3-IMAGE-ALIAS-WITNESS PASS: four-plane source-over accepted ",
            "overlapping source/destination and mutated the same backing; ",
            "@safe is NOT physical noalias; NOT production admission");
}
