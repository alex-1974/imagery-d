# M3.2.13 — Exact Prepared forgery proof and anti-hoist setup qualification

**Status:** Two full four-toolchain runs **PASS**, including
[CI #38174431567](https://github.com/alex-1974/imagery-d/actions/runs/38174431567)
and [CI #38174649217](https://github.com/alex-1974/imagery-d/actions/runs/38174649217).
The exact private constructor denial, all inherited DIP1000/semantic
and full-pixel oracles, and the end-to-end four-route setup evidence
runner are qualified. **Local Dell XPS timing, optimizer/codegen
interpretation and release reuse break-even remain OPEN.**

**Issue:** [#48](https://github.com/alex-1974/imagery-d/issues/48)  
**PR:** [#49](https://github.com/alex-1974/imagery-d/pull/49)  
**Branch:** `research/m3-2-preparation-hardening`,
stacked on M3.2.12 `research/m3-2-unified-sealed-factory`.
No changes outside `imagery-d`.

## 1. Repair a false-positive negative compilation

The previous M3.2.9
`negative-prepared-forgery` test attempted the obsolete
**five-argument** `PreparedSemanticMap` constructor. After the
M3.2.11 private checked-executor refactor its actual constructor
accepts **exactly one** `ResearchCheckedExecution` argument.

The old DMD/LDC build failed because the call had the wrong argument
count/types, while the old grep accepted any diagnostic mentioning
`constructor`. Such a failure does **not** establish privacy.

The new source-level external probe uses:

```d
return PreparedSemanticMap(ResearchCheckedExecution.init);
```

The intended type and *current arity* are valid; construction
must be forbidden because `PreparedSemanticMap.this` is private
to its defining module. The new runner specifically matches the
named constructor and `private`/`not accessible`-equivalent
compiler diagnostic at `app.d`. Mere wrong arity, import failure,
linker failure or syntax errors do **not** qualify. All M3.2.6
and M3.2.11/12 existing whole-source lifetime/private access
negative tests still run on DMD 2.111/2.113 and LDC 1.41/1.43.

## 2. Why the original 19–20 ns setup number was exploratory

[M3.2.12 local XPS research results](
m3-2-unified-sealed-factory-xps-results.md) showed an
`unified_verified_binding_only` stage of 19–20 ns
for 3/17/64/256 channels, versus 114 ns for M3.2.11's
*semantically different* once-only revalidation+binding at 256.
That matched the source mechanism (one full identity scan removed),
but the original setup probe used only **100 nearly identical
iterations per process** and could be distorted by:

- LDC interprocedural hoisting/inlining and constant arguments;
- the sample count and 100 ns timer granularity;
- allocator and GC state during the two explicit `.idup` paths;
- CPU frequency, temperature, cache, affinity and almost-full swap;
- differences between immutable retained backing and caller-mutable
  alias contracts.

The earlier ~43-ROI snapshot amortization is a **numerical
illustration**, not a release-quality decision threshold.

## 3. New independently checked preparation workload

A new CLI in the existing M3.2.6 experiment is:

```text
--setup-challenge       [iterations=20000] [rounds=12] [warmups=2]
--setup-challenge-smoke [iterations=24]    [rounds=2]  [warmups=1]
```

It benchmarks **four separate preparation operations**:

| Label | Measured semantic work |
| --- | --- |
| `borrow_validate` | Build mutable-descriptor M1 image and borrow intrinsic metadata, checking IDs per setup. |
| `immutable_verify` | Build verified immutable image (O(channelCount) identity scan), with no snapshots. |
| `unified_binding_only` | Prepare three explicit selected bands from an already verified immutable image, excluding its factory cost. |
| `snapshot_and_verify` | Copy two mutable descriptor arrays via `.idup`, then validate and construct the immutable image. |

Eight preconstructed metadata sets vary IDs, calibration scale
and offset. The timed setup uses a deterministic runtime-evolving
LCG selector, different input set each iteration, and four
`pragma(inline,false)` wrappers. The selected binding rotates
among three distinct permutations. Each timed method returns
an observable checksum which is validated against an **independent
non-timed expected sequence**; an invalid duplicate-band binding
is separately checked before timing. The four methods rotate
execution positions. Raw data include run/round/slot/mode,
iterations, measured nanoseconds, observed checksum and oracle.

This is a **stronger anti-hoist challenge**, not a formal proof
that no compiler transformation can eliminate work.
In particular the sealed binding result only exposes the success
marker; no pixel mapping is performed in this isolated setup test.
Use the separately retained real three-way pixel benchmark for
whole-operation performance. Any very short setup latency must
still be reviewed against optimized disassembly and longer
controlled XPS distributions.

`analyze_setup_challenge.py` refuses incomplete four-path cycles,
duplicated modes/slots, different iteration counts, checksum
oracle mismatch and inconsistent input-dependent results.
It reports median/MAD per channel count/mode, while leaving
raw time series available for inspecting drift.
At 12 rounds the rotating method ordering is balanced.

## 3a. Completed hosted qualification

[GitHub Actions #38174649217](
https://github.com/alex-1974/imagery-d/actions/runs/38174649217)
finished **4/4 PASS** (DMD 2.111/2.113; LDC 1.41/1.43).
Every job executed the existing M3.2.6/9/11/12 positive and
negative contract suite, including the corrected **current exact
one-argument** M3.2.9 forged-Prepared constructor privacy check,
then a dynamic preparation smoke and the retained independent
three-way mapped-image pixel oracle.

LDC 1.43 also executed the **entire new evidence runner** in
tiny hosted-smoke mode (`REPEATS=1 ROUNDS=4 ITERATIONS=24 WARMUPS=1`):
the analyzer accepted **16 complete four-path cycles / 64
measurements** and reported **balanced execution slots: True**.
All four route-specific runtime checksums agreed with the independent
selector oracle. It wrote the expected raw/summary CSV and JSON,
compiler-negative log, and timed-binary hash manifest.
A hosted success establishes runner integrity, **not** a speedup
or nanosecond-quality measurement; no hardware XPS results were
collected for this new experiment.

## 4. XPS reproduction

From `libs/imagery-d`:

```bash
git fetch origin
git switch research/m3-2-preparation-hardening
git pull --ff-only origin research/m3-2-preparation-hardening

COMPILER=ldc2 REPEATS=5 ROUNDS=12 ITERATIONS=20000 WARMUPS=2 \
  bash experiments/m3_2_validated_roi/tools/qualify_setup_challenge_xps.sh
```

The script records Git source SHA and worktree states for imagery
and raster, compiler/DUB versions, CPU governor and affinity,
hardware/memory snapshots, all historical and exact current
constructor-negative compiler logs, optimized binary SHA-256,
source-independent per-process raw benchmark logs, statistical
CSV/JSON outputs and available disassembly/symbol inventory.
It does not checkout/clean/reset/write `raster-d` or any sibling
repository. When the local raster checkout is not exactly
`v0.2.0`, report the measured commit and label the evidence
**local-state research**, not exact release-tag performance.

The main `--prepared-consumer-benchmark` remains a separate
end-to-end mapping workload. Preparation is relevant only when a
consumer reuses enough ROIs with the same genuinely immutable
metadata and verified binding to justify setup.

## 5. Admission decision

**Already supported:** the sealed common-private-kernel semantics,
DIP1000 lifetimes and four-compiler exact-constructor denial;
[M3.2.12 recorded XPS data](m3-2-unified-sealed-factory-xps-results.md)
remains the source-specific pixel-mapping research baseline.

**Not yet admitted:** new anti-hoist XPS timing numbers, GC- and
frequency-controlled allocation latency, real consumer ROI reuse,
any release break-even threshold, a public Prepared/ImageView
ownership API or a strict pinned-`raster-d v0.2.0` comparison.

Preserve grandfathered stacked research PRs and evidence;
no merger of the experimental chain wholesale into `develop`.
