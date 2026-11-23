# Hessian vertical rows: paired source experiment, 2026-11-23

Refs #214; measurement protocol #212; path/statistics kernels #213.

Source receipt: `d049ecd21421dd94977c15bc68022d596a7e936a`; tracked modifications: `False`.
Binary build source: `d049ecd21421dd94977c15bc68022d596a7e936a`.
Host: Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz; measured CPUs [5]; observer CPUs recorded per session.
Overall collection: **subset_measured**. The portable configuration remains the default.

3/3 cells reach the strict minimum. Qualified and inconclusive effects are identified individually below.

## Scope and protocol

prepared Float32 input; strict worker except opt-in Gaussian32; Hessian three scales 1,2,4; frame copy/hash outside clock.

Same-target source comparison against 640f44bb3a377041995e2ce9fa2c833b72b8a9d1. LDC 1.43.0 ordinary DUB release, safe bounds checks, line-table metadata and loop-vectoriser success/missed/analysis remarks. Each A/B pair holds the target fixed; the three settings are absent, `x86-64-v3`, and `native`. There is no fast-math override. Each target independently passes the full numerical oracle.

At 1024² the standalone Hessian workspace owns four Float64 planes (32 MiB), separate from its caller-owned input/output. The 8 MiB Engine tile budget for #213 does not describe this standalone operation.

A separate pilot chooses 1..100 frames per cell, targeting at least 150 ms of kernel work so SMT tick accounting is observable. The batch kernel time is divided by its frame count; output publication/hash remain outside the clock. Four cells form each ABBA cycle. The source change must preserve exact full-output fingerprints.

The unchanged control is the same portable C shared object for every ISA setting, validated on 120 retained Canny cases. It runs on the measured physical core before and after each executable, with identical untimed preheat. Per-target D controls are retained separately as diagnostics.

At least 15 complete accepted cycles are required. The median ratio uses the geometric mean of the two symmetric A and B cells. A seeded 4,000-draw bootstrap resamples whole cycles. A conclusive effect additionally requires 10% change. Endpoint frequency movement >5%, load >6, governor/power changes or SMT sibling busy fraction >5% reject the entire cycle. Zero tick intervals are unresolved and rejected. Controls are diagnostic, not a normalization factor. Observations used in each result, including rejected cycles, are retained; retries stop at 90 cycles per cell or the predeclared per-session collection cap. A cap is checked only after a complete cycle and never admits fewer than 15 accepted cycles.

Combined receipts retain disjoint completed cells, with CPU and session provenance in the JSON. No existing cell is replaced by a preferred rerun. An interrupted legacy attempt is explicitly recorded; unfinished in-memory observations from that attempt are excluded. Each paired cycle uses one physical core.

## Paired results

| Kernel | Setting / CPU | ns/px median ± MAD | Baseline ns/px ± MAD | Ratio [95% CI] | Cycles accepted/rejected | Effect | Exact output identity |
|---|---|---:|---:|---:|---:|---|---|
| hessian | portable / 5 | 414.169 ± 1.963 | 646.432 ± 3.782 | 0.639 [0.634, 0.642] | 15/0 | improvement | True |
| hessian | v3 / 5 | 373.152 ± 2.135 | 657.187 ± 2.403 | 0.566 [0.565, 0.568] | 15/0 | improvement | True |
| hessian | native / 5 | 372.163 ± 1.103 | 603.384 ± 0.909 | 0.616 [0.615, 0.617] | 15/1 | improvement | True |

## Descriptive raw pairs

These intervals include every complete recorded cycle, including frequency/SMT exclusions. They describe the observed busy host and provide no target admission or isolated-core claim. The strict table above retains the original hygiene decisions.

| Kernel | Setting / CPU | Raw cycles | Ratio [95% CI] | Observed effect |
|---|---|---:|---:|---|
| hessian | portable / 5 | 15 | 0.639 [0.634, 0.642] | improvement |
| hessian | v3 / 5 | 15 | 0.566 [0.565, 0.568] | improvement |
| hessian | native / 5 | 16 | 0.616 [0.615, 0.617] | improvement |

## Deterministic instruction companion

