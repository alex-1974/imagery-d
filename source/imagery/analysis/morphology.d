/++
Grow, shrink or clean a binary image mask. Use `dilate` and `erode` for
individual steps, or `opening` and `closing` for their paired operations.
These names are also available through `import imagery;`.
+/
module imagery.analysis.morphology;

public import imagery.analysis.primitives :
    dilate, erode, opening, closing;

