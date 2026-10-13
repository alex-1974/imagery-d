# M3 RGBA — Exact runtime sRGB LUT in public raster zip: native micro-ROI XPS evidence

**Measured:** 2026-10-13 18:41:11 UTC (Europe/Vienna 20:41:11 CEST).
**Evidence classification:** verified native **research-only** measurement. No production image API, general numeric failure contract, micro-ROI switching threshold, release baseline or cross-platform guarantee is admitted.

## Provenance and independent validation

**User-provided compressed archive:** `micro-20261013T184111Z.tar.gz`

**Whole-archive SHA-256:**
`01fd2a53362d57314ad3ae3edbbe7c1dd3976e29b05a33a25ccdd35d174ae6cf`

This report was independently derived from the **raw per-case CSVs**, not merely copied from the generated `MICRO_SUMMARY.csv`. All 16 summary values were recalculated and reconciled against their corresponding nine original round records. Source snapshots were omitted from the upload; source provenance relies on the runner contract, recorded SHAs, and builds in the uploaded logs. The raw archive itself is external research evidence, not committed into Git history.

| Observation | Recorded evidence |
|---|---|
| Reference hardware | `xps-15`, Intel Core i7-9750H (6 physical / 12 logical cores, AVX2), Linux 6.17.0-22 |
| Research branch | `research/m3-rgba-layer-compositing` |
| **Measured imagery-d commit** | `52a1d5619e2b492f10405d6e22387e4541807e3d` |
| Dependency source mode | `pinned-v0.2.0`, full `--micro`, `smoke=0` |
| Measured raster-d | **v0.2.0**, `2f2415851e45001df92ce56dad409f680684ba8d` |
| Measured color-d | **v0.2.0**, `3359f08f4e83941ac1a8451cadefb146b5736019` |
| Compiler and DUB | LDC **1.43.0** (DMD frontend 2.113.0 / LLVM 22.1.8); DUB **1.42.0** |
| Build and execution | Release build once, then **direct executable invocation** under `/usr/bin/time -v` for each independent case |
| Files / checksums | **16/16** raw case CSVs match `CHECKSUMS.sha256`; derived `MICRO_SUMMARY.csv` regenerated **after** the manifest, not included in it |
| Case/round completeness | **16/16** expected case combinations, **9** paired measurement rounds each: **144/144** completed |
| Invocations | **32** full ROI calls per candidate per round; **4,608** calls per candidate across the 16 cases, with repeated calls inside each process being correlated samples |
| Differential | `pixel_differences=0` in **144/144** rows; 16/16 end-of-case `ZIP-EXACT-LUT PASS`; program checks **all 512² target pixels** against direct zip, LUT zip and unchanged four-plane imagery adapter, including untouched outside-ROI sentinels |
| Raster safety | Both actual physical source/target overlap directions rejected with error classes **before writes**, and source values verified unchanged by each case's own smoke validation |
| Current-thread GC | **0** observed allocated bytes in each measured direct/LUT pair |
| Diagnostic stderr | **16/16** case stderr files empty |
| Process paging | **0 major faults**, **0 process swaps** in all 16 `time -v` reports |

The *live* raster-d checkout `1ea67cb6…` was **not** the measured dependency. It, imagery-d, and color-d contained pre-existing untracked work. The pinned runner read `v0.2.0` tags and source HEAD via `git archive` and built only inside ignored `imagery-d/data/`. **No sibling repository was modified**.

### Exactly matched pixel work

The two timed branches invoke the **same public** `raster.zipTransformInto` execution mechanism, its plane/shape/noninjective-target/physical-alias preflight and row executor. The two callbacks differ only in **direct runtime color-d sRGB8 decode** versus lookup in the previously qualified **runtime-generated immutable `double[256]` table**.

Both retain the same fixed source layer opacity **0.37**, encoded-straight `SRgba8` source/straight encoded RGBA8 output, linear-light color-d source-over and quantization procedure. Both use separate owned image leases and an unmodified **four-plane imagery** correctness reference (not timed inside these two zip figures).

