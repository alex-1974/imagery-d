# RGB luminance stretch — eight-pixel LDC kernel

**Status:** candidate retained for review; local paired evidence shows a
modest complete-operation gain, but still misses the serial 30-fps target.

- Date: 2026-10-28
- Baseline: `faeec79` (four-pixel LDC kernel)
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Linux x86-64, Intel Core i7-9750H; CPU 0 pinned, `powersave`
- Build: `tests/perf_consumer`, Release, `--fullhd-only`

## Change

The LDC transform now processes eight pixels per main-loop iteration, then
uses the existing four-pixel vector path and scalar tail for the remainder.
The private transform helper is parameterized by vector width. DMD continues
to use the scalar implementation. On this default x86-64 target, LDC lowers
the eight-lane vector operations into narrower XMM operations rather than
YMM instructions; the experiment tests loop and group overhead, not AVX2.

## Paired complete-operation measurements

Each process used two warmups and seven timed batches of 12 complete
owned-result calls. The same baseline and candidate binaries were pinned to
CPU 0 and run in both orders:

| Order | Workload | Baseline | 8-pixel candidate | Latency change |
|---|---|---:|---:|---:|
| candidate → baseline | 1080p, no mask | 38.53 ms | 37.56 ms | −2.5% |
| candidate → baseline | 1080p, mask | 42.07 ms | 38.73 ms | −7.9% |
| baseline → candidate | 1080p, no mask | 41.75 ms | 38.73 ms | −7.2% |
| baseline → candidate | 1080p, mask | 42.06 ms | 39.84 ms | −5.3% |

The candidate was faster in all four order-swapped comparisons. The local
result is not a portable performance claim. The best observed candidate run
was about 36.3 ms per 1080p operation, still above the 33.3 ms serial
30-fps budget.

## Correctness and toolchain checks

The independent 24-case serial/parallel XYZ-D65-Y consumer oracle passed with
maximum one-byte error. LDC and DMD unit tests passed in Debug and Release.
The helper remains private and compile-time specialized; no public API or
numerical contract changed.

Retain the change only if the supported LDC CI matrix passes and subsequent
paired reference-machine measurements confirm the gain.
