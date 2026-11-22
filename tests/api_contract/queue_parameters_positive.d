module queue_parameters_positive;

import imagery.analysis.feature_regions;
import imagery.analysis.feature_requests;
import raster.region : Region2D;

void use(FeatureRequests queue,ref Engine engine,Source source,Sink success,RequestFailure failure) @safe
{
    const parameters=LocalStatisticsParams(5,40);
    queue.submit(source:source,region:Region2D(0,0,8,8),feature:Feature.localNormalization,
        parameters:parameters,priority:RequestPriority.visible,success:success,failure:failure);
    const GaborParams bank;
    queue.submit(source,Region2D(0,0,8,8),Feature.gabor,bank,RequestPriority.visible,success,failure);
    runFeatureView(engine:engine,source:source,region:Region2D(0,0,8,8),
        requested:[Feature.localStatistics,Feature.localNormalization],edge:8,parameters:parameters,sink:success);
}
