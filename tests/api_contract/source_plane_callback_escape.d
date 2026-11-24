module source_plane_callback_escape;
import imagery.analysis.feature_regions : ScalarPlaneConsumer;
ScalarPlaneConsumer!double escaped;
@safe void retain(scope ScalarPlaneConsumer!double consume)
{
    escaped=consume;
}
