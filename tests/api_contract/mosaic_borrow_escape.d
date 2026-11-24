module mosaic_borrow_escape;
import raster : RasterView;

RasterView!ubyte escaped;
@safe bool inspect(scope RasterView!ubyte rgba,scope RasterView!ubyte validity)
{
    escaped=rgba;
    return true;
}
