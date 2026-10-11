# M3.2.4 — Variable-length immutable metadata snapshots

**Status:** Research-only experiment. No public `imagery-d` API or final allocator policy.

This experiment extends the [M3.2.3 retained metadata lifetime](../m3_2_retained_metadata/README.md)
and reuses the accepted M1.5 common-grid view and M3.2.2 intrinsic
metadata contract without changing them.

## Hypothesis

A single retained image fixture can own any number of logically ordered
channel semantics, in immutable arrays, and provide a scope-bound
`BorrowedSemanticImage` that:

- shares the same metadata arrays across any number of ROIs;
- does not allocate, copy metadata or acquire pixel resources when borrowing;
- cannot outlive the owner from which it borrows;
- leaves pixel/validity resource retention to existing `raster-d` leases;
- preserves channel identity independent of physical layout, original label,
  colour-space assumptions, or how the pixels were produced.

## Deliberately limited prototype

`RetainedDynamicImage.create(ids, meanings, error)` validates per-plane
semantic identity and equal descriptor counts before publication, then
uses **two `.idup` allocations** to snapshot both arrays as
`immutable` data. A caller may mutate or release its original arrays
without changing those snapshots. Immutable source labels are already
immutable D strings; the prototype has no arbitrary ownership policy
for external source-provided metadata buffers.

**Lifetime finding:** A metadata slice can be returned separately in
`@safe` code even after its owner goes out of scope, because its immutable
storage is GC-managed. This does **not** allow returning a `BorrowedSemanticImage`
that references a local raster lease: the latter remains prohibited. Thus the
prototype gives *safe shared GC residency*, not strict metadata lifetime
tied to the owner. Any deterministic owner-controlled reclamation strategy
requires a different representation and new negative tests.

This approach uses D GC-backed allocation at **construction**, not
`@nogc`. This is a **candidate baseline**, not an allocation policy
recommended for a production image owner. Heap residency, allocator
choice, OOM and deterministic release still need separate qualification.

The owner retains `RasterLease!float` plus optional
`RasterLease!ubyte`; image borrows and ROIs keep the validated M1/M3
`return scope` relationships. It disables copying of the entire owner.
A positive `move(owner)` probe occurs **before** borrowing. Moving an
owner while borrowed is *not* an admitted capability.

A zero-length metadata snapshot is a valid empty metadata fixture for
this experiment. It is **not** an accepted promise that a usable image
may have zero channels.

## Probe corpus

Variable channel counts: **0, 1, 3, 4, 17, 64**.

- Both planar and interleaved physical raster layouts for nonzero images.
- Masked and mask-free paths; one invalid pixel in masked images.
- Caller input metadata mutated after owner snapshots.
- Explicit owner movement before acquiring a borrowed view.
- ROI `intrinsic.ptr` identity preserved; neither ROI nor
  `BorrowedSemanticImage` construction copies metadata.
- For at least three channels: ordered physical value selection of the
  last three channels; whole region equals four uneven ROI partitions,
  checked against a separate exact-value synthetic oracle.
- Identity and cardinality failures report distinct errors and do not
  publish a partially valid metadata owner.
- Negative compiler probes for owner and ROI escapes, checked for real
  DIP1000 diagnostics (not generic build failures). A separate positive
  compile probe establishes that GC-owned immutable metadata slices can
  survive the owner; this is safe but extends their GC residency.

The borrowed operation and ROI path reuse the existing
`@safe nothrow @nogc` M3.2.2/M3.2.3 kernels. The **construction
path is not `@nogc`**.

## Run

From `libs/imagery-d`:

```bash
bash experiments/m3_2_dynamic_metadata/tools/run.sh
```

Default compilers: DMD and LDC. A targeted compiler may be selected by
`COMPILERS=dmd`. Tests run debug and release positive paths and
two expected `@safe` compile-negative probes, plus one positive
GC-metadata lifetime escape probe.

The targeted GitHub Actions matrix uses DMD 2.111 / 2.113 and LDC
1.41 / 1.43, with `raster-d` tag `v0.2.0`.

## Explicit non-goals

No decoder integration, M2 cache/source API, geospatial grid logic,
heterogeneous sample representation, colour conversion, alpha/NoData
normalisation, or final public API is specified. The metadata arrays
are variable-length, but data processing remains one common-grid
`ImageView!float` and per-plane one-to-one semantic matching.

Next admission evidence must compare one-time GC snapshots with
deterministic/caller-controlled alternatives on allocation count,
transfer behavior, `@safe` proof, lifetime, and scale. It must also
measure memory and hot-path throughput with a raster-only control
before any performance or production claim.

Tracking: [Issue #30](https://github.com/alex-1974/imagery-d/issues/30)
and [PR #31](https://github.com/alex-1974/imagery-d/pull/31).
