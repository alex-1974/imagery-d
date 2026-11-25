# Read and write images

Use imagery's default configuration when the application needs file or URL
helpers. Call `openImage` for a requested region or `openImageBest` when the
request also specifies a target size for overview selection. The caller supplies
the path/resource and region; imagery does not own application scheduling.

## Turn decoded components into processing inputs

An opened region carries imageio's decoded component data and its range plan.
Choose the conversion before giving those components to an image operator:

| Required input | Use |
| --- | --- |
| A retained integer raster | `materializeUbyte` or `materializeUshort` |
| Separately owned native planes | `materialize` with a native-plane specification |
| RGB on a common grid | `materializeRgb!Spec` or the owned RGB materialization API |
| A temporary inspection of decoder planes | `visitNativePlanes` inside its synchronous callback |

With `ValidatedMaterializationSpec`, declare the component model, nearest or
bilinear upsampling, and output representation separately. For example,
`YCbCrModel` assigns component roles and a color-d conversion policy; it does
not identify those roles from byte values. Source geometry, sample siting and
color metadata must satisfy the selected specification.

Keep decoder storage alive for borrowed inspection. Choose an owned
materialization when the raster must survive release or reuse of the decoder's
storage. See [ownership](../concepts/image-data.md#ownership-and-borrows).

## Write an output image

`writeImageFile`, `writePng`, `writeJpeg` and the TIFF writer names are forwards
to imageio-d. Supply the layout, sample representation, metadata and byte sink
that the selected writer requires. Use `ImageWriteResult`/`ImageWriteError` to
inspect the result; `MetadataPolicy` controls metadata handling. Atomic TIFF
file publication uses `writeAtomically`.

These calls do not infer a color conversion from an arbitrary imagery raster.
Convert or pack samples into the writer's required representation first.
The definitive signatures and ownership/error rules are in the
[imageio-d v0.1.1 source reference](https://github.com/alex-1974/imageio-d/blob/v0.1.1/source/imageio/io.d).

## Format and layout limits

The default dependency is imageio-d `~>0.1.1`. Support depends on the selected
format, sample layout and component metadata. Released 0.1.1 rejects some real
GDAL RGB GeoTIFF depth/stride layouts; successful grayscale handoff does not
establish support for those RGB files. Check the decoder result before
materializing it. CRS transformations and application-specific interpretation
of geographic or spectral metadata remain with the application.
