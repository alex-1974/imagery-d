# ADR 0017: Bounded registered multiresolution mosaic

**Status:** Candidate under PR #205; not API or M6 completion  
**Date:** 2026-11-22

## Decision

Add opt-in `imagery.mosaic.multiresolution` as the concrete #148 integration
consumer. It composes overview selection, caller-provided regular RGBA8 tiles,
center-nearest/bilinear/cell-area filtering, explicit validity and arbitrary
contributor normalization into one transactional owned ROI.

Accept a precisely declared common registered extent and straight encoded-sRGB
RGBA8. Keep registration, reprojection, decoder storage, source policy evidence
and partial-footprint geometry with the caller. Reject unknown alpha association.
Filter in linear premultiplied space using color-d. Keep quality weights,
opacity and validity separate; infer neither NoData from black nor union coverage
from scalar relative weights.

Use callback-scoped tile borrows copied into four bounded LRU slots. Retaining
decoder leases would not establish a physical memory bound: a small raster view
may retain an entire backing, and raster-d does not publicly expose physical
resource byte accounting. Copying an explicitly bounded tile is the narrow,
auditable ownership boundary for this consumer. Do not introduce a parallel raw
raster descriptor or import raster-d internals to evade that boundary.

Bound work with tile/source limits, checked output/scratch budgets and tap/read
limits. Process 256-by-16 target blocks to reuse decoded rows before changing
sources. All coordinates are global to the full target, preserving independent
partition equivalence. Candidate owners and provenance remain private until
the final cancellation check. Keep the prior published frame intact on failure.

## Consequences

This gives #144 a qualified RGBA display integration without broadening the
existing scalar and feature-overview adapters. It does not change legacy
nearest-tile byte-preservation or two-RGB overlap semantics. Geometry/warp
sampling, HDR, arbitrary alpha/color encodings and real decoder/consumer
performance acceptance remain independent work. A bounded engine payload does
not imply bounded provider memory or a 60 fps guarantee.

The [contract and executable qualification](../multiresolution-mosaic.md)
define pixel cells, strict positive-tap NoData, conditional quality mixing,
threading, provenance, limits and failure classifications. Small trusted
boundaries only allocate/adopt checked malloc resources; affine pixel access
uses raster-d's validated scoped windows.
