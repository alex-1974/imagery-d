# RGB luminance stretch — post-merge local performance receipt

**Status:** local diagnostic confirmation of PR #122; not release qualification
or a portable performance guarantee.

- Date: 2026-10-28
- Revision: `3b29768726084d02959710b4ace3b9d8b750f8f7` (PR #122 on `develop`)
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- DUB: 1.40.0
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Build: Release, `tests/perf_consumer`
- Host: Linux 6.17.0-22-generic, x86-64, Intel Core i7-9750H, 12 logical CPUs
- Governor: `powersave`; process pinned to CPUs 0–3

## Method

The consumer compares the complete serial and four-worker owned-result
operation in alternating order. Each case uses two warm-up runs and seven
timed pairs, with deterministic 1920 × 1080 RGB8 input, both without a mask
and with an independently backed binary mask. The timings include threshold
estimation, output allocation, color conversion and raster writes.

Reproduce from the repository root with:

```sh
dub build --root=tests/perf_consumer --compiler=ldc2 --build=release --force
taskset -c 0-3 tests/perf_consumer/m3-levels-paired-perf --parallel-luminance
```

## Results

| Workload | Serial median | Four-worker median | Speedup |
|---|---:|---:|---:|
| 1920 × 1080, no mask | 33.194 ms | 9.380 ms | 3.54× |
| 1920 × 1080, mask | 33.428 ms | 10.378 ms | 3.22× |

The four-worker calls are below the 33.3 ms 30-fps budget. The serial
unmasked call is marginally below it, while the masked call is marginally
above it. This is consistent with the prior code-generation report: the
optimization materially reduced cost, but serial 30-fps behavior is sensitive
to CPU placement, frequency and workload details.

The independent paired reference, accuracy and bounded-workload checks passed
as part of both benchmark modes. The separate `--fullhd-only` mode also passed
its output preflight and measured 32.052 ms without a mask and 32.364 ms with a
mask, but its reported scope is the repeated ROI-to-float output path rather
than the complete owned-result operation; those figures are therefore not
compared directly with the table above.

These results are one post-merge confirmation on a single host. They should
not be treated as a latency guarantee for other machines or as a claim that
all serial workloads meet 30 fps.
