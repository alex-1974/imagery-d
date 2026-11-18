# 1080p luminance 60-fps feasibility receipt

**Date:** 2026-10-30
**Source head:** `195a216b4ef7e1c5b923dd6fca286ccb6228b1ee`
**Compiler:** LDC 1.42.0, D frontend 2.112.1, LLVM 19.1.7, Release
**Host:** x86-64, 12 logical CPUs
**Command:** `tests/perf_consumer/m3-levels-paired-perf --parallel-luminance`

## Result

The measurement is the complete owned 1920×1080 call: histogram, output
allocation, transform and publication. It is not a kernel-only timing.

| Case | Serial median | 4-worker median | 4-worker worst sample | Median fps |
|---|---:|---:|---:|---:|
| unmasked, unrestricted CPU affinity | 24.242 ms | 7.549 ms | 10.481 ms | 132.47 |
| masked, unrestricted CPU affinity | 24.224 ms | 8.077 ms | 8.295 ms | 123.81 |
| unmasked, process pinned to one CPU | 24.446 ms | 25.624 ms | 35.905 ms | 39.03 |
| masked, process pinned to one CPU | 27.942 ms | 28.030 ms | 30.022 ms | 35.68 |

The unrestricted four-worker medians are below the 16.667 ms budget for 60
frames/s. The pinned one-CPU runs are not. Worker parallelism is therefore a
consumer-selected resource policy, not an unconditional API performance
guarantee.

## Decision

Keep the documented 30-fps (33.33 ms) target as the robust baseline gate. Mark
60-fps (16.67 ms) as realistic for this host when an application can reserve
at least four workers and has comparable CPU headroom. Do not promote 60 fps
to a portable or single-core guarantee; benchmark the deployment machine and
account for contention, thermals and worker-budget policy.

The local run passed the existing correctness and normalized-output preflight.
These timings are a reference-machine diagnostic, not hosted-CI evidence or a
release performance promise.
