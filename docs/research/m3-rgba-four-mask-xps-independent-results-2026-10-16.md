# M3 RGBA — four-mask PM specialization: independent XPS paired review

**Date:** 2026-10-16 · **Research #74 / Design #75 / Draft PR #73**
**Disposition:** ACCEPT the **bounded observed performance result**;
**EVIDENCE ARCHIVE INCOMPLETE** (missing measured executable);
DEFER any public API, merge, release, or production performance guarantee.

## Source identities and exact captured artifacts

User-provided native XPS archive:
`20261016T084410Z.tar.gz`, SHA-256
`02f8de70e3acfea1d04e9e8075eeb0bee198650ebb2b733db710542d88c42921`.

The archive's `environment.txt` names:

- measured imagery-d commit
  `58a122e18e037dbf0f42a7509582d7c6e4857002`;
- LDC **1.43.0 Release**, DUB **1.42.0**, XPS-15,
  `2026-10-16T08:44:10Z`;
- raster-d **v0.2.0**
  `2f2415851e45001df92ce56dad409f680684ba8d`;
- color-d **v0.2.0**
  `3359f08f4e83941ac1a8451cadefb146b5736019`.

The source commit differs from the previous
**straight-dispatch** XPS recording
`20261016T080204Z.tar.gz`
(SHA-256 `069657e0c9619753ff974c4c7a7d4d0aed06653f16901032f732df432d0643a2`,
measured commit
`3c202beae50927bdda130f981c6248a50cecdcb1`),
and the initial fused implementation
`20261016T065934Z.tar.gz`
(measured commit
`a0f397688637667ff51e042089a2eb64308cdcd3`).

All **five** GitHub workflows for the **new exact
measured source commit** completed **SUCCESS**,
including DMD 2.112.1/2.113.0 and LDC 1.42/1.43
RGBA consumer gates with the 432-scene
all-pixel oracle, the four upper/lower/both PM
post-preflight mutation negative tests, native
malloc/import ENOMEM and original ownership probes.
Green CI does **not** establish full image-source
thread-safe snapshot or physical source/output noalias.

## Original-data replay — precise limits

The reviewer used an independent Python raw-data
recalculation, NOT the archived
`FUSED_COMPARISON.csv` as an authority, and checked:

- **40/40** individual raw CSV SHA-256 entries;
- original `environment.txt` and `build.log`
  SHA-256: both match the original manifest;
- **42 of the 43** original manifest entries are
  actually present and all **42/42** match;
- **840/840** valid timing records
  (40 cases × seven paired rounds × three
  complete owned-result stages; each 24 iterations);
- required rotated stage order, format/semantic
  headers, nonzero stage durations, exact human-readable
  success trailer, and distinct ROI case dimensions;
- **40/40** independently recomputed 21-column
  summary rows agree **exactly** with the archive
  at six decimal places;
- **20/20** semantic checksum groups agree between
  source planar/interleaved layouts;
- **40/40** per-case stderr streams empty;
- all 840 observed current-thread GC allocation
  deltas zero. Thread-local GC allocation is
  **not** peak RSS or physical native allocation.

### Incomplete manifest: hard limitation

The uploaded archive **OMITS**
`m3-fused-owned-consumer`, although the unchanged
original `CHECKSUMS.sha256` lists its hash:

`13e983daad9c9034f231574f6fba43d158d8ec10fa7beb5ad2ae1b87da680030`

Thus **43/43 original manifest PASS cannot be
claimed from this upload**, and neither the exact
native executable bytes nor compiled **code size**
were independently qualified by the reviewer.
The source SHA is supported by recorded
`environment.txt` and independent exact-head CI,
not the missing executable's content hash.
This is an **artifact transport/completeness
qualification gap**, not evidence that image
numerics or the timing CSVs are wrong.

Recover without new measurements: use the same
original XPS output directory
`data/m3-rgba-fused-xps/20261016T084410Z`,
run `sha256sum -c CHECKSUMS.sha256`
there and rearchive **including the unchanged**
`m3-fused-owned-consumer` file.
Alternatively upload only this original
binary with its hash. Do NOT rebuild a
different binary and call it the original,
overwrite the raw CSVs, or relabel provenance.

## Subsequent native XPS manifest confirmation — terminal receipt

The user subsequently provided the **original XPS terminal output**
from `data/m3-rgba-fused-xps/20261016T084410Z`
showing `sha256sum -c CHECKSUMS.sha256` reporting **OK
for all 40 CSV files**, `environment.txt`, `build.log`,
and specifically **`m3-fused-owned-consumer: OK`**.
This is **43/43 native-local manifest verification**, using
the original measured executable rather than rebuilding it.