valgrind-3.27.1, 32², identical cache model and collected `imageryInstructionRegion` (prepared compute plus complete output copy; setup/hash excluded). The original portable binary supplies the initial comparison policy; this extra Hessian check is separate from the six-kernel regression gate. No wall-time or hardware-counter claim follows from simulated misses.

| Metric | Before | After | After/before |
|---|---:|---:|---:|
| instructions | 8080066 | 5031292 | 0.6227 |
| d1_misses | 3898 | 3913 | 1.0038 |
| ll_misses | 27 | 27 | 1.0000 |

Unmodified comparison-policy check: **pass**. The before/after receipts, binary hashes and exact commands are in the adjacent JSON. Both timed Hessian builds use one frame per cell, so the later benchmark-only batch-preheat correction does not change their preheat work.


A ratio below 1 favors A. An inconclusive effect is not an improvement claim. These prepared-kernel results are not an Engine overhead or 60-fps admission.

## Loop decisions

| Loop family | Decision |
|---|---|
| Path row stencils | #213 exposes bounded equal-length min/max row expressions and an exact byte carrier. Keep the complete masked/wide-domain scalar fallback. |
| Local statistics | Keep exact integer rolling counts, ordered Float64 sums, constant certificates and centered fallback. Reduction/early-exit remarks do not justify reassociation or loss of masks. |
| Gaussian32 and median | Existing bounded row expressions / rank network allow packed operations. Width is a compiler decision; a missed loop remark is not proof that its body has no packed SLP/array instructions. |
| Ridge/Gabor accumulation | Equal-length array expressions already isolate the tap computation. Winner stores remain semantically ordered; bank angles do not call atan2. |
| Gradient/Hessian angles | Retain libm and exact degeneracy/validity rules. No polynomial error policy or approximation is introduced. |
| Hessian/tensor vertical taps | A separate source experiment traverses each tap across contiguous rows, preserving each pixel’s original tap order. The horizontal scalar traversal supplies the bit-exact transpose oracle; no new working planes are allocated. |
| Validation, preparation, full-domain fallback | Preserve safety checks, exits and independent reference behavior. Do not use unchecked pointers or blanket fast-math to silence remarks. |

No explicit-vector function was added, so there is no new vector/scalar dispatch to qualify. Existing DMD scalar and LDC vector luminance code remains in the ordinary functional matrix. No byte median 5x5 or new 16-bit API is claimed. Integer histograms and CLAHE already exist; a different lane-partition scheme needs its own representative benchmark. See [ADR 0024](../adr/0024-optional-code-generation-targets.md).

## Compiler evidence and reproduction

The adjacent remarks file retains every distinct hot-source remark emitted by the requested loop-vectoriser passes, including bare “loop not vectorized” messages for which LLVM supplied no more precise reason. Locations may occur with several reasons because templates and fallback paths are instantiated more than once. This is a compiler-reported inventory, not a claim that LLVM reports every machine loop. Other sources/dependencies and unknown locations remain in the full build logs; their hashes are in the JSON receipt.

Build the recorded binary-source commit in an isolated checkout before running the current qualification tools. For the source comparison, retain both the baseline and changed-source artifact directories. The commands below show the artifact layout, not a claim that today’s HEAD reproduces an earlier compiled source.

```sh
ORACLE_PYTHON=/path/to/pinned-python bash tools/build-codegen-experiment.sh benchmark/results/hessian-214
/path/to/pinned-python tools/qualify-codegen.py --artifacts benchmark/results/hessian-214 --output benchmark/results/hessian-214/paired --cpu auto --baseline-artifacts benchmark/results/codegen-214 --features hessian
python tools/report-codegen.py --artifacts benchmark/results/hessian-214 --measurements benchmark/results/hessian-214/paired/codegen.json --destination docs/benchmarks --stem hessian-rows-2026-11-23 --instruction-before benchmark/results/hessian-214/counter-before/instructions.json --instruction-after benchmark/results/hessian-214/counter-after/instructions.json
```

Pinned Python references: `tests/feature_program/requirements.txt`. Full binary/oracle/log/validation hashes and compiler version are retained in the adjacent JSON. Raw cycles live under the reproducible output directory.
