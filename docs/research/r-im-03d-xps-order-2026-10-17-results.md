# R-IM-03d — Native XPS controlled case-order receipt and findings

**Date/time:** 2026-10-17 19:34:08–19:36:00 UTC. **Status:** verified owner-supplied **exploratory native evidence**; demonstrates the previous apparent u16 interleaved-mask regression is **not stable across case order**. Does **not** prove thermal throttling, compiler codegen parity with C++, a production fast path, or safe output ownership.

## Original evidence, reproducibility and integrity

**Original upload:** `results.tar.gz`, 11,244 bytes, SHA-256 `251c76c0983d98ab09953fef5bdf72bb199e12d37ddb001a7b23067740828f3f`. The archive contains exactly eight ordinary UTF-8 logs (no directories or unexpected members). Each log's full content, including the original `sensors` snapshots and raw run order, was read and checked against the research protocol. Preserve the original uploaded archive alongside this analysis; the full original bytes were **not** uploaded to GitHub in this documentation-only slice. The individual content hashes below provide cross-checks.

| Run | Original log filename | Bytes | SHA-256 |
|---:|---|---:|---|
| 0 | `order-00-target-only.log` | 5,545 | `3e12e2c1ffed731e28b2b2a6bbf933e126860746e774e9007a79985c84561c44` |
| 1 | `order-01-forward.log` | 15,567 | `f736d6593e2a5a35f83bee6b896606caaa67e5b254715eba9cc0dc06bd97232a` |
| 2 | `order-02-reverse.log` | 15,567 | `932ab745c54675cddfb4daab055199288280a9ed6d2ca736f237349de1736893` |
| 3 | `order-03-control-only.log` | 5,403 | `e52d6d8e972f2b92efe8c42aadef59ae4556b8da357ea51a1dc66e679a2ef310` |
| 4 | `order-04-target-first.log` | 15,652 | `10f7503acb5a438aa0fdd06c2977380af95ca873b299a9b555c754f42c3dbf32` |
| 5 | `order-05-reverse.log` | 15,568 | `882af82c8274cb75990584c600434538941ab62a18452ec138243020c7b93450` |
| 6 | `order-06-forward.log` | 15,567 | `0807109fcbb81704ec953db5a6a0adbe662b2013d1040dc63fd30f6d0ada31fb` |
| 7 | `order-07-target-only.log` | 5,545 | `902efbb057eda1ba736ef6d8d4f027ea1849a15e83970a25d4d0942c15145097` |

