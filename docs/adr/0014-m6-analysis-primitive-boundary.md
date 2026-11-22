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

## Sobel/Canny correction checkpoint — 2026-11-22

The #193 benchmark follow-up exposed NaN-initialized float accumulators in
the old Gaussian, bilateral, guided and Sobel paths, including parallel
variants. Explicit zero initialization fixes these; value-based regressions
replace shape/agreement-only evidence. Scalar Gaussian rejects insufficient
destination storage before writes. OpenCV Sobel and an independent NMS plus
seeded-component oracle qualify the repaired Canny slice on finite fixtures.

The wavefront also dropped successors when an eight-way expansion exceeded
`2*count+1`. Two full-domain index arrays now reserve proven queue capacity
and swap across waves. The 17-pixel eight-ray regression exercises the loss.
This changes the previously incorrect result and bounds frontier payload to
16N bytes on x86-64; it does not claim allocation-free complete Canny calls.

Sobel uses unnormalized stencils, source-edge replication and finite inputs.
Canny has no implicit Gaussian, uses inclusive four-sector NMS, suppresses
the outer ring and performs eight-connected global hysteresis. Gradient tiles
with a one-pixel halo agree exactly. Global connectivity cannot be qualified
by arbitrary independent tiles; #186's broader region/ID workflow stays open.
Scientific admission of every remaining primitive is still pending.
