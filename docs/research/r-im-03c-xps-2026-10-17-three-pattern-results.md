# R-IM-03c — First native XPS three-pattern benchmark: optimized Levels math versus LUT

**Recorded:** 2026-10-17, 18:50:24 / 18:50:53 / 18:51:22 UTC. **Scope:** native *exploratory* evidence, three consecutive processes (one per input pattern), **not** release-performance qualification, colour fidelity or C++ parity.

## Source and provenance

- **Exact original logs, byte-for-byte:** [pattern 0](evidence/r-im-03c-xps-2026-10-17-pattern-0.log), [pattern 1](evidence/r-im-03c-xps-2026-10-17-pattern-1.log), [pattern 2](evidence/r-im-03c-xps-2026-10-17-pattern-2.log). Each retains the initial environment, compile/link messages and all original RAW/SUMMARY rows. No synthetic replacements, no timings from GitHub runners.
- **Source checksums:**
  - pattern 0: 14357 bytes, SHA-256 `185b7004453b8b237fe58aa2a8bc3f1564411479047989d3411f22fc60e38896`; first line `RUN_UTC=2026-10-17T18:50:24Z`.
  - pattern 1: 14498 bytes, SHA-256 `59150544d36c7c57e2260f6b8d7d95c8d35ec861b005e726e52709c4a7d3cc83`; first line `RUN_UTC=2026-10-17T18:50:53Z`.
  - pattern 2: 14498 bytes, SHA-256 `88e5b92a9e3f6126d6b8ca9c76643806bdabd8be10dbb64315c6f6bc0dddcec0`; first line `RUN_UTC=2026-10-17T18:51:22Z`.
- **Instrument and source:** XPS-15, Intel Core i7-9750H, Linux 6.17.0-22-generic, CPU governor `powersave`, LDC **1.42.0** (frontend DMD 2.112.1, LLVM 19.1.7), DUB 1.40.0; imagery-d `6dcc3ffa5773102a965e9746754b0c24e624ce5b`, raster-d v0.2.0 exact `2f2415851e45001df92ce56dad409f680684ba8d`.
- **Workload:** 1024×1024 samples × 4 channels (RGB selected; alpha copied), planar/interleaved source, destination opposite layout, mask absent or 0/128/255 graded editing selection. Levels b=.1, w=.9, gamma=2, lo=.05, hi=.95. One validated complete-image warmup outside timing for all four paths; 7 rotated rounds, each of four methods measured separately, per configuration. Prepared LUT build separately timed.
- **Log state:** pattern 0 had clean detached benchmark clone. Pattern 1 and 2 record two **untracked DUB-generated files** (`dub.selections.json` and the benchmark executable) from prior runs; neither is a source edit. No compiler/runtime error appears in any log.

## Audit of all original measurements

- **3 files × (224 RAW timings + 8 SUMMARY rows) = 672 RAW and 24 SUMMARY.** Recomputed all 96 seven-sample medians directly from the raw timing rows and verified **exact equality** to the logged medians.
- **Checksum verification across layout cohorts:** source checksum is identical within each (pattern,type,mask) combination for planar/interleaved cases, as expected.
- **All optimized-math mismatch fields are zero** in all 24 whole-image SUMMARY rows; the executable additionally enforces bit-for-bit original Phobos-vs-LUT equality and <=1 code for optimized alternatives before timing. This is a **fixed gamma-2, synthetic source-data** result, not universal accuracy certification.
- The LUT versus `llvm_pow` ratio over all 24 summaries is **1.28–1.77×** (positive LUT benefit). The raw `std.math.pow` baseline is much slower; it is subject to workspace toolchain defect **TC-0006**, so do NOT advertise a corresponding 10×+ advantage over optimized C++ or any optimized general direct backend.

## Complete source-derived medians

All times in **milliseconds**, except ratios. The code-entropy count includes all four source planes (including the unselected fourth plane); all full-domain sample patterns still cover all codes in the selected channels. Each ratio is `median LLVM / median LUT` or `median sqrt / median LUT`; medians, not the mean of individual ratios.

