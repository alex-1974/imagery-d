# R-IM-03c — Optimized direct Levels versus LUT: representative 16-bit data

> **Native XPS evidence update, 2026-10-17:** Three user-supplied 1024²/7-round benchmark logs are now archived without alteration, verified and analyzed in [R-IM-03c native XPS three-pattern results](r-im-03c-xps-2026-10-17-three-pattern-results.md), with [all three exact RAW log files](evidence/). References below that state “not yet measured” describe the **original pre-measurement experiment design**, now superseded by the linked evidence. Full 16-bit diversity was demonstrated; LUT remained 1.28–1.77× faster than optimized LDC `llvm_pow` over 24 tested cases, with an unexplained non-randomized last-case slowdown and no Clang/ownership/public API gate completed.

**Date:** 2026-10-17. **Classification:** research/probe, **not** production API admission, public LUT policy, XPS measured speedup, C++ parity or memory/alias safety gate.  
**Parent:** R-IM-03b [Draft PR #87](https://github.com/alex-1974/imagery-d/pull/87) at `c5e76918e241a5d260f76e7049ff02e5e320dfc3`. No rebases/merges of old research branches, no public `source/imagery` / root DUB, no sibling writes. General-image [scope Draft #84](https://github.com/alex-1974/imagery-d/pull/84) and grandfathered RGBA #73 remain independent.

## 1. Why R-IM-03b XPS data requires another controlled experiment

The first [real native XPS benchmark receipt](r-im-03b-xps-2026-10-17-first-results.md) showed **10.40–17.05×** faster prepared LUT versus its paired scalar `std.math.pow` implementation on a 1024² 4-plane image, one 7-repeat process run, LDC 1.42.0 Release, `powersave`. Those are **valid for that comparison only**.

Two limitations prevent promoting the numerical difference to a production recommendation:

- **TOOLCHAIN_ISSUES TC-0006:** Phobos `pow` in a pixel loop has a documented x87 extended-precision cost on LDC. A prepared LUT avoids that path; a fairer direct baseline should check `llvm_pow` and specialized `sqrt` for exactly gamma=2.
- **16-bit fixture:** R-IM-03b's `ushort` input was `257 * ((31*x + 17*y + 13*c) mod 256)`, i.e. **only 256 unique stored values**. The 65536-entry LUT was mathematically qualified by full-domain tests, but its cache locality was **not** benchmarked with broad 16-bit diversity.

## 2. Experimental variants and shared operation semantics

Research module `experiments/r_im_03a_levels/source/imagery/presentation/levels_integer_research.d` shares **exactly one ROI/pixel loop**, including original source/destination preflight, per-channel selection, source-code normalization, optional 0/128/255 graded selection opacity, non-selected channel passthrough and final single half-up integer quantization. Four distinct mapping math modes differ **only** in the nonlinear transformation:

| Mode | Implementation | Applicability/limitations |
|---|---|---|
| 0 | `std.math.pow(t,1/gamma)` | original R-IM-03b Phobos scalar baseline |
| 1 | `ldc.intrinsics.llvm_pow(t,1/gamma)` under **LDC** | compiler-native LLVM math; under DMD this research probe falls back to Phobos, **not** an optimized DMD result |
| 2 | `std.math.sqrt(t)` | **gamma exactly 2 only**; other gamma values return an explicit `invalidParameters` **before writing** |
| 3 | Existing immutable `ResearchLevelsTable!T` | 256 or 65536 unquantized binary64 entries, lookup then blend then round once; preparation measured separately |

Numerical requirement: original Phobos and prepared LUT must remain **bit-for-bit equal** for typed integer outputs on the entire source integer domain. Since `llvm_pow` or `sqrt` can yield different nearby binary64 results, they are compared with the original and an independent existing fixture oracle, **not silently asserted as bit-exact**. Allowed deviation is **at most one integer output code**, with any mismatches counted for each method. A separate half-way rounding oracle keeps the original half-up contract. This error budget is exploratory **not** a public promise that values may change by one code on optimization; a production decision must judge reproducibility and tie policy.

Primary references: [LDC llvm_pow intrinsic definition](https://github.com/ldc-developers/ldc/blob/master/runtime/druntime/src/ldc/intrinsics.di), [LLVM pow semantics](https://llvm.org/docs/LangRef.html), shared `.workspace/TOOLCHAIN_ISSUES.md` §TC-0006. The primary source is the workspace's **measured** TC-0006 compiler issue, not a guess that all compiler versions behave identically.

### Explicit numerical gates

The independent DUB consumer still executes all inherited R-IM-03a float (48 configurations) and R-IM-03b integer (32 configurations) tests. Its `exhaustive!ubyte` / `exhaustive!ushort` now also runs the two new direct variants over **all 256 and 65536 codes** (one wide 1-channel raster each), checks direct vs LUT equality, independent math oracle tolerance, counts exact discrepancies from optimized pow and sqrt, and tests wrong-gamma rejection leaves an already populated destination unchanged. All output storage is disjoint via `raster-d RasterLease`; no new owner type.

**Not qualified:** no output/source physical aliasing tests, no injected late-write failure atomicity, no native SIMD/LLVM vectorization proof, no non-test GUI caller or colour-space/premultiplied-alpha correctness. The target is scalar levels over **already prepared image values**, not a photo transfer curve or geospatial metadata parser.

## 3. Improved native benchmark

An independent `experiments/r_im_03a_levels/bench_03c` DUB research executable builds a **4-way paired** operation benchmark and stores *every measured invocation* as `RIM03C_RAW`, not just a final median.

Three input cohorts are explicitly selected by CLI argument:

| Cohort | Parameter | 16-bit input construction | Intended mechanism |
|---|---:|---|---|
| Original old-pattern control | `0` | `257 * eightBitCode` | reproduce earlier 256-value cache-locality case |
| **Broad true 16-bit diversity** | `1` | odd multiplier `40503 * (x + width*y) + 8111*channel` modulo 65536 | at 1024², covers full 65536-code domain; code checks >50,000 distinct codes for size ≥256 |
| Smooth synthetic gradient | `2` | weighted horizontal/vertical gradients in full 16-bit domain with channel offsets | smooth image-like spatial correlation, NOT a real photographic corpus |

`ubyte` continues using the old 0–255 fixture for direct comparison across all cohorts; cohort differences apply to `ushort`. The input and four outputs use **owned raster-d** memory with matched source/destination strides and all operation modes reuse those allocations. One full-image warmup per method and direct-vs-LUT + optimized-delta correctness assertion occurs **outside timed work**.

Timing sequence rotates all four methods in every round; raw timing rows identify the method, order, input pattern, channel type, layout and selection-mask state. There are **8 summaries per invocation** (two types × two source layouts × two mask states) and **32 × rounds raw timing rows**.

```bash
# In a separate benchmark clone, beside a pinned raster-d v0.2.0 clone:
cd /path/to/isolated/imagery-d
bash tools/research/bench_r_im_03c_levels_xps.sh "$PWD" 1024 7 0 ldc2 | tee old.csv.log
bash tools/research/bench_r_im_03c_levels_xps.sh "$PWD" 1024 7 1 ldc2 | tee full16.csv.log
bash tools/research/bench_r_im_03c_levels_xps.sh "$PWD" 1024 7 2 ldc2 | tee smooth.csv.log
```

The script rejects an incorrect raster-d SHA without modifying the sibling checkout. It prints git/OS/CPU/governor/compiler and complete benchmark rows. The benchmark reports unique source codes, one-time LUT-preparation microseconds, **four** median timings, per-method count of integer-code differences versus Phobos, LUT payload and a checksum.

**Do not treat benchmark compilation or a tiny GitHub-hosted canary as XPS timings.** The previous single-process/1024² results are preserved as a separate, distinct receipt. As of source authoring, **no native R-IM-03c result is known**. For release qualification repeat with size/corpus/thermal/affinity controls and a semantically identical optimized C++ reference; compute distribution rather than relying on one median, and inspect optimized LLVM codegen and register/stride costs.

## 4. Promotion decision remains OPEN

- If optimized direct is near the LUT within real-photo workloads and avoids half-megabyte allocations, it may be preferable for small/one-off operations.
- If LUT is consistently faster after preparation cost and controlled input entropy, it merits consideration as an **internal prepared fast path**, not mandatory public type.
- A gamma-specific sqrt variant is **not a generic substitute** for arbitrary gamma.
- Any LUT preparation cache, colour and alpha rule, noalias/publication mechanism or SIMD specialization is subject to ordinary M3 engineering admission gates: independently justified consumer, correctness/atomic failure behaviour, bounded residency, DMD/LDC and native performance evidence, documented decision.

No decision about C++ parity or production default should be made until the new native XPS measurements are collected and inspected.
