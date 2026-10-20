// MUST be compiler-rejected: Levels candidate has explicit @system boundary.
module safe_requires_review;
import imagery : Levels, tryLevelsOwned;
import raster : RasterView, RasterLease, Region2D;

@safe void cannotClaimSafe(RasterView!ubyte pixels,
                           ref RasterLease!float result)
{
    bool[1] affected = [true];
    auto status = tryLevelsOwned!ubyte(
        pixels, Region2D(0, 0, 1, 1), affected[],
        Levels(0, 1, 1, 0, 1), float.sizeof, result);
}
