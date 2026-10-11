# M3.2.2 — Channel identity, radiometry and explicit colour binding

**Status:** Research-only continuation of M3.2.1; not a frozen public API.

This experiment is maintained **only in `imagery-d`**. It does not consume
`imageio-d`, `proj-d` or image files.

## Accepted architectural anchors

- [M1 ADR 0002](../../docs/adr/0002-image-semantic-core.md):
  primary processing view with one sample type and common grid;
  immutable channel identity, separate colour binding; raw samples must
  not implicitly become physical values, normalized colour or alpha.
- [M2 ADR 0003](../../docs/adr/0003-source-cache-pipeline-architecture.md):
  explicit materialization and provenance without a forced source decoder.
- Prior experiment: `experiments/m3_2_semantic_display` originally
  qualified planar/interleaved and whole/ROI equivalence in PR #25.

## Prototype

The experimental `m3_2_channel_metadata.contract` module describes:

- `IntrinsicChannel`: a stable opaque ID, source label, quantity label,
  optional scale/offset and **no inferred RGB role**.
- `ColourBinding`: an explicit ordered (R,G,B) selection plus a declared
  interpretation tag **separate** from intrinsic band identity.
- `ValueInterpretation.stored`: direct sample selection; calibration ignored.
- `ValueInterpretation.physical`: explicitly evaluate
  `stored * scale + offset`; reject missing/invalid calibration before
  writing output.
- `SemanticMapError`: distinct errors for cardinality, channel identity,
  binding, calibration, validity, shape and data access.

The `ColourBinding.declaredColour` field is metadata only; the probe
does not convert to or from sRGB. Naming a band `R` also must not
change which plane is selected. Opaque names and quantities are kept
for consumers to interpret, not standardized in this experiment.

`mapComponentsInto` remains an `@safe nothrow @nogc` kernel operating
on the **existing M1.5 `ImageView!float`** and caller-owned
`WritableRasterView!float`. The separate `IntrinsicChannel` array is
a borrowed, read-only sidecar, not a second pixel storage system.
Its attachment and lifetime model are deliberately not public yet.

Validity continues to be separate. Invalid-to-zero is the explicit
current test policy only; it must not become an implicit NoData, alpha,
clipping, or physical-value policy.

## Positive and negative probes

The current synthetic 7 x 4 fixture adds:

- mismatched channel names versus explicit selection order (3,2,1);
- one unknown/uncalibrated channel retained while selecting calibrated bands;
- raw stored values unchanged despite nontrivial scale/offset metadata;
- physical values computed only when selected, including negative and
  greater-than-one results, no clipping/normalisation;
- exact planar/interleaved and whole/four-ROI equivalence;
- optional validity and truly mask-free path;
- explicit errors for cardinality, identity mismatch, duplicate/out-of-range
  selection, missing calibration and nonfinite calibration.

The existing M1.5 `@safe` negative escape probes run unchanged under
both compilers. No semantic ownership structure is promoted yet.

## Run

From `libs/imagery-d`:

```bash
bash experiments/m3_2_semantic_display/tools/run.sh
```

It runs positive debug and release modes and the M1.5 positive and four
expected-compile-error lifetime probes under DMD and LDC.

## Limitations and next evidence

No real decoder, georeferencing, spectral ontology, color management,
dynamic metadata container, alpha/NoData representation, common-grid
materializer, or public DUB package has been introduced.

A numerical contract and controlled performance comparison for
radiometric arithmetic must be completed before any production
admission. The simple independent formula oracle is appropriate to this
non-rounded integer-valued fixture, but not to general float errors.

Issue [#26](https://github.com/alex-1974/imagery-d/issues/26) tracks M3.2.2.