Selected ROI is `Region2D(7, 11, side, side)` on a fixed **512 × 512** retained raster, not a newly allocated tiny image. The whole 512² destination/sources are verified outside the timed intervals. Conditions:
- **16², 32², 64², 128²** offset square ROIs;
- mixed alpha 0/128/255, and both fully transparent with **nonzero hidden encoded RGB**;
- compact and row-padded packed `SRgba8` layouts;
- 9 alternating A/B rounds × 32 repeated ROI calls, one independently launched OS process **per condition**.

**Statistics:** Each table cell is the **median of the two layout-specific case medians** (one process each), in nanoseconds **per ROI pixel per single call**. The factor is the median of the two **paired case-ratio medians** (per-round direct_us/LUT_us), not a ratio of unpaired aggregate timings. No confidence interval or run-to-run production guarantee is implied.

## Main result: mixed alpha (representative)

| ROI side | Pixels | Direct color-d zip ns/pix | Exact LUT zip ns/pix | Median paired speedup |
|---:|---:|---:|---:|---:|
| 16 | 256 | **495.67** | **200.13** | **2.443×** |
| 32 | 1,024 | **397.19** | **158.68** | **2.481×** |
| 64 | 4,096 | **243.15** | **96.65** | **2.462×** |
| 128 | 16,384 | **386.95** | **142.95** | **2.470×** |

For **every** tested ROI size, including the actual **16²** offset rectangle, the same alias-checked LUT callback is faster by approximately **2.44–2.48×** on the observed XPS run (roughly 59–60% less *timed operation* latency). Neither general picture rendering nor whole application frame pacing is included.

### Full transparency: a separate semantic special case

| ROI side | Pixels | Direct zip ns/pix | LUT zip ns/pix | Median paired speedup |
|---:|---:|---:|---:|---:|
| 16 | 256 | **325.44** | **28.75** | **12.356×** |
| 32 | 1,024 | **363.83** | **25.50** | **13.851×** |
| 64 | 4,096 | **340.45** | **23.89** | **14.419×** |
| 128 | 16,384 | **313.06** | **19.01** | **14.898×** |

The output is canonical transparent black, but the direct path still calculates encoded RGB transfer for hidden colors. The existing `color-d` alpha-zero handling avoids expensive output encoding. **Do not market 12–15× as a typical mixed-alpha source-over speedup**. Neither variant has added an explicit early exit for input transparency.

### Full 16-case, layout-specific paired summary

Each line is one **independent process**, with nine paired rounds. The ratio is the **median of within-round direct/LUT ratios**, making it less sensitive to unequal process clocks than cross-process absolute elapsed time. Columns are `direct ns/pix / LUT ns/pix / paired factor`.

| ROI | Pattern | Compact | Row-padded |
|---|---|---|---|
| 16² | mixed | 501.71 / 207.15 / **2.4247×** | 489.62 / 193.12 / **2.4607×** |
| 16² | alpha0 | 287.11 / 28.44 / **12.1737×** | 363.77 / 29.05 / **12.5378×** |
| 32² | mixed | 254.52 / 96.62 / **2.5062×** | 539.86 / 220.73 / **2.4561×** |
| 32² | alpha0 | 418.88 / 30.73 / **13.8466×** | 308.78 / 20.26 / **13.8555×** |
| 64² | mixed | 236.10 / 93.23 / **2.4569×** | 250.20 / 100.07 / **2.4663×** |
| 64² | alpha0 | 314.32 / 22.71 / **14.2148×** | 366.58 / 25.07 / **14.6223×** |
| 128² | mixed | 383.49 / 153.84 / **2.4925×** | 390.40 / 132.07 / **2.4469×** |
| 128² | alpha0 | 261.22 / 15.74 / **14.9673×** | 364.90 / 22.29 / **14.8287×** |

**All 144 individual rounds have `lut_zip_us < direct_zip_us`.**
The direct/LUT round ratio across all cases ranges from **1.916× to 24.635×**. Transparent/mixed ratios must remain partitioned; the pooled median has no useful domain meaning.

