# M3 Levels — paired native gamma-2 performance evidence

**Date:** 2026-10-20  
**Candidate:** [PR #97](https://github.com/alex-1974/imagery-d/pull/97)
at `06bf260ccca11abb7555746d3c1b001907f08ee0`.  
**Baseline:** original unchanged `develop` `f47c0ca521b89b526d6e943335bca57b773e08ef`,
plus an independently implemented *generic-pow scalar math reference*
reproducing the candidate's pre-optimization pointwise math. This is not
a second `develop` binary: `develop` has no production Levels operator.  
**Dependency:** `raster-d` 0.2.0 source SHA
`2f2415851e45001df92ce56dad409f680684ba8d`.  
**Build:** DUB `--compiler=ldc2 --build=release`, LDC **1.43.0**,
Ubuntu 24.04 GitHub-hosted x86-64.

## Exact workload

A deterministic, bounded 4-channel **ubyte RGBA** input in interleaved
layout, 1-plane byte editing-selection mask with weights **0, 128, 255**,
the three colour channels selected, fourth channel passed through.
ROI is entire 512×384 or 1024×768 image. Parameters: input black
0.08, input white 0.91, gamma 2, output black 0.05, output white 0.95.
All three paths calculate ROI-local, interleaved **float** result, using
`raster-d` resource adoption and a new owned lease. Full sample-by-sample
result equality against both references is checked before timing
(tolerance 2e-6 float, **observed max absolute error 0** on both shapes).

Paths:
- **Candidate:** public `tryLevelsOwned!ubyte`, validation, full payload
  byte-budget check, mask, `raster-d` owner, scalar math with new
  gamma-exact-2 `sqrt` specialization.
- **Generic-pow control:** independent ordinary DUB consumer using the
  equivalent `pow(t, 1/gamma)` for gamma 2, with own `raster-d` owned
  output allocation/import, mask and full pixel read/write. This
  represents the original *scalar math mechanism*, not a byte-identical
  reconstruction of all production preflight/diagnostic work.
- **Sqrt control:** same independent consumer and allocation/ROI/mask
  work, using `sqrt(t)` rather than generic `pow`. It does not
  implement the full candidate parameter/overflow/failure domain.

Two warmup iterations per path; then seven measured iterations per path,
rotating their order every cycle, one CPU affinity selected with
`taskset`. Reports use **medians of full owned-result operation times**
(including output malloc/adoption and all pixel read/writes).
No I/O, image parsing, CLI startup, PPM encoding or synthetic source
generation is timed. `performance` CPU governor was reported on both
runners; virtualized frequency was not fixed or measured.

## GitHub Actions receipts

| Source / machine | Size | Candidate median | Generic-pow median | Sqrt median | Candidate/pow | Candidate/sqrt |
|---|---:|---:|---:|---:|---:|---:|
| [Push #39382305921](https://github.com/alex-1974/imagery-d/actions/runs/39382305921), Intel Xeon Platinum 8573C | 512×384 | 4,572 µs | 36,938 µs | 3,244 µs | 0.1238 | 1.4094 |
| Push, same runner | 1024×768 | 17,596 µs | 146,909 µs | 12,718 µs | 0.1198 | 1.3836 |
| [PR #39382310345](https://github.com/alex-1974/imagery-d/actions/runs/39382310345), Intel Xeon 6973P-C | 512×384 | 3,348 µs | 27,775 µs | 2,359 µs | 0.1205 | 1.4192 |
| PR, same runner | 1024×768 | 14,771 µs | 115,365 µs | 10,153 µs | 0.1280 | 1.4548 |

Both runners reported CPU affinity to logical CPU 0 and `performance`
governor. Each row is a **within-run three-way** comparison, not an
across-run subtraction. [Fast CI #39382310360](https://github.com/alex-1974/imagery-d/actions/runs/39382310360)
also passed DMD 2.111 and LDC 1.41; the full push and PR
DMD 2.113/LDC 1.43 Debug+Release consumer/compile-contract/DDox gates
passed on this same candidate HEAD.

An earlier, preliminary paired `sqrt`-only run on pre-optimization
commit `4498786` indicated candidate/reference ≈13.2–13.5, but its
runner exited with a **test-harness error**: uninitialized D
`double.init` was NaN. It is retained as diagnostic evidence only,
**not a passing benchmark receipt**. The harness explicitly initializes
its sink to zero in the corrected run, and all output correctness checks
must succeed before a performance receipt counts.

## Decision and remaining qualifications

**ACCEPTED as narrow optimization evidence:** exact gamma-2 sqrt
dispatch changes no public signature, is conditional on the exact
declared parameter, preserves the independent gamma-2 test oracle,
and avoids the large generic-pow performance cost for this one
representative masked RGBA workload. Other gamma values continue through
`pow` and gamma 4 is covered by an independent nested-sqrt regression.
The candidate's measured time remains roughly **1.38–1.46x** the
specialized direct-sqrt reference, so there is a residual gap. The
reference omits the candidate's full preflight, overflow and error
checks; the measured residual should not be attributed entirely to a
single unproven code-generation mechanism.

**NOT accepted from this record:** generic gamma performance parity,
color-managed/HDR numerical error envelope, unmasked or u16/f32
performance claims, cross-language C++ equivalence, stable real-world
frequency-controlled XPS measurement, hard throughput threshold,
allocation-count bound, peak RSS cap or full public API release.

No new `static if` mask specialization or unrelated experiment was
admitted. Research branches and prior failed CI evidence remain intact.
