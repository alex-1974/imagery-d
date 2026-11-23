# ADR 0022 — Pooled Engine delivery, row kernels and windowed paths

Status: implemented candidate; acceptance is recorded separately in the dated performance receipt.

## Precision and ownership

`Engine.run` retains its float64 `Value` contract. `runPlanar` and
`runPlanarView` explicitly request final float32 planes. Changing the existing
default would silently narrow scientific outputs and cached intermediate
statistics. This ADR chooses explicit opt-in publication instead. Arithmetic
and intermediate dependencies remain float64; normalization never consumes a
rounded final cache tile. The shared row kernels also serve
`Float32FeatureWorker`; they are part of ordinary Engine execution.

Each final tile contains three float32 channels and three byte masks:
15 bytes/pixel, compared with 32-byte `Value` on x86-64. Validity, orientation
validity and finite-result representability are separate. Overflow clears all
numeric channels and validity, and sets rangeFailure. Mathematical invalidity
keeps rangeFailure zero. Strength underflow clears orientation validity. This
is exact projection of the float64 result, not an alternative accumulation
policy. Final-only computation writes the same float32 output policy used by
prepared workers, without first building a complete `Value[]`. Full-precision
output staging remains where the dependency graph requires it. Morphology Point
intermediates and path double accumulators remain; 15 bytes is final tile
payload, not total live working memory. Scratch planning charges every such
array and the output-format signature prevents incompatible reuse.
The shared scalar working tile uses a double plane and a byte validity plane,
9 bytes/sample versus the preceding 16-byte `Point` array on x86-64. Sampling
adapts these planes to register-level Points; no raster ownership/layout API is
duplicated. Source conversion still runs once per real support sample.

Source identity/revision must be nonempty for planar execution and must change
when samples change. Results are synchronous readonly borrows. Copy samples
inside the callback to retain a snapshot. A readonly slice does not establish
unique ownership, and this aggregate does not claim deep DIP1000 enforcement.
Private owners can be recycled after callbacks finish. Source/provider/sink
reentry is rejected; every Engine is serial and noncopyable.

## Bounded retained state

`reserveCache` configures fixed metadata slots and a float64 cache budget.
Backing arrays are reused on FIFO replacement; live dependencies are pinned
for the current tile. Every reserved index slot and retained backing capacity
is charged. There is no separate unaccounted inactive pixel pool.

`reservePlanar` partitions at most 16 MiB between a full-precision dependency
cache (default 6 MiB) and final compact tiles (default 10 MiB). It does not add
another 16 MiB to an existing cache. The public cache reservation resets the
other mode. Scratch is separately bounded by 8 MiB. A complete scratch
signature includes shape, combined halos and family configuration. Partial
setup is never reused after an exception. Source samples overwrite scratch on
every miss; existing memory is never inferred to contain valid current input.

The warm allocation probe forces recomputation using caches smaller than the
frame, across all 49 tiled features and both publication formats. It measures
thread-GC bytes, including Engine overhead. This does not promise that an
arbitrary source or sink allocates nothing. Logical capacities exclude GC
headers, allocator fragmentation and RSS. Reservation/setup and cold misses
remain allocation-bearing and separately reported.

## Row arithmetic and complete fallback

A single support pass validates finiteness, masks and the clean [0,1] domain.
The prepared worker fills contiguous row scratch during that same input pass.
Only fully valid supports enter the clean path. Signed/wide inputs, missing
samples and negative zero retain the complete scalar implementation. The
ordinary Engine builds true replicated source halos before row execution.

Default Gaussian uses the original weighted online reduction, unrolled with fixed
coefficients. Replacing it with reassociated separable sums would change
float32 rounding ties and is a separate precision decision. Sobel retains the
scaled stable magnitude/angle rules. Median uses a 19-pair selection network,
qualified by all 512 binary neighborhoods and the differential corpus.
The prepared float32 median can retain a float32 support plane: monotone
finite rounding commutes with its odd order statistic. This preserves exact
final output even for Double inputs straddling Float32 rounding boundaries.
It does not apply to Gaussian summation. Missing, wide and negative-zero
supports still select the complete scalar fallback. The double Engine keeps
its double median plane. Separate sorted-sample and actual worker probes cover
rounding ties, tiny values and signed zero without relaxing a tolerance.

