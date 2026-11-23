# Pooled feature execution and window paths — 2026-11-23

Implementation and qualification for #195 and #206–210. The existing Float64 API remains available; planar final delivery, prepared Gaussian32 and windowed/lazy paths are explicit choices. This is development evidence, not a release or reviewed Dunia application acceptance.

Source: `29551197a7f96ed1c09843360ed57d67e53c4f4c`; baseline: `e80fc215a5f48ec817a1a86478fee44a07da4d8e`. LDC 1.43.0 / frontend 2.113, DUB 1.40 release (`-O -release -inline`, ordinary @safe bounds checks). Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz, Linux 6.17 x86-64. Single-thread affinity CPU 5; frequency and other desktop load uncontrolled. Cold repetitions=3, prepared/external repetitions=7; medians after warm-up. Four warm frames precede isolated-worker scaling. Hardware perf events remain unavailable; phase clocks, LLVM remarks and disassembly provide mechanism evidence.

Reproduce from the repository using the test-only requirements environment:
```sh
dub build :bench --compiler=ldc2 --build=release
dub build --root=tests/feature_program --compiler=dmd --build=debug
python tools/qualify-feature-performance.py --compiler ldc2 --cpu 5 \
  --kernel-repeats 7 --baseline /path/to/e80fc21-benchmark \
  --output /tmp/imagery-performance
```

The command retains native/external CSVs, independent numerical output, paired controls, complete cache accounting, epoch receipts, a JSON qualification and a generated Markdown report. Raw files are local under `benchmark/results/engine-path-2026-11-23/` (ignored); this condensed record is the repository evidence. The JSON records compiler, CPU, affinity, argv and both executable hashes. Generated build artifacts account for the raw working-tree dirty marker; production source was committed before measurement.

## Matched before/after Engine controls

Each of three cycles alternates baseline/candidate order and measures unchanged complete Canny as an independent control. These are actual cold computations with the same provider. The two time columns are medians of cycle times; the delta is the median of the paired ratios, not their quotient. Control ranges retain drift rather than normalizing away absolute regressions.

| Operator | Baseline ns/pixel | Candidate ns/pixel | Target delta % | Control delta range % |
|---|---:|---:|---:|---:|
| gaussian | 102.887 | 36.413 | -65.87 | -26.59 .. 3.46 |
| gradient | 157.962 | 75.009 | -52.51 | 0.84 .. 5.17 |
| localNormalization | 206.351 | 178.848 | -8.05 | -1.85 .. 5.01 |
| ridge | 625.211 | 104.199 | -83.26 | 0.13 .. 5.16 |
| gabor | 3306.700 | 359.489 | -88.82 | 1.00 .. 4.07 |
| pathOpening | 816.975 | 992.299 | -0.85 | -0.55 .. 120.02 |
| median | 167.337 | 27.814 | -83.05 | 1.02 .. 2.02 |
| canny | 40.554 | 39.072 | 0.26 | -0.44 .. 1.71 |

Path opening has no robust before/after throughput admission from this host: cycle 1 regresses 116.6% while its unchanged control moves 120.0%; stable cycle 2 differs by -0.85%. Its aggregate time medians are 21.5% worse, and that absolute observation is retained. No path-opening speedup is claimed.

Existing cold **batch** regression ceilings: **PASS**. Their raw result is retained in `regression.txt`. The paired path-opening outlier exceeds that ceiling; it remains an explicit uncontrolled-host qualification limitation, not a normalized PASS. The tighter 1024² scalar profile in `feature-budget-2026-11-23.json` also passes the retained batch receipt; other sizes/domains continue to use the earlier profile. They remain separate from prepared-kernel admission; the earlier CPU-0 exploratory sweeps showed large common-mode movement, including unchanged Canny/path controls.

## Prepared kernels and direct planar execution

| Operator / prepared mode | ns/pixel | Matching external ns/pixel | Ratio | Fixed target |
|---|---:|---:|---:|---:|
| gaussian / prepared-float32-gaussian32 | 4.665 | 1.093 | 4.268 | 5 |
| gradient / prepared-float32-soa | 50.056 | 24.039 | 2.082 | 5 |
| ridge / prepared-float32-soa | 64.071 | 135.132 | 0.474 | 4 |
| gabor / prepared-float32-soa | 670.430 | 430.166 | 1.559 | 4 |
| median / prepared-float32-soa | 5.303 | 1.129 | 4.697 | 5 |

