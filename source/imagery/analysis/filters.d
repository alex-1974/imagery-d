/++
Smooth an image while choosing how much edge detail to retain. Start with
`gaussianBlur` for general smoothing or `bilateralFilter` and `guidedFilter`
for edge-aware filtering. These names are also available through `import
imagery;`.
+/
module imagery.analysis.filters;

public import imagery.analysis.primitives :
    gaussianBlur, medianBlur, bilateralFilter, guidedFilter;