`Float32FeatureWorker.prepareGaussian32` explicitly selects a different
Gaussian arithmetic policy on an explicitly dimensionless domain.
`normalizedScalar` declares characteristic scale 1 and permits outliers with
strict fallback; raw caller-selected measurement units are rejected at setup.
Fully finite, valid [0,1] support uses two
separable float32 binomial passes. Source conversion and each rounded pass have
an absolute unit-domain error budget; 3*float32.epsilon bounds the final
strength difference from the strict float64 result under ordinary IEEE
round-to-nearest arithmetic. Missing, signed-zero and wider scalar supports
keep the strict fallback. Default `prepare`, ordinary Engine and default planar
delivery retain their previous arithmetic. This approximate policy has a
distinct parameter identity and does not enter an existing cache by accident.
It is a caller choice, not a hidden tolerance change. Tests measure its own
error distribution and verify exact fallback and zero-GC evaluation separately.

Gabor accumulates tap-major across a row, preserving the per-pixel tap order,
center subtraction and double winner comparisons. Four default filters use
5x5 and four use 9x9 support. Ridge/line response use shifted row slices and
strict bank-order comparisons. Configured kernels use the same backend and
fallback. No new production `@trusted` boundary or CPU floor is introduced.
Vectorization is measured rather than inferred from the loop layout.

## Prepared complete Canny

`CannyWorkspace.prepare` allocates magnitude and suppression float planes,
direction sectors, staged edges and a uint queue: 14 payload bytes/pixel.
`tryRun` is `@safe nothrow @nogc`, finite float32 input, unnormalized Sobel,
inclusive four-sector NMS, replicated source edges and global eight-connected
hysteresis. No Gaussian is implicit. Suppressed/border samples are unavailable
(NaN), including at zero thresholds. All errors and final cancellation preserve
the destination. Capacity setup is transactional; `.init` is not prepared.
Global hysteresis cannot be replaced by independent fixed-halo tiles.

## Windowed geometric shortest paths

`LazyCostPath!CostFn` owns local search state and caches a stable nonnegative
cost once per touched pixel/epoch. Global coordinates may exceed uint range;
local capacity is at most uint.max-1. NaN/+infinity block pixels; a negative
observation poisons that epoch and hides all partial answers. Functors must be
stable and non-reentrant within an epoch. Changing source, seed or fixed window
starts a new epoch. Window expansion can invalidate settled answers; it never
silently preserves them.

Distances remain float64. Local state is 8-byte distance, 4-byte heap index,
4-byte heap position/settled sentinel, 2-byte epoch and 1-byte parent direction:
19 bytes/reserved pixel. Lazy cached double costs add 8, totaling 27. The owned
`CostPath` wrapper keeps an 8-byte cost copy per global pixel plus 19 per
reserved local pixel. Full-grid payload is 27 versus the preceding 41; a
full-grid half-memory claim is false. A bounded window reduces reserved state
without reducing coordinate or distance precision. Allocator/provider/path
storage is separate.

Ordinary reset touches only seeds. First setup and ushort epoch wrap are
O(capacity) exceptions. Invalid reset coordinates preserve old answers;
provider/seed failures invalidate the new lazy epoch. The owned wrapper can
prevalidate blocked seeds before starting a new epoch. Short path buffers
remain unchanged and report required length. Existing deterministic ties and
the independent MCP rtol=3e-15 gate remain unchanged.

## Qualification and boundaries

Use the one-command harness in [the benchmark guide](../benchmarks/README.md).
Regression ceilings, independently fixed reference targets, numerical
qualification, warm allocation and multicore identity are separate gates.
Unmatched Canny/precision comparisons remain diagnostics. No stable API freeze,
reviewed Dunia ground truth, release or universal latency guarantee follows.

## Memory and timing comparison scopes

Final pixel payload is 15/32 of the previous Value tile. The cache-layout probe
also charges both fixed metadata indexes and conservative key strings. With a
single 256-square Gaussian/gradient/median tile and equal 16-slot reservations,
the complete retained cache is below half. A dependent normalization graph
retains its double statistics: its **whole** cache is about 0.74 of the previous
one, while final pixels remain 15/32. No half-memory claim applies to every
complete dependency graph or to RSS. Narrowing those statistics would violate
the exact projection/normalization contract and is deliberately excluded.

Cold Engine time includes Source callbacks, conversion, caching, provenance
and sink traversal; prepared-worker time starts from an existing working plane.
Comparing them as identical workloads is invalid. The report keeps both scopes,
profiles their phases and measures old/new Engine under matched providers. The
fixed 5x prepared Float32 targets are retained independently; a faster kernel
cannot erase an end-to-end regression or an unmatched reference contract.
