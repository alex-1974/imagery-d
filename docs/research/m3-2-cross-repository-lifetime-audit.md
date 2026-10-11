# M3.2 ownership / borrowing — cross-repository evidence audit

**Status:** Research audit; **not** a new production API or acceptance ADR.  
**Date:** 2026-10-11  
**Scope:** Read-only audit of `geo-d`, `raster-d`, `raster-d-research`,
and `containers-d`; only `imagery-d` may be changed by subsequent work.  
**Research context:** [M3.2.4 results](m3-2-dynamic-metadata-results.md),
[issue #30](https://github.com/alex-1974/imagery-d/issues/30),
[PR #31](https://github.com/alex-1974/imagery-d/pull/31).

## 1. Why this audit is necessary

M3.2.4 demonstrated variable-length immutable channel metadata snapshots,
compiler-checked raster and ROI borrows, and the distinct fact that a
GC-owned metadata slice can safely outlive the lexical owner that initially
held it. These results must be evaluated against **already-admitted workspace
designs** before introducing an additional allocation or ownership subsystem
in `imagery-d`.

This document distinguishes:

- **implemented public API**, verified from package source;
- **accepted repository-specific architecture**, which may still describe an
  unimplemented higher-level type;
- **historical experimental evidence**, which does not automatically describe
  the present implementation;
- **proposals for imagery-d**, which are not yet accepted or measured.

The shared rules in `DESIGN_PRINCIPLES.md` and `DLANG_PRACTICES.md` require
visible ownership, views without surprise copies, narrow audited unsafe
boundaries, correct `const` versus `immutable`, and positive **and
negative** DMD/LDC lifetime verification. Published package build flags must
not require consumers to enable `-preview=dip1000` package-wide.

## 2. geo-d: a mature model for compositional borrows

**Source authority:**

- [ADR-0003 — variable-size ownership and views](https://github.com/alex-1974/geo-d/blob/develop/docs/adr/ADR-0003-variable-size-geometry-ownership-and-views.md)
- [ADR-0009 — polygon/ring composition](https://github.com/alex-1974/geo-d/blob/develop/docs/adr/ADR-0009-polygon-representation-and-ring-composition.md)
- [Polygon2View source](https://github.com/alex-1974/geo-d/blob/develop/source/geo/polygon_view.d)

**Established contract:**

- `PolylineView`, `LinearRingView` and `Polygon2View` do not own backing
  point storage and do not implicitly copy it.
- `Polygon2View` borrows an array of ring descriptors, each of which can
  itself borrow independent point backing. This is a **view of views** whose
  full transitive lifetime must be maintained.
- The public polygon constructor uses `return scope` on the borrowed
  descriptor slice, and safe compile-positive/negative fixtures establish the
  intended escape behavior on DMD and LDC.
- `const` views are read-only through that capability, not immutable
  aliases or guarantees that external storage never mutates.
- `geo-d` deferred an owning dynamic `Polyline` rather than pretend a
  D slice defines ownership/copy/release semantics. It explicitly lists the
  future decisions: allocator, deep/share/move, mutation and `@nogc`.

**Direct imagery consequence:** borrowing one `ImageView!T` plus additional
intrinsic-channel metadata does not require a novel lifetime paradigm. The
existing M1.5 and M3.2.3 experiments follow the same **transitive borrow**
family as a polygon of rings. We should preserve those compiler-proven
relationships, including transitive ROI, rather than accept an
unrestricted pointer or an `@trusted` escape.

## 3. raster-d: authoritative pixel/validity ownership

**Source authority:**

- [Root public exports, released v0.2.0 tag](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/package.d)
- [Actual backing/lease source](https://github.com/alex-1974/raster-d/blob/develop/source/raster/backing.d)
- [M1.1 owner design](https://github.com/alex-1974/raster-d/blob/develop/docs/V0_2_RASTER_OWNER_DESIGN.md)
- [M1.2 allocate/adopt/wrap/clone contract](https://github.com/alex-1974/raster-d/blob/develop/docs/V0_2_OWNERSHIP_CONSTRUCTION_FAMILY.md)
- [M1.4 ROI and lifetime](https://github.com/alex-1974/raster-d/blob/develop/docs/V0_2_ROI_SUBREGION_CONTRACT.md)
- [M1.5 explicit deep-copy contract](https://github.com/alex-1974/raster-d/blob/develop/docs/V0_2_CLONE_DEEP_COPY_CONTRACT.md)

**Implemented and exposed today:**

- `RasterLease!T` retains a validated `RasterBacking`, and
  `RasterView!T` / `WritableRasterView!T` borrow its lifetime.
- Its private backing owner has deterministic reference-counted release.
  Copies retain the same physical resources; final release happens exactly
  once. Its count is **non-atomic**; no implicit concurrent retain/release
  safety is promised.
- Validated owned storage can be imported through existing public
  `OwnedByteResource` / `tryImportOwnedRaster` and
  `tryAdoptMallocResource` boundaries. The import contract tracks
  **pre-commit**, **success**, and **post-commit** failure disposition.
- ROI and nested ROI are non-owning, constant-time control-plane
  operations; the new view is transitively bound to the originating
  owner *variable*, even if another owner copy retains the same backing.
- A writable view does **not** promise uniqueness or concurrent writer
  exclusion.
- Current `raster-d` code already registers pointer-containing
  malloc-backed backing/control payloads with the GC for reachability,
  in addition to exact-once release.

**Document/source qualification:** `V0_2_RASTER_OWNER_DESIGN.md` defines
a higher candidate semantic owner `Raster!T`, but the `v0.2.0` root package
source exports **`RasterLease!T`, not `Raster!T`**. Treat the documented
higher owner as a design artifact, not an available public dependency.
This is not authorization to add `Raster!T` to `imagery-d`.

**Direct imagery consequence:** pixel, mask, ROI and external resource
ownership remain exclusively in `raster-d`. An imagery-domain owner, if
later admitted, may *retain existing raster leases* and immutable imagery
metadata; it must not create a second pixel/backing/reference-count engine,
or silently deep-copy raster data when copied.

## 4. raster-d-research: historical lifetime proof and pitfalls

**Source authority:**

- [R0.2 external storage / lifetime evidence](https://github.com/alex-1974/raster-d-research/blob/main/experiments/r0_2_memory_model/lifetime/README.md)
- [R0.3 raster view experiment](https://github.com/alex-1974/raster-d-research/blob/main/experiments/r0_3_raster_view/README.md)
- [R0.2 memory-model study](https://github.com/alex-1974/raster-d-research/blob/main/docs/research/memory-model.md)

These independent experiments demonstrate:

- successful retained owner copies with exact-once final release;
- views and nested ROIs working within their lifetime;
- whole-source compile-negative cases for stack-local owner/ROI escapes,
  including global and heap escape attempts in the research corpus;
- fully borrowed foreign buffers that cannot be safely retained must
  remain **synchronous, scope-bounded** callbacks rather than masquerade
  as owners;
- optimizations or adapters must preserve source borrow provenance.

The historical R0.2 model examined Phobos `SafeRefCounted`; the current
`raster-d` implementation instead contains a private, audited
`RasterBackingOwner` refcount/control block. **Do not mechanically copy the
research prototype into production**; retain the proof obligations.

**Direct imagery consequence:** a file decoder is not required to test
the `ImageView` lifetime model. In addition to existing M1.5 and M3.2.3
negative builds, test any new metadata owner for illegal global, heap,
ROI and foreign-buffer escapes where the language contract claims to
prevent them.

## 5. containers-d: deterministic raw storage and GC reachability

**Source authority:**

- [Runtime ring-buffer storage/ownership design](https://github.com/alex-1974/containers-d/blob/develop/docs/design/runtime-ring-buffer-storage.md)
- [RuntimeStorageOwner implementation](https://github.com/alex-1974/containers-d/blob/develop/source/containers/internal/runtime_storage.d)
- [M4.2 lifetime/storage research](https://github.com/alex-1974/containers-d/blob/develop/docs/research/m4-2-lifetime-storage-foundation.md)
- [Runtime allocator research](https://github.com/alex-1974/containers-d/blob/develop/evidence/research/runtime-storage-allocator.md)
- [Element lifetime implementation](https://github.com/alex-1974/containers-d/blob/develop/source/containers/internal/element_lifetime.d)
- [Public container package](https://github.com/alex-1974/containers-d/blob/develop/source/containers/package.d)

**Established lessons:**

- `RingBuffer!T` owns one runtime allocation. Normal copying is disabled
  to prevent a double owner or silent deep allocation.
- Its move operation transfers the storage handle in O(1), leaves the old
  owner inert, and does not relocate element addresses.
- A structural mutation, owner move, or owner destruction invalidates
  previously obtained borrowed segments. Lifetime annotations must be
  verified against the **actual pointer-owned storage**.
- Allocation of raw storage **does not** begin a `T` object's lifetime.
  The container must separately account for live elements, construction,
  destruction, and the clearing of vacated storage.
- For indirection-bearing `T`, C-heap storage is not automatically visible
  to D's GC. The implementation uses `hasIndirections!T` and
  `GC.addRange`/`GC.removeRange`, with zeroing of unused slots to avoid
  stale conservative roots.
- `RuntimeStorageOwner` is **package-private**. A public generic
  allocator interface was deliberately deferred: allocator state and
  lifetime otherwise become part of the consumer API and could add costs.
- `StaticVector!(T, Capacity)` is a *fixed-capacity* container, not a
  substitute for a variable-length metadata snapshot with arbitrary
  runtime cardinality.
- M4.2 shows compiler/codegen details for D move and placement
  construction must be validated against baseline toolchains; a generic
  helper is not automatically equivalent or zero-cost.

**Direct imagery consequence:** replacing `.idup` with a raw
`malloc`-owned array of `IntrinsicChannel` is **not** a trivial
optimization. Those descriptors include D `string` references, so
GC reachability and any independent string-content ownership must be
proven. A small `@trusted` boundary must establish allocation size,
alignment, object lifetime, registration/cleanup (if needed),
failure atomicity, and exact-once destruction.

Do **not** import `containers.internal.runtime_storage` into imagery:
it is private to `containers-d`, and a ring buffer is not inherently
the domain model of immutable image channel metadata. Reuse the
already-proven **engineering rules**, not private implementation types.

## 6. M3.2.4 result classified by actual lifetime

[Existing M3.2.4 evidence](m3-2-dynamic-metadata-results.md) establishes:

| Mechanism | Status | Actual guarantee |
| --- | --- | --- |
| `RasterLease!T` | Production `raster-d` public API | Retained pixel/validity backing; borrowed views bound to owner |
| M1.5 `ImageView!T` | Imagery research, compiler-tested | Borrowed raster + immutable semantic descriptors, transitive ROI |
| M3.2.3 compound view | Imagery research, compiler-tested | Adds borrowed intrinsic metadata to M1.5 image view |
| M3.2.4 `idup` snapshots | Imagery research, compiler-tested | Independently GC-retained immutable slice data; **not** deterministic owner-tied release |
| `containers.internal.RuntimeStorageOwner` | Private `containers-d` implementation | Deterministic unique raw storage, not a public imagery buffer abstraction |
| `Raster!T` high-level design | `raster-d` design document | **Not exposed by the verified v0.2.0 root package** |

Do not infer an ownership guarantee from `const(IntrinsicChannel)[]`:
`const` is a read capability, not immutable backing, unique allocation
or proof that the caller cannot mutate the source. M3.2.4's
`.idup` is an explicit **snapshot operation**, but the `string`
fields may reference separately existing immutable strings; this
experiment did not test arbitrary foreign string/byte-buffer lifetime.

## 7. Imagery-side architectural conclusion (proposal, not admission)

**Do not begin M3.2.5 by implementing yet another allocator.**

Maintain two independently meaningful capabilities:

1. **Borrowed processing semantics**: non-owning
   `ImageView!T` + immutable/read-only channel descriptors and optional
   validity. This is the default kernel-facing path: fast, no per-ROI
   allocation, `@safe` and ideally `@nogc`.
2. **Optional retained product/metadata state**: an owner justified by
   consumers who need data to survive beyond the caller's original
   metadata buffers. It retains existing `raster-d` leases and chooses
   an explicit metadata snapshot/retain/release model.

Potential metadata retention choices remain **candidates**:

- **caller-owned immutable storage borrowed via `return scope`**:
  no allocation by imagery, but caller must keep storage live;
- **GC-managed `.idup` snapshot** (qualified baseline):
  simple, safe lifetime extension, non-deterministic reclamation;
- **deterministically released metadata owner**: requires concrete
  consumer demand, GC-pointer reachability proof for string/indirection
  fields, exact-once release, safe move semantics, failure behavior,
  and performance evidence. A reference-counted variant would be a
  separate ownership contract from a unique move-only variant.

Avoid conflating `@nogc` *borrow/operation* code with allocation in
one-time construction. Do not promise that owner movement while borrowed
is safe: the source repositories explicitly distinguish such cases.

## 8. Minimal M3.2.5 qualification plan

Perform **evidence comparisons, not public type freezes**:

| Gate | Question | Required evidence |
| --- | --- | --- |
| C1: Borrow-only | Can current M1.5/M3.2.3 semantics serve callers retaining metadata themselves? | Positive/negative DMD + LDC owner, metadata, ROI and invalidation cases; no unnecessary snapshots |
| C2: GC baseline | What do the two `.idup` snapshots actually cost? | Allocator-count/RSS under 1, 3, 4, 17, 64, 256+ channels; repeated ROIs; test string reachability |
| C3: Deterministic alternative | Is owner-controlled reclamation required by a concrete consumer? | Exact resource-release, failure atomicity and owner move/drop tests; `hasIndirections` and GC-root invariants if using external memory |
| C4: Ownership choices | Unique move-only versus shared-retained immutable metadata? | Explicit copy/move/assignment semantics and compile-negative tests; no hidden deep copy |
| C5: Scope and compiler | Which borrows must be blocked at compile time? | Whole-source compile-fail tests with closely related valid controls; no false-positive failures |
| C6: Performance | Does a candidate hurt the image hot path? | Optimized LDC versus direct raster baseline, allocation counts, controlled varied-channel/ROI workload |
| C7: Integration | Does a real consumer require the additional owner? | Consumer-backed M3 acceptance/rejection ADR; no `imageio-d` or `containers-d` dependency by convenience |

**Decision pending:** Only after these gates should imagery decide whether a
public image owner is necessary and, if so, what its metadata ownership,
allocator and thread-safety contracts should be. Pixel ownership remains
`raster-d`'s responsibility throughout.
