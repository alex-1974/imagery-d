# M3 RGBA — native import substep XPS replication (2026-10-15)

**2026-10-15 follow-up:** The four-arm, 24-process XPS control subsequently [reproduced the entire 48/72/48/24 B sequence with direct `GC.addRange`/`GC.removeRange`](m3-rgba-native-gc-range-control-xps-2026-10-15.md). This strongly supports druntime scan-range bookkeeping attribution on the pinned XPS; the original three-arm trace and its 688 B / 12-event observation remain unchanged. The `import - gc-range` differential isolates 8 requests / 496 B of non-GC-table import metadata requests.


**Research evidence, Issue #74; Draft PR #73.** Status: **qualified event-trace observation**, not an allocator-size, GC-residency, object-identity, or all-in memory budget. **Decision: ADAPT attribution research; DEFER production API and memory-budget admission.**

## Frozen inputs and verification

- Submitted archive: `20261015T111435Z.tar.gz`.
- Archive SHA-256: `f1215a697394db4b9f15f8e36ca677dc0a8c1329b1fa5538e0dfe3e37ffc725f`.
- `environment.txt`: 2026-10-15 11:14:35 UTC; XPS-15, Linux x86-64, LDC **1.43.0**, DUB **1.42.0**, GCC **15.2.0**.
- Immutable `imagery-d` snapshot: `590309e156a88a43f03d6de58c8b7c2128d5ee65`, branch `research/m3-rgba-layer-compositing`.
- Pinned dependency tag commits: `raster-d v0.2.0` = `2f2415851e45001df92ce56dad409f680684ba8d`; `color-d v0.2.0` = `3359f08f4e83941ac1a8451cadefb146b5736019`.
- Mode `normal`, separate processes: **3 modes × 2 ROI sides × 3 repetitions = 18**. ROI side 16 and 256; each run has two explicitly tagged physical pixel buffers of `4 * side * side` requested bytes.
- **115/115 files referenced by `CHECKSUMS.sha256` hash-match**, including all event streams, result CSVs, logs, traced library and environment record; each of the 18 event streams independently replayed using the frozen snapshot's Python validator, reproducing both stages and lifetimes CSV **byte-for-byte**. All 18 marker contracts and intended pixel-buffer retirements pass; all stderr files are empty.
- Limitation: `snapshot/` is intentionally **not** in the evidence manifest. The recorded Git commit and sibling tag hashes establish the intended snapshot provenance but are not independent SHA-256 verification of every extracted snapshot byte. The manifest itself is covered by the submitted archive digest above.
- Source tree contained untracked preexisting research outputs/binaries, recorded in `source_status_begin/end`; the runner builds from `git archive HEAD` snapshots and does not incorporate untracked files. These are not an excuse to replace or discard active XPS work.
- On the measured commit, all five GitHub Actions workflow families completed with **success**. CI is not substituted for native XPS evidence.

## Event-accounting vocabulary

The opt-in C `LD_PRELOAD` recorder interposes selected malloc-family functions **on the invoking thread**. Its `A` event records *requested bytes*, including a new request after `realloc`; `F` may represent either `free` or the old pointer involved in `realloc`. Thus the sum of `A` requests is **not** peak live memory, allocator usable-size footprint, RSS, complete GC residence, or necessarily the count of distinct underlying physical allocations. A recorded `F` for a pointer allocated before the trace is counted as `pretrace_free`, not given a false birth.

Phase end `other_live_end_bytes` sums only still-live **interposed, untagged, originally requested bytes** according to the pointer replay. Tagged scratch/packed pixel buffers and the `GenerationAccounting` GC object are excluded from that metric. Stage 0 in a lifetime CSV means **still observed as live at trace end**, not a demonstrated leak.

## Replicated case comparison

Each row is identical across its three repetitions; the `import` signature is also identical between ROI sizes.

| ROI | Mode | Tagged pixel requests (2 total) | Additional untagged `A` events | Additional total requested bytes | Untagged live after stage 11 | Untagged live after stage 13 |
|---|---|---:|---:|---:|---:|---:|
| 16×16 | `raw` | 2 × 1,024 B | 0 | 0 B | 0 B | 0 B |
| 16×16 | `adopt` | 2 × 1,024 B | 0 | 0 B | 0 B | 0 B |
| 16×16 | `import` | 2 × 1,024 B | **12** | **688 B** | **200 B** | **24 B** |
| 256×256 | `raw` | 2 × 262,144 B | 0 | 0 B | 0 B | 0 B |
| 256×256 | `adopt` | 2 × 262,144 B | 0 | 0 B | 0 B | 0 B |
| 256×256 | `import` | 2 × 262,144 B | **12** | **688 B** | **200 B** | **24 B** |

This establishes **zero *interposed* untagged calls on simple adoption** in this setup, not allocation-free behavior of every public raster-d pathway.

### Phase attribution (`import - adopt`)

| Stage | Operation | Added `A` events | Added requested bytes | Untagged live at phase end |
|---:|---|---:|---:|---:|
| 3 | Adopt scratch | 0 | 0 B | 0 B |
| 4 | Import four-plane scratch | 5 | **368 B** | **272 B** |
| 5 | Borrow and copy scratch lease | 0 | 0 B | 272 B |
| 7 | Adopt packed | 0 | 0 B | 272 B |
| 8 | Import one-plane packed | 5 | **248 B** | **448 B** |
| 9 | Borrow and copy packed lease | 0 | 0 B | 448 B |
| 10 | Final scratch lease close | 1 | **48 B** | **200 B** |
| 11 | First packed lease close | 0 | 0 B | 200 B |
| 12 | Final packed lease close | 1 | **24 B** | **24 B** |
| 13 | No-owner assertions | 0 | 0 B | 24 B |

