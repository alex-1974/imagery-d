# M3 RGBA — Buffered commit, failure injection and allocation-inclusive micro-ROI research

**Status:** evidence-only prototype; native XPS micro-run **not yet provided**.
**Last method revision:** 2026-10-13. **Scope of writes:** `imagery-d` ONLY.
External `raster-d` and `color-d` interfaces are read-only at tagged **v0.2.0**.
Existing stacked Draft PR #73 remains open; no integration merge or public API admission.

## 1. Why another experiment is necessary

The [qualified large-image buffered XPS run](m3-rgba-buffered-copy-xps-2026-10-13.md)
at research commit `80415be3...` established a reused-scratch
buffered packed final commit at about **1.82–1.86×** the
original direct four-plane throughput on mixed-alpha
512²/1024×768 cases, with about **5–6%** extra
per-pixel time compared with a separate prepared
four-plane path. However the **two ROI-sized scratch
allocations** were done *before timing*. The
numerical 2-KiB prepared LUT was constructed once
per process, also outside timing.

It did NOT prove whether allocating/freeing scratch for every 16²/32²
viewer refresh costs more than the color work, nor did it prove original
source/target noalias or snapshot behavior. The new research revision
asks **both** smaller allocation-cost and prewrite-failure questions,
without changing external APIs or rewriting `raster` internals.

## 2. Supported public mechanisms and important nonclaims

- Prepared four-plane compositing reports classified
  `RgbaCompositeError` and accepts validated **runtime**
  opacity, using the exact binary64 color-d sRGB8 decode LUT.
  It retains the existing **caller source/output nonoverlap
  precondition**, with possible **partial scratch** on late
  read/quantization/write failure.
- `raster.copyInto` from a separately owned
  `RasterLease!SRgba8` to an owned packed target
  validates **scratch-vs-target** physical overlap,
  shape and final target injectivity before the copy.
  This is *not* a public prewrite checker for arbitrary
  **original four-plane source vs packed target** relations.
- The experiment does NOT use `@trusted`, false
  double-ownership of external buffers, raw-pointer
  forging to simulate overlap, `raster.internal`,
  duplicated affine proof logic, or changes in
  `raster-d`/`color-d`.
- **Original source/output overlap remains an open
  contract decision.** The public owner/view
  representations used here do not establish a
  physically aliased pair of a legitimate original
  `RasterLease!ubyte` and independent writable
  `RasterLease!SRgba8` referring to the same owner.
  Creating two independent owners for the same malloc
  resource would risk double destruction and is
  **not an acceptable test fixture**. The test therefore
  cannot claim original-source alias rejection or
  proven snapshot writes; it classifies that requirement
  as **BLOCKED by the current public representation**.
  If a future caller API chooses snapshot semantics,
  qualify it with one legitimately shared resource and
  a documented borrowed typed view/copy model, not a
  forged owner.

## 3. Expanded negative copy/prepare checks

The existing independent **432-scene** DUB research consumer
(`experiments/m3_rgba_layer_compositing/smoke/source/app.d`)
now additionally verifies **for every case**:

1. A separately owned packed final output is filled
   with a nontrivial RGBA sentinel. Calling the
   prepared four-plane computation with an inert
   `ResearchPreparedRgbaContext.init` returns
   `invalidPreparedContext` and the full packed
   final target remains exactly equal to the sentinel.
   No commit is attempted.
2. A deliberately **wrong-shaped packed final
   destination** containing the same sentinel is
   rejected by the public `copyInto` with
   `RasterCopyError.shapeMismatch` *before writes*.
   Every output pixel, including the added extra
   column, is checked unchanged.
3. The existing **same-backing packed source/target**
   copy-negative still returns
   `sourceDestinationOverlap`, and every
   previously staged pixel is compared after
   rejection. This proves *scratch vs packed target*,
   **not original four-plane sources vs target**.
4. The original smoke negative matrix continues to
   reject NaN, +/-inf, out-of-range opacity,
   invalid ROI, encoding, and noncanonical
   linear-premultiplied input, with unchanged
   four-plane sentinel output when preflight
   rejects the input.

These are **recoverable classified failures**,
not intentional segfault/paging tests. They
do not establish universal all-or-nothing writes
for an unexpected low-level failure during the
last copy. Both scratch allocation and metadata
construction are fully owner-managed; no simulated
double free or unowned writable pointer is introduced.

## 4. Matched reused vs allocation-inclusive benchmark

The existing DUB stage-attribution consumer now measures
**ten** independent stage labels, preserving the previous
eight mathematical/differential controls. New pair:

