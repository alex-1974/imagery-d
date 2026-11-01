# imagery-d v0.3.0

This release refines the public image-processing surface for consumers.

## Highlights

- The default `import imagery;` facade exposes conventional image-operation
  names such as `gaussianBlur`, `medianBlur`, `laplacian`, `canny`,
  `opening`, `closing` and `normalizedDifference`.
- Parallel, partitioned and intermediate Canny stages remain available for
  advanced consumers through `imagery.analysis.primitives` without enlarging
  the default facade.
- Research notes and detailed benchmark evidence are maintained separately in
  [imagery-d-research](https://github.com/alex-1974/imagery-d-research),
  keeping consumer source archives compact.

## Compatibility

The package remains pre-1.0. Direct imports of the primitive module retain
compatibility aliases for `medianFilter`, `laplace`, `open` and `close`.

