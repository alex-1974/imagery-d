# M5/M6 qualification receipt — 2026-11-08

## Toolchain

- DMD 2.111.0
- LDC 1.42.0
- raster-d 0.5.5
- color-d 0.3.0/0.3.3
- mir-algorithm 3.22.5 for the root package

## Results

| Gate | DMD | LDC |
| --- | --- | --- |
| imagery-d `no-io` unit tests | PASS — 97 modules | PASS — 97 modules |
| decoded RGBA8 tile mosaic | PASS — 70,272 component checks | PASS — 70,272 component checks |
| linear-light overlap blend | PASS — 43,008 oracle checks | PASS — 43,008 oracle checks |

The M5 consumers are deliberately independent of imagery-d I/O. They depend
directly on raster-d and color-d so workspace-local transport paths cannot
invalidate the pixel qualification.

M6 currently has deterministic primitive-level tests for Sobel output shape
and 4-connected component separation. Scientific accuracy, real corpus
coverage, performance budgets and ML adapter qualification remain open.
