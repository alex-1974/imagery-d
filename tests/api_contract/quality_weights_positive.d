module quality_weights_positive;

import imagery.mosaic.validity_policy : QualityContributor,tryQualityWeights;

bool use(scope const(QualityContributor)[] input,scope double[] output) @safe pure nothrow @nogc
{
    return tryQualityWeights(contributors:input,destination:output);
}
