# M3 RGBA native GC scan-range control — independent XPS evidence (2026-10-15)

**Issue #74 · Draft PR #73 · Research-only.**
**Result: direct-GC hypothesis SUPPORTED on the pinned XPS toolchain.**
**Decision: ADAPT the attribution model; DEFER complete memory budget, API promotion, merge, and release.**

This is a *new four-arm causal/differential control*, not a reinterpretation
of the previous 18-process three-arm dataset. It preserves both previous
full-producer 592 B / 10-request evidence and the isolated three-arm
688 B / 12-request dataset as distinct qualified protocols.

## Frozen material and independent verification

- Submitted archive: `20261015T114351Z.tar.gz`, whole-archive SHA-256
  `962c80a35e684d2d952a8c0b5efe1e2d40ce97ec420d300ea7fb0bbcf378c128`.
- XPS capture start `2026-10-15T11:43:52+00:00`, host `xps-15`, x86-64 Linux
  `6.17.0-22-generic`, Intel Core i7-9750H, LDC **1.43.0**,
  DUB **1.42.0**, GCC **15.2.0**.
- `imagery-d` branch `research/m3-rgba-layer-compositing`,
  immutable Git source commit `55deb26e709b3ef85bab6b823e15c338187fde03`.
- Read-only pinned sibling tags `raster-d v0.2.0` =
  `2f2415851e45001df92ce56dad409f680684ba8d`,
  `color-d v0.2.0` = `3359f08f4e83941ac1a8451cadefb146b5736019`.
  The runner fails closed if either tag moves.
- Normal mode; **24 independent processes**, 4 arms × ROI side 16/256 ×
  3 repetitions, two tagged physical pixel allocations per process:
  `4*side*side` bytes each.
- **151/151 payload manifest SHA-256 entries PASS** (includes tracer,
  build logs, all 24 raw traces, validator receipt and stage/lifetime CSVs),
  **24/24 event streams PASS** independent replay with archived pinned
  Python validator, all derived stage/lifetime CSV files **byte-for-byte
  equal**, all 24 output/empty-stderr assertions PASS.
- Independently recomputed `paired-differences.csv`: **390/390** rows
  exact; `paired-lifetime-differences.csv`: **216/216** rows exact.
- The submitted tar archive includes `snapshot/` (archived Git source
  snapshots plus build binary) unlike the earlier recommended exclusion.
  The 151-entry `CHECKSUMS.sha256` does **not** hash that snapshot
  directory. Do not infer file-level source-snapshot authentication from
  the payload manifest; the recorded Git SHAs and whole-archive digest
  identify provenance and bind the submitted archive.
- `source_status_begin/end` reports several **untracked pre-existing**
  research binaries, DUB selections and old evidence tarballs on XPS.
  The runner uses `git archive HEAD` and read-only sibling tags, so
  those untracked files are not part of its source snapshot. No other
  repository was modified.

## Falsification condition

The [pre-registered GC control protocol]
(m3-rgba-native-gc-range-control-protocol.md) asked whether two direct
`GC.addRange` operations and two `GC.removeRange` operations on
pretrace-allocated, zeroed 80-byte ranges yield the *same exact*
requested-size, birth-stage and death-stage sequence as `raster-d`
imports and final backing releases.

Pinned `raster-d/source/raster/backing.d` actually invokes
`GC.addRange(&control.backing, RasterBacking.sizeof)` on retained-owner
creation and `GC.removeRange(&control.backing)` at final release;
`RasterBacking.sizeof` is 80 bytes in this 64-bit build. The
`gc-range` arm directly calls those same **public druntime functions**
on two independent 80-byte foreign-memory carriers without importing
a raster or creating raster-d ownership metadata. Carriers exist in
**all four** arms before trace stage 1 and are retired after tracing;
their own `calloc`/`free` calls are therefore excluded from the trace.
All four arms still allocate and later free exactly two tagged real
pixel buffers.

The C interposer records invoking-thread malloc-family request
events, `free`, and `realloc` as a release/request pair. It **does not**
record allocator usable-size, internal allocator metadata, total GC
heap residence, cross-thread events, RSS, or mmap in general. An `A`
event is a *requested-size event*, not proof of a new physical block.

## Matched native results (identical in all six replicates per arm)

| Mode | Untagged malloc-family `A` events | Total requested bytes | Untagged live after stage 11 | Untagged live after stage 13 |
|---|---:|---:|---:|---:|
| `raw` | 0 | 0 B | 0 B | 0 B |
| `adopt` | 0 | 0 B | 0 B | 0 B |
| `gc-range` | **4** | **192 B** | **48 B** | **24 B** |
| `import` | **12** | **688 B** | **200 B** | **24 B** |
| `import - gc-range` | **8** | **496 B** | **152 B** | **0 B** |