Eligibility is restricted to declared prepared modes in the fixed policy. Gaussian32 explicitly permits an absolute error of 3*Float32 epsilon on valid dimensionless [0,1] support, with strict fallback. Strict preparation and Engine calculations keep Float64 arithmetic. Median rank projection is exact. External Gabor/ridge winner ties are not an oracle: retained scalar D comparisons cover complete angle/scale/winner fields, custom banks, radii 31, zero/near ties and signed zero. The 2x stretch goal remains separate.

| Operator | Cold Float64 Engine ns/pixel | Cold direct-planar Engine ns/pixel | Planar GC bytes/call |
|---|---:|---:|---:|
| gaussian | 36.285 | 27.937 | 13385984 |
| gradient | 69.809 | 70.272 | 13386032 |
| median | 31.720 | 26.645 | 13385984 |
| ridge | 99.131 | 83.180 | 13463984 |
| gabor | 342.664 | 386.712 | 13500848 |
| localNormalization | 176.462 | 177.555 | 22425904 |
| pathOpening | 967.423 | 999.882 | 15311152 |

Cold Engine includes Source callbacks, conversion, cache publication, provenance and sink traversal. Prepared timers begin with an existing working plane. These scopes are not interchangeable. The common row/output backend is shared; final-only planar computation avoids complete Value staging. Full-precision dependencies remain available to downstream math. Improvements are operator-specific, not a universal speedup.

## Phase clocks and generated code

These are diagnostic ImageryProfile builds at the same source head. Wall time is the median; phase columns are the last invocation divided by pixel count and need not sum to the median. Normal release measurements above have no profiling clocks.

| Size / operator | Wall median ns/pixel | Read last | Prepare last | Kernel last | Cache last | Sink last |
|---|---:|---:|---:|---:|---:|---:|
| 1024 / gaussian | 33.655 | 6.637 | 4.159 | 12.563 | 4.160 | 2.844 |
| 1024 / gradient | 77.568 | 7.650 | 4.284 | 53.997 | 4.926 | 3.249 |
| 1024 / median | 36.231 | 7.040 | 4.101 | 13.795 | 3.898 | 2.886 |
| 4096 / gaussian | 50.909 | 12.837 | 6.620 | 22.503 | 3.958 | 4.811 |
| 4096 / gradient | 142.735 | 14.586 | 7.489 | 109.943 | 5.046 | 5.462 |
| 4096 / median | 53.590 | 14.247 | 7.228 | 21.987 | 4.034 | 5.284 |

Portable release disassembly records zero TileReader calls in the path loop after explicit inlining and 10 row/array-operation functions with packed SSE Float32/Float64 arithmetic. LLVM remarks also retain missed vectorization (including scalar angle/libm and fallback loops). No claim of complete SIMD coverage or raised CPU floor follows. Full symbol/opcode records are in the raw archive.

## Memory, allocation and scaling

Shared scalar input uses 9 bytes/sample (double + byte mask), previously 16-byte Point storage on x86-64. Final storage uses three Float32 channels and three byte masks: 15 versus 32 bytes/pixel. Index reservations and retained backing capacities are charged. Default dependency/final cache partitions sum to at most 16 MiB; scratch stays at most 8 MiB.

| Operator, 256² / 16 slots | Legacy whole cache bytes | Dependency bytes | Planar final bytes | Whole-cache ratio |
|---|---:|---:|---:|---:|
| gaussian | 2104911 | 7680 | 990992 | 0.474449 |
| gradient | 2104897 | 7680 | 990978 | 0.474445 |
| median | 2104897 | 7680 | 990978 | 0.474445 |
| localNormalization | 4202230 | 2104955 | 991036 | 0.736750 |

Both metadata indexes and key strings are included. Whole-cache halving holds for these independent features; normalization retains double statistics and its complete graph is larger than half. Preserving those dependencies is an explicit precision decision (ADR 0022). No universal half-RSS claim is made.

Warm computed-work allocation: **98/98 catalogue/mode cases PASS**, zero thread-GC bytes, actual cache misses. Prepared workers, Canny and every measured scaling worker also report zero thread-GC bytes. This excludes arbitrary user callbacks/native allocation/RSS. Largest catalogue probe scratch payload: 46,864 bytes.

