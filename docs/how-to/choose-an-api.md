# Choose an image-processing API

Choose an entry point by the data you already have and how you need to keep
the result. Common operators are exported by `import imagery;`; the reusable
feature engine and specialized analysis modules use direct imports.

| Your input and task | Start with | Result/storage |
| --- | --- | --- |
| A dense scalar array to smooth | `gaussianBlur`, `medianBlur` | Preallocate a separate destination array |
| A dense image to differentiate | `sobel`, `canny` | Supply gradient arrays or a byte edge mask |
| A byte mask to clean or label | `opening`, `closing`, `connectedComponents` | Supply destination/label arrays |
| A borrowed raster view to adjust | `tryLevelsOwned`, `tryBrightnessContrastOwned` | A new ROI-local float raster, with a pixel-payload budget |
| Decoded RGB8 pixels to measure | `tryRgbHistogram256` | A histogram record with explicit status |
| Repeated region features | `Engine` from `imagery.analysis.feature_regions` | Shared input preparation and bounded tile/cache storage |
| Repeated scalar tiles with prepared buffers | `Float32FeatureWorker` | Borrowed float32 planes with separate validity masks |
| Thin-line response at declared scales | `hessianLineResponse` from `imagery.analysis.hessian_lines` | Caller-provided results and reusable workspace |
| Color superpixels and adjacency | `tryColorSlic`, `tryBuildRegionGraph` | Explicit label storage and an owned immutable graph |
| Geometric paths over a cost image | `CostPath` or `LazyCostPath` | Reusable search state over owned or lazily evaluated costs |
| Registered decoded RGBA tiles | `imagery.mosaic.multiresolution` | Owned ROI output or scoped display output |

The scalar `slic` exported by the basic segmentation module is a separate
grid-clustering baseline. Use `imagery.analysis.color_slic` for color SLIC in
Lab D50 and the connected region-graph workflow.

Before calling an operation, read its Ddoc contract for the sample domain,
input/destination overlap, failure behavior and default state. A returned status,
a valid numeric result and a valid orientation are separate facts; see
[image data](../concepts/image-data.md).
