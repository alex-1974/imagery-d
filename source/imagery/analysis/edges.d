/++
Find image gradients and edges. Start with `sobel` for horizontal/vertical
derivatives or `canny` for a connected edge mask. These names are also
available through `import imagery;`.
+/
module imagery.analysis.edges;

public import imagery.analysis.primitives :
    sobel, laplacian, differenceOfGaussians, gradientMagnitude, canny;

