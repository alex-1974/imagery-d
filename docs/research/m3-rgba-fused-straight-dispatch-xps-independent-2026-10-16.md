# M3 RGBA — independent XPS straight-alpha hot-path dispatch control

**Date:** 2026-10-16 · Research Issue #74 · Design Issue #75 · Draft PR #73
**Decision:** ACCEPT the bounded straight-alpha dispatch evidence,
**REVIEW** remaining PM overhead, and **DEFER** production API/merge/release.

## Exact archive and source identity

User-provided complete native archive:
`20261016T080204Z.tar.gz`, SHA-256
`069657e0c9619753ff974c4c7a7d4d0aed06653f16901032f732df432d0643a2`.
It was captured on the XPS-15 at `2026-10-16T08:02:04Z`
using LDC **1.43.0 Release**, DUB **1.42.0** and
measured imagery-d commit
`3c202beae50927bdda130f981c6248a50cecdcb1`.
The comparison/reference archive
`20261016T065934Z.tar.gz` came from
**different imagery-d commit**
`a0f397688637667ff51e042089a2eb64308cdcd3`
on the same XPS and toolchain at `06:59:34Z`.

Both archives pin read-only `raster-d v0.2.0`
`2f2415851e45001df92ce56dad409f680684ba8d`
and `color-d v0.2.0`
`3359f08f4e83941ac1a8451cadefb146b5736019`.
The *sole intended new source behavior* is an
alpha-association dispatch **outside** the emission pixel loops:
if neither layer is PM, call the original no-extra-PM-check
mathematical emission specialization; otherwise retain the
fused per-sample PM validation. Early semantic preflight
before any owned scratch allocation is unchanged.

## Independent raw evidence replay

Independent Python verification (without trusting or importing
the bundled summarizer) checked **both** archives:

- **43/43** original SHA-256 manifest files per archive,
  including all raw measurements and exact measured executable;
- **40/40** cases per archive, two source layouts,
  two source meanings, two alpha patterns, five ROI sides;
- **840/840** full-result observations per archive, with
  7 rotated same-case rounds × 3 owned result stages ×
  24 iterations, positive measured duration and correct metadata;
- exact literal success trailer in all raw CSV files,
  no stderr bytes across 40 cases in each archive;
- **40/40** recomputed 21-column summary rows per archive
  equal the archived `FUSED_COMPARISON.csv` at its
  six-decimal precision;
- all **20** source-meaning/pattern/ROI pixel checksums
  agree across planar and interleaved source layout;
- all recorded per-thread GC allocation deltas are zero.
  This is **not** a claim of zero native allocation,
  GC metadata, peak RSS or concurrency safety.

All **five GitHub workflows**, including **four
DMD/LDC RGBA consumer jobs**, completed SUCCESS
for the **exact new measured commit** `3c202bea...`.
Neither a Green CI nor a pixel checksum alone proves
physical source noalias or no partial private scratch
writes on an unexpected error.

## Recomputed paired performance

For each combination of meaning and alpha pattern there
are **10 cases** (two storage layouts × five ROI sides).
First compute each case's median of **seven within-round
full-call** `owned_fused_checked / owned_old_order`
ratios; then report the **median of ten case medians**.
This is not a ratio of unpaired stage-level medians,
nor a population speed guarantee.

| Semantic meaning | Pattern | Prior fused/old | New fused/old | New fused−old ns/px | New cases > +5% |
|---|---|---:|---:|---:|---:|
| encoded sRGB / straight | mixed | 0.996995 | **0.999983** | −0.002543 | 0/10 |
| encoded sRGB / straight | fully transparent | **1.097787** | **1.001685** | +0.040563 | **0/10** |
| linear sRGB / PM | mixed | 1.023399 | **1.021543** | +1.957194 | 1/10 |
| linear sRGB / PM | fully transparent | 1.131921 | **1.112738** | +3.610229 | **10/10** |

As a within-new-run **double-scan** control,
the median double/old ratios are respectively
**1.000166**, **1.000130**, **1.073929** and
**1.210612**. The straight-alpha
`fused/old` regression is essentially eliminated
without removing the early validity check.

The two **different** XPS runs are not an
interleaved/cross-commit randomized paired experiment.
One can compare their *internally paired ratios*,
but must not claim that every inter-run delta is a
same-clock-frequency causal speedup. The new
straight-transparent cohort is consistent across
source layouts/ROI sizes (0/10 cases over 1.05)
and the preceding cohort showed 9/10.
For transparent linear-PM, a persistent
**~11.27%** median increase remains, with
**10/10** cases crossing the +5% review trigger.
Mixed linear-PM is substantially closer to the old
one-scan path (+2.15%), although **one** case
still exceeds the threshold.

Example: interleaved **128×128 linear-PM** ROI
(new source):
- mixed: old 85.3185 ns/pixel, redundant 91.4271,
  fused 88.0198; same-round fused/old **1.02554**;
- transparent: old 30.8734, redundant 37.0717,
  fused 34.4724; same-round fused/old **1.11484**.
These are different stage medians; the paired ratio
need not equal a ratio of separately rounded medians.

## Mechanism and bounded next hypothesis

The current fused `runPreparedRgbaPixels!true`
contains **per-pixel runtime tests** for
`upper.association == premultiplied` and
`lower.association == premultiplied`, then
RGB<=A checks on the already-read local channel bytes.
These input associations are invariant for one
ROI operation. Whether LDC actually hoists
these checks is a **codegen question**, not
answered by wall-clock alone.

The proposed narrow follow-up is a **four-way
compile-time-specialized** PM-check mask,
dispatched **once per ROI** (no PM / upper only /
lower only / both). The existing emitted-color
math remains identical and the source pixels
actually used remain checked. A benchmark and
code-size comparison must establish whether the
new source shape helps transparent PM: it could
increase binary/code-cache pressure and perform
worse. Avoid another family of caching/scheduler
research types or public ABI flags. Retain
the original prepared destination guarantee
(fail-before-first-output-write) separately.

Do not weaken the early check on invalid PM input
before first malloc or silently omit a local
check on PM samples consumed after possible
source mutation. The `@safe` view alone does
not prove immutable input or physical nonoverlap.

**Decision:** ACCEPT the straight-alpha
hot-path dispatch as independently demonstrated
in research; ADAPT/MEASURE the remaining
two-source PM predicate under identical existing
native benchmarks; DEFER production API,
merge, release and any universal performance claim.
