# M3 RGBA Hotpath Attribution — Independent DUB Stage Consumer

**Research-only:** 2026-10-13. **Issue:** #72. **Draft PR:** #73,
stacked on #69. The baseline is
[m3-rgba-xps-2026-10-13.md](m3-rgba-xps-2026-10-13.md)
and motivation comes from
[m3-rgba-external-engine-hotpath-audit.md](m3-rgba-external-engine-hotpath-audit.md).

## Scope and methodology

This probe does **not** implement a new compositor, color kernel,
SIMD, public API or borrowed-pointer execution surface. It compiles a
separate real DUB executable
[`experiments/m3_rgba_layer_compositing/hotpath/`](../../experiments/m3_rgba_layer_compositing/hotpath/)
against **released** `raster-d v0.2.0` and `color-d v0.2.0`.

It instrumentally separates *workload classes* corresponding to the
current `tryCompositeRgbaSourceOver` operation, using **actual color-d
public types/functions** and a deterministic straight-encoded RGBA8
input fixture. It does not duplicate sRGB transfer functions or
Porter–Duff equations in the library under test.

For every measured case:

1. Create three **separate owned four-plane** raster leases for upper,
   lower and caller output, plus explicitly allocated **separate**
   arrays for packed input, decoded output and intermediary linear values.
   This isolates original ownership and avoids hidden full-image
   allocation inside the measured work.
2. Exercise three alpha distributions: **fully opaque**,
   **fully transparent with nonzero hidden RGB**, and **mixed**
   (zero/128/255). Sources are never premultiplied encoded sRGB.
3. Exercise **planar/interleaved** raster layouts and full/partial
   rectangular ROI. Packed color-stage arrays are contiguous irrespective
   of the requested four-plane raster layout; stage timings must
   **NOT** be compared as if changing the layout of packed arrays.
4. Before any timing, compute complete encoded-straight output both
   through the isolated color stages, the fused packed-array pipeline,
   and the **existing checked four-plane imagery research adapter**.
   Assert **exact byte equality of every output RGBA pixel** in the ROI.
5. Warm each stage, measure independently for N calls and alternate
   the order of seven measurements between rounds. After every round,
   recompute and independently validate the same complete outputs
   against the canonical research adapter.
6. Measure `GC.stats().allocatedInCurrentThread` byte deltas in each
   measured stage, require exactly zero, emit raw elapsed microseconds
   and deterministic output checksums. This does *not* demonstrate zero
   native allocations elsewhere in the process.

Each run emits one CSV line per **stage × round**. For example, with
three rounds the CSV contains **21** lines, plus header and a PASS
marker. Every stage operates on the same ROI pixel count, but its
work is purposefully different. **The stage costs are not additive and
cannot be subtracted from an end-to-end time to claim the cost of one
function**: input formats, memory working sets, validation, compiler
inlining, cache behavior and output types differ.

### Seven measured stages

| Stage | Precisely measured call workload | Important qualification |
|---|---|---|
| `checked_io` | Eight `RasterView!ubyte.trySample` + four `WritableRasterView!ubyte.trySetSample` calls, byte-XOR between two source channels | Checked-access *control only*; XOR is NOT color equivalent and it writes caller raster output. |
| `decode_2rgb` | Two `color.SRgba8.toAlphaSRgb!double` normalizations and **two** `color.SRgbd.toLinear` transforms, storing two `LinearSRgbd`-with-alpha values | Six sRGB channels per pixel, same color-d decode. No premultiplication, blend or raster view access. |
| `premultiply_2` | `color.premultiply` for two prepared straight linear+alpha values | Precomputed inputs, no decoding or color packing. |
| `source_over` | Scale premultiplied foreground light **and** alpha by opacity **0.37**, then `color.sourceOver` into a preallocated linear-premultiplied result | Identical math to canonical fixed-opacity path; no decoding, output unpremultiplication or quantization. |
| `unpremul_encode_quantize` | `color.unpremultiply`, `toSRgb`, and checked `tryToSRgba8` into a packed pixel | Includes alpha-zero transparent-black canonicalization and 8-bit half-up policy. |
| `packed_full` | Decode both input `SRgba8`, premultiply, source-over, unpremultiply, sRGB encode, quantize in one packed array loop | **Same tested output**, but array indexing vs checked four-plane IO and *no* prewrite alias enforcement; diagnostic, NOT production. |
| `fourplane_full` | The **unchanged** research `tryCompositeRgbaSourceOver` on lease-bound `RasterView!ubyte` | Full current checked four-plane adapter with runtime opacity and public view API. |

Explicitly **not** measured: per-component processor cycle counts, a
`pow`-only fraction, cache misses, SIMD vectorization, exact
per-operation scratch peak, full renderer frame latency. Those require
separate disassembly/profiling evidence. A naive 8-bit sRGB lookup table
or approximate polynomial is **not** part of this test.

## Qualified CI matrix

