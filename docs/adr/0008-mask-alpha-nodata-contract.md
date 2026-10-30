# ADR 0008: Mask, alpha and NoData contract for image operations

**Status:** Accepted for M3 qualification; not an API freeze  
**Date:** 2026-10-30

## Context

Photoshop and GIMP make local, non-destructive editing a primary workflow.
Dunia additionally needs validity and NoData handling for satellite imagery
and orthophotos. Existing Levels qualification already proves a caller-owned
8-bit graded selection mask and transactional owned output, but those rules
must be explicit before they are reused by other operations.

## Decision

1. A selection mask is an image-domain input, not an inferred property. A
   single-plane `ubyte` mask has coverage `0..255`; zero means unchanged or
   excluded, 255 means fully affected, and intermediate values linearly blend
   the operation result with the original value.
2. A validity/NoData mask is distinct from a selection mask. Validity controls
   whether a sample participates; selection controls operation strength. An
   operation must never reinterpret a source quality/classification raster
   without an explicit consumer policy.
3. Alpha is a channel with declared association. Operations preserve alpha by
   default; an operation may modify alpha only when its contract explicitly
   says so. Straight and premultiplied alpha are not interchangeable.
4. Numeric and colour-domain semantics are explicit per operation. No implicit
   sRGB decoding, colour conversion, NoData sentinel or alpha association is
   allowed.
5. Inputs must be equal-grid for pixelwise operations. Registration,
   reprojection and grid construction belong to the consumer/source adapter.
6. ROI operations must define outside-ROI behaviour. The preferred owned-result
   form publishes only after complete success; returned failure leaves the
   previous owner unchanged.
7. Whole-image and partitioned execution must be equivalent within the
   operation's documented numeric tolerance. Masks and validity fields are
   partitioned with the same logical coordinates.

## Consequences

The next M3 operations can share one semantic preflight vocabulary while
remaining layout-neutral over `raster-d`. Dunia constructs validity and quality
policies; imagery-d consumes explicit masks. A future public image/layer type
must carry alpha association and validity semantics rather than hide them in a
pixel-format enum.

This ADR does not admit file I/O, CRS transforms, scheduling, quality ranking,
cloud inference or a general layer graph.

## Qualification requirements

- binary and graded selection masks;
- validity/NoData exclusion and all-invalid regions;
- straight and premultiplied alpha cases where applicable;
- planar/interleaved layouts and signed strides;
- invalid shape/grid/ROI preflight with destination preservation;
- whole-versus-partition exactness or documented tolerance;
- DMD and LDC Debug/Release plus an independent consumer.
