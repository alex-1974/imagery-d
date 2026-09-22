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
