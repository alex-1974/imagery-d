# M3 — Exact runtime sRGB8 LUT inside public raster.zipTransformInto

**Date:** 2026-10-13. **Status:** research-only, awaiting native XPS measurements.
**Branch:** `research/m3-rgba-layer-compositing`, Draft PR #73 stacked on Draft #69.
**Domain:** two already decoded **straight, encoded sRGB8** RGBA layers;
linear-light `color-d v0.2.0` source-over; fixed upper-layer opacity **0.37**.

## Why this specific experiment exists

The [qualified XPS standalone LUT experiment](m3-rgba-lut-xps-2026-10-13.md)
reports approximately **2.5× complete packed-array** throughput with a
byte-exact runtime `double[256]` source sRGB-decode table. But its timed
function does **not** use checked `RasterView` execution or physical
alias preflight. It cannot support a production geometry/lifetime claim.

The next experiment must compare:
1. Public **`raster.zipTransformInto!direct`**, and
2. Public **`raster.zipTransformInto!exactTable`**,

with **exactly identical raster operations** and color mathematics,
both using raster-d's own structural checks, destination injectivity,
physical source/output overlap decisions and optimized row executor.

That source-level apples-to-apples comparison is implemented in the
independent DUB executable
[`experiments/m3_rgba_layer_compositing/lut_packed_zip/`](../../experiments/m3_rgba_layer_compositing/lut_packed_zip/).

## Important D/raster interface constraint

[`raster-d v0.2.0 zip_transform_into.d`](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/zip_transform_into.d)
requires a compile-time transform alias usable as:

```d
@safe pure nothrow @nogc SRgba8(SRgba8 left, SRgba8 right)
```

The callback receives **no runtime context**. A mutable global pointer,
thread-local mutable LUT or closure capture would weaken this contract
(and violates `pure`); modifying `raster-d` is outside scope.

