# M1.3 — imagery-d / color-d Boundary

**Project:** `imagery-d`
**Milestone:** M1 — Image Semantic Core
**Status:** Research synthesis; no API or dependency freeze
**Date:** 2026-09-22

## Purpose

Define the consumer-side boundary between `imagery-d` and the independently
developed `color-d` project.

This document does not prescribe `color-d` implementation or API. It records
what `imagery-d` owns, what general colour mathematics belongs to `color-d`,
and when a future dependency or cross-repository issue would be justified.

## Verified current color-d direction

The current `color-d` repository already establishes that:

- `imagery-d` is an intended consumer;
- `color-d` is the workspace authority for general colour mathematics and
  colour-space semantics;
- encoded sRGB and linear-light sRGB are distinct;
- colour-space conversion is explicit;
- storage and computation representations are distinct;
- straight and premultiplied alpha are distinct concepts;
- compositing is a general mathematical concern;
- clipping and gamut mapping are explicit;
- extended/out-of-gamut computational values are preserved;
- image codecs, image I/O, raster tiling, caching, resizing, blur and
  convolution are not `color-d` responsibilities.

`color-d` is still in research/architecture phase and has no stable public API.

Its currently validated experimental conversion chain is:

    SRgb!T
        <->
    LinearSRgb!T
        <->
    XyzD65!T
        <->
    Oklab!T
        <->
    Oklch!T

Alpha/premultiplied-alpha types and compositing remain planned research rather
than a stable dependency surface.

## Boundary principle

The strongest current separation is:

    raster-d
        owns raster representation

    imagery-d
        owns how raster channels acquire image-domain meaning

    color-d
        owns general colour-value mathematics

Or operationally:

    raster samples
        |
        | imagery-d identifies and binds semantic channels
        v
    image colour components
        |
        | future color-d integration
        v
    typed colour values and colour mathematics

`imagery-d` describes **which data are colour and how those data belong to an
image**.

`color-d` defines **what mathematically correct operations on colour values
mean**.

## color-d responsibilities

Presumptive `color-d` responsibilities include:

- colour-space value types;
- encoded versus linear-light RGB semantics;
- explicit colour-space conversion;
- general gamut testing, clipping and mapping;
- straight versus premultiplied alpha value semantics;
- general compositing mathematics;
- general colour interpolation;
- perceptual colour operations;
- relative luminance, contrast and colour-difference mathematics.

Exact type and function names remain owned by `color-d`.

## imagery-d responsibilities

### Channel identity

`imagery-d` determines which raster planes/bands represent:

- red, green and blue;
- grayscale/luminance;
- alpha;
- spectral bands such as NIR/SWIR;
- depth;
- quality or classification data;
- arbitrary/custom channels.

### Channel-to-colour binding

An image may contain channels that are not colour components.

Therefore `imagery-d` owns the mapping from image channels to a colour tuple.

It must not assume that channels 0, 1 and 2 are RGB.

### Image colour-encoding metadata

`imagery-d` owns the statement that a selected image-channel tuple is encoded
or interpreted under a particular colour description.

This is not the same concept as one mathematical `color-d` colour value.

Conceptually:

    image metadata:
        channels [i, j, k]
        form one colour tuple
        encoded as / described by X

A future adapter may materialize those samples as `color-d` values.

### Alpha channel binding

`imagery-d` owns:

- which image channel is alpha;
- whether alpha is present;
- whether source data are straight or premultiplied;
- preservation of the source convention;
- distinction from masks and NoData.

`color-d` owns the mathematics of straight/premultiplied values and
compositing.

### Raster-region execution

When a colour transform is applied across:

- a `RasterView`;
- an ROI;
- streamed regions;
- bounded-memory processing;
- a large image;

the mathematical primitive may come from `color-d`, but raster iteration,
region/lifetime handling and image execution remain outside `color-d`.

### Metadata preservation

`imagery-d` may need to preserve colour metadata that `color-d` does not yet
interpret, for example:

- ICC profile data or identity;
- PNG cICP;
- chromaticities / white point;
- transfer-function metadata;
- codec-specific colour tags.

Preservation does not imply that `imagery-d` or `color-d` must perform the
associated transform.

## Colour encoding metadata != colour value

A mathematical value such as a future:

    SRgb!float

is not equivalent to an image declaring:

    these raster channels are encoded as sRGB

The former is value-level colour mathematics.

The latter is image-level semantic metadata over raster channels.

Therefore the first `imagery-d` image descriptor must not be defined merely by
embedding a `color-d` colour-value type.

## Alpha metadata != alpha mathematics

Likewise:

    alpha channel = 3
    association = straight

is image metadata.

A future `Alpha!Color` or `Premultiplied!Color` is a mathematical colour-value
representation.

`imagery-d` must be able to preserve the source state even while `color-d` has
no stable alpha wrapper.

