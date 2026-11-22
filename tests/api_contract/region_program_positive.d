module region_program_positive;
import imagery.analysis.color_slic;
import imagery.analysis.region_graph;
import imagery.analysis.feature_components;

@safe RegionGraphError build(RegionGraphRequest request,LabelReader labels,
    ComponentReader input,ref RegionGraph published)
{
    return tryBuildRegionGraph(request:request,labels:labels,input:input,published:published);
}
@safe RegionGraphError merge(ref const RegionGraph source,scope const RegionMerge[] merges,
    RegionGraphRequest request,ref RegionGraph published)
{
    return tryMergeRegionGraph(source:source,merges:merges,request:request,published:published);
}
@safe ColorSlicError segment(ColorSlicRequest request,ComponentReader input,
    ComponentStore assignmentStore,ComponentTransaction transaction,
    ref ColorSlicSegmentation published,out ColorSlicMetrics metrics)
{
    return tryColorSlic(request:request,input:input,assignmentStore:assignmentStore,
        transaction:transaction,published:published,metrics:metrics);
}
@safe nothrow @nogc bool query(ref const RegionGraph graph,uint id)
{
    RegionDescriptor region;uint current;
    return graph.tryRegion(id,region)&&graph.tryResolveLabel(id,current)&&graph.neighbors(id).length!=0;
}