**Interpretation of non-monotone absolute times:** The mixed compact 32² case is ~254.5 ns/pix versus mixed padded 32² ~539.9 ns/pix; mixed 64² cases are ~236–250 ns/pix, while 128² cases can exceed ~383 ns/pix. The timings come from **different OS processes** and were collected without frequency/thermal isolation. This variability precludes attributing those absolute gaps to actual layout superiority, ROI size, cache shape or a particular instruction. The **paired direction within each process** is the supportable result. No measured crossover threshold or 60-FPS promise is established.

## Setup, memory, system caveats

- The immutable numeric LUT holds **2,048 bytes**. Initial preparation in a `shared static this()` callback, recorded **once per process**, is **39.5 µs median** across the 16 processes, **29–120 µs** range. This differs from previous larger-ROI runs (19 µs median); it is not a controlled code regression, and initial CPU frequency/scheduling is not isolated.
- Each process's maximum RSS is **10,484–10,904 KiB**, roughly **10.2–10.6 MiB**, inclusive of the full 512² **seven retained raster leases**, source/test fixtures, runtime and complete-pixel verifier, not the table-only or production compositor footprint.
- CPU governor `powersave` on **all 12 logical cores**. No clock trace, thermal sensors, fixed core affinity, context-switch intervention, `perf` events or optimized assembly are provided.
- The recorded start condition had `MemAvailable = 4,082,980 kB` and just **604 kB free swap** of 4,194,300 kB. Near-full swap does **not** imply the benchmark actively swapped: all 16 measured processes recorded **zero major faults and zero process swaps**.
- The release binary is built once in the pinned snapshot. Every timed ROI invocation runs in-process; compilation, setup, independent four-plane oracle, full-frame verification, table construction and user logging are excluded from per-call `direct_zip_us`/`lut_zip_us`.
- The 16 scenarios are independent OS invocations, **but there is exactly one OS process per scenario**, so the nine rounds are correlated and do not qualify a confidence interval over independent launches. A second XPS run with clock/thermal provenance could support a stable performance baseline.

## Engineering decision

**Qualified narrow finding:** The exact **sRGB8 `double[256]` LUT** delivers roughly **2.44–2.48×** throughput on **mixed-alpha small offset ROIs** even with the *existing public raster executor* and its physical alias/structural checks. **The hypothesis that fixed per-call zip overhead erases this benefit at 16² is falsified for this test.** No alternate fast path or small-size switch is justified by these observations.

**Keep design gates distinct:**
1. LUT and raster speed are proven **only** for packed, encoded-straight RGBA8 inputs at **fixed 0.37 opacity** with the probe's representable-output fixtures.
2. `zipTransformInto`'s **`@safe pure nothrow @nogc T,T->T`** callback has no runtime opaque context and **cannot return a classified checked quantization error**. Its current `SRgba8.init` fallback is **research-only** and not a production error contract.
3. The existing four-plane research compositor supplies runtime opacity and error classes, but explicitly relies on a **caller nonoverlap precondition**, unlike raster zip's actual prewrite physical noalias check. Do **not** silently replace one contract with the other.
4. Next imagery-only research should specify and test a **scoped prepared-context** with runtime opacity, deliberate `RgbaCompositeError` propagation, explicit view/storage lifetimes, and a documented difference between prewrite validation failures and exceptional partial writes. Reuse existing color-d and raster-d **public** mechanisms; do not import `raster.internal`, use unsafe mutable global state, change sibling code, introduce production APIs or merge draft PRs.
5. Investigate whether a genuinely public *already existing* error-capable, contextful raster primitive can provide the same physical-overlap preflight **before** proposing a cross-repository API gap. Any further generalization must undergo new numerical/negative tests and actual XPS timing, not only a faster LUT microbenchmark.

**Disposition:** Keep `research/m3-rgba-layer-compositing` and stacked **OPEN/DRAFT PR #73**. No merges or changes to `raster-d`, `color-d`, or any other repository.
