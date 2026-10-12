# M3.2.17 — immutable metadata ownership and amortized ROI reuse

**Status:** four-compiler correctness and XPS independent evidence
qualification **PASS**; 60 process logs / 1,920 packets / 19,200 real
ROI maps. Reuse of immutable and copy-once metadata reports **zero
per-packet GC metadata bytes**, while copy-each reports 17,744 B per packet.
See [independent M3.2.17 XPS results](m3-2-metadata-owner-xps-results.md).
No production/public API, zero-copy mutable freeze or lifetime
performance guarantee is admitted.

Historically **exploratory** research contract, stacked as
[PR #57](https://github.com/alex-1974/imagery-d/pull/57) on
[M3.2.16 PR #55](https://github.com/alex-1974/imagery-d/pull/55);
[Issue #56](https://github.com/alex-1974/imagery-d/issues/56).
No production API, no cross-repository edits, and no merger to `develop`.

## Why this experiment

[M3.2.16 independently audited XPS evidence](m3-2-gc-intervention-xps-results.md)
showed 17,744 bytes of two immutable-array `.idup` snapshots for
**each 256-channel packet** and repeatable GC pauses/tails. Precollecting
before every packet moved rather than eliminated cost; temporarily
disabling collection increased heap use and minor faults.

This is a *caller lifetime/ownership problem*, not evidence that the
GC itself needs new policy. The older
[M1.5 image-view contract](m1-image-view-contract.md) already states
that ROI creation must **not** clone semantic metadata. M3.2.12's
`ValidatedImmutableImage`/`PreparedSemanticMap` already provides
sealed `@safe @nogc` verified-once/prepared mapping over
**genuinely immutable** metadata. Source/lifetime/forgery negative
tests already protect that hot path.

## Verified design references within this workspace

| Repository | Reusable idea | What it cannot prove for imagery-d |
|---|---|---|
| [containers-d ScratchBuffer](https://github.com/alex-1974/containers-d/blob/develop/source/containers/scratch_buffer.d) | Retain capacity, reset temporary lifetimes, typed slices; non-GC allocated storage | A slice must not escape reset; it is **not** a frozen long-lived immutable metadata owner |
| [containers-d RuntimeStorageOwner](https://github.com/alex-1974/containers-d/blob/develop/source/containers/internal/runtime_storage.d) | Audited aligned allocation, move-only control, pointer scanning with `GC.addRange` for indirections | Internal to containers-d; does **not** expose general public UniqueBuffer/freezing |
| [raster-d 0.2 API](https://github.com/alex-1974/raster-d/blob/develop/docs/API_0_2.md) | Ownership transferred to `RasterLease`; views borrow without cloning | Owns raster resources, not intrinsically immutable channel metadata |
| [color-d performance](https://github.com/alex-1974/color-d/blob/develop/docs/performance.md) | Prepared state and destination-oriented `@nogc` operations | No metadata hand-off/alias-exclusivity claim |
| [osm-d performance](https://github.com/alex-1974/osm-d/blob/main/docs/PERFORMANCE.md) | Borrow source, preflight once, worker-local scratch arena as design | Block scratch is not a persistent immutable data owner |

These are architectural references, **not** justification for adding a
new `containers-d` dependency to `imagery-d`.

## Exact three-path question

All modes operate on the *same* 256-channel planar source with
validity mask, physical calibration, selected-three binding, and
4/16 actual mapped ROIs per packet. The metadata IDs and per-band
intrinsic calibration are identical. The same independently computed
observed first-pixel checksum and the full 3-component final ROI image
oracle must pass for every packet.

| Policy | Initial condition | Immutable copy frequency | Verification/preparation |
|---|---|---|---|
| `immutable` | Caller supplies already genuinely immutable arrays | **zero inside consumer**; creation outside timing | Once for all packets |
| `snapshot_once` | Caller holds mutable arrays | Exactly two `.idup` immutable arrays **once** | Once for all packets |
| `snapshot_each` | Caller holds mutable arrays | Exactly two `.idup` immutable arrays **per packet** | Every packet |

Snapshot isolation is checked explicitly: mutation through the
original mutable aliases must not change a `snapshot_once` value.
`fromImmutable` must keep the very same backing pointers (no copy),
but it **requires genuinely immutable original storage**. Construction
of such caller-supplied immutable arrays can incur separate cost
outside the consumer measurement; it is not free by definition.

A research-only `ResearchMetadataState` models the boundary:
`snapshot(scope const(...))` **copies** and
`fromImmutable(immutable(...))` **borrows**. It is a D value holding
GC-managed immutable-array references, **not** a uniquely owning
non-GC container nor a generic zero-copy freezing primitive.

## Strictly prohibited shortcut

`const(T)[]` can refer to mutable backing; neither `const` nor
absence of a currently-known alias proves exclusivity. Compiler-negative
configurations require implicit mutable→immutable and
const→immutable conversions to fail. A forced
`cast(immutable(T)[])` is **not an accepted safe freeze**.

To consider an actual zero-copy mutable→immutable handoff in the
future, first prove unique allocation provenance, that no writer
aliases or slices escaped, move-only transfer and destruct/exception
semantics for `IntrinsicChannel` (whose labels are immutable strings),
and @safe DIP1000 lifetime after transfer on DMD 2.111/2.113 and
LDC 1.41/1.43. Evidence from `containers-d`'s internal
`RuntimeStorageOwner` can guide a focused probe, but cannot be
silently promoted to a public shared API.

## Research performance rules

Use separate OS processes per mode and rotate launch order; report
allocation **before mapping** and **during each packet** separately.
Do not claim that `snapshot_once` and `immutable` have identical
caller guarantees or identical lifetime cost. At minimum record
the number of GC-backed arrays allocated per copy, byte counts,
hot-operation allocation, time to create immutable copies, one-time
validation/preparation time and ROI mapping time, with complete setup
amortization across all packets.

At 256 channels a `snapshot_each` single-packet baseline should
show approximately 17,744 GC bytes for its two arrays (toolchain
specific). `snapshot_once` should instead show that allocation
only **once outside the per-packet hot loop**, while immutable
inputs should have no new metadata allocation in the consumer path.
Zero bytes of hot GC allocation does not guarantee zero OS page faults,
zero cache misses or bounded latency.

The experiment deliberately uses the existing checked real mapping
executor and does not replace pixel work with a success flag.
M3.2.14–16 XPS data remain unchanged. New measured Dell XPS evidence,
codegen validation and negative tests are required before any
production or public-API decision.

## Next admission gate

1. DMD/LDC four-toolchain positivity and whole-source negative builds.
2. Correct source provenance and independent pixel oracle for every
   policy × repeat × packet × ROI-count × window size.
3. Actual observed GC allocation count/bytes per phase, including
   immutable-input construction *outside* the timed consumer.
4. The relative sizes of validation, single snapshot and repeated
   mapped ROI work across 4/16 ROIs and two window sizes.
5. An isolated exclusive-transfer prototype only **after** a
   trustworthy no-alias ownership proof; never accept a cast as proof.
6. Retain metadata source/lifetime/borrowing guarantees and
   no cloning for ROI. No writes to `containers-d` or `raster-d`.
