# Changelog

## Unreleased feature program

- Fix brightness/contrast channel selection, preserving unselected and zero-mask
  float samples exactly. Add a safe validated-window ROI copy; deprecate and
  disable the previously uninstantiable raw-pointer copy spelling (#222/#223).

- Review the complete public Ddoc surface, including direct imports, members
  and enum values; clarify units, default states, ownership and error behavior.
  Add executable consumer examples and compiler-JSON/rendered-page gates.
  Record existing copyRoi instantiation and brightness channel-selection
  defects separately as #222 and #223.

- Add optional scoped Float32/Float64 scalar Source windows with exact Sample
  fallback, transactional planar cache-buffer transfer and checked frame copies.
  Separate library publication and complete consumer materialization clocks.
- Evaluate Hessian/tensor with bounded two-dimensional Gaussian blocks,
  ordered fused derivatives and exact vector sqrt geometry; add explicit
  shape-aware scratch reservation while retaining legacy full-plane reserve.

- Qualify optional portable/v3/native LDC code generation with paired kernel
  measurements, full vectoriser remarks and per-target independent references.
  Keep the portable default and add the optional v3 reference job to CI.
- Traverse vertical Hessian/tensor taps across contiguous rows without changing
  per-pixel reduction order; retain the horizontal scalar transpose oracle.
- Compute path opening/closing with bounded row-wise grayscale dynamic
  programming and exact final Float32 min/max projection, retaining full
  scalar fallback and the previous DAG reference. Accelerate normalized local
  statistics with Float64 shifted running sums and centered rebase/fallback;
  preserve exact single/batched request identity and version the window recipe.
- Add paired Engine/worker/phase budgets, an independently validated aligned
  Canny C comparator, bounded noisy-host retries and bootstrap/MAD receipts.
  Add deterministic protocol self-tests and a manual instruction/cache canary.
- Reuse serial Engine scratch and bounded cache backing arrays; add explicit
  planar float32 delivery with full-precision dependencies and separate masks.
  Share validated row kernels with prepared workers: unrolled basic stencils,
  median selection network and tap-major oriented filters with scalar fallback.
  Store shared scalar working samples in separate double/validity planes.
  Offer explicit Gaussian32 preparation with a separate float32 error bound.
- Add transactional prepared global Canny and lazy/windowed geometric paths
  with epoch resets, compact local state and unchanged float64 distance rules.
- Add separate fixed target, computed-work allocation and isolated-worker
  scaling gates with generated reports; preserve pending target admission.

- Add mask-aware Lab D50 color SLIC with local search, connected cleanup,
  caller/file-backed assignments and transactional graph/label publication.
- Add immutable region graphs with complete moments/shape/coverage, CSR
  adjacency, boundary evidence, adjacent merges and persistent label lineage.
- Specialize exact single-source display sampling, validate destination planes
  per block and add scoped private display-buffer reuse. Qualify the documented
  resident 512² CPU target separately from decoding and general filtering.

- Qualify caller/file-backed cross-block component IDs, separate validity,
  statistics, contacts and line runs. Add transactional staged publication,
  structured errors, scratch budgeting and cancellation. Suppress spurious
  principal axes for symmetric regions; reject overflowing statistics.

- Harden imageio component/RGB materialization: preserve crop/source geometry,
  validate roles and matching color metadata before allocation, use declared
  sample centers and retain bilinear precision until color conversion. Add a
  safe single-buffer owned path with budget/rollback/provenance and explicit
  native inspection lifetime. Qualify real JPEG planes and a GDAL GeoTIFF
  handoff; isolate the upstream RGB TIFF depth/stride fix in imageio-d PR #26.

- Add opt-in bounded registered RGBA8 mosaic assembly: overview selection,
  explicit nearest/bilinear/area filtering, linear premultiplied color, spatial
  quality factors, separate validity and cancellation-safe owned ROI publication.
  Bound tile/work buffers and copy only needed source rectangles; preserve
  independent partition/layout equality and prior owners on failure. General
  fractional filtering remains outside the qualified resident 60 fps scope.

- Qualify arbitrary-source quality weights with Decimal references and explicit
  alpha/NoData/provenance policy. Use scaled products and compensated sums in
  the common case, retaining logarithmic fallback for lost intermediate range.

- Add mixed-family FeatureViewParams with shared input preparation and complete
  validation. Calculate combined tile work payload before allocation and adapt
  tile size to preserve 8 MiB even at maximal combined filter supports.

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
- Correct NaN centroid sums in the scalar grid-clustering baseline and add
  exact independent four-pass label maps. The separate color-SLIC and region
  graph APIs above provide the full-domain region implementation.

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
