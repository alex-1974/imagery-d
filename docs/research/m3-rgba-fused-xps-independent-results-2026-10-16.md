# M3 RGBA — independent XPS three-way fused checked result

**2026-10-16 · Issue #74 / Design #75 · Draft PR #73 · research only**

**Disposition:** ACCEPT verified XPS measurement; ADAPT the fused
private-staging approach, **DO NOT promote this source shape as production**.
The new PM path recovers most of the redundant-scan penalty for mixed alpha,
but transparent PM and encoded-sRGB transparent still exceed the registered
+5% review trigger. No production API, merge, freeze or release.

## Evidence, provenance and independent replay

User-provided archive `20261016T065934Z.tar.gz`
**SHA-256 `118092167003fc43e3f124aa31fbe20fe94aadbb9f4a00950af6ca1047c020ec`**,
recorded `2026-10-16T06:59:34Z` on XPS-15, Linux
6.17.0-22, LDC 1.43.0 Release, DUB 1.42.0.

- Measured *imagery-d source*:
  `a0f397688637667ff51e042089a2eb64308cdcd3`.
- Pinned *raster-d v0.2.0*:
  `2f2415851e45001df92ce56dad409f680684ba8d`.
- Pinned *color-d v0.2.0*:
  `3359f08f4e83941ac1a8451cadefb146b5736019`.
- This archive includes the exact measured release executable,
  build log, environment/cpu metadata, SHA-256 manifest, raw CSV,
  derived `FUSED_COMPARISON.csv`, per-case resource logs and empty stderr.
  Snapshot sources are present but **not** a substitute for the manifest's
  measured executable bytes. Live sibling worktrees were **not** used
  to build the benchmark.

Independent re-analysis of the archive's **raw CSV records**:
- **43/43** original SHA-256 entries match, including **40/40**
  benchmark CSV files, build log, environment and captured binary;
- **840/840** timed records (40 cases × seven rounds × three stages)
  have valid shape, positive duration, per-round stage rotation,
  correct 24 iterations and consistent case metadata;
- **40/40** rebuilt 21-column summary rows equal the archived
  `FUSED_COMPARISON.csv` **exactly at six decimal places**,
  without importing/trusting the source summarizer;
- **20/20** semantic meaning/pattern/ROI output hashes agree
  across planar versus interleaved source layouts; all
  **40 stderr files are empty**;
- all recorded per-thread GC byte deltas are zero. They do
  **not** establish zero allocator metadata, peak RSS,
  thread safety, or a physical memory guarantee.

All **five GitHub workflows** for the **exact measured
source commit `a0f397...` have completed SUCCESS**,
including the DMD 2.112.1/2.113.0 and LDC 1.42/1.43
independent consumer gates, native malloc/metadata
fault qualification, all-pixel oracle and paired
benchmark smoke. GitHub Actions CI is a correctness
gate, not a native XPS performance reference.

## Whole-result performance

All three stages are the *same* privately implemented full
owned packed `SRgba8` materialization, each including
scratch/packed malloc, public raster imports, source-over
and final result release. Their only intended differences
are preflight/check ordering:

- `owned_old_order`: one canonical PM scan after scratch allocation;
- `owned_early_preflight`: canonical PM scan before
  malloc, then a redundant full PM ROI scan after malloc;
- `owned_fused_checked`: canonical PM scan before
  malloc, then checks RGB<=A on locally loaded RGBA
  bytes **in the emission loop**, with no second
  independent full ROI scan.

**Method:** 10 cases per meaning×alpha cohort
(two source layouts × five ROI sides, 16–256 pixels).
For each case, compute **seven same-round
early/old, fused/old and fused/early ratios**, then
take their median. This table takes the **median of
the ten case-specific paired medians**. It is not a
ratio of independently pooled stage means or a
claim about all CPUs.

| Source semantics | Pattern | Double / old | Fused / old | Fused / double | Paired double−old median ns/px | Paired fused−old median ns/px | Fused/old cases >1.05 |
|---|---|---:|---:|---:|---:|---:|---:|
| Encoded sRGB / straight | mixed | 1.00057 | **0.99700** | 0.99415 | +0.048 | −0.244 | **0/10** |
| Encoded sRGB / straight | fully transparent | 1.00095 | **1.09779** | 1.08546 | +0.023 | +2.349 | **9/10** |
| Linear sRGB / premultiplied | mixed | 1.07840 | **1.02340** | 0.95149 | +6.954 | +2.131 | **0/10** |
| Linear sRGB / premultiplied | fully transparent | 1.21530 | **1.13192** | 0.92932 | +6.899 | +4.154 | **10/10** |

The paired median fused/old ratios correspond to
approximately −0.3%, **+9.8%**, +2.3% and
**+13.2%**, respectively, by the above table order.
**20/20** mixed/transparent linear-PM cases were
previously affected by duplicate scan;
the fused approach improves both relative to the
double-scan control, but remains materially slower
than the old allocation-before-preflight shape
where compositing is cheap. The 1.09779
encoded-transparent ratio is especially noteworthy
because neither source requires PM validation:
the additional runtime hot-loop test and/or
different optimized code shape may be responsible;
**the measurements do not prove which instruction
or compiler transform caused it**.

Selected cross-checks, **absolute per-stage median ns/pixel**:

| Case (interleaved, 128×128 ROI) | Old | Double scan | Fused | Same-round fused/old ratio |
|---|---:|---:|---:|---:|
| Linear-PM mixed | 87.316 | 93.899 | 89.468 | 1.025207 |
| Linear-PM fully transparent | 31.681 | 38.490 | 35.866 | 1.136029 |

The paired *ratio* need not equal the ratio of independently
rounded stage medians. Transparent PM has a larger
relative penalty partly because its original
compositing path is less expensive. No per-pixel
timing stage is arithmetically added to another.

## Implication and bounded next experiment

**Keep** early semantic preflight before the first pixel
malloc, correct disposal on late failure, and fully
private scratch before packed-result publication.
Those are separately mechanically qualified contracts.

**Do not** consider the new fused hot path performance
neutral. To determine if its unexpected encoded-transparent
overhead is due to the PM branch, make a minimal internal
single-dispatch specialization when **both**
source associations are `straight`: that case
needs no PM check in the inner loop, so call the same
compile-time original no-PM emission kernel.
For any PM source retain the fused check on the
locally loaded bytes; no unchecked public bypass
or borrowed-source immutability assumption.
Prove all 432 scenes, late-PM mutation classification,
no publication on failure and native ENOMEM guarantees
again before paired XPS remeasurement. If the
transparent linear-PM +13% persists, investigate
a bounded *same-pixel* PM predicate/codegen control,
not a speculative cache or new public optimizer family.

**Still open:** output form A/B selection, caller target
physical noalias, partial mutation on read/write failure,
native GC Error-level OOM, source data races/torn reads,
external consumer/public API admission, Tier-R physical
memory cap. A verified requested 8N/4N Tier-P accounting
rule is not a physical RSS guarantee.

**Result:** ADAPT narrowly; DEFER API/merge/release.
