# M3.2.5 — Borrow-only versus immutable snapshot: first evidence

**Status:** Focused semantic and lifetime qualification **PASS**; production
API/allocator admission **deferred**.  
**Date:** 2026-10-11  
**Repository:** `alex-1974/imagery-d`  
**Research branch:** `research/m3-2-borrow-vs-snapshot`  
**Validated experiment head:** `9704c423b10a393dc12527894cc3681dac26fde6`  
**CI:** [run 38134348182](https://github.com/alex-1974/imagery-d/actions/runs/38134348182), four successful jobs  
**Platform:** GitHub-hosted Ubuntu 24.04 x86_64  
**Raster:** released `raster-d` tag `v0.2.0`; no modifications to other repositories

## 1. Compiler and semantic gates

| Toolchain | Debug functional | Release functional | Stack-local intrinsic metadata escape |
| --- | --- | --- | --- |
| DMD 2.111.0 | PASS | PASS | Compiler rejected as intended |
| DMD 2.113.0 | PASS | PASS | Compiler rejected as intended |
| LDC 1.41.0 | PASS | PASS | Compiler rejected as intended |
| LDC 1.43.0 | PASS | PASS | Compiler rejected as intended |

The runner explicitly rejects unrelated DUB/dependency failures as
sufficient lifetime evidence. The existing M1.5 and M3.2.3/4 compile-negative
fixtures remain unmodified on their stacked research branches.

## 2. What was actually tested

- Channel counts **1, 3, 4, 17, 64, 256**.
- Pixel input: synthetic `float` with distinct per-channel and coordinate
  values; same `RasterLease!float` physical backing retained across
  both paths, not decoded files.
- Physical arrangements: planar (with separate `ubyte` validity) and
  pixel-interleaved (mask-free).
- **Borrow-only:** existing M1.5 `ImageView` plus M3.2.3 composite
  `tryBorrowSemanticImage` directly over caller-owned identity and
  intrinsic descriptor arrays.
- **Snapshot:** existing M3.2.4 `RetainedDynamicImage.create` makes
  two `.idup` arrays then uses the same retained `raster-d` backing.
- ROI views on both paths alias the corresponding original metadata arrays
  without copying metadata; their pointers were checked directly.
- For three or more channels: explicitly selected last three channels and
  applied exact binary-fraction `physical = stored * 0.5 - 10`.
  Outputs match each other bit-exactly and an independent coordinate/sample
  oracle. Invalid masked pixel maps to zero under the **test's explicit
  policy**, not a general NoData/alpha policy.
- Caller mutation of mutable intrinsic descriptors remains visible through
  the `const` borrow. Immutable snapshot descriptor values do not change;
  similarly the snapshot's channel identity remains independent of later
  caller mutation. No further borrow-based processing is performed after
  the caller intentionally changes channel identity.
- Identity and count mismatch failures reported distinctly.
- One new DIP1000 `@safe` stack-local intrinsic metadata escape rejected
  on all four compilers.

**Scope limitation:** the one-channel case tests structural borrows,
not a three-component display binding; zero-channel snapshots and M3.2.4's
owner-move tests remain covered only by the previous experiment.

## 3. Explicit copy / allocation boundaries

| API-seam property | Caller-borrowed | GC snapshot |
| --- | --- | --- |
| Explicit whole-metadata array copies per construction | **0** | **2 `.idup`** |
| Full-array copies per borrow or ROI | **0** | **0** |
| Metadata construction `@nogc` | Borrow-binding path: YES | Snapshot creation: NO |
| Current metadata lifetime | Scope-bound to caller storage | Independent GC-backed immutable descriptor arrays |
| Physical pixel owner | `raster-d` `RasterLease` | Same `raster-d` retained backing |
| Caller mutation isolation | No | Yes, for copied descriptor fields |

These are statements about explicit array-copy call sites in the two
existing **imagery metadata interfaces**, not instrumented allocation
counts. The test harness itself creates D arrays and raster/validity
buffers. `IntrinsicChannel` also contains D `string` fields; `.idup`
copies descriptor structs and references, and does **not** establish a
deep copy of independently referenced string payloads.

The experiment did not measure GC collections, peak RSS, memory budget,
external source-text lifetime, or deterministic metadata reclamation.

## 4. Initial LDC timing observations (advisory only)

Source: successful run `38134348182`, `ldc-1.43.0` matrix job,
`release` build on GitHub Ubuntu 24.04. The optional test emits
`metric,channels,iterations,elapsed_us,checksum`.

| Metric | 3 channels / 12,000 calls | 64 channels / 3,000 calls | 256 channels / 1,200 calls |
| --- | ---: | ---: | ---: |
| `borrow_bind` | 14 µs | 62 µs | 102 µs |
| `snapshot_create` | 2,114 µs | 900 µs | 1,522 µs |
| `borrow_roi` | 141 µs | 90 µs | 115 µs |
| `snapshot_roi` | 138 µs | 86 µs | 114 µs |

Reported **totals use different iteration counts**, so raw table rows
must not be compared across channel counts without normalization.
The benchmark is a single, order-dependent run on a shared cloud VM,
not a controlled XPS distribution. At the low end, the approximate
sub-nanosecond-to-nanosecond `borrow_bind` per-call time suggests
compiler hoisting/folding could be material despite checksum tracking.
Therefore **do not use its ratio to establish any speed advantage**.

The operations also perform different work: `borrow_bind` validates
metadata without copying, whereas `snapshot_create` performs validation
and creates two immutable arrays. A one-time snapshot can amortize
over many operations. Neither is an image decode or a general pixel-loop
benchmark.

**Mechanism-level finding:** the current M3.2.3 composite
`BorrowedSemanticImage.tryRoi` invokes the validation factory again.
It walks all intrinsic channel IDs to establish that the newly borrowed
ROI has the same identities. Thus composite imagery ROI has
`O(channel count)` **metadata revalidation** even though
`raster-d`'s own ROI is a pixel-copy-free `O(1)` control-plane
operation. The timing pattern is consistent with this code path, but
a controlled no-inline/anti-hoist benchmark is required before
quantifying the overhead.

## 5. Conclusion and next actual decision

**Admit no new owner or allocator from this experiment.**

For an image consumer that already retains stable metadata, the
borrow-only path provides correct explicitly bound image semantics
without an extra immutable metadata snapshot. It is therefore the
simplest current reference model, with explicit caller lifetime and
nonmutation responsibilities.

The snapshot path remains useful when a consumer requires **independent
descriptor values** after its input arrays can change or leave its
direct control. The existing GC-backed implementation gives
nondeterministic reclamation and is not a substitute for an established
deterministic release contract.

Before M3.2 production admission:

1. Measure a **validated-once** compound ROI derivation against current
   O(channel count) repeated validation without reducing DIP1000 safety;
   preserve lifetime and bad-input checks at the original validation
   boundary.
2. Collect optimized LDC benchmark distributions on a controlled
   machine, with anti-hoisting safeguards and raster-only baseline.
3. Decide whether a real consumer needs independently retained
   metadata before considering a deterministic owner.
4. Only if the owner is justified, qualify GC visibility for D string
   references, transfer/copy behavior, failure atomicity and allocation
   costs using the prior `containers-d`/`raster-d` research rules.

The measured result supports a **narrow performance investigation**
of repeated ROI channel validation; it does not justify new
ownership machinery or freezing a public API.

References: [issue #32](https://github.com/alex-1974/imagery-d/issues/32),
[PR #33](https://github.com/alex-1974/imagery-d/pull/33),
[cross-repository lifetime audit](m3-2-cross-repository-lifetime-audit.md).
