module mosaic_positive;
import imagery.mosaic.multiresolution;
import raster : RasterView;

static assert(MosaicError.init==MosaicError.notAttempted);
static assert(MosaicFilter.init==MosaicFilter.unspecified);

@safe MosaicError assemble(scope const MosaicSource[] input,
    scope ref const MosaicRequest options, ref MosaicFrame frame, out MosaicMetrics receipt)
{
    return tryAssembleMosaicOwned(sources:input,request:options,published:frame,metrics:receipt);
}

// The positive consumer uses the same scoped arguments as the rejected escape.
@safe bool inspect(scope RasterView!ubyte rgba,scope RasterView!ubyte validity)
{
    ubyte value;
    return rgba.trySample(0,0,0,value);
}

@safe void retainResult(ref MosaicFrame frame)
{
    auto aliasOfOutput=frame;
    assert(aliasOfOutput.region==frame.region);
}
