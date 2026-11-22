module worker32_positive;
import imagery.analysis.feature_worker32;
import raster : RasterView,RasterPlaneWindow,Region2D,withPlane;

static assert(FeatureWorkerError.init==FeatureWorkerError.notAttempted);
static assert(FeatureWorkerError.init!=FeatureWorkerError.none);

@safe void prepareWorker(ref Float32FeatureWorker worker)
{
    worker.prepare(feature:Feature.ridge,width:64,height:64,
        parameters:RidgeParams(2,7),inputDomain:FeaturePlaneDomain.scalar);
}

@safe nothrow @nogc bool scopedWorker(scope ref const RasterView!double view,
    scope ref const RasterView!ubyte mask,ref Float32FeatureWorker worker,
    Region2D core,out FeaturePlanes32 result,out FeatureWorkerError status)
{
    status=FeatureWorkerError.notAttempted;
    return withPlane(view,0,(scope ref const RasterPlaneWindow!double input) @safe nothrow @nogc {
        withPlane(mask,0,(scope ref const RasterPlaneWindow!ubyte selected) @safe nothrow @nogc {
            status=worker.tryEvaluate(input:input,core:core,result:result,mask:selected);
        });
    });
}
