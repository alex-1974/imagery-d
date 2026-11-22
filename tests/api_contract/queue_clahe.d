module queue_clahe;

import imagery.analysis.feature_regions;
import imagery.analysis.feature_requests;
import raster.region : Region2D;

void forbidden(FeatureRequests queue,Source source,Sink success,RequestFailure failure) @safe
{
    queue.submit(source,Region2D(0,0,8,8),Feature.clahe,ClaheParams.init,
        RequestPriority.visible,success,failure);
}
