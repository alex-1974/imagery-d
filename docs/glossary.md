# Glossary

| Term | Meaning in imagery-d |
| --- | --- |
| Alpha association | Whether RGB stores straight color or color already multiplied by alpha. The caller declares it. |
| Band | One named measurement/channel supplied by the caller, such as red or near-infrared. The library does not identify a physical band from its position. |
| Borrow / borrowed view | Temporary access whose owner must remain alive. For raster types, use the [raster-d view contract](https://github.com/alex-1974/raster-d/blob/v0.5.5/source/raster/view.d). |
| Color encoding | The relationship between stored channel numbers and color values, such as encoded sRGB versus linear-light RGB. |
| Feature | A selected image measurement, such as a local mean or line response. Its descriptor defines channel meanings and units. |
| Grid | The alignment and dimensions used to interpret sample positions. A grid identifier is caller metadata, not a CRS transformation. |
| Halo | The neighboring input pixels needed around an output region. A one-pixel derivative stencil has a one-pixel halo. |
| Level / overview | A caller-described resolution of an image. A level identifier does not by itself specify a scale factor. |
| NoData | A sample declared unavailable or unusable by the source. Numeric zero is not automatically NoData. |
| Output parameter | An argument in which a call writes its result. Failure/reset behavior is stated per operation; API parameters named `published` still refer to this role. |
| Owned result | A result with storage ownership sufficient for its documented independent lifetime. Raster ownership belongs to [raster-d](https://github.com/alex-1974/raster-d/tree/v0.5.5). |
| Payload budget | A limit on the bytes or counts named by an operation, not automatically a limit on total process memory. |
| Planar output | Separate arrays for feature channels and validity. Array entries use the documented row-major pixel indexing. |
| Provenance | The source identity, revision, grid, parameters and other facts attached to a result so that its origin can be distinguished. |
| Region of interest (ROI) | A rectangular subset of an image, expressed in the coordinate system required by the operation. |
| Revision | A caller value that changes when source samples or validity change. It distinguishes versions of the same source identity. |
| Selection mask | A mask whose role is declared by the operation: estimation membership or graded editing coverage. See [mask roles](concepts/image-data.md#three-kinds-of-masks). |
| Sink | A callback that consumes completed output synchronously. It must honor the result's borrow/lifetime contract. |
| Working memory | Temporary arrays or reserved buffers used to compute a result. Public names containing `Scratch` or `Workspace` keep their actual API spelling. |

For sample domains, validity and budget examples, see [image data](concepts/image-data.md).
