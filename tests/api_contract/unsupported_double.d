// MUST fail: candidate Levels admits ubyte, ushort, float, not double.
module unsupported_double;
import raster : RasterView, RasterLease, Region2D;
import imagery : tryLevelsOwned, Levels;
void cannotProcessDouble()
{
    RasterLease!float output;
    bool[1] choice = [true];
    auto result = tryLevelsOwned!double(
        RasterView!double.init, Region2D(0, 0, 1, 1), choice[],
        Levels(0, 1, 1, 0, 1), float.sizeof, output);
}
