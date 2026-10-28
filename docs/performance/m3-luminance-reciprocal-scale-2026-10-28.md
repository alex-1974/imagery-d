# RGB luminance stretch — reciprocal-scale experiment

**Status:** rejected; the tested LDC/x86-64 candidate was consistently slower.

- Date: 2026-10-28
- Baseline: `5a55f31` (normalized table encoder)
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Linux x86-64, Intel Core i7-9750H; CPU 0 pinned, `powersave`
- Build: `tests/perf_consumer`, Release, `--fullhd-only`

## Candidate

The four-pixel kernel replaced vector division of mapped luminance by input
luminance with SSE `rcpps`, one Newton refinement, and vector multiplication.
Other targets would retain vector division. The refinement preserves near-full
float precision; the complete independent byte oracle still passed.

## Paired complete-operation measurements

Each process used the existing benchmark: two warmups and seven timed batches,
12 complete owned-result calls per batch. The baseline and candidate binaries
were run in both orders, pinned to the same CPU.

| Order | Workload | Baseline median/call | Candidate median/call | Candidate change |
|---|---|---:|---:|---:|
| baseline → candidate | 1080p, no mask | 40.15 ms | 44.37 ms | +10.5% latency |
| baseline → candidate | 1080p, mask | 40.49 ms | 42.10 ms | +4.0% latency |
| candidate → baseline | 1080p, no mask | 40.75 ms | 39.32 ms | +3.6% latency |
| candidate → baseline | 1080p, mask | 40.92 ms | 40.27 ms | +1.6% latency |

The experiment was discarded and no reciprocal fast path was retained. The
small order-dependent gaps are within this powersave host's variability, but
both orderings favor the baseline. This indicates vector division is not a
useful isolated optimization target for the complete operation on this host.

## Correctness

The candidate passed the independent 24-case serial/parallel XYZ-D65-Y
consumer oracle with maximum one-byte error. LDC Release and DMD Release unit
tests also passed. Correctness did not compensate for the lack of a measured
performance win.

The next investigation should profile the full operation with reliable
phase-level instrumentation or inspect the table-decode/encode and memory
access paths. Do not retain target-specific reciprocal code without a paired
complete-operation win.