**Evidence strength and limits:** the user-supplied terminal receipt
closes the prior uncertainty about *whether the original executable
still exists and matches its original SHA on the XPS*. It does
**not** retroactively add the executable to the previously
uploaded `20261016T084410Z.tar.gz`; independent byte-for-byte
review of that native executable and its code size remains blocked
until the original file is transmitted. The prior 42/43
**archive** completeness statement remains historically true,
while the original XPS **local** integrity is now reported
as 43/43. Do not conflate these two verification contexts.
No benchmark restart or alteration of measured files is needed.

## Recomputed end-to-end paired performance

Three real full owned RGBA materialization paths
are compared *inside each of seven same-case rounds*:

1. `owned_old_order`: baseline ROI scan after
   scratch allocation;
2. `owned_early_preflight`: early full ROI check
   before malloc, plus a second PM ROI scan;
3. `owned_fused_checked`: early full ROI check
   before malloc and only check each PM input's
   already-read local pixels in the output loop,
   using four compile-time PM masks selected
   **once per ROI**.

For each source meaning/pattern cohort, the result
below is the **median of the 10 case-specific
seven-round median full-call ratios**. This is
neither a ratio of unrelated pooled stage means
nor a cross-commit paired experiment.

| Meaning / alpha case | Earlier straight-dispatch fused/old | New four-mask fused/old | New double/old | New fused/double | New signed fused−old ns/px | New cases >5% |
|---|---:|---:|---:|---:|---:|---:|
| encoded-sRGB straight / mixed | 0.999983 | **0.999782** | 1.004509 | 1.002326 | −0.020186 | **0/10** |
| encoded-sRGB straight / transparent | 1.001685 | **1.000252** | 1.001571 | 1.000438 | +0.006358 | **0/10** |
| linear-sRGB PM / mixed | 1.021543 | **1.006288** | 1.086757 | 0.914951 | +0.604630 | **0/10** |
| linear-sRGB PM / transparent | **1.112738** | **1.023381** | 1.209895 | **0.843454** | +0.773112 | **0/10** |

**Main quantitative result:** The *transparent-PM*
fused/old cohort median improved from a within-previous-run
**+11.27%** slowdown to a within-new-run
**+2.34%** slowdown; the number of its cases above
the preregistered **+5% review trigger** fell
from **10/10 to 0/10**. On this XPS and matrix,
the new fused/old case medians range from
**1.01080 to 1.039995** for transparent PM.
Linear-PM mixed improved from **+2.15%** to
**+0.63%**, with 0/10 cases above +5%.
The new encoded-sRGB controls remain broadly
at parity. Across **all 40** new cases,
the largest case-specific median fused/old
ratio is **1.044723** (encoded-sRGB
mixed, planar 64×64 ROI).

The single new run also provides direct
**fused vs double** same-round control ratios,
0.843454 (transparent PM) and 0.914951
(mixed PM); unlike the across-commit trend,
these are within-run comparisons.

The *different earlier and newer XPS runs*
were not randomized across source commits,
so their ratios cannot be treated as paired
between runs or as a universal causal/CPU
performance guarantee. Small ROIs in
particular have broad observed min/max
within-round variation. We have no repeated
independent days/hosts or binary code-size
comparison yet; the locally supported result
is **threshold met for the recorded XPS
workload**, not a general 0–5% bound.

## Design and admission implications

- The new **four-mask compiled check variant**
  preserves early fail-before-first-pixel-malloc
  validation, local PM checks on the exact
  consumed bytes, private staged scratch and
  no packed-result publication on failure.
- The caller-owned prepared destination
  variant retains full PM checking
  before its first output write.
- No longer justify more speculative hot
  loop branching variants on this evidence
  alone: the preregistered +5% review trigger
  has been cleared on this host/workload.
  First close the **missing measured binary**
  and review code size/codegen.
- **Still open:** actual downstream result
  form A/B, physical noalias enforcement
  for caller-owned output A, failure disposition
  and native Error-level OOM acceptance for B,
  Tier-R RSS, source concurrency and a
  minimal production package/consumer. The
  research-owned 8N peak / 4N retained
  requested pixel sizes do NOT bound
  process RSS or allocator metadata.

**Review status:** The 40-case performance
evidence is internally consistent and CI
qualified for its source commit. **Exact
binary evidence NOT fully archived**.
Promote neither the research wrapper
nor public API until its real contracts
and release gates are accepted.
