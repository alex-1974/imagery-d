# M3 RGBA — direct-packed 4N owned result: bounded research admission

**Date:** 2026-10-16  
**State:** IMPLEMENTED AS RESEARCH ONLY; **new exact-head CI + native XPS not yet qualified**.  
**Tracking:** Design #75, Research #74, grandfathered Draft PR #73.

## Problem and immutable controls

The original private four-PM-mask fused packed owner is the validated
performance reference. The separately compiled library producer's
full-owned 40-case XPS run regressed in 39/40 cases versus this private
control. Real ThinLTO did not remove four `trySample` and one
`trySetSample` calls from the library's second, pixelwise packing
loop: see
[m3-rgba-owned-library-thinlto-xps-independent-results-2026-10-16.md]
(m3-rgba-owned-library-thinlto-xps-independent-results-2026-10-16.md).

Two prior owners were held concurrently during the original producer:
a **4N four-byte scratch** and a **4N final packed raster**. The
new optimization is **algorithmic**, not a compiler-only request:
do not create four-channel scratch and do not repack a second time.

## Minimal source changes: one math path, two *private* destination types

The exact original `runPreparedRgbaPixels` has gained a **type template
parameter with a default of `ubyte`**. Its color-d conversion,
source-over, alpha handling, preflight and four compile-time PM
combination checks remain a single body. Only the terminal write
is specialized:

- Existing `WritableRasterView!ubyte` writes four byte planes and
  retains its exact old source behavior.
- New `WritableRasterView!SRgba8` writes **one packed POD sample**
  per pixel using the existing **public raster-d
  `trySetSample`** method. No direct memory access, raw pointers,
  reinterpretation, private backing or duplicate color conversion.

A clearly research-only staged-packed variant in `composite.d`
calls the same specialized loop. Its output argument by itself is
**not safe from physical aliasing with caller memory**; no
caller-supplied target/public API is authorized.

The new **research-owned** `tryCompositeOwnedRgbaDirectResearch`
in `owned.d` first validates empty result, checked ROI byte size,
metadata/PM of **the entire source ROI before pixel allocation**,
and then allocates exactly ONE fresh 4N packed raster. The target
is **not published** while `tryCompositeRgbaSourceOverPreparedStagedPackedResearch`
composes into it. At actual pixel use the four-mask specialization
again validates any PM-source bytes. Only after **every** pixel
succeeds does the owner escape through the original empty
`ref RasterLease!SRgba8` result. Any failure destroys a
still-private partially written output under raster-d's established
lease lifetime semantics.

This is still not a concurrent snapshot or Error-level OOM guarantee.

## Memory and performance model — not yet measured

For `N = checked(roi.width * roi.height)`:

| Qualified research producer | Requested physical pixel payload peak | Retained result | Additional full-image passes |
|---|---:|---:|---|
| Private fused owner | 8N bytes | 4N | one packing pass |
| Original separate owned library | 8N bytes | 4N | one packing pass |
| **New direct packed research candidate** | **4N bytes** | **4N** | **none** |

Payload estimates exclude allocator metadata, control blocks,
input owners, global memory pressure, GC stack/ranges and
consumer copies. No general quota/admission guarantee is implied.

Eliminating the five calls in the separate *packing* loop does not
prove that the remaining color computation/packed write has
ideal machine code. The default/ThinLTO ELF and the full-call
benchmark must be inspected separately.

## Implemented independent gates

The existing independently compiled DUB `owned_slice_smoke` consumer
now exercises both producers in **all eight** upper/lower PM mask
× mixed/transparent cases. Every pixel of its non-origin packed
ROI is checked against the independent four-plane reference and
between the 8N and 4N owner. It also checks source-mutation
independence, ordinary raster-d copied owner retention,
nonempty-`ref` rejection, invalid out-of-bounds ROI, inert
`.init` prepared context and invalid last-coordinate PM bytes.

**Actual native libc malloc/import faults against the direct
library function itself** (release + optional ThinLTO):

| Fault kind | Current direct producer expected outcome |
|---|---|
| 1 — scratch malloc | **Does not exist:** no scratch allocation performed |
| 2 — packed pixel malloc | Classified **Exception** from native failure, empty output, no pixel owner retained |
| 3 — packed raster import precommit metadata | Empty output, one previously allocated packed native buffer freed exactly once |
| 4 — packed raster import postcommit metadata | Empty output, one previously allocated packed native buffer freed exactly once, no double-free |

Each error fixture disarms its fault and must successfully
produce/read another complete direct packed result from the
same valid sources. An invalid last-coordinate canonical PM
pixel must stop **before** even the single packed native
allocation despite that malloc being armed. These new gates
are **implemented**, not yet established PASS.

## Distinct full-owned XPS test, no prior archive rewrites

A new unambiguous `--owned-direct-bench` test mode in the existing
independent large research consumer executes three complete
owned producer variants **inside the same binary**, with
four offset ROI byte-perfect oracle comparisons **outside**
timed work:

1. `owned_fused_checked`: original private 8N fused baseline.
2. `owned_extracted_library`: separate 8N library regression control.
3. `owned_direct_packed`: new 4N direct owner.

The independent
`tools/research/run_m3_rgba_direct_xps.sh`
uses the same pinned `git archive HEAD`,
raster-d/color-d v0.2.0, LDC1.43 Release, environment,
48? **40** case matrix (2 meanings × 2 alpha patterns ×
2 layouts × 5 ROI sizes), 7 rotated rounds, 3 stages,
24 complete owned iterations, exact benchmark binary and
native stderr/resource evidence. The independent
`summarize_m3_rgba_direct_xps.py` validator requires
`benchmark_protocol=direct-4N`, valid source/binary
manifest, 40 complete cases, 840 rotated records,
stage/cohort checksum agreement and six-decimal
paired summary reproducibility.

After a successful full `--micro`, the common
`archive_m3_rgba_owned_xps.sh` helper automatically
exports `m3-owned-direct-<run_id>.tar.gz` to
`$HOME/Downloads` without overwriting existing evidence;
the original full measurements remain in ignored
`data/m3-rgba-direct-xps`. The targeted DMD/LDC CI
adds parser self-test, real fault cases, default
three-way semantic smoke and pinned LDC1.43 XPS
smoke/archive checks.

**Status on entry:** no new XPS data exists.
No speedups, reduction in measured RSS or newly
green compiler/CI gates can yet be claimed.

## Admission / stop rule

Investigate on XPS only **after exact-head CI** passes.
Case-specific same-round paired ratios
`owned_direct_packed / owned_fused_checked`
and `owned_direct_packed / owned_extracted_library`
are primary; report cohort medians of 10 case medians
and underlying **absolute** ns/pixel, not pooled
ratios. Compare real ELF symbol/calls and resulting
size. The new 4N bound is an implementation-requested
pixel payload, not peak process RSS. A direct result
must preserve exact pixel oracle and native failure
semantics before any performance acceptance.

**Promote nothing** to `source/imagery` or
`develop` until genuine downstream need, external
DUB usability, entire native fault/error/ownership
matrix, negative scope/attribute tests and full
release-performance evidence are approved by a
numbered M3 ADR. This research PR remains
OPEN/DRAFT on its grandfathered stacked base.
No API freeze, merge, release or sibling repo writes.