| Pattern | Typ | Layout | Auswahl | Werte | Phobos ms | LLVM ms | sqrt ms | LUT ms | LLVM/LUT | sqrt/LUT | LUT-Setup ms |
|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | u8 | planar | nein | 256 | 231.709 | 27.890 | 26.906 | 16.737 | 1.67× | 1.61× | 0.043 |
| 0 | u16 | planar | nein | 256 | 235.289 | 31.333 | 29.031 | 17.746 | 1.77× | 1.64× | 4.857 |
| 0 | u8 | planar | ja | 256 | 162.555 | 27.054 | 27.019 | 17.929 | 1.51× | 1.51× | 0.021 |
| 0 | u16 | planar | ja | 256 | 161.089 | 27.553 | 27.554 | 17.554 | 1.57× | 1.57× | 4.544 |
| 0 | u8 | interleaved | nein | 256 | 226.208 | 27.537 | 26.375 | 16.485 | 1.67× | 1.60× | 0.021 |
| 0 | u16 | interleaved | nein | 256 | 232.281 | 30.918 | 29.295 | 17.630 | 1.75× | 1.66× | 4.737 |
| 0 | u8 | interleaved | ja | 256 | 160.541 | 25.661 | 25.263 | 16.852 | 1.52× | 1.50× | 0.022 |
| 0 | u16 | interleaved | ja | 256 | 323.027 | 71.591 | 69.471 | 44.444 | 1.61× | 1.56× | 5.421 |
| 1 | u8 | planar | nein | 256 | 226.671 | 27.388 | 26.887 | 16.806 | 1.63× | 1.60× | 0.033 |
| 1 | u16 | planar | nein | 65,536 | 230.273 | 31.155 | 28.664 | 21.457 | 1.45× | 1.34× | 4.804 |
| 1 | u8 | planar | ja | 256 | 161.154 | 27.076 | 27.056 | 17.584 | 1.54× | 1.54× | 0.021 |
| 1 | u16 | planar | ja | 65,536 | 168.256 | 28.047 | 27.444 | 21.910 | 1.28× | 1.25× | 5.077 |
| 1 | u8 | interleaved | nein | 256 | 235.561 | 27.821 | 27.425 | 16.989 | 1.64× | 1.61× | 0.023 |
| 1 | u16 | interleaved | nein | 65,536 | 238.675 | 31.636 | 29.370 | 21.489 | 1.47× | 1.37× | 4.984 |
| 1 | u8 | interleaved | ja | 256 | 160.404 | 25.565 | 25.083 | 16.990 | 1.50× | 1.48× | 0.023 |
| 1 | u16 | interleaved | ja | 65,536 | 333.972 | 71.320 | 69.407 | 50.435 | 1.41× | 1.38× | 5.093 |
| 2 | u8 | planar | nein | 256 | 227.977 | 27.847 | 26.695 | 16.890 | 1.65× | 1.58× | 0.043 |
| 2 | u16 | planar | nein | 20,854 | 247.045 | 30.623 | 28.427 | 18.085 | 1.69× | 1.57× | 4.710 |
| 2 | u8 | planar | ja | 256 | 160.919 | 26.940 | 26.529 | 17.386 | 1.55× | 1.53× | 0.022 |
| 2 | u16 | planar | ja | 20,854 | 172.535 | 27.337 | 26.664 | 19.501 | 1.40× | 1.37× | 4.904 |
| 2 | u8 | interleaved | nein | 256 | 227.063 | 27.264 | 26.560 | 16.391 | 1.66× | 1.62× | 0.022 |
| 2 | u16 | interleaved | nein | 20,854 | 249.214 | 30.646 | 28.553 | 17.581 | 1.74× | 1.62× | 4.965 |
| 2 | u8 | interleaved | ja | 256 | 159.741 | 25.588 | 25.187 | 17.087 | 1.50× | 1.47× | 0.021 |
| 2 | u16 | interleaved | ja | 20,854 | 322.575 | 62.051 | 60.653 | 44.093 | 1.41× | 1.38× | 4.988 |

## Causal interpretation (restricted)

