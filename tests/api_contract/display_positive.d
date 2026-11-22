module display_positive;
import imagery.mosaic.multiresolution;
@safe MosaicError visit(ref MosaicDisplayWorkspace workspace,scope const MosaicSource[] sources,
    scope ref const MosaicRequest request,scope MosaicDisplayConsumer consumer,out MosaicMetrics metrics)
{
    return workspace.tryVisit(sources:sources,request:request,consumer:consumer,metrics:metrics);
}
