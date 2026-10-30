# RGB luminance stretch — AVX2 RGB8 decode-gather experiment

**Status:** rejected; local diagnostic evidence only.

- Date: 2026-10-29
- Base revision: `9e162988a740ccbf36b4392f9a611acc346f0964`
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: x86-64 Intel Core i7-9750H, AVX2 and OS YMM state available
- Workload: Release consumer, 1920 × 1080, 12 complete owned-result calls per timed batch, seven replicates after two warmups

## Candidate

The LDC x86-64 build used a function-targeted Haswell kernel to decode eight
RGB pixels with three AVX2 `vgatherdps` instructions from a contiguous copy of
color-d's exact 256-entry sRGB table. Runtime selection checked CPUID leaf 1
(OSXSAVE and AVX), XGETBV's XMM/YMM state bits, and CPUID leaf 7 (AVX2). The
original color-d lookup kernel remained the fallback. The independent pixel
oracle passed on the AVX2 candidate and the generic-fallback control.

## Result

| Kernel | Unmasked median | Masked median | `perf stat` cycles | Instructions |
|---|---:|---:|---:|---:|
| AVX2 gather | 29.24 ms | 30.43 ms | 27.23 billion | 61.53 billion |
| Generic fallback control | 24.74 ms | 25.59 ms | 21.34 billion | 60.50 billion |

The gather path was about 18% slower in both complete-operation medians and
used about 28% more cycles. It removed no meaningful instruction volume: the
three gathers require index extraction and setup, and the table lookups already
hit a small, cache-resident 1 KiB table. The CPU-feature detector and fallback
are functionally correct, but the measured candidate does not justify shipping
the extra ISA-specific code or its maintenance cost.

The candidate was reverted. No changes to numerical behavior, API, dependencies
or build target remain. A future decode optimization should first reduce RGB
lane packing or lookup instruction overhead without assuming that AVX2 gather
is cheaper than three independent cache-resident scalar lookup streams.