All six repetitions for each arm have **one identical pointer-independent
lifetime signature**, across ROI side 16 and 256. Only tagged pixel
request size grows with the ROI. The four-arm comparison was made in
distinct processes (no reuse of one mutable runtime across arms).

### Exact GC-range signature reproduced

| Stage | Direct-GC operation | Added requested bytes | Birth → release |
|---:|---|---:|---|
| 4 | `GC.addRange` first 80-byte region | **48 B** | 4 → 8 |
| 8 | `GC.addRange` second region | **72 B** | 8 → 10 |
| 10 | `GC.removeRange` first region | **48 B** | 10 → 12 |
| 12 | `GC.removeRange` second region | **24 B** | 12 → **not freed within recorded window** |
| **Total** | | **192 B in 4 request events** | |

**All four GC events exactly match** the four analogous events of
the actual `import` arm in requested bytes, birth stage, free stage,
and requested-size balance. The 24 B outstanding after stage 13 is
also reproduced in `gc-range` without creating any raster-d backing.
This provides **strong causal differential evidence** that the
48/72/48/24 B sequence in the tested raster-d import path is
druntime GC scan-range bookkeeping. It is **not** a leak finding,
nor proof of `realloc` implementation details across runtimes.
The same address is reused for the four requests **within each process**,
but the recorder's free/new-request model by itself does not prove
every event is a distinct heap allocation or a specific internal
druntime table implementation.

An initial **pretrace-pointer free** occurs in stage 4 for both
`gc-range` and `import`, exactly one per run; the validator reports
it separately. It is not evidence of leaked or retained import ownership.

### What is left after removing the direct-GC signature?

| Import phase | Extra request sizes in `import - gc-range` | Requests / bytes | Recorded lifetime |
|---:|---|---:|---|
| 4 — four-plane scratch import | 96; 40; 88; 96 B | **4 / 320 B** | 96 B request released in stage 4; 40+88+96 = **224 B** until scratch final close in stage 10 |
| 8 — one-plane packed import | 24; 24; 40; 88 B | **4 / 176 B** | First 24 B request released in stage 8; 24+40+88 = **152 B** until packed final close in stage 12 |
| 10 — scratch final close | — | 0 new requests | All **224 B** scratch-owned requests released |
| 12 — packed final close | — | 0 new requests | All **152 B** packed-owned requests released |
| **Total** | | **8 / 496 B** | **120 B temporary**, **376 B coexisting retained requested-size metadata** |

This separation agrees with the *source-backed type-size model* for
the pinned 64-bit upstream: temporary `PlaneDescriptor` arrays
(4 × 24 B and 1 × 24 B), stable `ResourceEntry` blocks
(40 B each), stable descriptor arrays (96 B and 24 B), and
`RasterBackingControl` requests (88 B each). The control-derived
phase/size/lifetime match is strong, but without allocation stack
evidence it does **not** establish per-event exact source call sites.
In particular, **376 B is the sum of requested native metadata sizes
that coexist while both backings are alive** in this controlled
two-import trace; it is not an allocator physical-cost guarantee,
the actual peak native heap, a per-ROI budget rule, or the image's
total resident footprint.

In the earlier three-arm trace, `import` had 200 B still recorded at
stage 11. Here that **decomposes to 152 B associated with the final
packed owner + 48 B GC bookkeeping**. The final 24 B belongs to the
differentially reproduced GC registry trajectory, **not** a proven
unfreed `RasterBacking` or raster-d lease. The larger full-producer
nine-stage baseline of **10 A events/592 B** remains a different
protocol; do not overwrite its data with these numbers.

## Conclusion, scope and next research decision

**H-GC supported, rather than left open**, on the frozen LDC 1.43.0,
glibc, Linux x86-64 XPS environment and exact 0→1→2→1→0 scan-range
occupancy schedule. This is controlled attribution, not a guarantee of
all possible GC implementations or initial registry occupancies.

The per-resource imported native request model can be
**provisionally adapted** to separate the independently reproduced
shared GC table trajectory from retained backing/descriptor metadata.
The memory-accounting question in Issue #74 is **still unresolved**:
requested-size allocation events exclude usable allocation sizes,
GC heap and registration effects, mmap and RSS, caches and
multi-generation/subscriber interactions, and thread-general behavior.

**ADAPT:** preserve the reusable research-only four-arm comparison,
and write future budget work against real owner lifetimes and physical
memory measurements. **DEFER:** any production budget threshold or
public API admission, unwarranted per-owner 24/48 B charges, merge,
release and generalizing to different druntime/allocator versions.
**Do not** modify `raster-d` or `color-d` on this evidence.
