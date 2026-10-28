# RGB luminance stretch — sRGB table bounds-check elimination

**Status:** LDC hot-loop optimization retained for review; local evidence, not
a portable performance guarantee.

- Date: 2026-10-28
- Baseline: `0995f0f` (direct phase attribution)
- Candidate: current branch, after the normalized sRGB table lookup change
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Linux x86-64, Intel Core i7-9750H; CPU 0 pinned, `powersave`
- Workload: complete owned-result 1920 × 1080 LDC Release calls, serial

## Profile finding

After `kernel.perf_event_paranoid` was set to 0 for this session, hardware
counters and sampling became available. A 999 Hz call-graph profile captured
8,440 samples with no lost samples. The transform callback accounted for
79.7% of sampled user cycles, histogram/percentile work 11.9%, and `memmove`
6.7%. The transform is still the primary cost; neither raster-d's executor
nor color-d's transfer functions are an external bottleneck.

The baseline assembly showed two dynamic slice-bounds branches for each
output channel in `encodeNormalizedSrgbFromTable`. The transform guarantees
that each encoded input is in `[0,1]`: `Clip=true` clamps it, while
`Clip=false` returns before encoding if a channel is outside that range. The
encoding table has 1,026 entries (1,024 intervals plus two endpoints), so the
largest valid linear input, 1.0, yields index 1,024 and interpolation reads
indices 1,024 and 1,025.

## Change

The private LDC-only interpolation helper now uses a `uint` index and reads
the two validated table entries through a pointer. The `@trusted` boundary is
limited to those reads and rests on the range and table-size invariants above.
This removes the dynamic slice checks and the unnecessary unsigned `size_t`
conversion sequence from every output channel. Public API and color results
are unchanged.

## Complete-call counters

Each process ran the real full-owned-result 1080p consumer in Release, pinned
to CPU 0. `perf stat -r 2` wrapped two process runs for each variant and
process order. Reported counts are the averages printed by `perf`:

| Process order | Variant | Cycles | Instructions | Branches | Branch misses |
|---|---|---:|---:|---:|---:|
| baseline → candidate | baseline | 34.146 B | 93.045 B | 8.599 B | 12.55 M |
| baseline → candidate | candidate | 28.439 B | 83.157 B | 5.832 B | 11.36 M |
| candidate → baseline | candidate | 28.748 B | 83.157 B | 5.832 B | 11.38 M |
| candidate → baseline | baseline | 33.832 B | 93.045 B | 8.599 B | 11.68 M |

Across the two process orders, the candidate reduced cycles by about 15.9%,
instructions by 10.6%, and branches by 32.2%. The reduction held in both
orders. The complete-call benchmark's medians across those four process runs
were:

| Workload | Baseline | Candidate | Change |
|---|---:|---:|---:|
| 1080p, no mask | 37.36 ms | 31.49 ms | −15.7% |
| 1080p, mask | 37.61 ms | 31.61 ms | −16.0% |

Each process used two warmups and seven alternating 12-call batches. On this
host both candidate medians are below the 33.3 ms 30-fps budget.

A separate serial/four-worker comparison pinned the process to CPUs 0–3 and
alternated seven full owned-result pairs. Four workers measured 10.29 ms
without a mask and 10.26 ms with a mask, for 3.13× and 3.27× speedups over
the paired serial calls (32.21 ms and 33.52 ms). The masked serial result is
just above the frame budget in that comparison, reinforcing that the exact
latency depends on CPU placement and frequency.

## Correctness and limits

The independent M4 luminance corpus passed all 24 serial/parallel XYZ-D65-Y
oracle cases, with maximum one-byte output error 1; it also passed four
invalid-request cases, masks, and constant-bin identity. LDC and DMD Release
unit tests passed.

These measurements are local diagnostics from one CPU and one host. They
support the optimization's direction and size, not a general latency promise.
The `perf_event_paranoid` change was a session environment setting and is not
part of the repository.
