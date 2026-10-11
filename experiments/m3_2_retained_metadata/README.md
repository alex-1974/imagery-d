# M3.2.3 — Retained raster and metadata lifetime experiment

**Status:** Research-only; no public API or production package admission.  
**Scope:** `imagery-d` only; no `imageio-d` / `proj-d` dependency.

## Motivation

M1.5 verified a lease-bound processing `ImageView!T` holding one
`RasterView!T`, immutable M1 channel descriptors, and optional validity.
M3.2.2 introduced separate intrinsic channel descriptions for explicit
stored/physical value interpretation.

This probe asks whether those two **borrowed** representations can remain
valid together, including through ROI, with a single owner retaining the
necessary raster resources and immutable metadata.

## Selected research model

```text
RetainedFourChannelFixture              ← test owner only
├─ raster-d RasterLease!float            ← pixel resource retention
├─ raster-d RasterLease!ubyte (optional) ← mask resource retention
├─ immutable ChannelDescriptor[4]        ← M1 identity, in owner
└─ immutable IntrinsicChannel[4]         ← M3.2.2 metadata, in owner
                 │
                 ▼ borrow() / DIP1000
         BorrowedSemanticImage           ← non-owning, cheap view
         ├─ M1.5 ImageView!float
         └─ const(IntrinsicChannel)[]
                 │
                 ├─ tryRoi()             ← shares metadata, no copying
                 └─ mapInto()            ← M3.2.2 semantic kernel
```

The fixed-size fixture is **only a synthetic test**, not the proposed
representation for arbitrary image channels or a public `ImageLease`.
No new pixel-storage owner exists: both pixel resources are
`raster-d` leases. Borrowed views must not outlive their fixture.

Intrinsic channel identities are cross-validated with the M1.5 channel
descriptors when the bound view is constructed. Metadata is truly
`immutable` in this research fixture, not just mutable backing exposed
through `const`. No implicit RGB/alpha/NoData/colour inference occurs.

**Important D safety evidence:** Two attempted post-construction paths
were rejected by DMD/LDC because a borrowed scope image could not be
assigned to an ordinary result or returned from a scope-local.
The successful form is a direct, compiler-checked struct value
construction of `BorrowedSemanticImage(image, intrinsic)`, with both
factory inputs explicitly `return scope`. This is a documented result,
not permission for an `@trusted` escape hatch or a compiler workaround.

## Tests

The positive test creates a 5 × 3 four-plane `float` source with
planar and interleaved layouts, both with and without a separate one-plane
validity mask. It borrows the composite image from its retained fixture,
maps components (3,2,1) through the existing explicit physical scale/offset
kernel into caller-owned output, and verifies whole versus four uneven ROI
partitions exactly. Metadata is shared through ROI without copies.

Additional failure tests reject wrong intrinsic cardinality, mismatched
semantic IDs, and out-of-bounds ROI.

Five **expected compile failures** exercise `@safe` DIP1000:

- `negative-intrinsic-escape` — stack-local intrinsic metadata;
- `negative-primary-escape` — stack-local primary lease;
- `negative-validity-escape` — stack-local validity lease;
- `negative-owner-escape` — stack-local combined owner;
- `negative-roi-escape` — ROI derived from stack-local owner.

The shell runner requires a compiler diagnostic at this experiment's
contract file mentioning a scope/reference escape; it rejects generic
failures as insufficient evidence.

## Execute

From `libs/imagery-d`:

```bash
bash experiments/m3_2_retained_metadata/tools/run.sh
```

The default runs both `dmd` and `ldc2`, debug and release positive
paths, and five negative compile configurations. An explicitly selected
compiler can be used:

```bash
COMPILERS="dmd" bash experiments/m3_2_retained_metadata/tools/run.sh
```

The associated targeted CI checks DMD 2.111.0 / 2.113.0 and LDC
1.41.0 / 1.43.0 with public `raster-d` v0.2.0, using the original
M1.5 and M3.2.2 contract modules unchanged.

## Boundaries and unresolved decisions

- Metadata cardinality, ownership strategy and allocation remain
  **provisional** outside this four-channel fixture.
- The owner does not introduce a new general-purpose heap allocator or
  reference-counted resource model.
- No code reads JPEG/PNG/TIFF, nor defines `imageio-d` integration.
- The colour-binding representation, values/presentation conversion,
  NoData/alpha relationship, real numerical tolerances and source
  revision/materialization semantics are not frozen.
- No claimed byte-for-byte memory-efficiency or throughput improvement.
- Before public API promotion, prove the same laws for variable-length
  metadata, error and move semantics, independent numerical behavior,
  realistic resident images and performance versus `raster-d` controls.

Tracking [imagery-d #28](https://github.com/alex-1974/imagery-d/issues/28)
and stacked [PR #29](https://github.com/alex-1974/imagery-d/pull/29).
