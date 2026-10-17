# M3 native RGBA — direct GC scan-range falsification control

**Status: pre-registered protocol; independent native XPS verification completed in [the qualified GC-range XPS report](m3-rgba-native-gc-range-control-xps-2026-10-15.md).**


**Issue #74 · Draft PR #73 · Research-only protocol (2026-10-15).**
Status: **IMPLEMENTED; four-arm XPS measurement QUALIFIED on 2026-10-15.**
This file preserves the premeasurement falsification criteria rather than
retroactively rewriting predictions as observations. See the linked measured
report for the outcomes. Do not alter the archived 18-process earlier record.

## Question / falsifiable hypothesis

The [independently replayed XPS import-substep evidence]
(m3-rgba-native-import-substeps-xps-2026-10-15.md) established a repeated
48 → 72 → 48 → 24 byte native request sequence across two public
`raster-d` imports and final lease releases, with only 24 B left live in
the 13-stage observation window. Pointer reuse and the phase alignment
suggest shared bookkeeping, but **do not identify its call site**.

**Hypothesis H-GC:** the sequence is produced by druntime's *global
conservative scan-range table*, mutated through `GC.addRange` and
`GC.removeRange`, rather than four individually-owned raster objects.

Direct source confirmation in pinned, **read-only** `raster-d v0.2.0`:
[`source/raster/backing.d`](https://github.com/alex-1974/raster-d/blob/2f2415851e45001df92ce56dad409f680684ba8d/source/raster/backing.d)
registers `&control.backing` with
`GC.addRange(&control.backing, RasterBacking.sizeof)` and calls
`GC.removeRange(&control.backing)` at the **last** backing-owner
release. Audited 64-bit `RasterBacking` layout = **80 bytes**.
The real backing, and its representation, remain internal to raster-d.
The matching independent control intentionally does **not** import or
access this private representation.

[Official druntime API contract](https://dlang.org/phobos/core_memory.html):
`GC.addRange(const void*, size_t, const TypeInfo = null)` adds a
caller-managed memory range to conservative scanning;
`GC.removeRange(const void*)` removes it. Both are `@nogc nothrow`.
No allocation-freedom promise follows from those attributes.
The caller must keep the foreign range valid while registered.

## Controlled comparison

Extend the existing 13-phase, opt-in `LD_PRELOAD` experiment with
`--case=gc-range`, preserving `raw`, `adopt`, and `import`.

**All four cases** initialize the exact same two **80-byte, zeroed,
C-heap range carriers before phase 1**, in addition to the existing
prepared non-pixel accounting baseline. This equalizes pretrace C
allocator state and keeps these carrier allocations **outside** the
recorded event window. All four destroy the carriers after the
recorder stops, so the control does not introduce an owned-carrier
retention into the trace. Opaque external touches after the final
marker prevent optimized LDC from eliminating these matching
pretrace allocations. The carriers are not pixel buffers and their
content never enters the RGBA algorithm.

In all four arms: separately mark and allocate two real
`4*side*side` malloc pixel blocks in phase 2 and 6; hold each through
its intended lifetime and free each in phase 10 and 12, respectively.
`raw` handles these directly, `adopt` uses public move-only tokens,
and `import` uses the previously qualified public four-plane scratch
and one-plane packed import with temporary extra lease copies.

**`gc-range`** uses direct raw ownership (no raster-d adoption or
import); its only additional actions are:

| Stage | `gc-range` call | Purpose |
|---:|---|---|
| 4 | `GC.addRange(scratchScan, 80)` | Register one foreign scan range; mirror first import |
| 8 | `GC.addRange(packedScan, 80)` | Register a second range; mirror second import |
| 10 | `GC.removeRange(scratchScan)` | Unregister the first; mirror scratch final close |
| 12 | `GC.removeRange(packedScan)` | Unregister the last; mirror packed final close |

These two zeroed foreign carriers represent scan-table **occupancy**,
not the layout of `RasterBacking`. Their size matches the pinned
private layout, but callback/resource pointers and actual GC-reachability
patterns are intentionally not tested.

All runs are separate processes; do not use one process to successively
run the different arms. Compare the **same LDC 1.43.0**, same glibc
interposer, immutable `git archive HEAD` snapshots, tagged pixel sizes,
side 16 and 256, and fresh runtime state. XPS runner:
`tools/research/run_m3_rgba_native_import_substeps_xps.sh`.
Full run = **4 arms × 2 ROI × 3 repeats = 24 processes**;
`--smoke` = 8 processes.

The replay validator checks the marker and intent protocol, legal
pixel birth/retirement stages, dangling ownership, event byte fields,
and observed pointer lifetimes. Its outputs include:
`side-*-{raw,adopt,gc-range,import}-stages.csv`,
`*-lifetimes.csv`, `paired-differences.csv` and
`paired-lifetime-differences.csv`, with SHA-256 manifest.
Matched deltas include `gc-range-raw` and `import-gc-range`.
The latter **still includes** the adoption/import paths and is
not automatically a physically isolated per-backing byte budget.

## Interpretation, including adverse outcomes

- **Exact signature reproduced** by `gc-range` in three repeats and
  both ROI sizes, with matching request sizes, phase births/deaths and
  terminal 24 B: strong **differential attribution** to druntime's
  global range registration in the pinned runtime/build; corroborate
  call-site if stronger naming is required. Do not assume every
  druntime implementation, compiler, GC configuration, or thread uses
  the same table.
- **Different, partial or absent signature:** H-GC is **not
  established**. Report raw events and inter-process variation. If
  discrepancy depends on range-table occupancy, test that separately;
  do not retune the control until its output fits.
- **Unexpected events in `raw`/`adopt`:** report and investigate before
  subtracting. Identical pretrace carriers may influence allocator bin
  state relative to the archived 18-process experiment, but all four
  new arms share that modified starting condition.
- **Outstanding 24 B after phase 13:** do **not** call this a leak;
  continuing runtime global state or allocator retention needs a
  separate observation/release check.
- **Compiler/CI-only observations:** establish smoke/contract behavior,
  **not** XPS qualification. CI may have different versions or
  process-global druntime state even with the pinned compiler.

## Decision constraints

**ADAPT** attribution science; **DEFER** complete physical metadata
budget, RSS/mmap/GC residency bounds, hidden thread-allocation claims,
public `imagery-d` API, PR merge, and release. No changes to
`raster-d` or `color-d`. The previous 18-process record remains
reproducible by checking out its frozen source commit
`590309e156a88a43f03d6de58c8b7c2128d5ee65`.
