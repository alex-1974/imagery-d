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

- `Engine.run` overloads with typed local-statistics and path parameters.
  Default parameter identity is backward compatible. Nondefault windows
  change cache keys, halo and result provenance before reuse.
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
- `tryRegionQuality` returns noise and detail indicators without class labels
  or a claim to identify physical sensor resolution.
- `structureTensor` uses explicitly reserved scratch and float32 output
  planes. Discrete Gaussian derivatives and integration share a documented
  three-sigma replicated-edge contract. Scales are in pixels. Gaussian
  derivatives subtract paired samples to preserve constant planes exactly.
- `tryQualityWeights` normalizes arbitrary explicit coverage/quality/preference
  factors without assigning domain-specific source rankings.
- Variable local moments/extrema use separable rolling Welford records and
  monotone queues. The numerical method is identified by
  `windows=centered-welford-monotone-v2` in parameters/cache identity. Mean and
  standard deviation may differ in final rounding from the original nested
  scan; validity, population variance, minimum-valid, clamped-border and
  constant-window semantics are preserved. Explicit default parameters and
  the ordinary default entry point continue to use identical arithmetic.
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
