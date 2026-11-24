module worker32_mutable_result;
import imagery.analysis.feature_worker32;
@safe void forbiddenMutation(ref FeaturePlanes32 result)
{
    result.channels[0][0]=7; // published planes are readonly borrows
}
