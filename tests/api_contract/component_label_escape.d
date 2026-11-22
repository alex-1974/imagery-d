module component_label_escape;
import imagery.analysis.feature_components : LabelWriter;
import raster.region : Region2D;

const(uint)[] escaped;
@safe LabelWriter invalidWriter()
{
    return (Region2D row, scope const(uint)[] labels) @safe { escaped = labels; };
}
