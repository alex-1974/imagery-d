# R-IM-03d — Resolve the XPS 16-bit interleaved-mask last-case anomaly

> **Native evidence update, 2026-10-17:** The owner supplied the eight actual XPS result logs as `results.tar.gz`. The full archive has been validated and the outcome is recorded in [R-IM-03d XPS controlled-order results](r-im-03d-xps-order-2026-10-17-results.md). Sections below that say native measurement is missing describe the original *pre-measurement protocol*. The suspected u16 interleaved-mask case is **normal in six of seven executions** (including a forward-last run); late slowdowns move to unrelated layouts when test order changes. Package-sensor values reach **100 °C**, making global/time-varying hardware performance state a leading but unproven mechanism. The actual root cause, C++ parity and public API admission remain OPEN.

**Date:** 2026-10-17. **Status:** independent research-only benchmark and CI qualification. **Native R-IM-03d measurement NOT YET EXECUTED**. No production API, release-performance claim, C++ parity, image colour-management, or source-provenance requirement is admitted.

**Parent research:** [R-IM-03c Draft PR #89](https://github.com/alex-1974/imagery-d/pull/89) at `6eff1e2f9ac0d7a1ced923fb98652dfa23eeed96`. This R-IM-03d branch is **stacked intentionally** to reuse its already independently qualified optimized math benchmark. [R-IM-03c native XPS receipt](r-im-03c-xps-2026-10-17-three-pattern-results.md) and all original logs are preserved verbatim. [R-IM-03b Draft PR #87](https://github.com/alex-1974/imagery-d/pull/87), general-image [scope Draft PR #84](https://github.com/alex-1974/imagery-d/pull/84), and grandfathered RGBA Draft #73 remain untouched.

## Research question

The **last** case in each of three native R-IM-03c runs is `ushort / interleaved / editing-mask`. For full u16 entropy, its `llvm_pow` / prepared-LUT medians are **71.320 / 50.435 ms**, versus **28.047 / 21.910 ms** for `ushort / planar / editing-mask`. This slowdown also affects the Phobos and gamma-2 sqrt variants. The test case was *always last*, so runtime order/thermal/frequency, layout or allocation pressure cannot be distinguished by the previous benchmark.

The anomaly does **not** justify prematurely changing `raster-d` strides, imagery-d semantics, source encoding, math kernels, SIMD, or scheduler configuration.

### What remains identical

Research module `levels_integer_research.d` and all four Levels methods are **byte-identical** to the parent: (1) Phobos pow, (2) LDC llvm_pow, (3) gamma-2 sqrt, (4) immutable binary64 LUT. Underlying input generator, ROI, source/destination layout relation, channel selection, selection mask, integer quantization, validation, owned `raster-d` views and 7 rotated repeated math steps are also unchanged.

**Only the order of full test configurations changes.** The benchmark still warms all methods and validates complete output equality before recording each case's 4×7 elapsed times. The R-IM-03c raw `RIM03C_RAW` and `RIM03C_SUMMARY` schema is preserved, and R-IM-03d adds explicit `RIM03D_CASE_BEGIN/END` markers.

## Case ordering and controls

The fixed original case indices in `bench_03c/source/app.d` are:

| Index | Type | Source layout | Selection | Purpose |
|---:|---|---|---|---|
| 0 | u8 | planar | none | original first |
| 1 | u16 | planar | none | full precision control |
| 2 | u8 | planar | mask | mask-only byte control |
| **3** | **u16** | **planar** | **mask** | **comparison control** |
| 4 | u8 | interleaved | none | interleaved byte control |
| 5 | u16 | interleaved | none | 16-bit interleaved without selection |
| 6 | u8 | interleaved | mask | interleaved mask byte control |
| **7** | **u16** | **interleaved** | **mask** | **suspected last-case anomaly** |

New case modes (fifth positional executable argument): `forward` (original 0→7), `reverse` (7→0), `target-first` (7, then 0→6), `target-only` (only case 7), and `control-only` (only case 3). The original default remains `forward`.

**What these can test:** If case 7 is always slow even when first or alone, the anomaly cannot be explained simply by always being last; inspect memory layout, access pattern and allocator. If it slows mostly when last, process order/load/thermal/allocator-state mechanisms become more plausible. **They do not prove thermal throttling** or guarantee a controlled CPU frequency; look for frequency/temperature correlations and independent repeatability.

## Native XPS driver

Opt-in research script: [`tools/research/bench_r_im_03d_order_xps.sh`](../../tools/research/bench_r_im_03d_order_xps.sh)

```bash
# Inside an isolated imagery-d checkout stacked at the R-IM-03d SHA.
# Pin adjacent raster-d to 2f2415851e45001df92ce56dad409f680684ba8d.
cd /isolated/imagery-d
bash tools/research/bench_r_im_03d_order_xps.sh "$PWD" 1024 7 1 ldc2
```

The wrapper checks the pinned `raster-d` exact commit and **does not checkout/reset/write the sibling**. It builds the DUB release executable **once**, not between measurement modes. It creates a fresh `~/imagery-rim03d-results-XXXXXX` output directory (or takes a sixth output-directory argument) and executes **eight independent processes** in this order:

```text
0 target-only
1 forward
2 reverse
3 control-only
4 target-first
5 reverse
6 forward
7 target-only
```

For each run, capture raw `RIM03C_RAW` rows and `RIM03C_SUMMARY` rows; record exact mode and case ordering; capture timestamp, CPU0 instantaneous reported scaling clock, first `cpu MHz` from `/proc/cpuinfo`, and optional `sensors` output **before and after**. Host CPU governor, compiler, Git SHA, OS, CPU identification and pinned raster-d revision are printed. CPU frequency/thermal snapshots are observations, **not** true per-instruction or per-iteration frequency control. The script deliberately does **not** require root, set CPU governors, pin affinity, trigger sensors when unavailable, or rewrite existing workspace branches.

**Data volume:** each complete `forward`, `reverse` or `target-first` process records 8 cases × 4 methods × 7 rounds = 224 raw timings; each isolated process has 28. With three unisolated+two repeated reversed/forward modes and two target-only processes (as listed above), the total expected is **5 complete × 224 + 3 isolated × 28 = 1,204 RAW samples** and **43 summary cases**, spread across eight archived logs. (Two `target-only` and one `control-only` are the three isolated modes.)

**Important:** because the mode sequence is itself fixed, the experiment only narrows causal hypotheses; robust confirmation will require reversing the *process* sequence, independent runs across cold/warm machine states, and telemetry of effective clocks/temperatures during, not just before/after. Real photograph/graphics corpus, other sizes, Clang/C++, end-to-end allocations, RSS and alias/publication remain subsequent gates.

## Quality and safety gate

New [CI workflow](../../.github/workflows/r-im-03d-levels-case-order.yml) compiles/re-runs the existing independent R-IM-03a/03b/03c consumer under DMD 2.111/2.113 and LDC 1.41/1.43 in Debug and Release against pinned raster-d v0.2.0. A **tiny LDC 1.43 Release canary**, which makes **NO performance claims**, executes all five modes, checks numbers of raw and summary rows and checks numerical summary invariants (unique source codes, mismatch counters, LUT table payload, full-image checksum) between case orderings. The independent Levels logic is unchanged. No public `source/imagery` or root DUB package.

Original XPS evidence and historical research branches should not be rebased, cleaned, retargeted, renamed, deleted or merged merely to normalize workflow. This report requires a **true native XPS receipt** before any statement that the anomaly is explained.

## Next questions after native measurement

1. Compare case 7 as first/last/alone against case 3 alone and within both orderings; keep all raw pair distributions and environmental snapshots.
2. If results clearly implicate memory layout rather than test order, narrow with single-operation benchmark holding whole-image owners live and testing matching rather than opposite destination layout. Only then investigate `raster-d`/inner loop; **no sibling code edits** without explicit request.
3. If CPU/load drift is more plausible, record clocks under workload, normalize with a stable control kernel and vary order independently. Avoid explaining observed slowdown with an unmeasured mechanism.
4. Complete genuine consumer, colour semantics, output ownership/alias safe publication, optimized Clang C++ equivalence and multi-size performance gates before promoting any production API.
