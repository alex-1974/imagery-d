# RGB luminance stretch — initial Release throughput receipt

**Status:** local diagnostic evidence; not a portable performance claim
**Date:** 2026-10-23
**Candidate base:** `63f077bc4a8a3c029cda2f7e81523f889be6795f`
**Compiler:** LDC 1.43.0, D frontend 2.113.0, LLVM 22.1.8
**DUB:** 1.42.0
**Build:** `dub build --root=tests/perf_consumer --compiler=ldc2 --build=release --force`

## Workload and method

The native consumer creates deterministic interleaved RGB8 input with
`(x*29 + y*17 + channel*53) & 255`, then times the complete owned full-ROI
operation at percentiles 1 and 99, including output allocation and raster
writes. Each shape receives two warm-ups and seven timed runs; the median is
reported. The source construction, output preflight and owner destruction are
outside the timed interval. Before timing, every output sample is checked to be
finite normalized sRGB in `[0,1]`.

Runs were pinned to CPU 0 on Ubuntu 26.10 x86-64, Intel Core i7-9750H, with the
reported `powersave` governor. The fixed histogram occupies 512 KiB; the
reported output payload is `width*height*3*sizeof(float)`. No speedup against a
different algorithm or platform is claimed.

## Results

| ROI | Median | Throughput | Replicates |
|---:|---:|---:|---:|
| 512 × 384 | 45,606 μs | 4.311 Mpixel/s | 7 |
| 1024 × 768 | 179,950 μs | 4.370 Mpixel/s | 7 |

These measurements establish a repeatable bounded workload and a baseline for
later same-machine comparisons. They do not complete release performance
qualification; rerun on the exact candidate head and supported CI hardware.
