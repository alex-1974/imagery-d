module source_plane_ref_escape;
import raster : RasterPlaneWindow;
const(RasterPlaneWindow!double)* escaped;
@safe void retain(scope ref const RasterPlaneWindow!double plane)
{
    escaped=&plane;
}
