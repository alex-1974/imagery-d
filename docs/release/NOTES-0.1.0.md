# imagery-d v0.1.0 — First release

The first pre-1.0 release of **imagery-d**, a general-purpose image
processing library for the D programming language. This is a small
usable starting point, **not** a feature-complete image editor or a
v1.0 stability promise.

## Included

- **Scalar Levels** for already decoded `raster-d` views with
  `ubyte`, `ushort` or `float` samples.
- Per-channel selection, explicit ROI and optional 8-bit weighted
  editing mask; no implicit sRGB/ICC conversion or alpha policy.
- A fresh **ROI-local, interleaved owned `RasterLease!float`** result,
  with explicit byte budget for the *new pixel payload*.
- Two callable `@safe` `tryLevelsOwned` overloads; predictable normal
  returned-error behavior and retained prior output on failure.
- Ddoc and a [consumer tutorial](docs/tutorial/levels.md).

The package is MIT-licensed and depends on `raster-d ~>0.2.0`.

## Compatibility

**Supported:** Linux x86-64; tested on Ubuntu 24.04 with
DMD 2.111.0/2.113.0 and LDC 1.41.0/1.43.0.

**Best effort:** macOS 15 and Windows 2025 passed ordinary DMD/LDC
consumer canaries; the full release matrix was not required there.

**Pre-1.0:** Source API may evolve in future 0.x minor versions;
no stable ABI, universal numerical ULP bound, process RSS cap,
image decoding, file-writing or automatic colour-management guarantee.

## Basic use

```d
import imagery : Levels, LevelsError, tryLevelsOwned;
import raster : RasterLease, RasterView, Region2D;

@safe LevelsError applyLevels(
    scope RasterView!ubyte image,
    ref RasterLease!float result,
    size_t maxResultBytes)
{
    bool[3] channels = [true, true, false];
    return tryLevelsOwned!ubyte(
        image,
        Region2D(0, 0, image.width, image.height),
        channels[],
        Levels(0, 1, 2, 0, 1),
        maxResultBytes,
        result);
}
```

Only `LevelsError.none` means success. The result owner is retained
on ordinary returned errors. The budget covers only the new float pixel
payload; a runtime OOM `Error` is not guaranteed recoverable.

## Installation

Source: https://github.com/alex-1974/imagery-d

After the repository has been **registered by its maintainer** at
https://code.dlang.org/, the registry discovers SemVer tags.
Then DUB consumers can depend on `imagery-d ~>0.1.0`.

Registration and automatic registry indexing are separate from creating
this GitHub Release. Do not treat the registry as live until the
published `imagery-d@0.1.0` can actually be fetched and consumed.

## Qualification

On the last reviewed `develop` commit before release promotion,
DMD/LDC package tests, positive/negative API contracts, ordinary and
out-of-tree source-archive DUB consumers, 624-sample independent
90-digit Decimal oracle, P6 end-to-end image consumer and rendered
DDox checks passed. Linux compiler floor and clean
`raster-d@0.2.0` registry-resolution tests passed. Performance
qualification was bounded to the demonstrated gamma-2 path.

Release publication requires checks on the **exact release PR head**
and actual tagged main commit. No new research or C++ parity benchmark
is necessary for this first 0.1.0 release.
