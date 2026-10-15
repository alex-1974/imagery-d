# M3 RGBA — native XPS multigeneration and serialized-cancellation replay (2026-10-15)

**Status:** Verified single-host, single-threaded research evidence for
[Issue #74](https://github.com/alex-1974/imagery-d/issues/74), retained on
the existing stacked [Draft PR #73](https://github.com/alex-1974/imagery-d/pull/73).
This is **not** a public imagery-d API, a native-memory/RSS limit, an
asynchronous-cancellation guarantee, or a release decision.

## Archive provenance and verification

User-supplied archive `20261015T065540Z.tar.gz`, recorded by the XPS
runner at **2026-10-15 06:55:40 UTC**, SHA-256:

```text
2dcd27fdbf2ff03fe41ebf6d55bb7f1fe0a0511bd30343a081281b468c15f86d
```

The archive has **483 tar entries**, including pinned source/dependency
snapshots; no duplicate paths or path-traversal names were found. Its
`CHECKSUMS.sha256` lists **9 files**, and independent SHA-256 recomputation
against the original archive found **9/9 PASS**:

| File(s) | Verification |
|---|---|
| `environment.txt` | PASS |
| `build.log` | PASS |
| `generation-summary.csv` | PASS |
| `consumer-run-0.txt`, `consumer-run-1.txt`, `consumer-run-2.txt` | PASS ×3 |
| `consumer-run-0.stderr`, `consumer-run-1.stderr`, `consumer-run-2.stderr` | PASS ×3 |

All three standard-error files are empty; all three runs contain
`M3 RGBA multigeneration PASS:`, `M3 RGBA generation cancellation PASS:`,
and the complete independent RGBA oracle's PASS trailer. The release build
successfully linked `m3-rgba-layer-compositing-consumer`. Build diagnostics
are pre-existing `mir-core 1.7.4` deprecation warnings concerning
`ldc.intrinsics.LLVM_version`, **not** build or test errors.

| Provenance | Observed archive value |
|---|---|
| Host | `xps-15`; Intel Core i7-9750H, 6C/12T |
| OS | Linux/Ubuntu x86_64; kernel `6.17.0-22-generic` |
| Compiler | **LDC 1.43.0**, Release |
| DUB | **1.42.0** |
| imagery-d source | `133077cd51756b8d7eee821f2e768f86530542af` |
| raster-d `v0.2.0` | `2f2415851e45001df92ce56dad409f680684ba8d` |
| color-d `v0.2.0` | `3359f08f4e83941ac1a8451cadefb146b5736019` |
| CPU governors | `powersave` on all 12 logical CPUs |
| Build inputs | `git archive HEAD` and immutable tagged dependency archives |

The user's live working tree did contain unrelated untracked build outputs
and earlier local research tarballs. They did **not** enter the benchmark
build, because the runner builds an independent archived Git snapshot.

**GitHub source qualification:** the exact measured imagery-d commit
`133077cd...` completed **5/5 GitHub workflows with SUCCESS**, including
the independent RGBA consumer under **DMD 2.112.1, DMD 2.113.0,
LDC 1.42.0, and LDC 1.43.0**.

## Three independently invoked release consumer runs

| Native XPS observation | Run 0 | Run 1 | Run 2 |
|---|---:|---:|---:|
| Thread-GC allocation delta around one three-ticket control object | **256 B** | **256 B** | **256 B** |
| Generations A/B/C concurrently retained across same-slot replacement | PASS | PASS | PASS |
| Different-generation refund and overcapacity rejection | PASS | PASS | PASS |
| Last-owner lifetime surviving cache destruction | PASS | PASS | PASS |
| Serialized cancellation, including post-eviction retain | PASS | PASS | PASS |
| 256 explicit temporary retain/close pairs with zero extra GC allocation | PASS | PASS | PASS |
| 432 byte-exact source-over scenes | PASS | PASS | PASS |
| 51,840 independently checked RGBA samples | PASS | PASS | PASS |
| Maximum per-channel deviation | **0** | **0** | **0** |
| Process standard-error output | empty | empty | empty |

The native CSV is exactly:

```csv
run,metadata_thread_gc_bytes,cancellation_pass,multigeneration_pass
0,256,yes,yes
1,256,yes,yes
2,256,yes,yes
```

All three stdout logs are **byte-for-byte identical** (SHA-256
`b2335480f7fdaf512918c37698c52a0a8a6ede9b913d4473bbadacdf628e5800`);
they contain functional markers, not benchmark timing distributions.
The summary CSV is SHA-256
`88fad1989bf6aa77712b6fd7e83937337e9a5e6529050bbd4c05d8a6e4486611`.

## Memory inference and comparison with the previous model

- **New three-generation control:** **256 observed thread-GC allocated
  bytes per one newly constructed fixed-three-ticket `GenerationAccounting`
  metadata object**, in each native XPS process run. This matches the
  earlier **256 B** seen in all eight DMD/LDC debug/release consumer runs
  on hosted GitHub CI.
- **Old two-ticket control:** previously measured **128 thread-GC bytes**
  per `DeliveryAccounting` object in its own native XPS workflow. The
  measured allocation delta **doubles**, but the objects have different
  feature contracts and capacities: the new class can account for
  simultaneously live evicted and successor generations in the **same**
  mutable cache slot. This comparison is not a production scaling formula.
- **Hot subscriber cancellation:** 256 explicit temporary
  `tryRetain/close` pairs in the new serialized test reported **zero
  further thread-GC allocation**. The existing physical raster-d leases
  still perform their own non-atomic retention/release behavior.
- **No admission bound:** `GC.stats().allocatedInCurrentThread` is an
  *allocation counter*, not the managed object's exact `sizeof`, peak
  live GC heap, collected bytes, native `malloc`/raster allocations,
  allocator bookkeeping, total process RSS, or a cross-thread allocation
  sum. It does not measure a lifetime-peak resident cost.
- **Illustrative ROI accounting charges** of peak metadata 128 B /
  retained metadata 64 B used by the independent consumer still do
  **not** bound this observed 256-byte GC class, much less all other
  native metadata. A production admission equation must include the
  control plane explicitly and measure native/GC residency.

## Lifetime contract and remaining gates

The three-record research prototype verifies:

1. A, B and C keep separate accounting generation IDs and genuine
   `RasterLease!SRgba8` owners, even when B and C replace evicted A in
   the same cache slot.
2. A later D can reuse an **empty ticket record** but not A's old
   generation ID.
3. Cache eviction alone does not refund while external controlled
   subscribers still own a generation; final release refunds its
   charge exactly once after the backing lease is dropped.
4. Bad/undercharged ROI size plans, insufficient peak budgets,
   failed producer reservations and exhausted generation tickets
   are rejected without accidental publication or lost credit.
5. Cancellation is **serialized synchronous `close()`**, not parallel
   cancellation, cancellation callbacks on other threads, or a
   guarantee for values stored in GC-managed containers.

**Not qualified by this archive:** concurrent use of non-atomic
`raster-d` refcounts, inter-thread hand-off, arbitrary external raw
lease escape, actual full-memory/native-allocator residency, dynamic
generation-limit/backpressure policy, async cancellation, production
API lifetime, or workload performance. This runner records **no
nanosecond/microsecond timings**; do not infer performance parity or
regression from the three PASS-only process invocations.

## Research disposition

**ADAPT for continued bounded research; DEFER public API admission.**
The measured 256-byte GC control-plane allocation is consistent across
the native XPS and compiler matrix, while lifetime/cancellation
correctness is supported in the tested single-threaded traces. The
next substantive qualification is **all-in memory accounting**:
explicit metadata/GC record lifetime plus per-generation actual
native/GC allocation and peak RSS across mixed old/new live
generations. After that, define a safe thread-confinement or
cross-thread serialization contract and a generation pool exhaustion
policy.

The original archive stays external to Git. This lightweight
research report records its SHA-256 and result values; no snapshot,
compiled executable or unrelated repository is committed.
Keep Issue #74 **OPEN** and stacked PR #73 **OPEN/DRAFT**; no merge.
