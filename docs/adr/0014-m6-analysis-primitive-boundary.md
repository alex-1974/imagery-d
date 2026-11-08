# ADR 0014 — M6 analysis primitive boundary

**Status:** M6 STARTED — PRIMITIVES REQUIRE OPERATOR QUALIFICATION

## Decision

M6 begins with deterministic CPU primitives over caller-owned scalar planes:
filters, gradients/edges, morphology, indices and segmentation helpers.
These operations remain explicit functions over supplied samples and
dimensions. They do not infer sensor meaning, CRS, NoData, class labels or
model provenance.

The existing primitives are useful implementation seeds, not yet a promise of
scientific accuracy or a stable algorithm catalogue. Each promoted operator
requires an independent oracle, boundary/invalid-input tests, numerical
tolerance, allocation behaviour and a documented memory/performance budget.

ML-assisted interpretation remains an optional adapter boundary. Model
loading, inference runtimes, training data and device scheduling do not belong
in the core M6 API without a concrete consumer contract.

## Qualification order

1. scalar filters and Sobel/Canny gradients;
2. binary morphology and connected components;
3. index formulas with explicit band/unit contracts;
4. watershed/SLIC-style segmentation;
5. optional external ML adapters after the classical operators are stable.
