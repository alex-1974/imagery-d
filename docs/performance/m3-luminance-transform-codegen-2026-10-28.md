# RGB luminance stretch — transform code generation probe

**Status:** diagnostic; no production kernel change accepted.

- Date: 2026-10-28
- Baseline: `0995f0f` (merged direct phase attribution)
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Linux x86-64, Intel Core i7-9750H; CPU 0 pinned, `powersave`
- Workload: complete owned-result 1920 × 1080 LDC Release call, serial

## Findings

Linux hardware performance counters are unavailable in this environment:
`perf_event_paranoid` is 4 and `perf stat` reports that no events can be
opened. No system setting was changed. The compiler's native assembly was
therefore inspected instead, using the exact Release flags and dependencies
of the perf consumer.

The LDC `Vector!(float[8])` path does not become an eight-lane AVX operation
under the default x86-64 target. Its emitted hot code uses XMM scalar
operations (`mulss`, `addss`, `movss`), lane shuffles (`shufps`), scalar
indexed loads from the decode and encode tables, and individual output
stores. This matches the earlier evidence that the default target does not
emit YMM code. The indexed color-table accesses are not hardware gathers.

An instrumented alternative removed the vector construction and performed
the same decode, luminance, bin map, scale, clipping, and normalized table
encoding with a compile-time unrolled scalar loop. It passed the independent
24-case output oracle (maximum one-byte error). Paired complete-call results
were too unstable to establish a speedup:

| Process order | Workload | First variant | Second variant |
|---|---|---:|---:|
| scalar group → current kernel | 1080p, no mask | scalar 67.39 ms | current 91.01 ms |
| scalar group → current kernel | 1080p, mask | scalar 96.73 ms | current 104.69 ms |
| current kernel → scalar group | 1080p, no mask | current 40.90 ms | scalar 74.00 ms |
| current kernel → scalar group | 1080p, mask | current 41.76 ms | scalar 86.25 ms |

The direction reverses with process order, and baseline latency ranges from
about 41 ms to 105 ms. The scalar alternative is rejected; the existing 8/4
kernel remains unchanged. These measurements are not a useful reference for
ranking close candidates.

## Consequence

The current evidence still places the cost in imagery's transform arithmetic
and its scalar color-table accesses. It does not identify a raster-d executor
or color-d transfer-function defect, so no dependency issue is warranted.
Further kernel work needs a stable reference host or same-process paired
comparison and a usable performance-counter environment. Avoid another loop
width-only experiment. A next candidate should reduce actual per-pixel table
interpolation or address one clearly identified dependency chain, preserve the
independent byte oracle, and win on the complete owned-result call in both
mask modes and both process orders.
