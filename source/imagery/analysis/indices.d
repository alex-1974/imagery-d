/++
Combine two image bands into a normalized difference. Start with
`normalizedDifference` and supply bands with the intended meaning and
alignment. The operation does not identify spectral bands or infer a validity
mask.
+/
module imagery.analysis.indices;

public import imagery.analysis.primitives :
    normalizedDifference, normalizedDifferenceValid;

