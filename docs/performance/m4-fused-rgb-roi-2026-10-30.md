# Prepared RGB LUT — direct ROI output qualification

**Status:** Issue #114 complete; existing public composition is sufficient.
No public API or numerical contract change is admitted.

- Date: 2026-10-30
- Base: `develop` after v0.2.0 publication record
- Compiler: LDC 1.42.0, D frontend 2.112.1, LLVM 19.1.7, Release
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Intel Core i7-9750H, Linux x86-64, CPU 0 affinity, `powersave`
- Command: `taskset -c 0 tests/perf_consumer/m3-levels-paired-perf --fused-rgb-roi`

## Consumer and semantic boundary

The consumer prepares one RGB8 percentile-stretch LUT from the existing
masked histogram API. The mask estimates the LUT only. Every requested output
pixel is transformed. Histogram completion is a barrier before either pixel
path starts; it is not fused into the transform.

The independent baseline performs two raster-d scoped passes: source RGB8 to
a full-size mapped RGB8 intermediate, then intermediate to final RGB8 output.
The direct path applies the same fixed LUT from source RGB8 directly into the
final output. Operation order, byte lookup, clipping and quantization are
identical. Both paths publish only complete caller-owned benchmark outputs.
This experiment selects RGB without alpha; it makes no alpha-association,
colour-profile, validity-mask, codec or file-I/O claim.

## Correctness

The two paths produced exact equal output bytes for:

- interleaved and planar three-plane RGB8 storage;
- positive and negative row strides;
- a non-origin 11×8 ROI in a 19×13 source;
- a LUT prepared from an independently backed partial binary mask;
- the three complete benchmark shapes below.

Preflight checks also reject an empty ROI, an out-of-bounds ROI and a
destination whose dimensions do not match the ROI, without modifying the
destination.

The implementation uses raster-d callback-scoped plane windows. Borrowed
views do not escape, and destination dimensions are checked before writing.
Malformed layout/address rejection remains raster-d's responsibility; this
consumer introduces no new unchecked public entry point.

## Complete transform-pass measurements

Each row uses two warmups and alternating A/B order. The median includes both
baseline pixel passes or the one direct pixel pass. LUT preparation and output
allocation occur once outside the repeated edit pass. Payload figures include
source, final output and, for the baseline, the full-size intermediate; owner
metadata and the fixed 768-byte LUT are excluded.

| Shape | Baseline median | Direct median | Speedup | Baseline payload | Direct payload | Saved |
|---|---:|---:|---:|---:|---:|---:|
| 64×64 | 0.041 ms | 0.025 ms | 1.592× | 36,864 B | 24,576 B | 12,288 B |
| 1600×1200 | 19.901 ms | 12.310 ms | 1.617× | 17,280,000 B | 11,520,000 B | 5,760,000 B |
| 4000×3000 | 136.791 ms | 80.612 ms | 1.697× | 108,000,000 B | 72,000,000 B | 36,000,000 B |

These are local relative measurements, not portable latency promises. Hosted
CI reruns the exact-output and same-run comparison but imposes no absolute
timing threshold.

## Decision

The material win comes from avoiding a redundant full-image write and read,
not from an ISA-specific kernel. A consumer already holding the public fixed
LUT can apply it while producing its chosen final destination. imagery-d does
not need a public DAG, fusion optimizer, scheduler or destination API for this
case. A future admitted operation that itself owns final RGB8 output should
use the same one-pass implementation principle internally. Statistical,
neighbourhood, format and colour-management barriers remain explicit.
