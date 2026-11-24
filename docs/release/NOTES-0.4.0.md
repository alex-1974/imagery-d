# imagery-d v0.4.0

This pre-1.0 source release expands reusable image analysis and bounded
execution above raster-d. It serves photographic, scientific and geospatial
consumers without requiring geographic metadata for general image operators.

## Highlights

- Typed, cooperative and batched feature requests share tiled dependencies
  and retain explicit masks, parameters, provenance and memory budgets.
- Color SLIC partitions RGB images in Lab D50. Immutable region graphs expose
  region measurements, adjacency, boundary evidence, merges and label lineage.
- Prepared Canny, local statistics, geometric paths and Gaussian-derived
  structure operators reuse bounded working storage. Full-precision defaults
  remain; Float32 output and optional CPU targets are explicit choices.
- Registered multiresolution mosaics combine supplied geometry, quality,
  validity and weights with cancellation-safe owned output. Materialization
  preserves declared component geometry, color roles and native lifetimes.
- Public Ddoc describes units, initialization, ownership and error behavior,
  with executable examples and rendered-symbol coverage checks.

## Corrections and migration

Brightness/contrast changes only selected channels. Unselected or zero-mask
floating samples retain their exact bits, including nonfinite values and
signed zero.

The old raw-pointer `copyRoi` overload is deprecated and disabled; it was
uninstantiable. Use the safe overload with a validated raster plane window
inside `withPlane`. It validates the ROI and destination before writing and
supports signed strides without retaining the borrow.

## Boundaries

Source compatibility may change in later pre-1.0 minor releases; no stable ABI
is promised. Linux x86-64 is supported; macOS and Windows remain best effort.
The package is distributed as GitHub source, without new DUB registration.

The measured 60-fps result covers named resident 512-by-512 display workloads,
not decoding, network access, arbitrary filters or complete application
latency. Optional x86-64-v3/native experiments do not raise the portable CPU
floor. See the workload-specific benchmark receipts for numerical and timing
limits.

This release does not claim reviewed Dunia multi-tool scene acceptance,
general source scheduling, CRS transformations or semantic object recognition.
The released imageio-d 0.1.1 has known real RGB GeoTIFF depth/stride limitations;
its separate decoder fix must be released and qualified before that path is
promised. General image processing and no-io consumers are independent of
that application-specific decoder acceptance.
