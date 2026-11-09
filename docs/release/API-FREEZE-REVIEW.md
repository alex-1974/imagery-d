# API freeze review — current develop

## Candidate public additions

| Area | Public modules | Disposition |
| --- | --- | --- |
| Overview policy | `imagery.pyramid.overview_selection` | Candidate for freeze |
| Source quality | `imagery.pyramid.source_quality` | Candidate for freeze |
| Regular tile mosaic | `imagery.mosaic.decoded_tile_mosaic` | Candidate for freeze; regular grids only |
| Overlap blend | `imagery.mosaic.overlap_blend` | Candidate for freeze; aligned RGB8 only |
| Validity policy | `imagery.mosaic.validity_policy` | Candidate for freeze |
| M6 analysis | `imagery.analysis.*` | Qualification only; no broad freeze yet |

## Freeze constraints

- No implicit reprojection, resampling, source selection or NoData inference.
- Callers provide geometry, quality, validity and blend weights explicitly.
- Returned failures do not replace an existing published owner.
- M6 primitives remain pre-release until numerical oracles and performance
  budgets exist per operator.
- ML adapters are not part of the core API freeze.

## Verification

- `dub test --config=no-io --compiler=dmd`: required
- `dub test --config=no-io --compiler=ldc2`: required
- M5 DMD/LDC qualification consumers: required
- Real-image and platform evidence: release gate, not local freeze proof
