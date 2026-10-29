# RGB luminance stretch — pass the decode table by reference

**Status:** retained LDC optimization; local evidence, not a portable latency guarantee.

- Date: 2026-10-29
- Baseline: `3a0761d` (direct LDC sRGB lookup, before this change)
- Candidate: `0441467` (decode table passed by reference)
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Linux x86-64, Intel Core i7-9750H; pinned to CPUs 0–3
- Workload: Release paired consumer, 1024 × 768 and 1920 × 1080, masked and
  unmasked, serial and four-worker, two warmups and seven timed pairs

## Finding and change

The LDC transform helper accepted `SRgb8DecodeTable!float` by value. The
consumer's optimized assembly contained a 1,024-byte `memcpy` from the static
256-entry table into a stack temporary in each 4- and 8-pixel group. At 1080p,
the 8-pixel loop therefore copied 265,420,800 bytes (253.1 MiB) of the same
table during one transform pass.

The private helper now accepts the immutable table by `ref`. The optimized
pixel kernel no longer contains that copy. Pixel arithmetic and public APIs
are unchanged, and the independent output oracle passes.

## Whole-consumer counters

Baseline and candidate binaries were run in A/B/B/A order under `perf stat`,
counting user instructions and cycles over the complete paired consumer
process. Each invocation executes the same warmups, timed pairs and workload
matrix, including both image sizes, mask modes and worker configurations.

| Run | Variant | Instructions | CPU cycles |
|---|---|---:|---:|
| A1 | table by reference | 13,442,269,608 | 5,231,807,740 |
| B1 | table by value | 15,362,684,828 | 5,548,933,134 |
| B2 | table by value | 15,372,460,717 | 5,713,495,436 |
| A2 | table by reference | 13,442,266,267 | 5,045,665,375 |

The candidate averaged 12.5% fewer instructions and 8.7% fewer CPU cycles
than the baseline. Its two instruction counts differ by less than 3,400,
while the baseline counts differ by about 9.8 million. The candidate also
passed all paired reference, accuracy and workload checks on each run.

These counters support a concrete reduction in CPU work for this workload.
They do not promise the same wall-clock gain on other processors or compiler
versions.

## Follow-up profile

A sampling profile of the updated consumer collected 2,736 samples with none
lost. The transform callback accounted for about 74% of samples and histogram
accumulation about 19%; the former `memmove` hotspot no longer appeared. The
transform remains the main optimization target. Previous experiments found
that an approximate vector reciprocal and wider/unrolled alternatives did
not provide reliable whole-operation wins, so those paths remain unchanged.

Validation also passed DMD and LDC unit tests, both compiler Release consumers,
API compile probes, archived external-consumer validation, and the three CI
workflows on the candidate commit.

## Follow-up: smaller encoding table rejected

A 2,048-interval table was tested against the 4,096-interval version in
A/B/B/A order. The independent image oracle still passed its one-byte bound,
but whole-consumer counters showed no useful gain:

| Variant | Mean user instructions | Mean user cycles |
|---|---:|---:|
| 2,048 intervals | 13.401 B | 7.438 B |
| 4,096 intervals | 13.432 B | 7.425 B |

The smaller table reduced instructions by only 0.24% while increasing cycles
by 0.17%; run-to-run variation was larger than either difference. The table
remains at 4,096 intervals to preserve more numerical margin without a
measurable performance tradeoff.
