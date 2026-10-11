# M3.2.12 — Dell XPS unified verified factory: observed results

**Status:** local-state **RESEARCH PASS** for complete 3-path ROI+pixel mapping, lifetime/privacy contracts, and a single private shared execution kernel. **NOT a production, public-API, strict pinned-dependency or prepared-state break-even admission.**

**Captured:** 2026-10-11 20:31:58 UTC.  
**Operator archive:** `prepared-20261011T203158Z.tar.gz`, SHA-256 `f681b7133a9ab8e9139bf3e23650242cf2fa6dd8c799f463936886c27ccd45ca`.  
**Measured imagery commit:** `1e0e0763ed7b4b75561aa4bd2aaac014e7a23d6e`,
branch `research/m3-2-unified-sealed-factory`; tracked source clean.
Two untracked local generated files: `dub.selections.json` and the benchmark executable.  
**Prior experiments:** [M3.2.11 local-state XPS](m3-2-sealed-execution-xps-results.md), [M3.2.10 common-kernel XPS](m3-2-common-pixel-kernel-xps-results.md).

## 1. Host, dependency and compiler provenance

- Dell XPS 15, Intel Core i7-9750H, 6 cores / 12 threads;
  Ubuntu Linux 6.17.0-22-generic, LDC 1.41.0 release
  (DMD frontend 2.111.0, LLVM 19.1.7), DUB 1.40.0.
- `intel_pstate` governor **powersave**, OS-default CPU affinity.
  Dynamic CPU clock and thermal state were not pinned.
- Memory captured about 14 GiB installed / 10 GiB used;
  **4.0 GiB swap used, only ~15 MiB swap free**.
  This is a host-state caveat, not proof of swapped hot code/data.
- Local `raster-d` commit `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`,
  **not** exactly `v0.2.0` tag
  `2f2415851e45001df92ce56dad409f680684ba8d`.
  The 17 local untracked entries are earlier catalogued benchmark
  executables and an `experiments/` directory; no tracked raster
  files were changed. DUB's `raster-d ~release/0.2` line does
  not attest exact release-tag dependency pinning.
- Five independently launched processes; 12 rounds and three mapped
  variants, 24 full map iterations per observation, two warmups.
  The benchmark's schema/banner is still named `M3.2.9`
  because it reuses the same synthetic consumer, **not** because
  the M3.2.12 source was omitted.

## 2. Independent data audit

A separate stdlib-only parser (not the repository's
`analyze_prepared_xps.py`) reviewed all five process logs
against `prepared-raw.csv`, recomputed all published
`prepared-summary.csv` and `prepared-setup.csv` values,
and examined the compiler-negative and codegen artifacts:

- **4,320/4,320 raw mapping records** match the five process logs,
  allowing equivalent numeric checksum spellings (`633`/`633.0`).
- **1,440/1,440 complete three-way matched cycles**: one
  conservative `revalidated_image`, one
  `verified_immutable_image` + ordinary one-shot map, and
  one `prepared_semantic_map`; identical 24 iterations
  and numerical checksums within each matched triple.
- Four band counts **3/17/64/256**, ROI sizes **8/32/64**,
  two layouts (interleaved unmasked or planar with independent
  validity), five processes, 12 rounds.
- Measurement order is exactly balanced: every method appears
  **480 times** in each of the three execution slots.
- All **24** published case medians, median absolute deviations
  and paired speed-ratio medians agree with independent calculation
  within CSV rounding; all **16** preparation rows agree with
  median-of-five per-process setup means.
- For all 1,440 cycles, compared with conservative One-shot,
  Prepared wins **1,010**, loses **385**, ties **45**.
  Compared with already-verified ROI + ordinary one-shot,
  Prepared wins **902**, loses **440**, ties **98**.
- These 1,440 measurements are nested in only five processes,
  not independent samples from 1,440 machines. The elapsed totals
  have 100 ns granularity, roughly 4.17 ns/map at 24 maps/sample.

### Positive, negative and codegen evidence

- Local **LDC 1.41.0 debug and release positive cases PASS** for
  M3.2.6 and M3.2.9, including stored/physical values, layout/mask,
  nested ROIs, invalid descriptors/calibration/destinations.
- Original **four primary/validity/metadata/ROI DIP1000 escape**
  negatives, mutable-`const` metadata rejection and repaired
  M3.2.6 external-forgery negative PASS.
