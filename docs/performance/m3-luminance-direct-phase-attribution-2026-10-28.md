# RGB luminance stretch — direct phase attribution

**Status:** local diagnostic evidence; not a portable performance claim.

- Date: 2026-10-28
- Revision: `fb6ca1e` plus this diagnostic change
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Linux x86-64, Intel Core i7-9750H; pinned to CPU 0, `powersave`
- Workload: 1920 × 1080 RGB8, owned float output, serial (`workerLimit=0`)
- Method: two warmups and nine calls per mask mode; clock reads bracket the
  actual histogram/rank-selection phase and actual raster transform phase in
  `stretchImpl`. Total time brackets the same public owned-result operation.
  The reported remainder is computed per call as total minus both phases.

## Measurements

Two consecutive process runs gave the following medians:

| Run | Mask | Full call | Histogram and percentile selection | Raster transform | Setup/allocation remainder |
|---|---:|---:|---:|---:|---:|
| 1 | no | 38.903 ms | 5.735 ms | 32.856 ms | 0.091 ms |
| 1 | yes | 38.996 ms | 5.861 ms | 33.326 ms | 0.088 ms |
| 2 | no | 41.217 ms | 5.277 ms | 35.757 ms | 0.136 ms |
| 2 | yes | 38.727 ms | 5.965 ms | 32.719 ms | 0.082 ms |
| 3 | no | 50.205 ms | 7.315 ms | 42.989 ms | 0.112 ms |
| 3 | yes | 45.706 ms | 5.881 ms | 39.846 ms | 0.110 ms |
| 4 | no | 38.366 ms | 4.817 ms | 33.436 ms | 0.091 ms |
| 4 | yes | 38.319 ms | 5.739 ms | 32.563 ms | 0.091 ms |

Run-to-run transform variation is material on this powersave host, so these
values identify where time goes rather than promise an exact latency. Still,
the result is clear enough for prioritization: the transform dominates at
about 33–43 ms by itself, histogram work costs about 5–7 ms, and the remaining
validation, setup, allocation, LUT construction and publication are below
0.2 ms in these calls. The 30-fps serial budget of 33.3 ms is exceeded by the
transform in four of eight observations and nearly consumed in another,
before histogram work is counted.

A DMD 2.111.0 Release instrumented run was also checked as a compiler sanity
check: unmasked total/histogram/transform/remainder medians were 134.581 /
25.033 / 108.468 / 0.915 ms; masked were 128.141 / 20.352 / 106.693 / 0.927
ms. This is not directly comparable to the LDC performance target, but it
confirms that the same phase boundaries work under the second supported
compiler and that the transform dominates there too.

The measurements include the real raster-d executor boundaries and owned
output writes. They replace the old `--pass-attribution` staged reconstructions,
whose separate buffers and access patterns could not be reconciled with full
API latency. The diagnostic build is enabled with:

```bash
dub build --root=tests/perf_consumer --compiler=ldc2 --build=release \
  --d-version=ImageryPerfAttribution --force
taskset -c 0 tests/perf_consumer/m3-levels-paired-perf --pass-attribution
```

Normal builds do not expose the measured overload or execute clock reads.
The measured entry points exist only under `ImageryPerfAttribution`; the
existing production API remains unchanged.

## Consequence

Do not spend the next optimization cycle on allocation, LUT setup, or the
histogram. Focus on the transform kernel's per-pixel arithmetic and encoded
channel lookup/encoding. Any candidate must preserve the independent
one-byte output oracle and improve the complete owned-result call in paired,
order-swapped runs. The transform needs a substantial gain: saving only a
small fraction of histogram time cannot reach 30 fps.

## Follow-up kernel experiments

Two LDC Release candidates were tested on the same CPU-pinned 1080p
full-owned-result benchmark. Each result is the median of seven batches of 12
calls after two warmups; baseline and candidate process order was swapped.

| Candidate | Order | Unmasked baseline → candidate | Masked baseline → candidate |
|---|---|---:|---:|
| 16-pixel group before existing 8/4 paths | baseline then candidate | 36.89 → 36.17 ms | 35.41 → 35.94 ms |
| 16-pixel group before existing 8/4 paths | candidate then baseline | 37.59 ← 37.01 ms | 36.14 ← 36.03 ms |
| Clamp-based luminance-bin mapping | baseline then candidate | 36.10 → 36.96 ms | 36.42 → 36.45 ms |
| Clamp-based luminance-bin mapping | candidate then baseline | 37.18 ← 35.59 ms | 36.03 ← 35.99 ms |

The 16-pixel group passed the independent 24-case one-byte image oracle, but
its masked result regressed in one paired order and improved only marginally
in the other. Clamp-based mapping was effectively tied for masked input and
reversed direction for unmasked input. Neither candidate showed a reliable
complete-call improvement, so neither is retained. The existing 8/4-pixel
kernel remains the baseline. These trials reinforce that the next useful
experiment needs to reduce actual per-pixel work rather than only change loop
grouping or threshold-branch shape.

## Explicit four-worker comparison

The current 8/4-pixel LDC Release kernel was also measured through the complete
owned-result API with the process pinned to CPUs 0–3. The paired benchmark used
two warmups and seven alternating serial/four-worker measurements:

| 1080p workload | Serial | Four workers | Speedup |
|---|---:|---:|---:|
| no mask | 38.198 ms | 11.352 ms | 3.37× |
| mask | 38.533 ms | 11.724 ms | 3.29× |

Both four-worker results are comfortably below the 33.3-ms frame budget on
this host, while the serial calls miss it. This is local evidence, not a
portable latency guarantee. Since `workerLimit` is already caller-controlled,
the practical next step for a 1080p preview is to choose a worker budget based
on the application's CPU budget; changing the API's sequential default would
need a separate design decision and workload evidence.
