# M6 feature regions — first slice

This is the selection and qualification plan for [issue #182](https://github.com/alex-1974/imagery-d/issues/182). The [feature-region module](../source/imagery/analysis/feature_regions.d) implements the region kernels and sequential cache. The [executable harness](../experiments/m6_feature_regions/README.md) qualifies the module through both library configurations.

## Scope

The feature layer serves photography, scientific imaging, remote sensing and other image processing. Dunia Vision supplies the first integration workload. Feature definitions use declared sample and channel semantics. Physical quantities retain their declared units, and calibrated samples require explicit mapping before any operator that expects a normalized domain. Grid geometry may be expressed in pixel coordinates, physical coordinates or a georeferenced grid, according to the source.

Spatial operators should work on explicitly selected scalar planes with a declared numeric domain and validity. Photographic color operations use explicitly declared RGB encoding. Monochrome and scientific multiband sources can supply a scalar band without RGB conversion. Qualify further input formats and operators incrementally. The first RGB8 experiment fixes one reproducible input contract.

Add an independent photographic fixture for color and contrast, and a synthetic masked scalar fixture with declared units for scientific-image qualification. Check that scalar statistics retain the input units and that the selected band, sampling grid and validity appear in provenance. These cases complement the Dunia Vision integration workload.

## Consumer and input

Use two Dunia Vision requests on the same image revision and overlapping regions. A path review requests local contrast and gradient, while a shoreline review requests OKLab and gradient. Both consume the same gradient definition and can reuse completed results for identical regions. The initial harness can exercise these requests using an in-process consumer. Actual Consumer validation takes place during integrated acceptance in #187, after all implementation stages have been merged into `develop`.

Start with a region-readable, common-grid RGB8 source with declared sRGB encoding and an explicit binary validity plane. RGB channels share an extent and sampling grid. A source revision identifies immutable samples, metadata and validity for the duration of a request. Keep source identity, revision, analysis extent, grid and level in provenance. Carry spatial metadata when supplied. Use raster-d 0.5.5 for its region, view and storage contracts and color-d 0.4.0 for color math.

## Feature and region contracts

| Output | Definition | Input halo |
|---|---|---|
| Linear luminance | Rec. 709 luminance coefficients applied to decoded linear sRGB | 0 |
| OKLab | Linear sRGB to XYZ D65 and OKLab through color-d | 0 |
| Global distribution | 256 fixed-width bins on linear luminance in [0, 1], including 1 in the last bin. Reduce over the declared analysis extent and count valid samples only. Per-bin counts are exact. Report percentile bins using nearest rank. An empty distribution has no percentile. | 0 per scanned block |
| Local brightness and contrast | Mean and population standard deviation over a 7 × 7 window of valid luminance samples. Require a valid center and at least 25 valid positions. | 3 |
| Gradient strength and orientation | 3 × 3 Sobel derivatives scaled by 1/8, Euclidean strength and atan2(dy, dx) in radians, with x right and y down. Require every stencil position to be valid. Direction is invalid for zero magnitude. | 1 |

Clamp coordinates at the true source boundary for the neighborhood operators. The validity of a clamped sample follows the same coordinate mapping. Halo samples at internal region boundaries come from the source. Each output carries its own validity. The output payload at invalid positions is unspecified. Emit only the requested target region, using bounded processing tiles internally. Provider tile, feature cache region and processing tile are separate geometries.

The first staged implementation may calculate the features independently. Share the luminance intermediate within work for a single tile when the same request needs it. Compute the global distribution in an independent blockwise pass when requested, with a fixed-size accumulator. Keep output feature IDs and parameter versions explicit while validating the contract internally.

## Qualification

1. Implement a small independent whole-image reference using direct window loops. Use known color vectors, uniform fields, horizontal and vertical ramps and a hand-counted masked histogram to verify semantics independently of decomposition.
2. Compare that reference with region requests using non-origin, odd-sized, thin and overlapping regions, several tile sizes, strided inputs, masks and true source edges. Compare validity masks and counts exactly. Use absolute tolerance 1e-6 for normalized scalar features and 1e-5 radians for cyclic angle distance on fixtures with a well-resolved gradient. Include separate assertions for zero strength and undefined direction.
3. Run DMD correctness checks for the supplied-image path and validate the consumer against both supported library configurations. Start with sequential execution and processing tiles of up to 256 × 256. Set an initial working-set target of 8 MiB for the analysis engine, excluding the test fixture, caller-retained results and cache. Account for source read buffers, halo, intermediates, scratch and the unpublished output. Measure any source-owned buffers separately. Deliver results through a region sink so larger requests can be consumed within budget.
4. Replay the two requests with an internal result cache capped at 16 MiB. Key by source identity and revision, grid/level, output region, feature identity, parameters and implementation version. Track caller-retained result lifetime separately. Exercise hits, misses and revision changes. If concurrent requests share computation in this slice, exercise subscriber cancellation and publication of completed results.
5. Use the manifest-pinned Earth image at `data/m4/land_ocean_ice_2048.jpg` for initial realistic LDC Release measurements, with decoding and analysis timed and accounted for separately. For the bounded-residency check, provide a region-readable fixture and vary total source dimensions independently of tile size. Record compiler versions, commands, input identity, allocation counts, peak working set and cold/warm request timings. Use an actual Dunia Vision scene during integrated Consumer validation in #187.
6. Review the measured contract and document the production API decision in an ADR.

The initial radius, sample threshold, numerical tolerances and budgets are experiment parameters. Workspace-wide documentation under `.workspace/` was unavailable when drafting this plan. The repository roadmap and ADRs supply the qualification rules.

## API admission review

The experiment validates two interfaces as candidates for production. A synchronous reader supplies a requested input region in caller-provided storage. A scoped sink receives each completed output region, its feature values and per-feature validity, and provenance. Provenance includes the source and revision, grid and level, selected band and its input unit, output extent, feature ID and implementation version. The histogram returns the same provenance for its analysis extent. Parameter changes must change the identity used for reuse. The descriptor identifies fixed parameters explicitly and includes an implementation version. Fitted operations carry the applied profile alongside the fixed settings.

The sink borrows data only for the callback. A caller that needs to hold results must retain its own copy. A reader failure aborts the request, with previously delivered tiles remaining valid. A failed tile cannot be published before its computation completes. The sequential experiment exercises a private exact-tile cache and a synchronous reader. Cache accounting measures live entry data and the process measurement records runtime overhead separately.

Admit the synchronous reader and sink as an opt-in module at `imagery.analysis.feature_regions`. The caller adapts its raster views or other bounded source to the reader by filling scoped, row-major scratch. This allows RGB and scalar sources with different layouts without attaching source or cache state to a raster view. The module uses raster-d's region representation. The engine owns its scratch and cache and cannot be copied.

The harness imports the library module in both default and no-io configurations. DMD's DIP1000 preview additionally checks scoped access in no-io. Applying that preview to every dependency in the default configuration exposes existing errors in transport-d 0.2.1. The ordinary default build and checks pass. The full consumer validation runs through #187 after the implementation is integrated into develop.

## M6 radiometry follow-up (#183)

The histogram pass also computes the global mean and population variance over valid linear luminance. Both are NaN when the extent has no valid samples. Fit a global luminance profile once on an explicit analysis extent using valid RGB8 samples and the existing 256-bin histogram. Percentiles are integral nearest ranks in 1 through 100. The low bin's lower edge and high bin's upper edge define the interval. An empty distribution or two ranks in the same bin cannot supply a usable profile.

Apply the profile to any requested region on the same source revision and grid. The output is dimensionless analytical linear luminance clipped to [0, 1]. Its validity comes from the source and its provenance includes the analysis extent, fitted bounds and percentile parameters. The input image remains unchanged. Every region uses identical bounds, including at tile seams. The engine can reuse cached linear luminance. The normalized output adds at most one reusable tile buffer (2 MiB at a 256-pixel tile edge on x86-64). Actual Consumer validation remains part of #187.

### Fixed local operators

The operators use the same source-edge clamp and per-output validity as the first slice. These parameter sets define the first implementation version.

| Feature | Definition and validity | Halo |
|---|---|---:|
| Local normalization | Center minus 7×7 mean, divided by population standard deviation. A constant valid neighborhood yields zero. | 3 |
| Dynamic range | Valid maximum minus valid minimum over the same 7×7 window. Both 7×7 operators require a valid center and at least 25 valid positions. | 3 |
| Box, Gaussian, median | 3×3 uniform mean, separable binomial weights [1, 2, 1] (a compact Gaussian approximation), or median. Require a valid center and at least five valid positions. Weights are renormalized over valid positions. | 1 |
| Bilateral | The Gaussian weights multiplied by a range weight with sigma 0.1 in linear luminance. Same validity rule as the 3×3 filters. | 1 |
| Anisotropic diffusion | One four-neighbor step with time step 0.2 and exponential conductance with scale 0.1. Require all five cross positions to be valid. | 1 |
| Laplace and sharpness | Four-neighbor Laplacian and its absolute magnitude. Require all five cross positions to be valid. Sharpness measures local high-frequency response and is an indicator for blur evaluation. | 1 |
| Noise | Median absolute deviation from the median of the valid 3×3 samples. Same validity as the 3×3 filters. This local dispersion indicator also responds to texture. | 1 |
| Clipping and underexposure | Separate binary flags for any encoded RGB channel at 255 and linear luminance at or below 0.01. | 0 |

Bilateral, diffusion, clipping, underexposure, exposure matching and CLAHE use RGB8/sRGB because their parameters are defined on encoded RGB8 or normalized linear luminance. The other neighborhood operators also support scalar measurement channels. Smoothing, local brightness, Laplace, sharpness, noise and range use the scalar's input units on the pixel grid. Local normalization is dimensionless. The quality features are deterministic indicators and carry their own validity.

### Exposure matching and CLAHE

Exposure matching uses two usable profiles fitted with the same percentile ranks. It clips the source at its fitted bounds and maps that interval linearly to the reference interval. Output provenance records both profiles. It addresses luminance exposure only.

CLAHE uses 32×32 source-anchored cells, including partial cells at the right and bottom. It histograms valid pixels in 256 bins and caps each bin at ceil(2 × valid count / 256), with a minimum cap of one. It redistributes excess uniformly, spacing remainder increments across the histogram, and uses the resulting cumulative fraction. Constant cells preserve luminance. Each output blends the maps at the four nominal surrounding cell centers and renormalizes weights across nonempty cells. The source validity mask propagates to the results. Neither cell geometry nor interpolation depends on the requested region or processing tile edge.

At the 256-pixel processing tile limit, neighborhood operators use at most 4,293,760 bytes of reusable tile buffers. The scalar filter scratch is at most nine doubles per operator invocation. Exposure matching adds one reusable 2 MiB output tile. CLAHE adds the same output tile, one 32×32 source cell and up to 100 fixed-size cell maps, for less than 6.3 MiB of combined tile and cell storage on x86-64. Cache retention is budgeted separately. CLAHE reads only the cell data required for each output tile and discards its cell maps after each processing tile.

## M6 overview and interactive execution (#184)

`imagery.analysis.feature_overviews` selects among caller-supplied region-readable grids covering the same logical extent. The existing overview selector is the authority for level ordering and avoiding undersampling. The adapter returns the selected reader and resolution along each axis relative to the finest pixel grid. Feature provenance carries the selected level, grid identity and grid dimensions. Physical or geographic resolution follows from the caller's grid metadata.

`resampleFeatureSource` creates an explicitly requested same-extent grid. It maps target pixel centers back to source centers and clamps at the true parent image edge. Nearest selects the higher coordinate on an exact tie. RGB stays encoded RGB8 under nearest. Scalar bilinear interpolation uses a 2×2 window, requires valid finite samples at each nonzero weight, and retains the band's unit. Both readers fill caller-provided tiles and use at most four source samples at a time. Resampling identity includes the parent grid and level, source and destination extents, policy and implementation version. The explicit display resampling scope, including area reduction, remains in #144. Resampling and quality-weighted assembly of decoded mosaics remain in #148.

The tile descriptor defines input kind, scalar dependency, halo and implementation version. The tiled operators convert to scalar luminance or consume a selected scalar band only when needed. Histogram-driven exposure and CLAHE request luminance through the tile engine, and their own parameters are applied after luminance lookup. The same exact tile identity drives completed-result reuse and single-flight grouping. It contains source identity, revision, grid, band, units, level, dimensions, encoding, region, feature and implementation version. Fixed operator parameters are explicit key fields, alongside the implementation version. Spatial metadata and the resampling policy also participate in the key. Fitted output transformations have explicit profile provenance and reuse the underlying luminance cache.

`imagery.analysis.feature_requests` is a cooperative event-loop queue for fixed tile operators. The caller submits tiles up to 256×256 and pumps one tile at a time. Passing the same key joins the pending or running job. Priority is the highest active subscriber priority, with visible work ahead of background work and FIFO among tied priorities. Capacity is 32 jobs and 128 subscribers. A zero token signals that the caller can retry later. The queue holds its own fixed request records and references to the caller's readers and closures. Callers may partition larger viewports or cancel outside the visible extent as they pan.

Cancellation removes one subscriber and skips queued work with no remaining subscribers. A synchronous source read can run to completion after cancellation. Completed tiles remain eligible for cache reuse and cancelled subscribers receive no callback. Computation failure publishes no result and notifies remaining subscribers with the error. Submitting the same key again can retry a failure. The event-loop contract requires serial access to queue methods. Source reads and callbacks run on the pumping thread, so an application can place the queue on its own worker to keep a UI responsive. Priorities take effect at tile boundaries.

Core tile buffers require at most 4,293,760 bytes and dispatch keeps at most one additional 2 MiB completed tile. The accounted live cache cap remains 16 MiB. Neither request storage nor scratch grows with the full dataset extent. This budget excludes caller-owned sources, callback state and runtime allocator overhead. Actual Consumer validation remains in #187 after the final integration into develop.

## M6 multiscale structure (#185)

The fixed tile descriptors are the source of truth for each input halo. Structural and evidence planes preserve invalid centers. All offsets are evaluated on the source grid with its normal edge clamp. Scale values are in pixels of the selected level.

| Operator | Output contract | Halo |
|---|---|---:|
| Entropy | Shannon entropy in bits over 16 linear luminance bins in a 7×7 window, with at least 25 valid samples | 3 |
| LBP | Eight neighbors clockwise from northwest, bit set when the neighbor is at least the center | 1 |
| GLCM | Contrast, energy and homogeneity of a symmetric, horizontal, one-pixel cooccurrence matrix. Use the same 16 bins and at least 21 valid pairs in the 7×7 window | 3 |
| Central edges | Signed central difference projections at 0°, 60° and 120°, or edge density at threshold 0.05 and normalized axial orientation histogram over 5×5 centers | 1 or 3 |
| Gabor | Quadrature magnitude, normal angle and wavelength. The bank has wavelengths 2 and 4 at four angles. Each member is independently addressable. The aggregate selects the strongest member with deterministic ordering. The response measures differences from the center and is zero for a constant plane | 2 or 4 |
| Ridge and line response | Positive center-minus-opposite-sides contrast at radii 1, 2 and 3 across four directions. The line feature additionally requires positive response along three neighboring positions. Return strength, tangent angle and radius separately | 3 or 4 |
| Erosion, dilation | Square radius 1 min/max with complete validity support | 1 |
| Opening, closing, hats | Two square radius 1 passes. The top hat subtracts the opening from the original, and the bottom hat subtracts the original from the closing | 2 |
| Directional opening, closing | Separate horizontal, vertical and southeast-diagonal length-three responses | 2 |
| Square morphology profiles | Separate outputs at radii 1, 2 and 3 | 6 |
| Path opening, closing | Maximin or minimax over seven-sample paths containing the center. Each step advances along one principal axis and may move one pixel laterally. Require at least one complete valid path | 6 |

The tile engine uses three heap buffers for each noncached region request and reuses them across processing tiles. Profile and path operators add only fixed local scratch. The Gabor bank is precomputed as an immutable table. Filter use and units are independent of application interpretation.

## M6 connectivity and region output (#186)

`feature_components` labels a fixed analysis extent in scan order and joins provisional labels across block boundaries. Four- and eight-neighbor connectivity are explicit. The canonical component ID is the smallest provisional ID of the connected set. Changing block size preserves IDs for the same analysis extent and inputs. Seed filtering keeps only components containing a marked seed and supports seeded growth or Canny hysteresis.

`feature_segmentation` supplies masked OKLab or scalar candidates, as well as weak and strong candidates from Sobel, non-maximum suppression and two thresholds. A color-distance constraint controls single-link merging. A source-anchored cell constraint yields grid-constrained superpixels. These are deterministic connected regions with a hard cell constraint. Shape, color, valid texture and valid edge statistics are accumulated after label resolution. The interface streams ordered region pairs once per shared pixel side for caller aggregation. `traceLabelLines` reports maximal labeled runs on four lattice directions. It produces straight segments on those directions.

Callers provide read/write label storage, which may be disk-backed. The provisional store and streamed contact data are usable after the computation succeeds. Its size follows the analysis extent. In-memory engine scratch follows the explicit label budget and fixed 256-pixel scan support. If the component limit is exhausted, the call fails and leaves provisional data for the caller to discard. Source adapters bound feature tile reads and use a private 16 MiB feature cache. Canonical label zero covers excluded pixels. An optional validity writer distinguishes NoData from valid pixels excluded by policy or seed filtering.

## M6 spectral and quality evidence (#187)

`feature_evidence` requires scalar bands on the same declared grid and level with matching sample domains and units. Pairwise difference retains the input unit and ratio is dimensionless. Zero denominators, invalid or nonfinite samples and out-of-range unit reflectance yield invalid output. Vegetation response uses (NIR − red)/(NIR + red). Water response uses (green − NIR)/(green + NIR). These signed spectral measurements are in [−1, 1] and require declared roles and unit reflectance. Every tile carries provenance for both band revisions and the common grid. The three reusable buffers for pairwise features total 3 MiB at 256×256 on x86-64.

The RGB engine also provides relative darkness against the local mean and a shadow candidate that weights it by low absolute luminance. Visibility evidence is an exposure indicator based on saturation and low luminance. Edge evidence scales Sobel strength from 0 to 1. Region evidence reports pixel compactness and valid edge/texture coverage. NoData is distinct from a valid zero response. The outputs describe image measurements and heuristic evidence. Application-specific memberships belong to Dunia Vision.

Local acceptance uses synthetic reflectance with known results and the real RGB scene for image evidence, segmentation and channel arithmetic. Actual validation with several Dunia Vision tools follows the integration of the implementation into develop.

### Square morphology execution

The compound square operators use separable extrema passes and two tile-local intermediate buffers. Source-edge extension happens in the input reader and intermediate validity propagates through both passes. Path and directional variants use their own kernels. For the maximum 256-pixel tile edge and radius-three profiles, the combined tile buffers use 6,617,280 bytes on x86-64, within the 8 MiB work budget. The operator definition and result provenance are identical to the original square reference.


## Consumer contract after review

Use `describeFeature` for fixed operator settings, declared dependencies, access shape, halo, selected level, storage, channel names and ranges, units, cost and validity. `runFeatureView` takes the consumer's requested tile feature IDs, validates the selection before emission and streams feature-tagged tiles. Dedicated reductions, CLAHE and profile operations keep their explicit entry points. This is the supported M6 integration layer on develop. The lower-level structure kernel and component research details do not carry a frozen compatibility promise. Stable general analysis APIs keep their own contracts.

Tile features, profiles, CLAHE and spectral outputs in this layer are analytical planes. Presentation and image-product transforms use their dedicated APIs. Linear luminance derived from sRGB8 is dimensionless. Channel descriptors with source-relative units resolve against the source unit for scalar measurement bands. Local standardization, spectral ratios and spectral normalized differences are dimensionless. Luminance-based evidence scores are heuristic. Output masks distinguish valid zeros from missing results.

Sobel orientation is directed modulo 2π. Gabor normal orientation and ridge or line tangent orientation are axial, with zero equivalent to π. Strength, orientation, scale and validity have distinct fields. Zero strength leaves orientation undefined. Every exposed Gabor member has named wavelength, angle and sigma. Structuring elements, offsets, boundary rules and radii are fixed settings recorded with results. Float64 remains the computed and cached representation.

Sources can declare scalar or sRGB8 encoding, a measured or spectral band role, CRS, pixel-corner affine and physical pixel spacing with its unit. The original RGB flag supplies the encoding for existing callers. A scalar plane may carry linear luminance or scientific measurements without transfer decoding. A resampled source records the parent grid and policy and updates its affine basis vectors and declared spacing. Grid or georeference equality is caller-declared and checked for aligned spectral operations. The source reader supplies the validity mask. Scalar processing also rejects nonfinite values.

The queue exposes its 32-job, 128-subscriber, 256-pixel tile and 16 MiB cache limits as named contract constants. Cancellation applies per subscriber and takes effect before delivery. A running synchronous source read may finish. Label storage is caller-backed, and optional validity output travels on a separate channel from numeric labels. Region contact and label stores remain provisional until success. Persistence and a general graph executor remain follow-up layers.

Dunia Vision qualification still requires actual route, shore or water, and building-adjacent tool requests against the integrated develop revision. The harness provides analytical references and simulated request sharing. It can exercise those library contracts before the consumer tools exist.

## Shared feature views and follow-up qualification

Feature views stream results in tile order, then request order. For a cold tile, the engine reads the largest required input window once and prepares one scalar plane. It retains no intermediate image across tiles. The descriptor dependency plan resolves local statistics and gradients before their dependent outputs, irrespective of selection order. A missing intermediate is evaluated once and held for its tile. A cached output can skip its dependency work. Cheap intermediate work is driven by the requested features. OKLab and complete feature outputs share by exact cache identity. Callers can declare different selections for different tasks without introducing task names into imagery.

Descriptors now distinguish qualified develop features, input sample model, mathematical domain and cacheable output, in addition to version, parameters, halo and output channels. The maturity enum distinguishes experimental, qualified develop and release-stable contracts. The descriptor assigns the current tile catalog to qualified develop. Complete reductions, source-cell operations and fitted outputs stream through their respective interfaces. Fitted outputs reuse underlying luminance tiles. Output identity and provenance include the complete fitted source profile and, for exposure matching, the reference profile. Persistent storage remains follow-up work.

Optional product metadata supplies the provider, sensor, acquisition timestamp, one-based band number and a nominal scalar range. The range is descriptive for general scalar operators. Unit-reflectance operations separately enforce their accepted range. Metadata and validity policy travel with feature output provenance. Product metadata also participates in tile identity. Separate feature domains distinguish encoded RGB8, decoded color, linear luminance, calibrated scalar samples and operations that use both encoded RGB8 and linear luminance.

For region statistics, variance is the population variance of the accepted color samples. Fill ratio is labeled pixel count divided by the bounding box area. Orientation is the major axis of the pixel-center covariance in pixel coordinates modulo π. Equal principal moments leave orientation invalid. Region provenance carries caller-supplied source information, analysis extent, connectivity/seed policy and implementation version. Label and optional validity sinks keep their existing provisional-store behavior on failure. Extra per-component statistics are accounted for by the component scratch-budget query.

The precision screen reports round-trip errors separately from production feature arithmetic. Production representation remains Float64. Measurements are specific to the sampled fixture and channel. They do not set a tolerance for a persistent store or validate downstream classification after quantization.


### Dependency execution contract

Dunia Vision can resolve the qualified-develop catalog with `describeFeature` and `resolveFeaturePlan`. The resolver reports transitive dependencies once, in topological order. A cycle aborts planning before source reads or callbacks. Dedicated access descriptors identify global reductions, source-cell operations and fitted operations. Their explicit entry points retain control of the fitting, reduction or cell extent. The lower-level experimental kernels are not part of this consumer contract.

For tiled views, scalar luminance is a virtual dependency realized over the required halo window once. The engine materializes local moments and gradients as needed. Those exact-region planes remain attached to the active tile even if the retained cache evicts a reference. No other intermediate plane is pinned. The maximum extra pinned payload is two 256×256 value tiles, or 4 MiB on x86-64, over the existing tile-buffer accounting. Retained cache accounting is separate with its original 16 MiB cap. Requested outputs are emitted in tile and request order. Repeated IDs within one selection emit once. A dependency read or evaluation must finish before its dependent output can be cached or delivered. Earlier completed tiles can remain observable if a later tile fails.

`featureEvaluations` counts new evaluations driven by requested outputs and `dependencyEvaluations` counts new materializations driven by dependencies. `dependencyCacheHits` includes a retained-cache lookup or a dependency already pinned for the current tile. `dependencyCacheMisses` counts demand for a materialized dependency that had neither. Scalar preparation is measured independently because it may include halo samples outside the output tile.