New [`m3-rgba-hotpath-stage-attribution.yml`](../../.github/workflows/m3-rgba-hotpath-stage-attribution.yml)
uses pinned `raster-d`/`color-d v0.2.0` and builds a **real DUB
consumer** with `-preview=dip1000`.

Compilers:

- **DMD 2.112.1**
- **DMD 2.113.0**
- **LDC 1.42.0**
- **LDC 1.43.0**

For each compiler, exercise **3 alpha distributions × 2 four-plane
layouts × 2 ROIs = 12 independent end-to-end stage scenarios**,
**2 rounds × 7 stages = 14 timing rows per scenario**; assert
exact per-pixel equality to canonical imagery output, unchanged
post-round checksum and zero observed thread-local GC allocation.
LDC 1.43.0 also runs the partial-ROI smoke under DUB debug.

A pinned-snapshot **runner-smoke** in the same workflow executes
[`run_m3_rgba_hotpath_xps.sh`](../../tools/research/run_m3_rgba_hotpath_xps.sh)
with `--smoke` against *read-only git-archived* release sources,
validates four independent short CSV files, provenance and SHA-256
checksums. The runner and its resulting measurements are not promoted
into production source.

## Native XPS measurement recipe

From the `imagery-d` research branch after a safe fast-forward to
the new commit, and in the terminal session where **LDC 1.43.0** is
active:

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/imagery-d
git status --short
git fetch origin
git merge --ff-only origin/research/m3-rgba-layer-compositing
export PATH="$HOME/dlang/ldc-1.43.0/bin:$PATH"
hash -r
ldc2 --version | sed -n '1,3p'
bash tools/research/run_m3_rgba_hotpath_xps.sh
```

The runner **rejects non-1.43.0 LDC**, creates two independently
pinned dependency checkouts without touching sibling branches and
builds one release executable in
`imagery-d/data/m3-rgba-hotpath-xps/<UTC>/snapshot/`.
Every case runs the built executable **directly** under
`/usr/bin/time -v`, recording environment and source SHAs, the CPU,
governors, memory state, process resource usage, raw stage CSVs and
SHA-256 for each case.

Default XPS workload: **512×512 with 5 rounds × 2 iterations**, and
**1024×768 with 4 rounds × 2 iterations**; cross **three alpha
distributions × two raster layouts × two ROIs** (24 complete
scenarios). Smaller `--smoke` is for CI.

Exclude the generated snapshot when packaging evidence:

```bash
OUT=$(find data/m3-rgba-hotpath-xps -mindepth 1 -maxdepth 1 -type d | sort | tail -n1)
tar --exclude='./snapshot' -czf "$HOME/Downloads/m3-rgba-hotpath-xps.tar.gz" -C "$OUT" .
```

If local `git status` is dirty, inspect it before a branch update.
The runner itself archives committed HEAD only and never overwrites
live sibling work. Timing on GitHub-hosted runners is useful only
for same-run diagnostics, not for an absolute XPS reference.

### Validated derived summary

After checksumming raw scenario CSV files, the runner invokes
[`summarize_m3_rgba_hotpath.py`](../../tools/research/summarize_m3_rgba_hotpath.py)
to produce `STAGE_SUMMARY.csv` with stage **median, min, max,
nanoseconds/pixel/call, rounds and checksum**. The summarizer validates
the raw column schema, seven stages per round, complete unique round
indices, consistent workload definitions, zero per-stage GC-byte deltas,
and identical canonical output checksums between planar and interleaved
layout for otherwise identical fixture/ROI configurations.

The summary is **derived**; the authoritative checksummed evidence
remains the raw case CSV set. The derived `STAGE_SUMMARY.csv` is
generated after the checksum manifest and is not included in that
manifest. Run the summarizer again to reconstruct it.

A fast stage does not prove its counterpart in a complete compositor is
cheap: there are different arrays, layout checks, input reuse and compiler
optimizations. The summary shows **where to focus profiling next**, not
a mathematically additive breakdown or a verified number of
`llvm.pow` calls.

## Decision gates after observing native stage results

1. Document per-distribution/ROI **paired raw median spread**;
   do not state isolated `pow` cost without a `pow`-specific probe.
2. If decoding dominates, test **exact indexed 256-byte decode LUT**
   as another independent experiment with exact output comparison
   to `color-d v0.2.0` for every input byte and all 432 original
   numerical scenes. CTFE/runtime double rounding matters.
3. If generic checked IO dominates, explore **existing public**
   raster execution/packed POD mechanisms first; a general noalias
   and failure-complete public API needs its *own* boundary review.
4. Consider prepared linear-premultiplied regions only with an explicit
   cache/working-set budget and lifetime contract. Benchmark first-use
   plus repeated composition separately.
5. SIMD/JIT/threading only after codegen inspection and proof of
   numerical/API equivalence, including partial ROI, invalid PM,
   alpha-zero canonicalization and fail-before-write on errors.

**Status:** stage-attribution correctness is qualified only when the
CI gates on the **exact experiment commit** pass. Native XPS timings
require the user's next uploaded raw evidence. Retain Draft PR #73;
do not merge or modify sibling repositories.