**Source and environment:** benchmark from R-IM-03d exact source head `d00545e759f8f7924db5c396bf5682afcdebbd16` (parent [R-IM-03c PR #89](https://github.com/alex-1974/imagery-d/pull/89)), pinned raster-d `2f2415851e45001df92ce56dad409f680684ba8d`. Intel Core i7-9750H on `xps-15`, Ubuntu Linux, **LDC 1.42.0 Release**, 1024×1024 4-channel image, full 16-bit sample-code pattern **1**, 7 rotated rounds for each of four math methods (Phobos `pow`, LLVM `pow`, gamma-2 `sqrt`, prepared binary64 LUT), planar/interleaved and optional editing-selection mask; no real photo source data. Governor `powersave` from preceding experiment; this eight-log archive directly contains cpufreq and sensors snapshots but does not independently repeat the complete original build environment header.

**Integrity checks performed:** exactly **1,204 `RIM03C_RAW` entries** and **43 `RIM03C_SUMMARY` records** across eight processes (five full runs × 224 timings and three isolated cases × 28); one summary per BEGIN/END case marker in correct order. All **172 per-method, per-case seven-element medians** were independently recomputed from the raw microsecond values and match the stored summaries exactly. For all 43 cases, the reported `llvm_mismatches` and `sqrt_mismatches` are zero; the executable itself asserts exact Phobos/LUT output agreement as preflight before recording timings. This only certifies the measured synthetic gamma=2 domain, not every colour space or gamma value.

## Target case 7: u16 interleaved + 0/128/255 editing mask

Times are measured **median ms per complete 1024² image operation**, *excluding* the per-process LUT preparation. The `target-first` and `reverse` modes put case 7 first; `forward` puts it last.

| Run | Case-order mode | Case 7 position | LLVM pow (ms) | LUT (ms) | LLVM/LUT |
|---:|---|---|---:|---:|---:|
| 00 | target-only | alone | 27.681 | 20.896 | 1.325× |
| 01 | forward | **last** | 27.756 | 21.148 | 1.312× |
| 02 | reverse | **first** | 28.561 | 21.450 | 1.332× |
| 04 | target-first | **first** | 27.699 | 20.763 | 1.334× |
| 05 | reverse | **first** | 28.790 | 21.607 | 1.332× |
| 06 | forward | **last** | **77.279** | **54.453** | 1.419× |
| 07 | target-only | alone | 30.115 | 23.030 | 1.308× |

Across the six runs **excluding** the single strong outlier `order-06`, the target's typical (median of six process medians) is **28.159 ms LLVM** and **21.299 ms LUT**. The slowest run is **2.74× LLVM** and **2.56× LUT** those reference medians. These ratios are descriptive of this small repeated protocol, not uncertainty-bounded population estimates.

The actual comparison control, case 3 **u16 planar with editing mask**, stays near **27.11–28.32 ms LLVM / 21.31–22.39 ms LUT**, including in the processes where another late case slows down.

## Evidence that the anomaly travels across cases and positions

The strong slowdowns are **not consistently coupled to case 7, its interleaved layout, or the presence of selection**:

- **Run 01, forward (cases 0→7):** case 7 is last but **normal**, 27.756 ms LLVM, 21.148 ms LUT. This rules out an unconditional 'last implies slow' explanation.
- **Run 02, reverse (7→0):** case 7 first **normal**; the run finishes with no comparably large slowdowns. CPU package rose from 86 °C to 92 °C.
- **Run 04, target-first (7 then 0→6):** case 7 **normal**, 27.699 / 20.763 ms. Later, case 5 **u16 interleaved no mask** reaches **78.04 / 50.16 ms**, and case 6 **u8 interleaved with mask** reaches **58.18 / 41.20 ms** (LLVM / LUT). CPU package 92→100 °C.
- **Run 05, reverse (7→0):** case 7 first **normal**, 28.790 / 21.607 ms. Cases 1 **u16 planar no mask** and 0 **u8 planar no mask**, now the **last two**, rise to **75.11 / 54.02 ms** and **77.36 / 48.69 ms**, respectively. CPU package 100→100 °C.
- **Run 06, forward (0→7):** case 7 **last** is anomalously slow, 77.279 / 54.453 ms; earlier **case 3 planar-mask remains normal**, 27.825 / 21.934 ms. CPU package 100→100 °C.
- **Run 07, target-only:** even after multiple hot runs, case 7 is **near baseline**, 30.115 / 23.030 ms. CPU package 100→97 °C.

The direction of these effects is consistent across **all four math backends** (including Phobos and gamma-2 sqrt), which suggests a shared processing-environment effect rather than a defect confined to `llvm_pow` or the LUT. The varying affected case identity argues **strongly against** a persistent `raster-d` interleaved-mask algorithmic regression.

## Thermal and frequency observations: measured versus inferred

The recorded CPU **Package id 0** sensor temperatures, in time order, are:

| Run | Mode | Reported package °C before → after | Reported CPU0 current frequency MHz before → after |
|---:|---|---|---|
| 00 | target-only | 84 → 87 | 4208 → 4224 |
| 01 | forward | 87 → 86 | 4029 → 4192 |
| 02 | reverse | 86 → 92 | 4098 → 4130 |
| 03 | control-only | 92 → 92 | 4068 → 4010 |
| 04 | target-first | 92 → **100** | 4104 → 3962 |
| 05 | reverse | **100 → 100** | 2799 → 3700 |
| 06 | forward | **100 → 100** | 4000 → 3451 |
| 07 | target-only | **100 → 97** | 3780 → 4085 |

The sensor printout identifies **100 °C** as critical (`crit = +100.0°C`) on this machine. Hence **temperature-/power-related performance variation is an important, evidence-supported hypothesis**, especially because late cases slow down across multiple layouts and computation methods as sustained workload accumulates. However:

- `sensors` and `scaling_cur_freq` are sampled **only at process boundaries**, not at the time of each slow pixel loop; neither core affinity nor clock normalization was controlled.
- Some runs report 100 °C but have mostly normal timing; a 100 °C snapshot **does not establish** that a given sample was throttled.
- No thermal-throttling/perf-counter log, instantaneous effective clock trace, power/PL1/PL2 limit, system-load data, or per-case CPU-frequency samples were captured. An allocator/GC/OS scheduling disturbance cannot be excluded by current evidence.
- Do **not** claim that 100 °C *proves* Intel thermal throttling, nor use an altered frequency-governor result as a direct equal-condition performance proof without recording the new conditions.

## Quantitative fast-path observation

When the target case is not in the clear slowoutlier regime (6 of 7 observations), prepared LUT is **consistently faster than LDC `llvm_pow`**, and both paths produce exact matching output codes in the tested gamma-2 synthetic domain. Per-process median target LLVM/LUT ratios are **1.308–1.334×** in those six measurements. This is compatible with the earlier R-IM-03c full-code data, but no new image-size/gamma/C++ baseline was introduced.

The LUT retains a 512 KiB binary64 lookup payload and incurs separate table-preparation time; faster execution here is **not** a general admission decision for production APIs, especially for small regions or changing parameters.

## Disposition and next targeted gate

**Research conclusion: likely global/time-varying performance disturbance, and a strong negative finding for the hypothesis of a stable u16 interleaved-selection implementation defect.** Keep R-IM-03d as measurement evidence. Do **not** change `raster-d`, the numerical contract, or a production fast-path on these observations.

Before any further benchmarking or optimization:

1. Inspect XPS cooling/fan/airflow and run the laptop on a stable power source. Avoid multiple prolonged high-temperature runs until the cause of 100 °C package readings has been reviewed.
2. If practical, repeat a **short** target/control crossover with continuous CPU package-temperature, effective clock/frequency and kernel thermal/throttle event telemetry, time-aligned with **each case**. Use a reverse/run-balanced order across separate sessions, with sufficient cooldown and a documented power/governor condition. Distinguish sample timing from before/after sensor snapshots.
3. Re-measure other sizes and real image patterns under reproducible system conditions. Compare `sqrt`, `llvm_pow`, LUT including setup and allocation/RSS, and a semantic-parity optimized C++ baseline; do not treat unrelated C++ code doing different work as evidence.
4. Independent correctness and production admission gaps remain: alias-safe/transactional result ownership, alpha/colour-management semantics and a real downstream consumer. No public API freeze from this observation.

**Branch policy:** preserve parent PR #89 and the full R-IM-03c archived logs, keep this R-IM-03d experiment Draft under PR #91 and Issue #92. Research evidence is not a merge to `develop`; no writes to other repositories or modified sibling state.
