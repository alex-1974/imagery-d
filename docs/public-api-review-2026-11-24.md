# Public API documentation review — 2026-11-24

This review covers every source module at develop `a42fe459ac06aee2f4d637e9c3b7250affac120a`,
with the documentation changes on `codex/public-api-documentation`.
Issues [219](https://github.com/alex-1974/imagery-d/issues/219),
[220](https://github.com/alex-1974/imagery-d/issues/220) and
[221](https://github.com/alex-1974/imagery-d/issues/221) guided the work.
Their draft wording was checked against implementation and tests rather than
adopted as an existing contract.

## Scope and method

All 47 source modules were compiled to unfiltered DMD JSON. The inventory includes
root re-exports and direct imports, public types, aliases, overloads, methods,
fields, properties and enum values. It excludes compiler-generated members,
unittests and nonpublic declarations/containers. Template protection missing from
compiler JSON is recovered from source modifiers, labels and blocks.

The resulting surface contains **1,241 public declarations across 36 modules**.
Overloads and members count separately; this is not comparable to the original
heuristic count of about 277 grouped symbols. Every declaration has attached Ddoc.
Every public function/constructor argument has a Params entry; non-void functions have Returns.
Direct explicit throws have Throws sections. Transitive exception behavior still
requires semantic review; this check does not prove a complete call graph.

Author review applied the six questions in [the style guide](DDOC-STYLE.md) to
purpose/use, numeric domains, result/failure state, ownership/lifetime, explanatory
order and public-only use. Existing precise numerical and lifetime contracts
were retained. Comments were added or revised wherever those facts were absent
or obscured. Public modules with complete existing documentation, such as the
planar-cache metrics family, retain it.

All 36 modules with public declarations have documented executable examples.
Meaningful related methods and trivial members share family examples rather
than duplicate one test for every accessor or alias. Important type-level
examples are checked on their actual rendered pages. The complete source-level
example count and per-module inventory are reported below; presence is not a
substitute for reading the example.

## Contract corrections and clarifications

- CostPath edge weights use the **arithmetic** endpoint mean times geometric
  step length. Gaussian sigma is in pixels; line width is not universally twice sigma.
- A try prefix does not promise nothrow or preserved output. Out parameters
  reset on entry; ref outputs and working storage have operation-specific rules.
- Floating-point defaults are NaN unless initialized explicitly. Exposure and
  brightness/contrast identity values must be constructed explicitly.
- RGB indices distinguish encoded normalization from transfer-decoded linear
  values. Black chromaticity has its own validity flag. Histogram self-matching
  really does use an identity table, including unoccupied bins.
- Distribution.percentile accepts integral 1..100 and returns a bin index or -1.
  This differs from the newer RGB histogram percentile interface.
- NormalizedDifferenceValid uses NaN for explicit mask exclusion; a small
  denominator still produces zero. This differs from spectral-evidence validity.
- Source levels are identifiers, not an inferred ordering. Source identity,
  revision, grid, dimensions and metadata all matter to caching. Borrowed plane
  callbacks retain their explicit semantic lifetime limitations.
- Exposure and curves aliases name scalar mappings. Owned raster variants are
  separate operations. The stray flood-fill sentence on cannyPreview was corrected.
- Internal kernel declarations already have package/private protection; this
  pass does not change their visibility or hide public APIs by omitting modules.

## Existing implementation defects exposed by the review

[Issue #222](https://github.com/alex-1974/imagery-d/issues/222): copyRoi!float cannot
instantiate under its declared @safe signature on DMD 2.113.0 or LDC 1.43.0.
Its Ddoc describes the limitation and directs callers to tryReadPlane with a
validated RasterView. It is counted and visible in the reference.

[Issue #223](https://github.com/alex-1974/imagery-d/issues/223): brightness/contrast
validates the affected-array length but currently maps unselected channels too.
A separate public DUB consumer reproduced [0.25,0.75] becoming [0.35,0.85] with
[true,false] and brightness +0.1; the expected unselected result is 0.75.
This limitation is documented as a defect, not adopted as the desired contract.

Both defects need separate semantic changes and regression qualification. No
production algorithm, signature or visibility changed here. A lexical comparison
of all 47 modules, excluding comments and unittest blocks, found zero changed
runtime-token sequences.

## Validation

- Controlled DMD 2.113.0 and LDC 1.43.0: all 39 default unittest modules pass,
  including documented examples using public APIs.
- Declared frontend floor DMD 2.111.0: default and no-io checks are recorded in
  the PR; no-io has 38 unittest modules.
- Eight compiler-backed documentation-gate probes pass on DMD and LDC. Negative
  probes remove a public comment, parameter entry, return contract or exception contract, omit a
  module/page, and remove expected family-example pages. Private template
  members and protection labels are excluded by the positive control.
- DDOX 0.16.24 renders the complete site. The gate rejects missing public pages
  and malformed Ddoc warnings. Source, CostPath, worker, queue, Hessian/tensor,
  region-graph, SLIC and Levels family examples are checked on their type pages.

Reproduce the main checks with:

```sh
DC=dmd-2.113.0 bash tools/build-docs.sh
dub test --compiler=dmd-2.113.0 --force
dub test --compiler=ldc-1.43.0 --force
dub test --compiler=dmd-2.111.0 --force
dub test --config=no-io --compiler=dmd-2.111.0 --force
```

The machine-readable report is generated as build/ddox/coverage.json; the
reference entry is build/ddox/site/index.html. Neither generated artifact is a
second source of API truth or a published release.

## Review status

The author review and automated checks cover the complete public surface.
An **independent consumer readability review** requested by #220 remains a PR
review step; it is not represented as completed by the author or by coverage
checks. No real-scene acceptance from #187 or released decoder integration from
#145/#146 is inferred from documentation examples.

## Per-module coverage

| Module | Public declarations | Documented examples |
| --- | ---: | ---: |
| `imagery.analysis.canny_worker` | 10 | 1 |
| `imagery.analysis.color_slic` | 52 | 1 |
| `imagery.analysis.colour_indices` | 9 | 1 |
| `imagery.analysis.cost_path` | 18 | 1 |
| `imagery.analysis.execution` | 34 | 1 |
| `imagery.analysis.feature_components` | 87 | 1 |
| `imagery.analysis.feature_contracts` | 26 | 1 |
| `imagery.analysis.feature_evidence` | 51 | 1 |
| `imagery.analysis.feature_overviews` | 11 | 2 |
| `imagery.analysis.feature_parameters` | 38 | 7 |
| `imagery.analysis.feature_regions` | 237 | 6 |
| `imagery.analysis.feature_requests` | 15 | 1 |
| `imagery.analysis.feature_segmentation` | 2 | 1 |
| `imagery.analysis.feature_worker32` | 34 | 7 |
| `imagery.analysis.hessian_lines` | 22 | 3 |
| `imagery.analysis.lazy_cost_path` | 22 | 1 |
| `imagery.analysis.planar_cache` | 8 | 1 |
| `imagery.analysis.primitives` | 35 | 8 |
| `imagery.analysis.quality` | 6 | 2 |
| `imagery.analysis.raster_adapters` | 9 | 1 |
| `imagery.analysis.region_graph` | 72 | 1 |
| `imagery.analysis.rgb_histogram` | 22 | 3 |
| `imagery.analysis.structure_tensor` | 10 | 4 |
| `imagery.compositing.source_over` | 28 | 1 |
| `imagery.io` | 120 | 2 |
| `imagery.materialization` | 33 | 1 |
| `imagery.mosaic.decoded_tile_mosaic` | 20 | 1 |
| `imagery.mosaic.multiresolution` | 93 | 2 |
| `imagery.mosaic.overlap_blend` | 10 | 1 |
| `imagery.mosaic.validity_policy` | 14 | 3 |
| `imagery.presentation.brightness_contrast` | 19 | 1 |
| `imagery.presentation.exposure_curves` | 17 | 1 |
| `imagery.presentation.levels` | 19 | 2 |
| `imagery.presentation.luminance_stretch` | 14 | 1 |
| `imagery.pyramid.overview_selection` | 14 | 1 |
| `imagery.pyramid.source_quality` | 10 | 1 |

Total: 1241 declarations and 74 documented examples.
