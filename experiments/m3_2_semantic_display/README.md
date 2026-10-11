# M3.2 — Synthetic semantic display probe

**Status:** Research experiment; neither public API nor production-admission decision.

**Question:** Does a source-independent, explicitly bound three-component image
operation preserve common-grid channel meaning and optional validity while
remaining independent of physical raster layout and ROI partitioning?

## Boundaries

- Uses only public `raster-d` types for storage, leases, views and ROIs.
- Reuses **the original M1.5 experimental ImageView contract** from
  `../m1_5_image_view_contract/source/m1_5_image_view/contract.d`.
  The previous M1 evidence remains untouched.
- Four synthetic float planes are presented through planar or interleaved
  `RasterLease!float`. The explicit three-channel selection is (3, 2, 1).
  Opaque semantic IDs do not imply a standard colour encoding.
- Optional one-plane `RasterView!ubyte` validity is handled independently of
  alpha and NoData. This experiment chooses **invalid -> zero output values**
  as one explicit policy, not as a universal renderer convention.
- No codecs, filesystem sources, `imageio-d`, CRS, sampling conversion,
  sRGB assumptions, implicit normalization, dynamic scheduler, or cache.
- Destination storage is provided by the consumer. The hot mapping function
  is written as `@safe nothrow @nogc`.

## Test questions

| Probe | Experiment |
| --- | --- |
| H1 | Identical semantic pixels over planar and interleaved raster layouts |
| H2 | Same output across independently created in-memory inputs, representing distinct hypothetical origins (not real decoder tests) |
| H3 | Existing M1.5 primary/metadata/validity/ROI lifetime compile-negative probes are rerun |
| H4 | Reject duplicate/out-of-range RGB selection, wrong channel-descriptor count, and invalid same-grid validity dimensions |
| H5 | Whole region equals four uneven ROI partitions, exactly |
| H6 | Materialization failures and revision mismatches are *not* yet covered; reserved for the source boundary |

The semantic oracle for this identity/selection operation is a simple
independent formula `channel * 100 + y * 10 + x`.
No numerical tolerance is required for mere exact value selection.

## Running

From the workspace `libs/imagery-d` directory:

```bash
bash experiments/m3_2_semantic_display/tools/run.sh
```

The script defaults to `dmd` and `ldc2`, and accepts
`COMPILERS="dmd"` for a narrower local check. It runs the M3.2
positive runtime probe and replays M1.5's previously validated four
`@safe` DIP1000 negative lifetime builds for the same compiler.

The DUB recipe compiles only the required **M1.5 contract module**
through `sourceFiles`, not the M1.5 `app.d` executable.

## Qualification limits

A green probe supports source-independent semantic mapping but does **not**
justify freezing public `ImageView` names, generic channel metadata, sample
conversion policy, output encoding, or decoder integration.

Before any M3 public surface is admitted: consumer requirement, complete
semantic contract, independent numerical oracle when arithmetic is added,
ownership and failure semantics, bounded residency, optimized LDC performance,
negative compile gates and acceptance ADR remain mandatory.

Tracks [imagery-d issue #24](https://github.com/alex-1974/imagery-d/issues/24).
Interoperability boundary proposal: PR #23.