| Operator | 1 worker ns/pixel | 2-worker speedup | 4-worker speedup | 12-worker speedup |
|---|---:|---:|---:|---:|
| gaussian | 43.349 | 1.684 | 3.302 | 3.280 |
| gradient | 129.249 | 1.967 | 3.131 | 3.867 |
| median | 51.468 | 1.838 | 3.123 | 3.719 |
| ridge | 154.549 | 1.952 | 3.386 | 4.434 |
| gabor | 693.279 | 1.842 | 3.057 | 3.729 |
| localNormalization | 245.596 | 1.806 | 2.797 | 3.354 |
| pathOpening | 1045.733 | 1.860 | 3.507 | 3.893 |

All four worker counts produce the same SHA-256 over three numeric planes and three masks. Each thread owns its Engine, callback, scratch and cache; no non-atomic raster lease or serial Engine is shared. 12 denotes affinity-visible logical CPUs, not 12 physical cores. The full receipt retains speedup and efficiency, including sublinear results.

## Canny and interactive cost paths

- Canny `legacy-global`: 46.252 ns/pixel, 25186304 GC bytes/call, logical scratch 25165824 bytes.
- Canny `prepared-global`: 36.270 ns/pixel, 0 GC bytes/call, logical scratch 14680064 bytes.

Prepared Canny reserves 14 bytes/pixel versus the former four-float/size_t-queue 24-byte payload on x86-64. It keeps no implicit Gaussian, inclusive four-sector NMS and global eight-connected hysteresis. Errors and final cancellation preserve destination bytes. 120 exact finite/border/zero-threshold/extreme cases pass. OpenCV quantized derivatives and scikit-image interpolated NMS differ: their ratios stay diagnostic and Canny target admission remains pending an aligned comparator.

| Cost-path reservation on 4096² / 256² window | Bytes | Setup ms | Normal reset ns | Wrap clear ms | Moving-window query µs | GC bytes |
|---|---:|---:|---:|---:|---:|---:|
| window-reservation | 1769472 | 0.828 | 2.477 | 0.010 | 1193.990 | 0 |
| full-reservation | 452984832 | 217.660 | 4.123 | 1.689 | 1124.080 | 0 |

Normal reset touches seeds and increments an epoch; first setup and ushort wrap clear the reserved stamps. Every moving-window query starts a new graph/epoch and evaluates only touched costs. Source costs must stay stable during an epoch. No settled answers survive changed windows. Lazy state is 27 bytes/reserved pixel; owned CostPath uses 8 bytes/global cost plus 19 bytes/reserved local state. Full-grid 27 vs 41 is not halving; the bounded window demonstrates the half-memory mode without weakening Float64 distances. Provider/caller/allocator storage is separate. The 64-case MCP gate remains rtol=3e-15 with exact finite masks; 36 additional window domains, deterministic paths and wrap/poison/failure cases pass.

## Verification and limits

Six supported compilers (DMD 2.111/2.112/2.113 and LDC 1.41/1.42/1.43), both default/no-io configurations: 12 successful test runs. DMD/LDC API/DIP1000 positives and 14 negatives, generated DDOX including the new Gaussian32 example, actual filtered git archive and a separate archive consumer pass. Independent feature/region/mosaic references remain enabled. No new production @trusted marker or CPU floor is introduced.

Numerical receipt excerpts:
```text
Mixed views: 5355 reference samples, 31 support combinations; peak work payload=8353216
Explicit Gaussian32: 2156 float32/64 strided/ROI samples, masked/wide/signed-zero fallback; max error=4.3772161e-08, absolute gate=3*float32.eps
Float32 timing comparators: median exact; Gaussian/gradient max error=5.96046448e-08; absolute gate=3*float32.eps on [0,1]
Lazy/reset/window cost paths: 36 independently checked domains; zero-GC replay
Planar Engine: 344 RGB/scientific/partition cases, 491972 samples; exact final float32 conversion, full-precision dependencies
Cost paths: 64 random/connectivity/step cases; MCP relative error=0; path reconstruction error=0
```

The raw generated report visibly separates regression, fixed target admission, warm allocation and scaling. Raw phases/codegen are diagnostic supplements to ordinary release wall time. Release/API freeze and reviewed Dunia scenes/labels (#187) remain separate work; no general feature-pipeline 60-fps promise follows.

See [ADR 0022](../adr/0022-pooled-engine-row-kernels-and-window-paths.md) and [the benchmark guide](README.md).

Local raw archive SHA-256: `e878f75896fe4d6671a4ab8697b451caca76fde1c77c998fa1920460432e7a11`.
