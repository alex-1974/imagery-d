# Code layout for maintainers

Use this map to find an operation's public entry point and the implementation
that supports it. Caller-facing choices are documented in
[choosing an API](how-to/choose-an-api.md); this page is for changing the code.

| Source area | Responsibility |
| --- | --- |
| `imagery/package.d` | Common public imports |
| `imagery/presentation/` | Levels, brightness/contrast, exposure and curves |
| `imagery/analysis/{filters,edges,morphology,segmentation,indices}.d` | Small navigation modules forwarding common operators |
| `imagery/analysis/primitives.d` | Shared basic implementations and advanced staged/parallel forms |
| `imagery/analysis/feature_regions.d` | Source/result contracts, region engine and feature descriptors |
| `imagery/analysis/feature_parameters.d`, `feature_requests.d` | Typed settings and cooperative requests |
| `imagery/analysis/feature_worker32.d` | Prepared scoped worker interface |
| `imagery/analysis/{row_kernels,window_kernels,path_kernels,feature_structure,feature_output32}.d` | Shared implementation calculations and output policies |
| `imagery/analysis/{color_slic,feature_components,region_graph}.d` | Color clustering, connected labels, measurements and adjacency |
| `imagery/analysis/{structure_tensor,hessian_lines,cost_path,lazy_cost_path}.d` | Specialized analysis with explicit workspaces |
| `imagery/compositing/` | Alpha/validity-aware compositing |
| `imagery/pyramid/`, `imagery/mosaic/` | Overview policy, quality/validity and registered image assembly |
| `imagery/materialization.d`, `imagery/io.d` | Conversion specifications and default imageio integration |

raster-d owns raster storage, views, layouts and generic tile mechanics;
color-d owns color models and conversions. Keep image-domain calculations here
without introducing a second raster owner, decoder or application scheduler.
The [ADRs](adr/) record decisions and boundaries.

## Documentation and verification

Source Ddoc is the public contract. Module introductions identify the caller's
starting points; detailed mathematical/lifetime requirements remain attached to
the symbols that need them. Internal helper modules point applications to the
public interface rather than exposing a second application entry point.

Tests are grouped by contract, consumer behavior, corpus, precision and
performance. Documentation programs are extracted from their Markdown source;
public Ddoc examples run in the module suites. The compiler-JSON gate checks
public declarations before rendering and verifies the generated symbol pages.
See [CONTRIBUTING](../CONTRIBUTING.md) for exact commands.