## ICC and advanced colour management

Current `color-d` intentionally does not attempt to be a full colour-management
system and initially excludes ICC processing, CMYK workflows, device profiling,
rendering intents and complex display calibration.

Therefore:

    unsupported by current color-d
        !=
    discardable by imagery-d

`imagery-d` must be able to preserve relevant metadata even when no current
workspace library interprets it.

## HDR and extended values

`color-d` currently defers a complete HDR pipeline, but its validated
mathematical direction already avoids implicit clipping and preserves extended
floating-point values.

This is compatible with scene-linear imagery such as OpenEXR.

`imagery-d` must independently avoid treating 1.0 as a universal upper bound.

No new `color-d` requirement is needed at this stage merely to preserve
extended image values.

## Remote sensing

Remote-sensing bands are not inherently colour values.

Examples include:

- NIR;
- SWIR;
- thermal;
- atmospheric bands;
- classification;
- quality masks.

A false-colour presentation may map these to display RGB, but that mapping must
not mutate intrinsic band identity.

Thus:

    spectral-band semantics
        belong to imagery-d

    mathematical colour produced by a selected presentation mapping
        may use color-d

## Storage types

`color-d` research distinguishes packed storage candidates such as `SRgb8` /
`SRgba8` from floating-point computational colour types.

`raster-d` separately supports representation-safe POD raster samples.

Neither fact should force one physical image representation.

Both of the following can remain semantically valid candidates:

    RasterView!ubyte
        + separate logical R/G/B planes

and, if later justified:

    RasterView!SRgb8

The image-semantic contract must not depend on one of these storage choices.

## Dependency decision

Current state:

    imagery-d -> raster-d
        established

    imagery-d -> color-d
        architecturally permitted
        likely useful later
        not required for M1 semantics
        not admitted yet as a stable dependency

Reasons to defer:

1. `color-d` has no stable public API.
2. M1 can define image semantics without executing colour mathematics.
3. `imagery-d` must preserve metadata beyond current `color-d` scope.
4. premature coupling would bind two research-phase APIs.
5. `color-d` already plans concrete consumer integration before stabilization.

A dependency should be reconsidered when a concrete `imagery-d` operation needs
a sufficiently stable `color-d` capability.

## Current imagery-d consumer requirements

M1 currently expects an eventual general colour library to provide:

- explicit encoded versus linear-light sRGB;
- explicit conversions;
- preservation of extended computational values;
- straight versus premultiplied alpha;
- correct linear-light compositing;
- compact value types suitable for hot paths;
- allocation-free scalar operations;
- practical `float` support;
- deterministic semantics usable by region/batch execution.

Current `color-d` research already covers or explicitly plans these areas.

Therefore no new `color-d` issue is justified now.

## When to create a color-d issue

Open a cross-repository issue only when:

1. a concrete `imagery-d` consumer requires a general colour capability;
2. that capability conceptually belongs to `color-d`;
3. the current `color-d` roadmap/research does not already cover it;
4. the requirement can be stated as a consumer need rather than a prescribed
   implementation;
5. the issue links back to the originating `imagery-d` case.

Good form:

    imagery-d operation X requires semantic capability Y for reason Z

Avoid:

    color-d should implement exact type/function/API Q

unless `color-d` itself has already selected that API direction.

## Responsibility matrix

| Concern | raster-d | imagery-d | color-d |
|---|---|---|---|
| raster sample storage | owns | consumes | — |
| layout / strides / interleaving | owns | consumes | — |
| channel identity | — | owns | — |
| spectral-band identity | — | owns | — |
| stored -> physical scale/offset | — | owns | — |
| image NoData semantics | — | owns | — |
| validity meaning | generic mechanism possible | owns image meaning | — |
| identify alpha channel | — | owns | — |
| straight/premultiplied mathematics | — | preserves source state | owns |
| colour-component binding | — | owns | — |
| colour-space mathematical values | — | consumes later | owns |
| colour-space conversion | — | executes across raster later | owns math |
| compositing mathematics | — | image-region execution | owns math |
| ICC metadata preservation | — | owns/preserves | not initial scope |
| gamut mathematics | — | consumes | owns |
| ROI / streaming mechanics | owns | image orchestration | — |
| false-colour source-band mapping | — | owns | colour result only |

## M1.3 conclusion

No architecture conflict between `imagery-d` and current `color-d` direction
has been identified.

The current boundary is:

> `imagery-d` owns the semantic binding between raster channels and image colour
> meaning; `color-d` owns general colour mathematics once those channels are
> represented as colour values.

Also:

> `imagery-d` must preserve image colour metadata even when current `color-d`
> cannot interpret it.

And:

> M1 does not require an immediate `color-d` dependency.

The M1.3 GitHub issue can be considered research-complete once this document is
reviewed and committed. Future integration remains a separate implementation
decision driven by a concrete image operation.
