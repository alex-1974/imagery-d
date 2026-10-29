# RGB luminance stretch — direct LDC sRGB table lookup

**Status:** local LDC candidate retained for review; results are not a
portable performance guarantee or release qualification.

- Date: 2026-10-28
- Baseline: `e4232d7` (PR #123 on `develop`)
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- DUB: 1.40.0
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Linux 6.17.0-22-generic, x86-64, Intel Core i7-9750H
- Governor: `powersave`; process pinned to CPUs 0–3
- Workload: full owned-result 1920 × 1080 Release consumer, serial and four workers

## Change

The LDC vector path previously interpolated each encoded channel from a
1,024-interval sRGB table. It loaded two adjacent samples and performed the
fraction calculation and interpolation for each output channel. The candidate
uses 4,096 intervals and rounds the normalized linear value to the nearest
table point, replacing that work with one indexed load. The 4,097-entry table
occupies about 16 KiB. DMD and the LDC scalar tail retain interpolation.

The steepest sRGB segment has slope 12.92, so nearest-point sampling on this
grid contributes at most about 0.41 of an 8-bit code value before float
rounding. An ABBA comparison against an 8,192-interval direct table favored
4,096 intervals for masked and four-worker calls, while unmasked serial
results were effectively tied:

| 1080p workload | 8,192 intervals | 4,096 intervals |
|---|---:|---:|
| Serial, no mask | 25.81 ms | 25.95 ms |
| Serial, mask | 26.39 ms | 25.33 ms |
| Four workers, no mask | 8.08 ms | 7.74 ms |
| Four workers, mask | 8.04 ms | 7.66 ms |

The smaller table reduces the hot working set while preserving byte-oracle
accuracy.

## Order-swapped complete-operation measurements

Baseline and candidate executables were built from the same dependency graph.
The source variants were run baseline, candidate, candidate, baseline. Each
process used two warm-ups and seven timed pairs, and included threshold
estimation, output allocation, color conversion and raster writes. The table
reports the mean of the two process medians:

| 1080p workload | Baseline | Candidate | Latency reduction |
|---|---:|---:|---:|
| Serial, no mask | 32.48 ms | 25.30 ms | 22.1% |
| Serial, mask | 32.13 ms | 25.10 ms | 21.9% |
| Four workers, no mask | 9.42 ms | 7.89 ms | 16.2% |
| Four workers, mask | 9.84 ms | 7.68 ms | 21.9% |

Both serial candidate cases are below the 33.3 ms 30-fps budget in this
measurement. The spread between repeated process medians reinforces that
these are local measurements on a frequency-scaled host.

Reproduce the consumer workload from the repository root with:

```sh
dub build --root=tests/perf_consumer --compiler=ldc2 --build=release --force
taskset -c 0-3 tests/perf_consumer/m3-levels-paired-perf --parallel-luminance
```

## Validation and limits

The independent M4 XYZ-D65-Y byte oracle passed all 24 serial and parallel
cases with both LDC and DMD Release consumers. The maximum output difference
was one byte; four invalid requests, masks and constant-bin identity also
passed. DMD and LDC Release unit tests passed.

The faster lookup is LDC-specific and introduces a bounded approximation in
the float output curve. It remains within the repository's explicit
one-code-value byte-oracle tolerance. The measurements support retaining the
candidate for normal CI and review; they do not establish a latency guarantee
on other CPUs.
