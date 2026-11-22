module region_graph_mutation;
import imagery.analysis.region_graph;
@safe void invalid(ref RegionGraph graph)
{
    graph.regions[0].statistics.id=123;
}
