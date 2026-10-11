# M3.2.11 — Sealed checked execution: research qualification

**Status:** Source-level research design implemented. DMD/LDC/negative and
codegen evidence are tracked on [PR #45](https://github.com/alex-1974/imagery-d/pull/45).
**Do not admit a public API or production merge on source review alone.**

**Issue:** [#44](https://github.com/alex-1974/imagery-d/issues/44)  
**Branch:** `research/m3-2-sealed-execution`, based on
`research/m3-2-common-pixel-kernel`.  
**Prior measured baseline:** [M3.2.10 XPS results](
m3-2-common-pixel-kernel-xps-results.md).

## 1. Threat: external preflight bypass

M3.2.10 separated full metadata/binding preflight from one shared checked
pixel loop. But its `researchExecuteCheckedPixels(image, indices,
scales, offsets, ...)` was exported from an experimental D module.
An `@safe` caller could supply arbitrary indices/calibrations.
`@safe` makes checked array/raster memory access safe; it does **not**
establish valid image semantics or radiometric identities.

**Invariant:** no unverified caller may execute the common pixel kernel
with unchecked semantic indices and calibration values.

## 2. Construction-controlled, nonowning execution value

The M3.2.11 experiment places both the original M3.2.2 one-shot
mapper and `ResearchCheckedExecution` in
`m3_2_channel_metadata.contract`. The only pixel/validity/write
loop is now a **module-private** `pragma(inline,false)`
function, so an ordinary external import cannot invoke it.

The checked value has:
- explicit **private constructor**, suppressing external D aggregate
  initialization or positional fabrication;
- inert `.init` (cannot perform mapping);
- borrowed `ImageView!float` and three selected band/calibration
  values, not pixels, owners, or copied buffers;
- `return scope` child-ROI construction preserving primary/validity
  and semantic backing lifetimes;
- `scope @safe nothrow @nogc` output mapping that checks **each**
  destination's three-plane count and exact ROI extent, then calls
  the same private checked pixel function as one-shot.

The only public *research* checked-capability factory does **not**
accept a caller's arbitrary `ImageView`, which may contain
`const(ChannelDescriptor)[]` with mutable aliases. Instead it
accepts `RasterView!float`, truly
`immutable(ChannelDescriptor)[]` and
`immutable(IntrinsicChannel)[]`, an optional validity view, and
explicit binding/interpretation. It verifies plane/metadata counts,
**all channel semantic IDs**, distinct in-range bound bands,
single-plane aligned validity, required finite physical calibration,
and constructs a new `ImageView` *from those immutable descriptors*.

The M3.2.6 `ValidatedImmutableImage` now retains its original
immutable identity slice, and M3.2.9 `PreparedSemanticMap` wraps
the checked execution capability rather than exposing any raw
kernel call or its selected-index/scalar arguments.

### Work/complexity

- Initial `ValidatedImmutableImage` construction: O(channelCount).
- Initial `ResearchCheckedExecution` sealing: **another O(channelCount)
  identity comparison** plus O(1) explicit 3-band preparation.
  This is a deliberate, visible *once-per-prepared-binding* cost to
  avoid an unsafe cross-module "trust me" flag.
- Derived ROIs: no repeated semantic-ID pass, just checked raster and
  optional validity ROI/extent work.
- Per mapping: O(width × height) shared checked pixels; destination
  shape verified per call. No new metadata snapshot, GC allocation,
  owner or unsafe pointer arithmetic is introduced.
- Source pixel buffers are not immutable; the borrow is nonowning.
  Callers must still meet the raster backing lifetime contract.

To eliminate the duplicate **one-time** identity pass in production,
the image factory and sealed-execution factory would need a
shared private implementation module/capability. Do **not**
reintroduce a caller-forgeable boolean to bypass it.

## 3. Ordinary one-shot contract preserved

The original `mapComponentsInto` remains the caller-mutable
`const` fallback: it rechecks all channel IDs, binding,
destination shape, validity, and calibration *on every call*.
Its error order and no-write-on-preflight-failure checks from
M3.2.10 remain required. The original and sealed maps call the
same **private noninline execution loop** after those checks.

The invalid-mask-to-zero behavior remains *research-only policy*,
not a general NoData, alpha or colour-conversion API.

## 4. Qualification gates

Four-toolchain CI: **DMD 2.111.0, 2.113.0 and LDC 1.41.0, 1.43.0**,
with pinned GitHub `raster-d v0.2.0`. Each job must pass:
- existing M3.2.6 semantic/lifetime debug+release and six negative
  scope/mutable-metadata/forgery tests;
- existing M3.2.9 prepared debug+release, full pixel oracle and
  three negative scope/constructor tests;
- two **new compile-negative** external probes: an `@safe` user
  tries to call the now-private raw executor; another tries to
  construct `ResearchCheckedExecution` with unchecked indices.
  An unrelated syntax/link/dependency error **does not count**;
- identical three-way exact pixel mapping including independent
  validity, nested ROIs and physical/stored modes;
- optimized LDC codegen must show **one** common noninline symbol
  called by original and sealed-prepared routes in the timed binary,
  and the evidence runner must produce validated paired/tripled CSV.

Research CI timing is a harness smoke only. It is not the XPS
performance qualification.

## 5. Hardware and promotion gates

The local Dell XPS comparison must be rerun on this **new source
revision**; M3.2.10's 1.29–1.33× at 256-band 8×8 maps was measured
*before* sealing and is not a qualified prediction of the new
preparation/run costs.

The existing runner from the imagery-d project root is:

```bash
git fetch origin
git switch research/m3-2-sealed-execution
git pull --ff-only origin research/m3-2-sealed-execution

COMPILER=ldc2 REPEATS=5 ROUNDS=12 ITERATIONS=24 WARMUPS=2 \
  bash experiments/m3_2_validated_roi/tools/qualify_prepared_xps.sh
```

A non-tagged sibling `raster-d` checkout is explicitly recorded,
not silently treated as released `v0.2.0`; nothing in other
repositories is reset, cleaned or written.

**Not yet decided:** final module/package boundary for a production
public image API, numeric/alias/concurrency guarantees outside the
current oracle, exact metadata setup amortization and any release
performance threshold. Keep original research evidence on PRs
#35–#43 intact and avoid merging the entire experimental chain
into `develop`.
