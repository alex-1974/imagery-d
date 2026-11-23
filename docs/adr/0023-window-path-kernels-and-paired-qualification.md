# ADR 0023 — Window/path kernels and paired qualification

Status: implemented candidate; numerical, memory and performance acceptance are
recorded separately. Follow-up issues: #212 and #213.

## Centered local statistics

The existing separable Welford/monotone-queue implementation remains the complete
fallback. Fully valid or masked finite [0,1] supports may instead use shifted
running sums, squared sums and exact valid counts. The first valid sample is
the shift. Input validation is fused with the horizontal scan, before any final
output is published. The vertical scan traverses contiguous rows. Statistics
remain Float64. Wide units, nonfinite or signed-zero support retain the previous
implementation. An uncertain small/negative variance is recomputed from the
centered local reference rather than clamped to zero.

Exact certificates track equal valid values across horizontal windows and then
across vertical row blocks, ignoring mask gaps. They prove constant windows
without square cancellation or per-window rescans. This matters for plateaus
different from the tile shift. A masked/unmasked ordinary regression bounds
reader work linearly on two such plateaus at radius 31.

Extrema are computed only when required by the request, without selecting a
different statistics algorithm. In particular, adding dynamicRange to a shared
request must preserve the exact single-request statistics and cached results.
The numerical implementation identity is `unit-sums-or-centered-welford-v3`.
Existing tolerances and minimumValid semantics remain unchanged. The bounded
column carriers use 18 KiB of stack on x86-64, plus 4 KiB for constant
certificates without extrema, or 16 KiB for optional extrema queues;
array-payload budgets exclude stack, fixed object metadata, allocator headers and RSS.

## Min/max path morphology

Forward and backward grayscale path recurrences share one predecessor row per
length, updated in descending length order. A strip retains max(8,2*length)
output scanlines, capped by the requested extent. Horizontal processing
transposes the loaded support so that both orientations have contiguous row
stencils. Lengths 1..31 and lateral steps 0..2 keep their existing halos and
parameter/cache identity. Invalid samples are unreachable infinities, with no
numeric-zero substitution. The threshold DAG and per-pixel scalar evaluators
remain independent retained references.

Final Float32 paths may use Float32 recurrence storage: finite monotone
conversion commutes with this lattice of min and max. Negative zero,
unrepresentable input and nonzero values rounded to zero select the complete
double scalar reference before touching output. This is an exact final
projection, with no new error tolerance. Float64 output and dependencies retain
double carriers. Reserved arrays, including strip and row storage, are charged
in the existing tile planner; private workspace replacement is transactional.

An additional carrier handles complete supports whose every sample is exactly
`Float32(code)/255` for an integer code 0..255. This is checked by value equality,
not approximate quantization, and works for either final precision. It uses byte
min/max rows and maps selected codes back to their exact source values. Complete
validity guarantees a straight full-length path at every core cell; endpoint
codes 0/255 therefore serve as neutral unreachable partial states without
creating invalid-data results. Any mask hole, signed zero or other alphabet
selects the ordinary Float32/Float64 recurrence. Both carriers' complete arrays
are reserved and charged. The benchmark records actual byte-carrier tile counts;
the hit rate is measured, not inferred from the input filename or format.

## Measurements on one laptop

Prepared external comparisons, end-to-end Engine overhead, profiled phases,
allocation and instruction counts are separate checks. Strict Engine Gaussian
is compared to the strict worker, not to the approximate Gaussian32 option.
Cold Float64, cold planar and prepared planar Engine executions use the same
fixture and complete final frame copies as the worker. Their shared-process
ABBA cycles observe all three channels and all three masks outside the timer.
Source revisions force actual Engine computation. Setup/cold GC and configured
parameter-identity allocations remain separately visible.

Each recorded measurement has before/after frequency, load, governor, power,
temperature and SMT accounting snapshots plus unchanged Canny controls.
Frequency movement above 5%, excessive load and sibling activity above 5% of
its accounted ticks reject the entire paired cycle. This declared background
allowance does not establish physical isolation; zero-tick intervals remain
unresolved and are rejected. A stricter zero-activity option remains available.
Rejections are retained, retries are bounded,
and failed hygiene cannot become a passing admission. A same-work preheat
precedes frequency sampling: hashing/serialization can exercise a different
turbo state from floating-point kernels. The report does not infer a cause for
historical host drift from endpoint snapshots alone.

At least 15 complete accepted ABBA cycles are required. Medians, MAD and seeded
bootstrap 95% intervals resample whole cycles. Improvement/regression claims
also need a 10% minimum effect; controls are diagnostic, never used to normalize
away absolute regressions. Over-budget confidence intervals fail, insufficient
or borderline evidence remains pending (exit 2), and only an upper confidence
bound under the budget passes. Bootstrap intervals are evidence from these
sessions, not a guarantee about arbitrary future machine load.

The aligned C Canny reference is separately authored and validated against all
120 retained scalar cases, including zero thresholds, narrow images and extreme
finite values. It has no implicit smoothing, replicated Float32 Sobel, inclusive
four-sector NMS and global eight-connected hysteresis. Its DFS visitation order
differs from the D FIFO. The primary C build uses portable `-O3`, no fast-math
and no FP contraction. Math errno is disabled because squared magnitudes cannot
be negative and errno is not an observable of this private finite benchmark.
`-march=native` is separately built, validated and timed; it does
not silently raise imagery-d's CPU floor. OpenCV/skimage Canny remain diagnostic.

Callgrind collects one named prepared frame, excluding setup, telemetry and
hashing. Its fixed cache model is a deterministic manual regression canary,
not a measurement of physical cache misses or a replacement for wall time.
Numerical preflight and deterministic gate self-tests also run in CI.
