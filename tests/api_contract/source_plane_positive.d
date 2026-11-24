module source_plane_positive;
import imagery.analysis.feature_regions : Source,ScalarPlaneConsumer;
import raster : RasterView,withPlane;

@safe nothrow @nogc bool borrow(T)(scope ref const RasterView!T view,
    scope ScalarPlaneConsumer!T consume)
{
    return withPlane(view,0,consume);
}

@safe void sourceContract(ref Source source)
{
    source.readPlane=null;
    source.readPlane32=null;
}

import imagery.analysis.hessian_lines : HessianLineWorkspace;
import imagery.analysis.structure_tensor : TensorWorkspace,StructureTensorParams;
import imagery.analysis.feature_worker32 : FeaturePlanes32;
import raster : Region2D;
@safe void shapeContract(ref HessianLineWorkspace h,ref TensorWorkspace t)
{
    double[3] sigmas=[1,2,4];h.reserve(1024,1024,sigmas[]);
    t.reserve(1024,1024,StructureTensorParams.init);
}