The D language **explicitly permits once-only runtime initialization of
an `immutable` module variable inside `shared static this()`**, after
which pure functions may access that immutable shared state.
References:
[D language `immutable` initialization](https://dlang.org/spec/const3.html);
[D shared module initialization](https://dlang.org/book/concurrency_shared.html);
[D pure function global-state rules](https://dlang.org/book/functions_more.html).

Research construct:

```d
private immutable PreparedLut preparedLut;
shared static this()
{
    auto table = makeRuntimeTable(); // exact color-d runtime transfer
    preparedLut = table;             // one immutable initialization
}
```

The actual code also times one-time initialization and stores
`setupUs`. The **immutable global process lifetime** is an
experimental integration mechanism, not an accepted general API
or engine owner design. No GC allocation occurs in the timed pixel
callbacks. The global is **not** reinitialized when color profiles,
pixel representations or callers change; in this probe it only
applies to the explicitly encoded, straight, **byte-domain**
sRGB8 contract.

No CTFE table equivalence is presumed. The runtime-generated values
are checked **for all 256 channel bytes** against actual runtime
`color-d` on each supported DMD/LDC compiler. This specifically
avoids treating `__ctfe` Phobos pow and LDC `llvm_pow`
as automatically binary64-identical.

## Meaningful A/B semantics and gates

The two callbacks invoke the **same** actual
`color-d` `premultiply`, `sourceOver`,
`unpremultiply`, `toSRgb` and `tryToSRgba8`
functions, with the same expression order and the same
compile-time opacity 0.37. Their **only intended difference**
is the `toLinear` step versus lookup of the runtime-prepared
binary64 equivalent in the immutable 256-entry table.

Three independent retained-owner `RasterLease!ubyte`
buffers provide the **unchanged four-plane semantic reference**.
Inputs/output for both tested packed paths are
`RasterLease!SRgba8`, **separate** from the reference and
each other. No private `raster.internal` import is used.

Kernels are exercised under:
- mixed alpha (0/128/255), all opaque, all transparent with
  **nonzero hidden RGB**;
- **compact** and **row-padded** packed layouts (the same
  meaningful elementwise 32-bit sample arrangement);
- full-image and **nonzero-origin offset ROI**
  (`Region2D(7,11,w-14,h-22)`);
- every output pixel in the ROI compared against both
  competing packed outputs and against the four-plane reference;
- **all pixels outside partial ROIs remain the original sentinel**;
- actual **left/output and right/output physical alias**
  are rejected by raster with the exact error category,
  **before writing**, with all source bytes checked unchanged.

These do not cover general planar packed-input adaptation,
negative strides, multi-image scheduling or
4/8/16-bit input formats. Raster-d's own generic
tests separately exercise its negative-stride and
noninjective-destination cases.

Every timing run:
- warms both zip paths and the semantic reference outside
  the measured intervals;
- **alternates order** of equivalent public zip API
  calls between rounds;
- requires **0 current-thread GC allocated-byte delta**
  for either timed path;
- reports direct/LUT microseconds per round,
  iterations, ROI pixel count, checksum, mismatch count and
  one-time `lut_init_us`;
- performs all-pixel differential again after every
  paired timing round.

**Remaining limitation (critical):** The selected
`zipTransformInto` callback returns only `SRgba8`.
It cannot propagate a checked **quantization failure**.
The experiment's failure branch uses `SRgba8.init`,
and expected test fixtures stay finite and storable.
This callback is **not** a general production
`tryComposite` replacement. It also has
fixed compile-time opacity 0.37, no arbitrary runtime
opacity API, no general association validation
and no new caller-owned table/engine lifetime model.

## Compiler CI and real XPS qualification

The new workflow
[`m3-rgba-lut-packed-zip.yml`](../../.github/workflows/m3-rgba-lut-packed-zip.yml)
builds a real separately linked DUB consumer against
tagged `raster-d v0.2.0` and `color-d v0.2.0`.
Correctness matrix: DMD **2.112.1/2.113.0** and LDC
**1.42.0/1.43.0**. It executes the 3 × 2 × 2
= **12 packed-layout/alpha/ROI combinations** per
compiler, two timed rounds each, plus the LDC 1.43
debug build and a pinned-snapshot runner smoke.
**CI results must be verified against the exact
current commit**; earlier queued/failed workflow runs
are not acceptance.

For the reference hardware, use the **read-only
pinned** runner:

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/imagery-d
git status --short
git fetch origin
git merge --ff-only origin/research/m3-rgba-layer-compositing
export PATH="$HOME/dlang/ldc-1.43.0/bin:$PATH"
hash -r
ldc2 --version | sed -n '1,3p'
OUT="$PWD/data/m3-rgba-lut-zip-xps/ldc143-$(date -u +%Y%m%dT%H%M%SZ)"
bash tools/research/run_m3_rgba_lut_zip_xps.sh "$OUT"
tar --exclude='./snapshot' -czf "$HOME/Downloads/$(basename "$OUT").tar.gz" -C "$OUT" .
```

The runner archives **committed source HEAD** and both exact
v0.2.0 release commits (without writing to sibling repos),
builds once in release, directly invokes the generated executable,
captures CPU/governor/memory/compiler/RSS/faults,
all raw paired-round CSV files, SHA-256 for each file,
and stderr/build logs.

A qualified native run will measure 512² and 2048²,
three alpha patterns, two layouts and full/partial ROI:
**24 cases** at LDC 1.43.0. These results, not the
packed-array 2.5× ratios, will answer how much of the
LUT advantage survives the actual alias-checked raster
execution boundary.

## Native XPS evidence (2026-10-13 18:11 UTC)

The first **full, pinned, supported-LDC** real-XPS run has now
been reviewed and retained in the
[standalone benchmark evidence report](m3-rgba-lut-zip-xps-2026-10-13.md).

**24/24** raw CSV SHA-256 checksums; **144/144** complete paired
measurement rounds; 0 differing RGBA pixels, 0 observed
current-thread GC-byte deltas, both prewrite physical
source/destination overlap directions rejected, and
all 24 stderr logs empty.

For **mixed alpha**, median case throughput speedup
on the *same public zip executor* is **2.496× at 512²**
and **2.456× at 2048²**, covering compact/row-padded
input and whole/offset ROI. Both fully transparent
inputs are a special-case ~**14.6–14.9×** ratio
and must not be advertised as a typical image rate.
One-time runtime immutable LUT initialization took
**19 µs median**, range 14–38 µs.
No exact small-ROI crossover was measured.

**This closes the restricted native-XPS performance
observation gate, not production API/failure/lifetime
acceptance.** The callback still only returns `SRgba8`,
has fixed 0.37 opacity and cannot signal arbitrary
checked quantization failures. Keep the branch/PR DRAFT
and do not modify sibling libraries.

## Decision rules

1. Require exact per-pixel output and exact
   quantization/alias/error proof within the
   probe's limited declared scope; benchmark
   discrepancies are not automatically good.
2. Do **not** advertise the earlier
   packed-array ~2.5× as the speedup of this
   public-zip kernel until measured here.
3. Distinguish added program-level
   immutable table lifecycle/setup cost
   from per-operation hotloop time.
4. Do not infer packed RGB input support for
   arbitrary image color profiles or planar
   image layouts.
5. No production API/ADR, no new `raster-d`
   overload, no new `color-d` assumption,
   no modifications in other repositories,
   no merge into `research-integration`,
   `develop` or `main` without separate
   acceptance evidence.
