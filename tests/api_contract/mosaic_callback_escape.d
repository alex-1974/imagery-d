module mosaic_callback_escape;
import imagery.mosaic.multiresolution;

MosaicTileConsumer escaped;
@safe MosaicTileStatus provider(size_t level,size_t x,size_t y,scope MosaicTileConsumer consume)
{
    escaped=consume;
    return MosaicTileStatus.missing;
}