- Source **u16 unique code diversity**: pattern 0 **256** (old `257×byte`), pattern 1 **65536** (full 16-bit domain via odd-modulo permutation), pattern 2 **20854** (smooth synthetic gradient). The original issue of merely 256 values in the 16-bit benchmark **is resolved for pattern 1**.
- With **pattern 1**, the full-domain u16 LUT medians are **21.457–21.489 ms** in the two unmasked layouts, while `llvm_pow` takes 31.155–31.636 ms. The two **masked** cases diverge: planar LUT 21.910 vs LLVM 28.047 ms, but the final interleaved u16+mask case LUT 50.435 vs LLVM 71.320 ms.
- Pattern 0 to pattern 1 u16 LUT runtime increases at matching layout/mask by **13.5–24.8%**, consistent with broader lookup access and cache working-set effects but not proof of a specific cache miss cause. Pattern 2 contains 20,854 distinct input codes and largely falls between/resembles the cases rather than universal full-distribution degradation.
- For pattern 1 u16, the measured LUT runtime reduction vs optimized LDC `llvm_pow` is **21.9–32.1%**, or equivalently the direct method takes **1.28–1.47×** the LUT time. Compared with the gamma-2 `sqrt` special case, the LUT runtime reduction is **20.2–27.3%**. This is narrower than the earlier Phobos comparison but still positive for all four layout/mask cohorts.
- At 1024² the **LUT preparation** in pattern 1 u16 is 4.804–5.093 ms; the ratio `setup/(LLVM median − LUT median)` lies between **0.244 and 0.827**. Thus setup amortizes within one complete operation under this benchmark, not for arbitrary small images, multi-parameter interactive changes or colour managed operations.
- **Critical non-randomized configuration-order anomaly:** The **last** case of each process is u16 + interleaved + selection mask; all four methods then take roughly **2–3×** their corresponding planar-mask or unmasked interleaved times. For pattern 1: Phobos 333.972 ms, LLVM 71.320 ms, sqrt 69.407 ms, LUT 50.435 ms, versus planar-mask 168.256 / 28.047 / 27.444 / 21.910 ms. This is repeatable in all three source logs but **the configuration was always measured last**. Temperature/frequency drift, time/order, memory layout and bandwidth cannot be separated by this run. **Do not claim an interleaved-layout penalty or a thermal root cause yet.** Randomize/reverse configuration order and record clocks/temperature under a separate follow-up gate.
- All results describe **single threaded** public raster-d checked-view sample access, not an optimized contiguous pointer path, SIMD codegen, tile scheduler, whole-image process time including decoding, or reference-equivalent Clang C++ kernel.

## Next gates before performance/admission decisions

1. **Resolve last-case anomaly** with reversed/randomized configuration order, isolated repeated final-case trials, cold and warmed CPU, recorded effective frequency/temperature, and raw per-round observations. Keep original order and results as a control.
2. Repeat 256²/1024²/2048² workload sizes, explicitly time LUT preparation and account for memory/GC residency; capture several independent process runs and raw distributions with power/affinity controls or full environmental metadata.
3. Build and validate a semantically **identical** optimized Clang/C++ comparator (the same four channels, ROI, input/output layout, mask rules, gamma=2, saturating half-up integer rounding, preflight and buffer/ownership comparison). Compare *separate* raster-d view overhead against unavoidable floating-point math.
4. Investigate arithmetic simplification and a native optimized D pointer/ROI path without bypassing accepted raster-d ownership and safety; measure real production-like edited layers, changing parameters and float/HDR cases.
5. Resolve **physical noalias** and safe publish-on-success/late-write error semantics before considering a public imagery-d operation. Colour-managed photographic and premultiplied-alpha requirements remain outside this scalar-math experiment.

**Disposition:** the prepared LUT remains a **promising internal fast-path candidate**, but the measured ~1.3–1.8× runtime gap versus optimized direct math is not enough to freeze the implementation, particularly with the unexplained last-configuration slowdown. Keep issue #90 open and PR #89 Draft. All sibling repositories and accepted production API remain unchanged.