All omitted phases have no untagged events. **One free of an untracked/pretrace pointer** occurs in import phase 4, with identical behavior in all six import runs; it does not establish a leak or a known live allocation.

### Observed per-request lifetime signature

The following table is identical in all six `import` traces. `free=0` denotes observation-window end; every row represents exactly one `A` event in a given trace.

| Birth stage | Free stage | Requested bytes | Qualified observation |
|---:|---:|---:|---|
| 4 | 4 | 96 | Scratch-import-scoped temporary; aligns with 4 × 24-byte plane descriptors |
| 4 | 8 | 48 | First anonymous changing-size request |
| 4 | 10 | 40 | Scratch-associated request |
| 4 | 10 | 88 | Scratch-associated request |
| 4 | 10 | 96 | Scratch-associated request |
| 8 | 8 | 24 | Packed-import-scoped temporary; aligns with one plane descriptor |
| 8 | 10 | 72 | Second anonymous changing-size request |
| 8 | 12 | 24 | Packed-associated request |
| 8 | 12 | 40 | Packed-associated request |
| 8 | 12 | 88 | Packed-associated request |
| 10 | 12 | 48 | Third anonymous changing-size request |
| 12 | 0 | 24 | Fourth anonymous changing-size request; still live at trace end |

Across all six runs, the four **48 → 72 → 48 → 24 B** events use the **same pointer address within their respective process**, each with a recorded `F` before the next `A`. The C recorder also encodes a successful `realloc(old, size)` as an `F(old)` / `A(new)` pair. Therefore this sequence is **compatible with successive in-place reallocations of one bookkeeping table**, though `free` followed by reuse of an address cannot be excluded by this trace alone.

## Revised evidence interpretation versus the prediction

The prior [premeasurement attribution hypothesis](m3-rgba-native-import-substep-attribution.md) predicted `368 + 224 = 592 B` and 10 additional requests, by counting a 48 B unknown per raster import and expecting no allocation requests during owner close. The native XPS traces **falsify that exact 13-stage prediction**: scratch import = **368 B** (matches), packed import = **248 B** (not 224), scratch close = **48 B**, packed close = **24 B**; sum **688 B**, 12 events. Do not silently reinterpret these numbers to preserve the hypothesis.

Pinned raster-d source plus phase lifetime make a narrower decomposition plausible:

| Group | Per-trace requested bytes | Role supported by source / measured interval |
|---|---:|---|
| Four-plane import temporary + retained 40/96/88 | **320 B**, 4 requests | 96 B temporary at stage 4; 40/96/88 persist until scratch final close at 10 |
| One-plane import temporary + retained 40/24/88 | **176 B**, 4 requests | 24 B temporary at stage 8; 40/24/88 persist until packed final close at 12 |
| Other dynamically changing 48/72/48/24 | **192 B**, 4 request events | Across imports and owner closes, potential shared bookkeeping; **exact subsystem is unproven** |
| **Total** | **688 B**, 12 `A` events | Requested-byte event sum only |

Of the remaining requests after stage 11, 152 B (= 40+24+88) share the packed lease's recorded lifetime; the additional 48 B is from the changing-size sequence. Final packed close frees 200 B of recorded requests while causing another 24 B request, leaving **24 B** at stage 13. The net decrease is 176 B, not a proven 24 B leak.

The previous [full-producer XPS controls](m3-rgba-native-allocation-controls-xps-2026-10-15.md) found **10 requests / 592 B per `import-raw` producer** and **200 B retained until owner close** under a different, nine-stage full producer protocol. The present 13-stage **two-resource isolated import** experiment is not that same allocation sequence, nor the same observation-window start or GC-bookkeeping state. It does **not** invalidate those earlier measured counts; it **does** invalidate the unqualified claim that one isolated public scratch+packed import always produces exactly 10 requests / 592 B.

The shape and phases of the 48/72/48/24 sequence are **consistent with the GC scan-range registration and deregistration operations** called in pinned `raster-d/source/raster/backing.d`, but are **not enough for call-site identification**. Classify as **unknown shared-bookkeeping candidate**, not per-backing stored ownership or a verified `GC.addRange` allocation.

## Next falsification, in research only

1. Compare a **direct druntime `GC.addRange` / `GC.removeRange` control** on the two existing tagged malloc buffers against `raw` / `adopt` / `import`, retaining the same stages, zero pixel copying, LDC, and fresh-process design. Independent control should mirror registry occupancy (0 → 1 → 2 → 1 → 0). The GC contract must be verified before implementing this probe.
2. Add call-site evidence if necessary (symbols/stack capture without allocation in the tracer, or a separately qualified profiler). Do not infer allocation identity from shared sizes or pointer reuse alone.
3. Separately qualify *physical* retained owner budget and GC/mmap/RSS behavior under multi-generation/cache/subscriber workloads; the interposed event-request sum cannot answer those budgets.

**Decision:** **ADAPT** targeted research attribution; **DEFER** all-in memory budget, thread/allocator generalization, API promotion, PR merge and release. No source changes to raster-d or color-d.
