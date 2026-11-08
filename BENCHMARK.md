# imagery-d Benchmark Principles

## Purpose

Benchmarks are architecture evidence.

Performance claims without correctness and memory measurements are incomplete.

## Metrics

Record where relevant:

- elapsed time;
- MPix/s;
- effective GB/s;
- allocation count;
- allocated bytes;
- temporary-memory peak;
- total working-set peak;
- thread count;
- CPU utilisation;
- compiler and version;
- compiler flags;
- CPU architecture.

## Workload classes

### Micro

Small kernels for compiler, vectorisation and memory behaviour.

### Region

Representative processing windows such as 2K, 4K and 8K regions.

### Streamed

Datasets for which whole-image residency is undesirable or impossible under the
configured memory budget.

### Interactive

Viewport-oriented workloads involving source loading, cancellation, reuse,
priority and progressive refinement.

## Correctness invariant

For finite-neighbourhood image operations:

```text
whole-image result
        ≈
streamed/region result with sufficient halo
```

within the operation's documented numerical tolerance.

Region or tile boundaries must not create artificial discontinuities.

## Boundary cases

The corpus should include:

- objects crossing provider-tile boundaries;
- roads crossing boundaries;
- buildings crossing boundaries;
- natural features crossing boundaries;
- neighbouring source tiles;
- imagery mosaic seams.

## Memory

Measure separately where possible:

- source/cache memory;
- decoded raster memory;
- processing workspace;
- temporary buffers;
- outputs.

An eventual engine must support explicit memory budgets.

## Compilers

Correctness must remain testable with DMD.

Performance work should primarily include LDC/LLVM.

Auto-vectorisation/code generation should be inspected before explicit SIMD is
introduced.

## Architecture coverage

Performance-sensitive conclusions that affect general architecture should
consider at least:

- x86-64;
- AArch64.

Architecture-specific fast paths must not leak into image semantics without a
domain reason.

## Hosted CI versus reference machine

GitHub-hosted runners are appropriate for:

- correctness;
- portability;
- OS/architecture coverage;
- compiler/code-generation inspection;
- relative same-run comparisons.

Independent hosted-runner elapsed times are not stable absolute performance
baselines.

Absolute historical timing should use a documented stable reference machine.

## M3 RGB luminance preview target

The recorded 1920×1080 full-owned-call preview target is **30 frames/s**:
33.33 ms per call, including histogram, output allocation, transform and
publication. A 30 ms call is approximately 33.3 frames/s. A 60 frames/s goal
would require at most 16.67 ms per call on this single-call latency measure.

Use `tests/perf_consumer/m3-levels-paired-perf --parallel-luminance` to report
masked and unmasked serial and four-worker medians, implied frames/s, and the
largest of seven parallel samples. Both frame-rate comparisons are diagnostic;
the 30 frames/s target is the currently recorded goal, and 60 frames/s is
shown to make a stricter future goal explicit. A 2026-10-30 LDC Release
reference receipt measured 7.55 ms unmasked and 8.08 ms masked at 1080p with
four unrestricted workers (60-fps feasible on that host), while one-CPU runs
measured 25.62/28.03 ms (60-fps infeasible). Thus 60 frames/s is a conditional
multicore consumer target, not a single-core or portable guarantee. See the
[60-fps feasibility receipt](docs/performance/m3-luminance-60fps-2026-10-30.md).
Run on a documented reference machine with CPU affinity and other substantial
CPU workloads recorded.
Hosted CI must check correctness, not impose an absolute timing threshold.

## Imagery corpus

Real imagery is required for meaningful architecture and performance tests.

The corpus should vary:

- latitude;
- hemisphere;
- elevation;
- terrain;
- urban/rural environment;
- provider/source;
- effective resolution;
- image quality;
- neighbouring tiles;
- mosaic seams.

Imagery itself is not committed.

Version instead:

- scene ID;
- source ID;
- ground extent;
- retrieval parameters/time;
- dimensions;
- resolution where known;
- provenance;
- content hash.
