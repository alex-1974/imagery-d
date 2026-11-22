# Changelog

## Unreleased feature program

- Replace variable-window moment/extrema scans with centered separable
  Welford updates and monotone queues, with explicit algorithm identity and
  tolerance-qualified rounding changes.
- Add scale-normalized Hessian line responses with Sato, Frangi and Meijering
  variants, explicit polarity/scales, reserved scratch and independent oracles.

- Add an opt-in benchmark subpackage (`dub run :bench`) for tiled features.
- Inline typed sampling for structural feature kernels.
- Add explicit scalar area reduction, RGB indices, histogram matching LUTs,
  region noise/detail statistics and incremental geometric cost paths.
- Add typed local-statistics and path-morphology parameters to Engine requests,
  including parameter-specific halos, cache identity and provenance.
- Add typed ridge, line-response, Gabor-bank, shadow and CLAHE parameters with
  unchanged default outputs, complete identities and pre-read validation.
- Qualify Gaussian structure tensors over fractional/maximal scales, explicit
  halos, unit rescaling and float32 output; handle isotropy and tiny sigmas.
- Expose settled cost-path predecessors and qualify anisotropic, incremental
  multi-seed searches and bounded-window equivalence without query allocation.
- Reuse path-morphology longest-path updates across each tile, with reserved
  scratch, exact finite-value semantics and signed-zero fallback.
- Add independent OpenCV/scikit-image reference probes and compiler-matrix tooling.
- Add an opt-in prepared float32 SoA worker over scoped raster-d working
  planes, with float64 arithmetic, separate range/validity masks, reusable
  scratch and allocation-free tile evaluation.
- Qualify regional noise/detail measurements against known Gaussian blur,
  independent reductions, affine unit changes, NoData and release timings.
- Correct NaN-initialized float accumulators in Gaussian, bilateral, guided
  and Sobel primitives; prevent Canny wavefront successor loss and reject short
  Gaussian destinations. Add value/connectivity reference regressions.
- Include complete Canny in the feature benchmark and add single-threaded
  OpenCV/scipy/scikit-image timing diagnostics with explicit semantic scope.
- Support typed local/path/ridge/line/Gabor/shadow settings in cooperative
  queued requests and batched feature views, with shared identity/halo
  resolution, canonical-default coalescing and complete subdivided delivery.

## Unreleased

- Update the default `imageio-d` dependency to `~>0.1.1` and expose its typed
  image-writing facade through `imagery.io` and the default `imagery` import,
  including atomic publication, TIFF, PNG and JPEG writer contracts.
- Narrow the default `import imagery;` facade to canonical consumer names;
  advanced parallel and partitioned kernels remain available from
  `imagery.analysis.primitives`.
- Establish the separate `imagery-d-research` companion repository and keep
  long-form research and benchmark evidence out of consumer source archives.
- Canonicalize the primitive spellings `medianBlur`, `laplacian`, `opening`
  and `closing` while retaining direct-module compatibility aliases.
- Begin M5 with deterministic overview-grid selection over a common logical
  extent. The pure, allocation-free API chooses the coarsest level that avoids
  undersampling both target axes and explicitly reports when no available
  level can do so. Pixel resampling, overview generation and mosaics remain
  out of scope.
- Add explicit source-quality selection with deterministic tie-breaking and
  a distinct no-eligible-source result.
- Add regular decoded RGBA8 tile mosaics with nearest-neighbour ROI mapping,
  explicit alpha association, output budgets and retained-owner failure
  semantics.
- Add explicit linear-light sRGB overlap blending with caller-provided u8
  weights, plus a validity policy for one-valid, two-valid and both-invalid
  source pairs.
- Start M6 qualification for deterministic scalar analysis primitives and
  record DMD/LDC M5 qualification receipts; ML adapters remain out of scope.

## v0.2.0 — RGB analysis and luminance stretch

- Add RGB8 histograms and ROI statistics with explicit binary selection,
  retained-result failure behavior and exact per-channel counts.
- Derive inclusive cumulative counts, integer nearest-rank percentiles,
  percentile contrast-stretch LUTs and histogram-equalization LUTs from the
  same histogram record. Masking selects estimation samples, not edit targets.
- Add RGB8 percentile luminance stretch using color-d sRGB transfer and
  XYZ-D65-Y bounds, with an ROI-local owned normalized float result, explicit
  payload budget, clipping policy and optional worker budget.
- Verify the luminance result against an independent P6 byte oracle on
  synthetic and file-consumer fixtures; retain a documented one-byte output
  tolerance for float-to-byte serialization.
- Improve the LDC luminance path with direct output lookup and by-reference
  reuse of color-d's RGB8 decode table. Local full-call measurements are
  documented separately and are not a portable latency promise.
- Upgrade source dependencies to `raster-d ~>0.5.5` and
  `color-d ~>0.3.0`. The published v0.1.0 Levels source contract remains.
- Extend internal M4 validation with SHA-pinned synthetic fixtures and an
  optional real-image RGB histogram check; corpus tools and image bytes are
  excluded from the source package.

## v0.1.0 — Initial release

- Candidate scalar Levels owned-result API for already materialized image channels; `@safe` through one narrowly reviewed `@trusted` malloc/adoption step.
- Explicit `LevelsError.notAttempted` invalid-success default, returned-failure publication semantics and required result pixel-payload budget.
- Scalar gamma-2 sqrt specialization; independent Decimal oracle regression covering 624 deterministic cases, including extreme finite float/selection cancellation.
- Real P6 and paired native Release consumers, rendered DDox, DIP1000 and non-exposed Into negative compile gates.
- Source-archive DUB consumer verified outside the Git checkout on DMD/LDC, Debug/Release.
- General-image scope (ADR 0005), first Levels priority (ADR 0004) and
  narrow source-API acceptance (ADR 0006) are documented.
- Initial Linux x86-64 release; macOS and Windows are best effort.
- Pre-1.0 source compatibility may change in future minor versions;
  no stable ABI is promised.
