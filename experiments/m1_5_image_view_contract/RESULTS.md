# M1.5 ImageView Contract Results

## Status

PASS

Verified locally on 2026-09-22.

## Toolchains

- DMD 2.111.0
- LDC 1.41.0
- LDC frontend: DMD 2.111.0
- LLVM 19.1.7
- target: x86_64-pc-linux-gnu

## raster-d dependency

- commit: `a073b3ad6b541fcd8421ed304722feaa47e9083b`
- worktree during result recording: `clean`

The experiment uses the sibling `raster-d` repository through the DUB path
dependency declared in `dub.sdl`.

## Verification matrix

| Probe | DMD 2.111.0 | LDC 1.41.0 |
|---|---|---|
| positive runtime / ROI | PASS | PASS |
| primary lease escape | REJECTED | REJECTED |
| semantic metadata escape | REJECTED | REJECTED |
| validity lease escape | REJECTED | REJECTED |
| ROI transitive escape | REJECTED | REJECTED |

## Positive contract

The runtime probe confirmed that one experimental common-grid image view can
compose:

- one `RasterView!float` primary raster;
- borrowed immutable channel semantics;
- one optional `RasterView!ubyte` validity raster.

It also confirmed:

- channel-descriptor count validation;
- primary/validity extent validation;
- ordinary sample access;
- validity access with `0 = invalid` and non-zero = valid;
- one relative ROI applied to primary and validity together;
- semantic descriptor storage shared across ROI rather than copied;
- mask-free construction without a validity sidecar;
- an `@nogc` semantic ROI path.

## Lifetime contract

All four compile-negative probes were rejected by both compilers under
`-preview=dip1000` and `@safe`.

The rejected cases attempted to return an image or ROI beyond the lifetime of:

1. the local primary `RasterLease`;
2. local semantic metadata;
3. the local validity `RasterLease`;
4. the corresponding transitive ROI borrow.

This establishes that the experimental wrapper preserves the lifetime
relationships inherited from `raster-d`.

## Important test-harness finding

The first version of the compile-negative probes omitted `@safe`.

In that form the primary-escape probe compiled successfully.

This was not evidence that the ImageView lifetime model was unsafe. DIP1000
escape rejection is being tested as an `@safe` language guarantee, matching the
established `raster-d` lifetime probes.

After the negative functions were correctly marked `@safe`, DMD and LDC both
rejected all four escape cases.

The requirement that lifetime compile-negative probes execute inside `@safe`
code is therefore part of the retained research methodology.

## ROI geometry correction

The first positive runtime probe used an ROI origin inconsistent with the
sample coordinate asserted by the test.

The ROI was corrected from `(1,1,2,2)` to `(2,1,2,2)`, making parent sample
`(3,2)` correctly correspond to ROI-local sample `(1,1)`.

This was a test-fixture error and did not change the semantic contract.

## M1.5 result

The experiment supports the provisional contract:

    ImageView!T
        =
    one common-grid RasterView!T
        +
    borrowed immutable image semantics
        +
    optional same-grid RasterView!ubyte validity

The experiment provides evidence that this composition can preserve primary,
metadata and validity lifetimes transitively through ROI without introducing a
second raster ownership system.

## Still not decided

PASS does not freeze:

- final public type names;
- final semantic metadata owner;
- final NoData representation;
- validity-binding cardinality;
- colour-binding cardinality;
- writable image API;
- heterogeneous image-product representation;
- `color-d` integration.

Those remain later architecture decisions.