- M3.2.11 raw private-kernel and checked-executor constructor
  access probes PASS. The new M3.2.12 verified-semantic-token
  constructor attempt fails for the *exact private constructor*
  on this LDC, not wrong argument count.
- The XPS disassembly has exactly **one** noninline
  `researchExecuteCheckedPixels` definition. The
  `common-kernel-audit.log` identifies calls in original
  `mapComponentsInto` and the compiled Prepared consumer
  (with the wrapper inlined) and records **PASS**.
- Separately, [hosted CI #38171946199](
  https://github.com/alex-1974/imagery-d/actions/runs/38171946199)
  was **4/4 PASS** for DMD 2.111 / 2.113 and LDC 1.41 / 1.43.
  Hosted benchmark timings are **smoke only**, not XPS performance.

**Remaining stale negative:** the *historical M3.2.9* external
`PreparedSemanticMap` forgery fixture currently fails at
a superseded multi-argument constructor call and is accepted as
a negative-build success by its old regex. It does **not** independently
prove privacy of the current one-argument Prepared wrapper
constructor. Current M3.2.11 and M3.2.12 direct-execution/token
privacy gates do pass for their precise intended denial reasons.
Before API promotion, update the old M3.2.9 fixture to call the
**current exact constructor arity** and require explicit privacy
diagnostics on all four compilers.

## 3. Whole-mapped-image measurements

All values are median **ns per complete mapping** including
ROI derivation, checked raster/validity reads, three-channel
radiometric `stored*0.5-4` and output writes. Each row is
60 matched triples. The speed ratio is the **median of matched
One-shot/Prepared ratios**, not a quotient of marginal medians.

| Bands | ROI | Layout | One-shot ns | Verified ROI + one-shot ns | Unified Prepared ns | Paired old/prepared |
| ---: | --- | --- | ---: | ---: | ---: | ---: |
| 3 | 64×64 | interleaved | 34,004.2 | 33,781.3 | 34,162.5 | 1.0015× |
| 3 | 64×64 | planar+mask | 37,768.8 | 38,550.0 | 38,258.3 | 0.9990× |
| 64 | 8×8 | interleaved | 616.7 | 581.3 | 562.5 | **1.0840×** |
| 64 | 8×8 | planar+mask | 714.6 | 666.7 | 645.8 | **1.0750×** |
| 256 | 8×8 | interleaved | 779.2 | 695.8 | 612.5 | **1.2808×** |
| 256 | 8×8 | planar+mask | 829.2 | 739.6 | 645.8 | **1.2662×** |
| 256 | 32×32 | interleaved | 9,660.4 | 9,583.3 | 9,429.2 | 1.0227× |
| 256 | 32×32 | planar+mask | 9,572.9 | 9,489.6 | 9,308.3 | 1.0273× |
| 256 | 64×64 | interleaved | 39,737.5 | 40,108.3 | 39,333.3 | 1.0084× |
| 256 | 64×64 | planar+mask | 40,770.8 | 40,360.4 | 40,454.2 | 1.0068× |

All 24 combinations are present in the operator's raw CSV
and independent recomputation. For **256 bands / 8×8**,
Prepared was faster than original One-shot in **60/60**
paired rounds **in each layout**, with *paired median*
absolute savings of **170.83 ns/map** in both.
The five process-level medians of the old/prepared ratios
span **1.2065–1.4399×** interleaved and
**1.2595–1.4323×** planar+mask; absolute timing
drift and host variability are visible.

At only 3 bands and 64×64 there is no material advantage.
At 256 bands / 64×64 the ~0.7–0.8% paired median improvement
is small relative to run/process drift and not a general speed
guarantee. A planar 64×64 process-level ratio outlier also
warns against causal interpretations of marginal timing.

## 4. One-time preparation costs: source benefit measured

The experiment separately measures 100 preparation iterations
per process. Values here are **medians of five process means
in ns per preparation**:

| Bands | Borrow + validate | Already immutable image factory | **Unified three-band binding only** | Two `.idup` + image factory |
| ---: | ---: | ---: | ---: | ---: |
| 3 | 2 | 2 | **19** | 115 |
| 17 | 6 | 6 | **19** | 498 |
| 64 | 30 | 21 | **19** | 1,725 |
| 256 | 89 | 89 | **20** | 7,325 |

The new `unified_verified_binding_only` stage **does not
repeat O(channelCount) identity verification**: that work
occurs once in the immutable image factory co-located in the
same D module as the private pixel executor. The binding
stage performs only three explicit selected-band and physical
calibration checks, without allocating a new metadata owner.
Its **19–20 ns** observed cost across all band counts
is consistent with O(1) work, subject to optimization
and timer-resolution uncertainty.

M3.2.11 on an earlier dated XPS run measured **114 ns**
for `sealed_execution_validate_and_prepare` at 256 bands;
M3.2.12 now reports **20 ns** for the *different O(1)
binding stage*. The ~94 ns difference is consistent
with eliminating the redundant O(channels) pass, **not
a controlled, contemporaneous A/B estimate**.

### Illustrative reuse economics — not release thresholds

At 256 bands, a caller explicitly making both immutable
descriptor snapshots solely for this path pays approximately

```text
two .idup + verified factory              7,325 ns
unified checked 3-band binding                20 ns
minus old caller borrow/validate             -89 ns
---------------------------------------------------
incremental preparation                   7,256 ns
```

At the observed **170.83 ns** paired median savings for
256-band 8×8 mapping, an arithmetic payback would be
**ceil(7,256 / 170.83) ≈ 43 mapped ROIs** for either layout.
These are synthetic mapping/reuse assumptions, not
qualified thresholds. The short setup probes may be
compiler-hoisted, their clock granularity is coarse, snapshot
costs are GC/state dependent, and real consumers may reuse
bindings differently.

If the consumer **already owns immutable descriptors**, the
two `.idup` costs do not apply; a verified image is still
required, but no snapshot cost is inherent to this
Prepared path.

## 5. Evidence fingerprints

| Item | SHA-256 |
| --- | --- |
| Full supplied archive | `f681b7133a9ab8e9139bf3e23650242cf2fa6dd8c799f463936886c27ccd45ca` |
| `environment.txt` | `42d459eb57146b05f48518710e807e5d96181a6ed0910059a8d0d067d8379180` |
| `prepared-raw.csv` | `88934d7af0af4905cb42253c52b7ce86d036eb3b5b135062848c6dfe894f1442` |
| `prepared-summary.csv` | `1e2afde6cad671c7b3dd82db79869a08e4a98982eb5f1ccb55f4f03f016fa8bb` |
| `prepared-setup.csv` | `38bc43b9312cdc4e4109cc6d56b8e770a6d40fe8d45eaad48d7ba2fd1f959575` |
| `m3212-unified-negatives.log` | `60acb5cae161bbe583a0d3c39175a2bfe9ae9aa09fb3cd390a7e72b09e7c89d0` |
| `common-kernel-audit.log` | `0942f50ee76d7166e97e64634e6bdd9486d5c61889e526e33bc7966776af203f` |
| `disassembly.txt.gz` | `df5566bf77a71c55fbd121318fc5121032ed89ebeb7e137dd5513080e3818823` |

The `timed-binary.sha256` manifest records
`59cc9a16146a83fa384d0d026c8aebe8399d8187efda341823f11ee6a22a81ac`
for the locally timed executable. The executable **bytes
were not uploaded**; this is an operator-recorded
fingerprint, not an independently rehashed binary or
cryptographic proof tying the disassembly to that binary.

## 6. Decision and next qualification

**Research ACCEPT:** full local-state XPS matched-triple
dataset; safety/lifetime and exact-arity checked-token
constructor denials; one private shared noninline
pixel-kernel mechanism; real prepared-path benefit for
repeated 64/256-band **small** synthetic ROIs; and
the elimination of one duplicate O(channels) preparation
scan while retaining the D module privacy boundary.

**Production/release DEFERRED:** cross-compiler
actual consumer performance, representative ROI reuse,
corrected stale M3.2.9 forged-wrapper negative,
broader NaN/Inf/subnormal/input aliasing and error-order
testing, anti-hoist/GC controlled setup benchmarking,
pinned `raster-d v0.2.0` XPS dependency,
CPU frequency/affinity control and package/API review.
Prior M3.2.7–11 reports remain independent evidence,
not combined into one overclaimed benchmark.

No changes outside `imagery-d`; PR #47 remains
stacked research on #45, no merge to `develop`.
