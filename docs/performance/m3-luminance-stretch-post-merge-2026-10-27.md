# RGB luminance stretch — post-merge local performance receipt

**Status:** local diagnostic baseline; not release qualification or a portable performance claim.

- Date: 2026-10-27
- Revision: `c44737e6d5de121e9621f925f1d186d26f59884b` (PR #115 merged to `develop`)
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- DUB: 1.40.0
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Build: Release, `tests/perf_consumer`, `--production`
- Host: Linux 6.17.0-22-generic, x86-64, Intel Core i7-9750H, 12 logical CPUs
- Process CPU affinity: CPUs 0–11 allowed; benchmark was not pinned
- Governor: `powersave`

## Method

The benchmark retains deterministic interleaved RGB8 input across calls and
times the complete owned-result operation, including threshold estimation,
output allocation, color conversion and raster writes. It validates normalized
output before reporting. Preview cases use two warm-up batches followed by
seven timed batches, each with 12 calls. Camera-frame cases use two warm-ups
and seven timed calls. The default `workerLimit` is zero, so these results are
for the sequential operator. The host's CPU affinity allowed all 12 logical
CPUs, and the run did not explicitly pin a CPU or lock frequency.

Reproduce from the repository root with:

```sh
dub run --root=tests/perf_consumer --compiler=ldc2 --build=release --force -- --production
```

## Results

| Workload | Median | Throughput | Mask |
|---|---:|---:|:---:|
| 1920 × 1080, 12-call preview batch | 57.219 ms/call | 36.240 Mpixel/s | no |
| 1920 × 1080, 12-call preview batch | 56.917 ms/call | 36.432 Mpixel/s | yes |
| 4000 × 3000 | 370.260 ms | 32.410 Mpixel/s | no |
| 6000 × 4000 | 752.191 ms | 31.907 Mpixel/s | no |

The benchmark's semantic preflight and the `M3_RGB_LUMINANCE_STRETCH_PERF`
gate passed. At 1080p, 30 frames/s requires about 62.2 Mpixel/s; this sequential
run measured about 36.4 Mpixel/s (roughly 17 frames/s). It therefore does not
meet that target by itself. Parallel runs have separate measurements in the
[historical performance investigation](m3-luminance-stretch-2026-10-23.md).

## Parallel follow-up on the same revision

The same Release consumer was rerun with `--parallel-luminance` and
`--worker-sweep`. Both benchmark gates passed. LDC's paired four-worker run
compared serial and parallel calls in alternating order:

| Compiler | Workers | Mask | Serial median | Parallel median | Speedup |
|---|---:|:---:|---:|---:|---:|
| LDC 1.42.0 | 4 | no | 78.084 ms | 21.316 ms | 3.66× |
| LDC 1.42.0 | 4 | yes | 77.678 ms | 22.561 ms | 3.44× |
| DMD 2.111.0 | 8 | no | 147.266 ms | 27.066 ms | 5.44× |
| DMD 2.111.0 | 8 | yes | 143.789 ms | 28.865 ms | 4.98× |

Both LDC four-worker and DMD eight-worker results are below the 33.3 ms 30-fps
budget, including the masked workload. DMD's full worker sweep had substantial
host variance: its paired serial medians ranged from about 143 ms to 329 ms as
the sweep progressed. Treat the DMD speedups and absolute timings as noisy;
the latest eight-worker pair is evidence that this host can meet the target,
not a stable guarantee. The API remains sequential by default, so applications
must explicitly budget workers for full-resolution preview.

Reproduce the parallel checks with:

```sh
dub run --root=tests/perf_consumer --compiler=ldc2 --build=release --force -- --parallel-luminance
dub run --root=tests/perf_consumer --compiler=dmd --build=release --force -- --worker-sweep
```

The host was running with the `powersave` governor, and the run was not CPU
pinned. Compare future local measurements only under a similarly controlled
compiler, build, workload and host configuration; use the candidate CI matrix
for qualification.

The subsequent LDC helper-inlining experiment and AVX2 assessment are recorded
in [the next-optimization investigation](m3-luminance-next-steps-2026-10-27.md).