| Stage label | What is timed | Not timed |
|---|---|---|
| `buffered_packed_commit` | Prepared four-plane computation → separate packed scratch repack → **public `copyInto`** to caller-owned final packed target, with **two reused ROI-sized scratch owners** | 2 KiB prepared table creation, first scratch allocation, caller's final target allocation, image fixture setup |
| `buffered_allocating_commit` | **Two new native `malloc`-backed ROI-sized scratch owners per call**, same prepared computation/repack/copy, and destruction on exit | Prepared table creation, caller's final target allocation, image fixture setup |

Both use the **same** prepared LUT, input pixel patterns,
opacity **0.37**, source and final owner/view contract,
result type, and mathematical oracle. The second treatment
allocates exactly two **4 bytes/ROI pixel** scratch
payloads for **8 bytes/pixel** aggregate live payload;
both share an already owned separate final target.
The source and target remain independent and the
same packed copy preflight runs in both treatments.
No GC allocations are *expected* in timed loops;
C `malloc`/free are native and **not** counted as GC,
which is why both treatments' wall times must be
paired and whole-process resource logs retained.

The two treatments' outputs are each verified
**outside timing** against the independently computed
RGBA mathematical oracle after every paired round.
Output staging errors still propagate classified
statuses in the caller-visible underlying prepared
four-plane function, but the stage wrapper currently
reduces successful/error cases to `bool`; it is a
benchmark, not a proposed error-typed public API.

### Native small ROI protocol

`tools/research/run_m3_rgba_hotpath_xps.sh --micro OUTPUT_DIR`

- input backing fixed at **512²**; selected nonzero-origin
  `Region2D(5,7,N,N)` with
  **N = 16, 32, 64, 128**, preserving original
  source and final output dimensions where meaningful;
- two alpha distributions **mixed** (0/128/255)
  and **transparent with nonzero hidden RGB**,
  plus two layouts **planar/interleaved**:
  **16 independent case processes**;
- **7 rotated stage-order rounds × 24 ROI invocations**
  of **each of 10 stage labels** within each process;
  checksummed raw CSV, full cross-stage byte
  equality per ROI, current-thread GC delta, CPU
  governor, environment, build log, stderr,
  maximum RSS and process paging;
- `--micro-smoke` uses 192² backing,
  N = 16 and 64, both layouts, mixed alpha,
  two rounds, two iterations, for the CI gate.
  The existing `--smoke` and full benchmark
  remain available.

The native XPS analysis MUST compare
**within each same-process/same-ROI paired scenario**:
`buffered_allocating_commit / buffered_packed_commit`
(for total native allocation/destroy cost), and
`buffered_packed_commit / prepared_fourplane_full`
(for buffering/repack/copy overhead).
Absolute ns/pixel must be qualified separately,
especially for 16² since overhead dominates.
The per-scenario ratio is not evidence for a
fixed automatic dispatch threshold; record
CPU governor/clocks/thermals and use a second
independent session before a release-regression threshold.

`STAGE_SUMMARY.csv` is a **derived** unpaired
per-stage summary; for claimed paired factors use the
source raw CSV rounds by identical `round`, not merely
the ratio of aggregated stage medians. Do not
add isolated stage costs together.

### Run after exact-head GitHub CI is green

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/imagery-d
git status --short
git branch --show-current
git fetch origin
git switch research/m3-rgba-layer-compositing
git merge --ff-only origin/research/m3-rgba-layer-compositing
export PATH="$HOME/dlang/ldc-1.43.0/bin:$PATH"
hash -r
ldc2 --version | sed -n '1,3p'
OUT="$PWD/data/m3-rgba-hotpath-xps/alloc-micro-$(date -u +%Y%m%dT%H%M%SZ)"
bash tools/research/run_m3_rgba_hotpath_xps.sh --micro "$OUT"
tar --exclude='./snapshot' -czf "$HOME/Downloads/$(basename "$OUT").tar.gz" -C "$OUT" .
```

The runner rejects an output directory that already
contains files, compiles **committed HEAD** in pinned
source snapshots created only under ignored
`imagery-d/data/`, and does not alter sibling
working trees. If local Git status or branch motion
blocks the fast-forward, **do not reset** user work.

## 5. Decision state

The earlier 9-stage large-XPS evidence
at commit `80415be3...` is still valid **only
for the 9-stage version and that workload**.
The ten-stage micro benchmark must pass the
four-compiler CI and a **new native XPS** run
before new performance claims.

**Research verdict today:** Failure-negative and
small-ROI allocation-vs-reuse instrumentation
are implemented; original-source/final-target
alias proof remains a public-representation
blocker. No selected snapshot semantics,
no generalized error-atomic API, no prod
change, no merge, and **no writes outside imagery-d**.
