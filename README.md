# imagery-d

General-purpose image processing in D.

`imagery-d` filters images, adjusts tones, measures image features and combines
image regions. Use it in photo editors, scientific image analysis and GIS
applications. The processing core works on the decoded pixels you supply.

## Status

The current release is [v0.4.0](https://github.com/alex-1974/imagery-d/releases/tag/v0.4.0).
The library is pre-1.0: source compatibility may change between minor releases;
no stable ABI is promised. The package is not registered on DUB yet.

Linux x86-64 is qualified on Ubuntu 24.04 with DMD 2.111.0, 2.112.1 and 2.113.0,
and LDC 1.41.0, 1.42.0 and 1.43.0. The frontend floor is 2.111.0. macOS and
Windows remain best effort, with optional smoke tests rather than release support.
See the [changelog](CHANGELOG.md) for versioned changes.

## Install

Clone the released source alongside your DUB application:

```sh
git clone --branch v0.4.0 --depth 1 https://github.com/alex-1974/imagery-d.git
```

Add this dependency to the `dub.sdl` of a sibling application:

```sdl
dependency "imagery-d" path="../imagery-d"
```

DUB resolves the published dependencies. Use the `no-io` subconfiguration when
working only with decoded pixels; see [installation and configurations](docs/how-to/install.md).

## A first example

Blur a 2-by-2 grayscale image with a Gaussian standard deviation of one pixel:

```d
import imagery : gaussianBlur;

void main() @safe
{
    float[] image = [0, 0.2, 0.8, 1];
    float[] softened = new float[](image.length);
    gaussianBlur(image, 2, 2, 1.0f, softened);

    assert(softened[0] > image[0]);
    assert(softened[3] < image[3]);
}
```

Supply a separate destination with room for every sample and a finite positive
sigma. Dimensions and scale limits are described in the API reference.
For raster views and independently owned results, follow the [Levels tutorial](docs/tutorial/levels.md).

## What is inside

| Area | What you can do | Main entry points |
| --- | --- | --- |
| Filters | Smooth images while choosing how much edge detail to keep | `gaussianBlur`, `medianBlur`, `bilateralFilter`, `guidedFilter` |
| Edges | Measure gradients and produce edge masks | `sobel`, `laplacian`, `canny` |
| Morphology | Grow, shrink and clean binary masks | `dilate`, `erode`, `opening`, `closing` |
| Segmentation | Fill a seeded area or label connected mask regions | `floodFill`, `connectedComponents` |
| Color regions | Create connected color superpixels and measure their adjacency | `tryColorSlic`, `tryBuildRegionGraph` (direct imports) |
| Band indices | Combine aligned bands using declared band roles | `normalizedDifference` |
| Tone and statistics | Adjust levels or derive histograms and luminance bounds | `tryLevelsOwned`, `tryRgbHistogram256`, `tryRgbLuminanceStretchOwned` |
| Compositing | Combine normalized RGBA pixels and raster regions | `sourceOver`, `tryRgbaSourceOverOwned` |
| Overviews and mosaics | Select resolution and combine registered image tiles | `imagery.pyramid.*`, `imagery.mosaic.*` |
| Feature extraction | Reuse local measurements, line responses and geometric paths | `imagery.analysis.feature_regions`, `hessian_lines`, `cost_path` |
| Image I/O | Read supported image regions and write imageio layouts | `openImage`, `writeImageFile` (default configuration) |

`import imagery;` exposes the common operators. Advanced feature, color-SLIC and
region-graph modules use direct imports; see [choosing an API](docs/how-to/choose-an-api.md).
File-format and layout limits are described in the [I/O guide](docs/how-to/image-io.md).

## Documentation

- **Start using the library:** [documentation index](docs/README.md),
  [Levels tutorial](docs/tutorial/levels.md), [installation](docs/how-to/install.md).
- **Understand the data:** [pixels, masks and ownership](docs/concepts/image-data.md),
  [glossary](docs/glossary.md).
- **Look up a contract:** [versioned API reference](https://alex-1974.github.io/imagery-d/v0.4.0/).
  In a Git checkout, run `bash tools/build-docs.sh` and open `build/ddox/site/index.html`.
- **Check numerical and performance limits:** [accuracy and validation](docs/accuracy-and-validation.md),
  [released benchmark evidence](https://github.com/alex-1974/imagery-d/tree/v0.4.0/docs/benchmarks).
- **Work on the implementation:** [code layout](docs/ARCHITECTURE.md),
  [design decisions](docs/adr/), [research companion](https://github.com/alex-1974/imagery-d-research).

## Related libraries

| Dependency | Version range | Responsibility |
| --- | --- | --- |
| [raster-d](https://github.com/alex-1974/raster-d/tree/v0.5.5) | `~>0.5.5` | Raster storage, views, ownership and generic tile mechanics |
| [color-d](https://github.com/alex-1974/color-d/tree/v0.4.0) | `~>0.4.0` | Color models and color conversions |
| [imageio-d](https://github.com/alex-1974/imageio-d/tree/v0.1.1) | `~>0.1.1` | Image decoding and encoding in the default configuration |
| [transport-d](https://github.com/alex-1974/transport-d/tree/v0.2.1) | `~>0.2.1` | File and URL byte resources for default I/O |

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Ddoc style guide](docs/DDOC-STYLE.md).
The project is assisted by AI; release and compatibility decisions belong to its maintainers.
MIT license; see [LICENSE](LICENSE).
