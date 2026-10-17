# M3 RGBA — Original-source alias and typed ownership boundary (raster-d v0.2.0)

**Scope:** Research-only; no imagery-d production API. Existing stacked Draft PR #73 remains open on Draft #69. **Only imagery-d modified.** The raster-d and color-d v0.2.0 source/tag contracts were inspected read-only on 2026-10-13.

## Question

Can a caller supply two legal original four-plane `RasterView!ubyte` inputs and a final writable packed `WritableRasterView!SRgba8` that physically overlap **and** have one valid retained owner? Such a fixture is a prerequisite to claiming either physically checked original-source overlap rejection or tested snapshot semantics for the buffered packed final commit.

This question must not be confused with the already-qualified `raster.copyInto` preflight of **packed scratch versus packed destination**.

## Exact public-contract evidence

At `raster-d v0.2.0`:

| Mechanism | Observed contract | Consequence |
|---|---|---|
| `raster.owned_resource.OwnedByteResource` | Move-only, one armed physical release obligation; `tryAdoptMallocResource` requires genuine ownership and transfers it into the token. | Two independent tokens pointing at one `malloc` allocation are **not** a legitimate fixture. |
| `raster.import_owned.tryImportOwnedRaster!T` | Consumes **one** owned resource on successful import into an initially empty `RasterLease!T`; the original token becomes disarmed; multiple planes may describe **one** allocation. | A consumed token cannot be used to create a second `RasterLease!SRgba8`. Failure is classified `emptyResource` without transfer. |
| `raster.backing.RasterLease!T` | Same-`T` copies retain one non-atomic shared `RasterBackingOwner` reference count, not another free obligation. `view()` and `tryWritableView()` borrow and retain no owner. | Genuine source/output alias with **one sample type** is representable safely, and writable access does not mean exclusive access. |
| `raster.view.RasterView!T` / `raster.writable_view.WritableRasterView!T` | Public sample/ROI operations; construction from physical metadata and execution-base access restricted to `package(raster)`. | No published caller-visible way was found to reborrow the same retained backing under another sample type. |
| `raster.copy.tryCopyRasterPlane` | Same-`T` physical sample overlap rejected **before** writes; byte-disjoint planes in a shared owner are allowed. | Alias validation is an **operation** guarantee, not an intrinsic exclusive property of `RasterLease` or `WritableRasterView`. |
| `raster.internal.*` affine overlap helpers | Package-internal. | No independently callable source/output noalias certificate for heterogeneous four-plane/packed views. |

Sources: [owned token](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/owned_resource.d), [owned import](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/import_owned.d), [backing/lease](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/backing.d), [read-only view](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/view.d), [writable view](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/writable_view.d), [public copy](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/copy.d), and [public exports](https://github.com/alex-1974/raster-d/blob/v0.2.0/source/raster/package.d). No functions are inferred from private, hypothetical future APIs.

## Executable public-consumer experiment

[The independent DUB alias boundary consumer](../../experiments/m3_rgba_layer_compositing/alias_boundary/source/app.d) is intentionally small and uses **only** the released package exports plus the published `color.SRgba8` type:

1. Own and import one `malloc` allocation with four interleaved `ubyte` planes; verify ownership transfer and consumed token.
2. Copy `RasterLease!ubyte` to retain **the same backing**, borrow a read-only source and writable target from distinct lease handles; check this borrow/copy procedure in an `@safe` function.
3. Fill all planes, attempt self-plane copy through public `tryCopyRasterPlane`, require `sourceDestinationOverlap`, then verify the entire affected plane remains unchanged.
4. From the same physical owner, copy green plane into byte-disjoint red plane; require success and exact sample equality. Sharing an owner is **not** equivalent to every plane pair overlapping.
5. Attempt to import the already-consumed `OwnedByteResource` as a *new* packed `RasterLease!SRgba8`; require `emptyResource`, `unchanged` disposition and inert packed lease.
6. Compile-negative `__traits(compiles)` controls ensure there is no implicit cross-`T` conversion between `RasterLease!ubyte` / `RasterLease!SRgba8` or their read-only view types. **This does not claim to prove the absence of every possible named API**; the absence of a published retype/borrow operation is supported by source inspection.

Only the initial `malloc` adoption is `@system` as required by its contract; all published retained-owner/borrow/copy checks are compiled from an `@safe` function. It performs no image compositing and claims no GPU/parallel/snapshot guarantee.

**Qualification gate:** the existing `m3-rgba-layer-compositing.yml` runs the standalone proof on **DMD 2.112.1, DMD 2.113.0, LDC 1.42.0, LDC 1.43.0** against pinned released raster/color v0.2.0. Treat it as *implemented/unqualified* until these exact-HEAD jobs finish.

## Resulting design boundary

**Representable today:** true one-backing aliasing for a common `T`, including the original four-`ubyte`-plane source and a writable **four-`ubyte`-plane** destination. The public same-`T` `copyInto` family checks such overlap, but the imagery four-plane compositing loop **does not inherit that check**. Calling the existing research compositor with an aliased source/output violates its explicit caller precondition, irrespective of whether some pixels happen to look correct.

**Not established today:** an original `RasterLease!ubyte` and a **packed `RasterLease!SRgba8` of the same physical backing** through a supported public reborrow operation. A test that constructs a second independent `free` owner on the original allocation would be invalid and potentially double-free. A private `@trusted` pointer cast, raw descriptor manufacture, or ported `raster.internal` affine overlap logic would not fix the public ownership contract.

The current buffered research harness creates separately owned four-plane scratch, packed scratch and final packed output. Consequently its existing passing copy preflight concerns scratch/target only. The historical claim **original four-plane source versus final packed destination overlap is checked** remains **BLOCKED**; no failure-atomic result for arbitrary original aliasing is asserted.

## Two *different* future contracts

**A — Caller-supplied packed output, prewrite alias rejection.** Keep explicit output and constant per-call working memory. To certify heterogeneous original-source/target overlap without weakening correctness would need a deliberately designed **public** physical-relation operation or a supported shared-owner typed view facility in the relevant provider layer. Such a proposal belongs in raster-d's own decision process; **do not alter that sibling repository under this task**. Avoid custom physical-pointer checks in imagery-d.

**B — Freshly owned packed result, published only on success.** Compose into independently allocated four-plane scratch, repack into **a fresh packed lease**, and return that packed lease only when every conversion succeeds. The packed scratch becomes the result, avoiding the existing third final-target allocation and its last `copyInto` pass. This would establish source/result nonoverlap **by construction** during a single-threaded call (assuming all source storage remains live and no concurrent mutation), not by certifying user-supplied output. It has **different caller ownership, allocation/residency, output and failure semantics** and is only a design candidate. No new public API or performance claim follows without a prototype, full 432-scene oracle, exact compiler tests, and separate native benchmark. It cannot transparently replace contract A.

**Decision:** Maintain the blocker for A, and investigate B as an *alternative* image-domain owned-result path only if an actual consumer wants that distinct API. There is no evidence-based justification yet for widening raster-d's public surface, manufacturing typed aliases, or selecting an automatic execution policy.
