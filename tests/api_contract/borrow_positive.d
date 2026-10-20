// Compile-only positive control: DUB paths and DIP1000 are configured.
module borrow_positive;
import raster : RasterLease;
@safe bool localBorrow()
{
    RasterLease!ubyte lease;
    scope auto view = lease.view();
    return view.planeCount == 0;
}

// Named-argument and UFCS probes are compile-only public syntax contracts.
// Invalid views are deliberately used: executing them is unnecessary.
import imagery : Levels, LevelsError, tryLevelsOwned;
import raster : RasterView, Region2D;

void ordinaryPublicCalls()
{
    bool[1] selected = [true];
    RasterLease!float published;
    auto source = RasterView!ubyte.init;
    auto mask = RasterView!ubyte.init;
    auto unmasked = tryLevelsOwned!ubyte(
        pixels: source, roi: Region2D(0, 0, 1, 1),
        affected: selected[], settings: Levels(0, 1, 1, 0, 1),
        maxResultBytes: float.sizeof, published: published);
    auto masked = tryLevelsOwned!ubyte(
        pixels: source, roi: Region2D(0, 0, 1, 1),
        affected: selected[], settings: Levels(0, 1, 1, 0, 1),
        selection: mask, maxResultBytes: float.sizeof,
        published: published);
    auto ufcs = source.tryLevelsOwned!ubyte(
        Region2D(0, 0, 1, 1), selected[],
        Levels(0, 1, 1, 0, 1), float.sizeof, published);
    assert(unmasked == LevelsError.invalidSource &&
        masked == LevelsError.invalidSource &&
        ufcs == LevelsError.invalidSource);
}
