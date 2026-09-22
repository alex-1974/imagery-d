# M1.5 ImageView Contract Experiment

## Status

Research spike only.

This experiment does **not** define the production `imagery-d` API.

It mechanically probes the provisional contract from:

`docs/research/m1-image-view-contract.md`

## Question

Can a small image-semantic wrapper safely compose:

- one lease-bound `RasterView!T`;
- borrowed immutable channel metadata;
- an optional lease-bound `RasterView!ubyte` validity sidecar;

while preserving all lifetime relationships through ROI?

## Dependency

The experiment uses the sibling workspace repository:

`../../../raster-d`

through DUB.

It therefore tests the actual current public `raster-d` lifetime boundary
rather than recreating it locally.

## Positive checks

The default configuration verifies:

- float primary raster + UInt8 validity raster;
- channel count validation;
- validity extent validation;
- sample access;
- validity access (`0 = invalid`, non-zero = valid);
- ROI of primary and validity together;
- semantic metadata sharing across ROI;
- an `@nogc` semantic ROI path;
- mask-free image construction.

## Compile-negative checks

Four DUB configurations must fail compilation under both DMD and LDC:

- `negative-primary-escape`
- `negative-metadata-escape`
- `negative-validity-escape`
- `negative-roi-escape`

They attempt to escape an `ImageView` beyond one of its borrowed lifetime
sources.

The negative probe functions are deliberately `@safe`. DIP1000 escape
rejection is tested as an `@safe` language guarantee, matching the established
`raster-d` lifetime probes.

A successful build of any negative configuration is a failed experiment.

## Run

From this experiment directory:

    ./tools/run.sh

or from the `imagery-d` repository root:

    experiments/m1_5_image_view_contract/tools/run.sh

The script requires both `dmd` and `ldc2`.

To run a selected compiler set:

    COMPILERS="dmd" ./tools/run.sh

## Interpretation

PASS requires:

1. positive runtime checks succeed;
2. DMD rejects every negative lifetime probe;
3. LDC rejects every negative lifetime probe.

Compiler errors from the negative configurations are expected evidence, not
test failures.

## Important limitations

This experiment does not yet decide:

- final public type names;
- final metadata ownership implementation;
- NoData representation;
- validity binding cardinality;
- multiple colour-binding representation;
- writable image API;
- image-product API;
- `color-d` integration.

The experiment is only a lifetime and common-grid composition gate.
