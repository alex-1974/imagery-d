# Feature performance qualification

Build with an installed supported compiler and test-only reference environment:

```sh
dub build :bench --compiler=ldc2 --build=release
dub build --root=tests/feature_program --compiler=dmd --build=debug
python tools/qualify-feature-performance.py \
  --compiler ldc2 --kernel-repeats 7 --output /tmp/imagery-performance --baseline /path/to/e80fc21-benchmark
```

Use `tests/feature_program/requirements.txt` in a virtual environment. The
baseline argument is optional and records chronological before/after controls;
it must be built from develop e80fc21, with matching compiler/flags. Supply
`--compiler` matching the actual benchmark build; the receipt records its exact
version, both binary hashes, CPU model, affinity and declared release flags. The
qualification command runs the independent numerical oracle, cold Engine,
prepared workers (strict and explicit Gaussian32), paired legacy/planar Engine,
complete cache-layout accounting, prepared/legacy global Canny, external references, all 98
warm computed-work allocation cases, isolated-worker scaling and 4096-square
epoch/window probes. It retains CSVs, a JSON qualification receipt, numerical
log and generated Markdown. Setup, input generation and checksums are excluded
where the native benchmark states so; cold Engine timing includes its setup,
source, cache and sink traversal. The source-only package excludes these tools.

Default size is 1024, three measured repetitions after warm-up. Set `--size
4096` for the larger case. `--cpu` pins single-thread measurements; multicore
uses `--workers` (default affinity-visible CPUs) with separate Engines, source
closures and caches. No shared lease/refcount is accessed concurrently.
Output writes are disjoint complete tiles and SHA-256 covers all three planes
and all three masks. Every worker's thread-GC bytes are measured. Four warm
frames fill all four reserved cache slots even for a worker assigned one tile;
new revisions force real computation in measured frames. Tiny tiles or
unfavorable scheduling may produce speedup below one; report it unchanged.

`performance-targets.json` fixes 5x basic and 4x oriented-filter admission
independently of machine-specific regression ceilings. `--require-targets`
fails for pending/missing comparable targets. Without it, pending target
admission stays visible while deterministic allocation must pass. In
particular, different Canny NMS/tie/quantization rules cannot establish an
equal-work target. Float64 SciPy median and float32 OpenCV median are distinct
reference rows. There is no target admission based on a fabricated uniform
float32 reference family.

`tools/check-feature-budgets.py` remains the separate machine-specific
regression gate. Its older ceilings can pass while ratio admission remains
pending. Raw paired timings identify drift; they do not license erasing an
absolute consumer-visible regression. Frequency/system load are uncontrolled
on the development host. Do not run compiler jobs during the timed phase.

For the deterministic CI probe alone:

```sh
./imagery-d_bench 64 2 resources
python tools/test-performance-targets.py
```

Warm computed work must allocate zero thread-GC bytes across all 49 tiled
features, with both float64 and planar delivery. Cache-hit replay alone cannot
qualify. Cold setup and arbitrary user callbacks may allocate; zero thread-GC
bytes is not a native-allocation/RSS guarantee. The test runs on supported
DMD/LDC in the feature-reference workflow; shared-runner wall time is not gated.

Additional standalone selectors are `prepared-canny`, `epochs`, `scaling`,
`worker32`, `resources` and `cost-path`. Phase attribution is optional:

```sh
DFLAGS='--d-version=ImageryProfile' dub build :bench --compiler=ldc2 --build=release --force
./imagery-d_bench 1024 3 all scalar
```

Phase columns are nanoseconds from the last invocation, not the median wall
sample. Profiling clocks affect execution and those numbers are diagnostic;
ordinary release timings are primary. All new row arithmetic is `@safe` with
ordinary supported release safety settings. Optional code-generation remarks
must record the exact compiler and flags; no AVX2 floor is assumed.

For a single prepared family, use for example
`./imagery-d_bench 1024 7 worker32 scalar median`. Gaussian emits both the
strict float64 arithmetic row and explicitly selected `prepareGaussian32`.
The latter has its own absolute 3*float32.epsilon accuracy contract on fully
valid [0,1] support, with strict fallback elsewhere. Float32 OpenCV Gaussian
and Sobel/strength/angle are separate timing rows from their Float64 versions;
median projection is exact. A prepared unit-domain target never silently
reclassifies cold Engine source/cache/sink work as a kernel-only timer.

`./imagery-d_bench 256 1 cache-layout` records complete cache payload, both
metadata indexes and final/dependency separation at equal tile/slot counts.
Final pixels are 15/32 of Value storage. Whole-cache halving holds for the
shown independent features; normalization retains full-precision statistics
and its whole graph is larger than half. The same report exposes that scope
instead of attributing every retained byte to final pixels.

Cold Engine/regression sweeps use `--repeats` (default 3). Prepared kernels and
external references can use `--kernel-repeats 7` independently, avoiding a
change in the cold-process GC workload merely to stabilize a small-kernel
ratio. Target eligibility is restricted to the declared prepared modes in the
fixed policy; cold Engine ratios are diagnostic and retain their separate
regression check. The checker rejects a target observation from an undeclared
execution scope. Thresholds remain 5x/4x regardless of observed values.
