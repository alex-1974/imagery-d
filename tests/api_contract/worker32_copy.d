module worker32_copy;
import imagery.analysis.feature_worker32;
@safe void forbiddenCopy(ref Float32FeatureWorker source)
{
    Float32FeatureWorker duplicate=source; // mutable prepared scratch is unique
}
