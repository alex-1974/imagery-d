# Changelog

## [Unreleased]

### Fixed

- Include DDox styles, scripts and symbol icons in rendered documentation.
  Restore the missing assets on stable and historical Pages and check local
  HTML/CSS resource references before publication.
  ([#230](https://github.com/alex-1974/imagery-d/issues/230))

### Changed

- Rewrite the README and module introductions around caller tasks. Document
  public fields individually and add installation, Levels and feature guides,
  concepts and a glossary. Compile the programs printed in those guides in CI.
  ([#228](https://github.com/alex-1974/imagery-d/issues/228))
- Keep benchmark and qualification evidence in the repository; ship the
  consumer guides and reference with the source package.
  ([#228](https://github.com/alex-1974/imagery-d/issues/228))

## [0.4.0] - 2026-11-24

### Changed

- **Migration:** replace the uninstantiable raw-pointer `copyRoi` spelling with
  the safe validated-window overload. The raw-pointer overload is deprecated
  and disabled. ([#225](https://github.com/alex-1974/imagery-d/pull/225))
- Clarify units, default states, ownership and failure behavior across the
  public API, including direct imports, members and enum values.
  ([#224](https://github.com/alex-1974/imagery-d/pull/224))

### Added

- Reusable feature requests with typed local, path, ridge, line, Gabor, shadow
  and CLAHE settings; bounded tile work; prepared workers; float32 delivery
  with separate validity masks; and revision-aware caching.
- Scale-normalized Hessian lines, structure tensors, geometric cost paths,
  cross-tile components and line runs, RGB indices and histogram matching.
- Mask-aware Lab D50 color SLIC and immutable region graphs with moments,
  shapes, adjacency, boundary evidence, merges and persistent label lineage.
  ([#205](https://github.com/alex-1974/imagery-d/pull/205))
- Registered RGBA8 mosaic assembly with overview selection, explicit filtering,
  linear-light blending, source quality, separate validity, cancellation and
  owned ROI publication. The qualified 60 fps target covers resident 512 × 512
  CPU display sampling; decoding and general fractional filtering have separate
  budgets. ([#218](https://github.com/alex-1974/imagery-d/pull/218))
- Image component/RGB materialization with explicit roles, source geometry,
  color metadata, owned output and memory budgets.
  ([#215](https://github.com/alex-1974/imagery-d/pull/215))

### Fixed

- Preserve unselected and zero-mask float samples during brightness/contrast
  adjustments. ([#225](https://github.com/alex-1974/imagery-d/pull/225))
- Correct scalar SLIC centroid accumulation and Canny frontier handling.
  Bound feature scratch and retain scalar fallbacks for exceptional numerical
  ranges. See the [release notes](https://github.com/alex-1974/imagery-d/blob/v0.4.0/docs/release/NOTES-0.4.0.md)
  for qualification details and limits.

## [0.3.3] - 2026-11-09

### Added

- Expose typed TIFF, PNG and JPEG writers through `imagery.io` and the default
  facade, using `imageio-d ~>0.1.1`, with structured errors, metadata policy
  and atomic TIFF publication.
  ([#179](https://github.com/alex-1974/imagery-d/pull/179))

## [0.3.2] - 2026-11-09

### Fixed

- Resolve default imageio-d and transport-d dependencies from published version
  ranges when using a source archive, without sibling checkouts.
  ([#178](https://github.com/alex-1974/imagery-d/pull/178))

## [0.3.1] - 2026-11-09

### Added

- Read files and URLs through imageio-d and transport-d; select `no-io` when
  the application supplies decoded pixels.
- Add materialization policies, source-quality selection, regular RGBA8 tile
  mosaics, linear-light overlap blending and separate alpha/NoData validity.
  ([release](https://github.com/alex-1974/imagery-d/releases/tag/v0.3.1))

## [0.3.0] - 2026-11-01

### Changed

- **Migration:** use conventional names from `import imagery;`: `medianBlur`,
  `laplacian`, `opening` and `closing`. Import modules directly for advanced
  and partitioned kernels and compatibility aliases.

### Added

- Select overview levels over a common logical extent and report when the
  finest available grid still undersamples the target.
  ([release](https://github.com/alex-1974/imagery-d/releases/tag/v0.3.0))

## [0.2.0] - 2026-10-29

### Added

- RGB8 histograms and ROI statistics, inclusive cumulative counts, integer
  nearest-rank percentiles, contrast-stretch and equalization LUTs. Estimation
  masks select samples; they do not select edit targets.
- Owned RGB8 percentile luminance stretch with color-d sRGB transfer,
  XYZ-D65-Y bounds, clipping policy and an explicit float pixel-payload budget.
  ([#129](https://github.com/alex-1974/imagery-d/pull/129))

### Changed

- Require `raster-d ~>0.5.5` and `color-d ~>0.3.0`; preserve the v0.1.0 Levels
  source contract. ([#129](https://github.com/alex-1974/imagery-d/pull/129))

## [0.1.0] - 2026-10-20

### Added

- Scalar Levels on decoded channels, returning an owned normalized float
  raster with an explicit pixel-payload budget and retained output on returned
  failure. `LevelsError.notAttempted` is the default error state.
- Linux x86-64 source release. macOS and Windows are best effort; pre-1.0 minor
  versions may change source compatibility and have no stable ABI.
  ([release](https://github.com/alex-1974/imagery-d/releases/tag/v0.1.0))
