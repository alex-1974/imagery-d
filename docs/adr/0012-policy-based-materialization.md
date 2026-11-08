# ADR 0012: Policy-based image materialization

## Status

Accepted as the implementation direction for the materialization adapter.

## Decision

Materialization policies are represented by compile-time D types and composed
through `ValidatedMaterializationSpec!(Model, Geometry, Output)`.

- `Model` describes component roles and colour policy;
- `Geometry` describes native, nearest or bilinear materialization;
- `Output` describes sample type and clipping/quantization semantics.

The implementation validates policy shape with template constraints and
`__traits(compiles, ...)`. New models are added as new descriptor types rather
than by extending a central runtime enum.

`color-d` owns colour mathematics. `imagery-d` owns plane selection,
materialization and conversion orchestration. `raster-d` owns retained storage
and views.

## Consequences

Known policy combinations are compile-time checked and can specialize without
virtual dispatch. Runtime decoder metadata remains at the adapter boundary and
must be mapped to an explicit model before colour conversion.

The legacy runtime `materialize(ImageRegion, ImageMaterialization)` entry point
remains available for compatibility. New code should prefer the typed
`materialize!Spec`, `materializeRgb!Spec` and raster adapter functions.
