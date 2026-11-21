# ADR 0015 — General-purpose feature-kernel implementation program

Status: implemented candidates; integration qualification in progress.

## Decision

The repository owner authorized implementation of the eight-stage program on
2026-11-21. General interest is sufficient demand for #197–204. Additional
consumer discovery is not an admission prerequisite for those operators.
Existing workspace ownership, explicit semantics and numerical verification
requirements still apply.

Implementation branches from integrated develop `819492a`, protecting the
desktop worktree's uncommitted earlier M6 work. Historical research issues
#24–94 (except retained delivery issue #74) are retired as active work; their
branches, draft PRs and evidence remain available. Closing historical issues
does not admit their proposed public types. #75 is superseded by the owned
compositing contract; #173's evaluation is resolved by materialization code,
with further acceptance retained in #174/#175. #16 remains repository work.

## Implemented surfaces

- `Engine.run` overloads with typed local-statistics, path, ridge, line-response,
  Gabor-bank and shadow parameters; CLAHE has a typed dedicated overload.
  Default parameter identity is backward compatible. Nondefault windows
  change cache keys, halo and result provenance before reuse. Floating settings
  use 17 significant decimal digits in identities, distinguishing adjacent
  finite values. Individual Gabor members select positions in the configured
  two-scale/four-angle bank; their historical names describe the default bank.
  Nondefault Gabor weights are prepared once on the first cache miss in a
  request, in two allocations reused across all pixels/tiles. CLAHE retains
  the underlying luminance cache, with complete output provenance and no
  cache of transformed output. Even cell edges 8..128 preserve the existing
  half-cell anchoring convention; tiles are capped at 192 for cells below 16
  to retain the 8 MiB combined scratch limit. Other typed features similarly
  cap processing tiles when their halo exceeds eight pixels. Requested tile
  edge remains an upper bound. Validation precedes reads and allocations.
- `FeatureResampling.areaScalar` integrates pixel cells on a same-extent
  reduction. Nonfinite or invalid positive-weight contributors invalidate the
  result. RGB interpretation requires a separately selected policy.
- `rgbIndices` requires an encoded or linear domain. color-d owns transfer
  mathematics. Zero RGB has undefined chromaticity and zero excess green.
- `tryRgbHistogramMatchingLut` derives independent stored-byte channel maps
  using exact inclusive CDF quantiles and transactional failure behavior.
- `CostPath` owns a prepared cost copy, heap, distances and predecessors.
  Search work is resumable and budgeted; path extraction uses caller storage.
  NaN/infinity block cells. Application cost construction stays outside.
  `predecessorOf` exposes settled map entries, with size_t.max for unknown or
  blocked cells and self-links at settled seeds. An indexed binary heap serves
  all input sample types. This explicitly refines #204's initial bucket-queue
  suggestion: even integer samples produce fractional/irrational edge costs
  with endpoint means, diagonals and supplied anisotropic steps. No cost
  quantization or new integer-only metric is introduced. A specialized exact
  integer metric/queue would require separate performance evidence.
- `tryRegionQuality` returns noise and detail indicators without class labels
  or a claim to identify physical sensor resolution.
- `structureTensor` uses explicitly reserved scratch and float32 output
  planes. Discrete Gaussian derivatives and integration share a documented
  three-sigma replicated-edge contract. Scales are in pixels. Gaussian
  derivatives subtract paired samples to preserve constant planes exactly.
  Off-center weights that underflow are zero derivatives, including sigmas
  whose squares underflow. Orientation is undefined for eigenvalue gaps at
  most 32 double epsilons times trace; this avoids reporting roundoff as a
  direction on isotropic tensors. Coherence is bounded to [0,1]. Source halos
  compose both Gaussian stages. Expanded independent references, analytic
  orientation/unit scaling, ROI and zero-allocation checks qualify #198.
- `tryQualityWeights` normalizes arbitrary explicit coverage/quality/preference
  factors without assigning domain-specific source rankings.
- Variable local moments/extrema use separable rolling Welford records and
  monotone queues. The numerical method is identified by
  `windows=centered-welford-monotone-v2` in parameters/cache identity. Mean and
  standard deviation may differ in final rounding from the original nested
  scan; validity, population variance, minimum-valid, clamped-border and
  constant-window semantics are preserved. Explicit default parameters and
  the ordinary default entry point continue to use identical arithmetic.
- Path opening/closing share a threshold-activated DAG across the padded tile.
  At each threshold a pixel qualifies when capped forward+backward lengths
  minus one reach the requested length. Horizontal and vertical monotonicity
  ensure the two halves concatenate into a valid path. Activation order gives
  the exact max-min opening or min-max closing. Sorted entries and capped
  updates take O(N log N + N*length*(2*step+1)) time, replacing independent
  O(length²) partial-path scans per output pixel. Seven reserved arrays take
  24N+outputArea bytes on x86-64 and are reused across tiles. Values are selected
  directly from finite source samples, without arithmetic rounding. Negative
  zero is detected before output writes and uses the retained scalar reference
  to preserve its min/max tie bits. Length one is a direct copy. Large mixed
  requests cap processing tiles at 128 when needed to retain 8 MiB scratch.
- `hessianLineResponse` supplies Sato, Frangi and Meijering formula families,
  bright/dark/both polarity, a supplied increasing pixel-scale list and separate
  strength, tangent angle, winning scale and orientation validity planes.
  Sigma² normalizes derivatives across scales. Gamma/responseScale are caller
  constants; no regional data maximum is inferred.

Hessian support is ceil(4*sigma), an evidence-based refinement of #197's
approximate 3*sigma proposal: the initial three-sigma DC-corrected stencil
differed by 4.48% from the scikit-image Sato line-center reference; four sigma
reduced this to 0.176%. This is explicitly a sampled Gaussian second-derivative
contract, not a claim of byte equivalence with scikit-image's two successive
first-derivative discretization or per-image Meijering normalization.

ADR 0016 supplies an opt-in prepared float32 SoA worker for scoped raster-d
working tiles. Arithmetic remains float64 and explicit range-failure masks
distinguish publication overflow from mathematical invalidity. Preparation owns
scratch; tile evaluation is allocation-free. It retains the existing engine
as an exact float-conversion oracle and records per-family timing trade-offs.

Float64 remains the existing feature engine's output/cache representation.
The new tensor output's float32 rounding is explicit; it does not replace the
qualified engine representation. Its outputs can overflow float32 on extreme
finite inputs; callers requiring larger energy ranges must rescale inputs.

## Verification and remaining admission

See `docs/benchmarks/feature-program-2026-11-21.md` for exact commands,
independent OpenCV/scipy/scikit-image probes, measured baseline and remaining
acceptance work. `tools/test-compiler-matrix.sh` fixes DUB while varying the
six controlled compilers. A failed or incomplete test is not release evidence.

#187's manually reviewed real scenes and actual tool workflows are a distinct
integration requirement. Existing simulated/analytical consumers establish
library behavior but cannot establish that application acceptance.

No release, stable API freeze or blanket M6 completion is declared here.
