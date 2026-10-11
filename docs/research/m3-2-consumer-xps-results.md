# M3.2.8 — Dell XPS mapped-image ROI and metadata preparation evidence

**Status:** XPS *measured-state* semantic mapping qualification **PASS**;
the ROI optimization has an observable **small-ROI/high-channel benefit**.
A universal consumer speedup, deterministic metadata owner, release benchmark
threshold and public/API admission remain **DEFERRED**.

**Evidence date:** 2026-10-11 UTC 18:07:30  
**Source:** user-supplied archive `consumer-20261011T180730Z.tar.gz`
(SHA-256 `14d2a13c6da1ded0e7da32b3c8d770824ef3508d07242496a81af77666edb0bd`)  
**Measured imagery commit:** `7de1ca4bb3717859f9078428bff4d65a679f1055`;
branch `research/m3-2-consumer-amortization`.  
**Machine:** Dell XPS 15, Intel i7-9750H (6C/12T), Linux
`6.17.0-22-generic`, LDC 1.41.0 (DMD frontend 2.111.0, LLVM 19.1.7),
DUB 1.40.0, optimized release, `intel_pstate`/`powersave`,
OS-default CPU affinity.  
**Related research:** [M3.2.7 ROI-only result](
m3-2-xps-roi-observed-results.md), [M3.2.8 harness/CI record](
m3-2-consumer-amortization-results.md), [Issue #38](
https://github.com/alex-1974/imagery-d/issues/38),
[PR #39](https://github.com/alex-1974/imagery-d/pull/39).

## 1. Evidence integrity

The archive contains 17 regular evidence files, including all five
`run-*.log` files, `environment.txt`, `build.log`,
`correctness.log`, `consumer-raw.csv`, `consumer-summary.csv`,
`consumer-setup.csv`, `consumer-summary.json`,
`timed-binary.sha256`, `symbols.txt`, and
`disassembly.txt.gz`.

Independently re-parsing the raw CSV and the five program logs established:

- **5 separate processes**, **9 timed rounds** per case,
  **24 cases** (4 channel counts × 3 ROI sizes × 2 layouts/mask policies).
- **2,160 raw mapping rows** = **1,080 valid matched pairs**;
  each branch performed 12 full mapping operations per timed row.
- For **1,080 / 1,080** pairs, exactly one conservative and one
  verified-immutable mode, different execution slots, identical iteration
  counts and **identical nonzero output checksums**.
- **2,160 / 2,160** exported rows match the corresponding raw
  lines in the five independent run logs.
- The existing M3.2.6 debug/release correctness probes and all
  six expected DIP1000/type/capability-negative builds **PASS** on local
  LDC 1.41.0. The prior cloud DMD 2.111/2.113 and LDC 1.41/1.43
  [CI run #38159493658](
  https://github.com/alex-1974/imagery-d/actions/runs/38159493658)
  also passed (but is not XPS timing evidence).
- An independent source-level oracle is run before timing for each ROI,
  both layouts and optional validity, comparing *every* mapped sample,
  not merely the visible timing checksum.

Evidence file SHA-256 for provenance:

| File | SHA-256 |
| --- | --- |
| `environment.txt` | `e5c7c7c337c9028518b3c5c58774f7f2a25a8754a3f06b96c89fc5e888a1f1e0` |
| `correctness.log` | `c9467127ce330725e243265b3a0d6e830809fb7f8e99122d53f741b8dfe33b20` |
| `consumer-raw.csv` | `e816c0cec4ab85b1e48d0b5b5d5752c4f2b1e945191c41d008124160070872af` |
| `consumer-summary.csv` | `0b59020b41495498aa005536882b339c76610c47f65effe806c1f4c773915ae5` |
| `consumer-setup.csv` | `3f8b83d9124419c28606ea80018a3560d7755c78131c9629ee65a30de13bb81a` |
| `disassembly.txt.gz` | `35237fd20ca5585bf154b587da61dd60d8892aa33660f6276ac91f4423e1d57e` |
| `symbols.txt` | `7d69f8c88c2957f2279c79c770f6682b5574dcf224a683b3e0befc9b76df057c` |

The runner produced **one** binary manifest
`timed-binary.sha256` recording executable SHA-256:

`c67d572ea86e4d0cc4105db5b9e940dc0475143561a3b0a4f5cac9f718ffefa2`

The executable **bytes themselves were not uploaded**. Unlike
M3.2.7, this new archive does not include a separately recorded
pre-correctness-build binary hash. We can identify the **runner's
declared timed executable**, but cannot independently hash executable
bytes or assert a two-manifest binary identity check.

The `imagery-d` source worktree was at the exact PR #39 research
head with two untracked generated files:
`experiments/m3_2_validated_roi/dub.selections.json` and the
benchmark executable; **no tracked imagery edits were reported**.

## 2. Measured mapped-image performance

The two timed paths apply the **same** existing M3.2.2
`mapComponentsInto` kernel with three explicitly selected channels,
`stored * 0.5 - 4`, optional validity mask and caller-owned 3-plane
float destination. The only intended difference is ROI construction:
general `BorrowedSemanticImage.tryRoi` versus
`ValidatedImmutableImage.tryRoi`.

Below are **median elapsed nanoseconds per full mapping operation**
over 45 paired observations per row. Ratio is the **median of paired
old/new ratios**, not the quotient of two unrelated medians.

| Channels | ROI | Layout / mask | Old ns | Validated ns | Paired ratio | Paired median saved ns |
| ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 3 | 8×8 | interleaved, no mask | 600.0 | 600.0 | 1.000× | 0.0 |
| 3 | 8×8 | planar, masked | 783.3 | 783.3 | 1.000× | 0.0 |
| 17 | 8×8 | interleaved, no mask | 608.3 | 608.3 | 1.014× | 8.3 |
| 17 | 8×8 | planar, masked | 791.7 | 783.3 | 1.011× | 8.3 |
| 64 | 8×8 | interleaved, no mask | 658.3 | 641.7 | 1.039× | 25.0 |
| 64 | 8×8 | planar, masked | 841.7 | 825.0 | 1.021× | 16.7 |
| 256 | 8×8 | interleaved, no mask | 875.0 | 791.7 | **1.102×** | **83.3** |
| 256 | 8×8 | planar, masked | 966.7 | 891.7 | **1.084×** | **75.0** |
| 256 | 32×32 | interleaved, no mask | 11,433.3 | 11,241.7 | 1.011× | 125.0 |
| 256 | 32×32 | planar, masked | 12,208.3 | 12,108.3 | 1.004× | 50.0 |
| 256 | 64×64 | interleaved, no mask | 47,133.3 | 46,708.3 | **0.997×** | **−116.7** |
| 256 | 64×64 | planar, masked | 47,391.7 | 47,183.3 | 1.004× | 208.3 |

The archive's `consumer-summary.csv` contains all **24** configurations
and per-case MAD values. At 256 channels / 8×8:
- interleaved: verified faster in **43/45** paired rounds;
- planar+validity: verified faster in **45/45** paired rounds.
- The five process-level medians of the paired speed ratio for
  interleaved 8×8 are **1.100, 1.104, 1.102, 1.106, 1.104**;
  for planar+validity **1.087, 1.094, 1.082, 1.084, 1.084**.

Across all sizes the 1,080 pairs were: **656 faster**, **321 slower**,
and **103 equal** for the verified variant. At 64×64, results for
many channel counts vary in sign across processes, with apparent
small differences dwarfed by tail latency/host noise.

**Interpretation:** The earlier 28.64× M3.2.7 result applies to
**ROI construction alone**, at 1024 channels. The corresponding
consumer ROI+full pixel-mapping workload has a much smaller relative
benefit. At 256 channels and 8×8 it remains an observable ~8–10%
improvement. At 32×32 it is roughly 0–1% in these configurations,
and at 64×64 there is **no stable general speedup claim**. Actual
sample reads, validity checks and output writes dominate the work.

Do not advertise the ROI-only ratio as mapping/decoder throughput.
These are hosted-independent but single-machine, single-compiler,
synthetic benchmarks, with `powersave` governor and no fixed CPU
affinity. The timer records totals over only 12 operations per row,
causing **8.33 ns/call granularity** for a 100 ns clock increment.

## 3. Metadata preparation cost

The preparation benchmark uses 100 iterations per process for each
channel count. Reported values below are **medians of the five
process-level mean-per-call measurements**, in elapsed nanoseconds:

| Channels | Caller borrow + validate | Already immutable factory | Two `.idup` + immutable factory |
| ---: | ---: | ---: | ---: |
| 3 | 2 ns | 2 ns | 138 ns |
| 17 | 6 ns | 9 ns | 451 ns |
| 64 | 20 ns | 31 ns | 1,587 ns |
| 256 | 84 ns | 128 ns | 6,641 ns |

**Important measurement caveat:** 2 ns and some other setup
times are extremely short. For the smallest cardinalities, compiler
inlining/hoisting, repeated identical arguments and clock resolution
could materially bias timings. The preparation probe does not
yet include an independently checked anti-hoist/codegen gate.
The caller-borrow and immutable factory also execute **different
validation paths**. Thus these are **exploratory preparation estimates**,
not certified per-object allocation latency.

If mutable metadata must be copied to immutable once, the
illustrative extra preparation time at 256 channels is
`6,641 − 84 = 6,557 ns` compared with caller-borrow validation.
Using the paired median observed ROI+mapping savings at 256 channels
and 8×8:

- interleaved 8×8: `6,557 / 83.33 ≈ 78.7`, or roughly
  **79 reused ROIs** for nominal payback;
- planar+mask 8×8: `6,557 / 75 = 87.4`, or roughly
  **88 reused ROIs** for nominal payback.

**These are arithmetic illustrations, not qualified break-even
thresholds.** They presume stable savings, equivalent required metadata
semantics, repeated similar operations, no GC penalty outside the timed
setup sample, and negligible benchmark confounds. When the original
metadata is **already immutable**, the two `.idup` snapshots are
not required and this estimated copy overhead is irrelevant.
If the consumer needs an independently retained immutable snapshot
for correctness, it cannot simply skip it to optimize time.

A meaningful release decision requires higher-resolution and
anti-hoisting setup benchmarks and real consumer reuse patterns.

## 4. Code generation checked

The supplied `symbols.txt` and decompressed disassembly expose
distinct `pragma(inline,false)` mapping wrappers:

- `mapConservative` at `0x284f0`: calls
  `BorrowedSemanticImage.tryRoi`, then
  `m3_2_channel_metadata.contract.mapComponentsInto`.
- `mapVerified` at `0x28690`: uses the immutable validated ROI
  (its ROI logic is visible in this wrapper) and then calls
  **the same** `mapComponentsInto`.
- The mapping kernel remains a real separate symbol
  at `0x25aa0`, including semantic preflight and per-pixel
  operations. The optimized ROI does **not** optimize away
  the mapping kernel's per-call channel checking.

This supports the measured pattern: the fast ROI removes one
control-plane scan, while both routes pay the same image mapping
cost. The assembler text is from the operator's provided artifact;
the raw executable bytes are unavailable for independent hash-based
attestation.

## 5. Dependency/worktree provenance

The local imagery HEAD is `7de1ca4…` with only the generated
untracked executable and DUB selections file.

The local `raster-d` dependency is still at
`1ea67cb6ffb2c887f78d160249a293ad74ba5cda`,
**not** the release-tag commit `v0.2.0`
(`2f2415851e45001df92ce56dad409f680684ba8d`).
Its 17 status entries remain untracked
`benchmark/` executables and `experiments/`; no tracked-file
modifications were reported in the operator's prior status/diff
inspection. The local DUB build says
`raster-d ~release/0.2`, rather than pinned exact tag.

Prior M3.2.7 read-only comparison indicated that the tracked
raster source differences across those commits are documentation
or comments, with no D source-code change in the nine files altered
between revisions. This is **source-level comparability**, not
a byte-identical released-tag dependency or guarantee that the
local untracked experiments are empty.

The benchmark **did not modify** other repositories, and no
repository checkout/reset is required to interpret the current
observations. Strict released-version pinning stays an open
promotion gate.

## 6. Decision

1. **Accept as research evidence:** The M3.2.6 validated-immutable
   ROI is correctly usable by a mapped-image consumer; at high channel
   count/small output ROI its savings are visible and reproducible.
2. **Do not generalize performance:** Pixel work dominates beyond
   tiny ROIs; this experiment does not establish universal mapping
   speedups or image-decoding benefit.
3. **Retain the narrow immutable requirement:** A merely `const`
   caller-owned metadata slice can change through other aliases;
   do not remove identity validation without a proven immutable
   semantic capability.
4. **Do not introduce a metadata allocator or public optimized
   `ImageView` solely from these numbers.** The GC snapshot adds
   a measurable one-time cost; whether it is needed is a consumer
   ownership/semantics decision, not only a benchmark choice.
5. **Remaining gates:** controlled anti-hoist preparation comparison;
   actual intended reuse/tile workloads; optional separate clean
   pinned-`raster-d v0.2.0` dependency baseline and exact binary
   provenance; public API/regression review if production promotion
   is later proposed.

No changes to production code, `develop`, `raster-d`,
`containers-d` or other workspace repositories are authorized by
this research result. Preserve it on stacked PR #39.
