module components_positive;
import imagery.analysis.feature_components;
import raster.region : Region2D;

@safe ComponentResult publish(ComponentReader input, ComponentTransaction transaction)
{
    return tryLabelComponentsTransactional(extent:Region2D(3, 7, 17, 19), input:input,
        transaction:transaction, policy:ComponentPolicy(true, true), labelLimit:1024,
        blockEdge:64, maxScratchBytes:componentScratchBytes(1024),
        provenance:ComponentProvenance("consumer", "revision", "grid"), cancelled:null);
}
static assert(!ComponentResult.init.ok);

@safe LabelWriter stageInto(uint[] destination)
{
    return (Region2D row, scope const(uint)[] labels) @safe {
        destination[row.x .. row.x+labels.length] = labels[];
    };
}
