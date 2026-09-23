# M2.5 — Product-to-Typed-ImageView Materialization

**Project:** `imagery-d`
**Milestone:** `M2 — Source / Cache / Pipeline Architecture`
**Issue:** `M2.5 — Define product-to-typed-ImageView materialization`
**Status:** Research draft — not a public API
**Date:** 2026-09-23

## 1. Purpose

M2.5 defines the explicit bridge from a heterogeneous imagery product to one
typed, common-grid `ImageView!T`.

The core question is:

> Given one product with several components, resources, native sample types,
> grids, resolutions, masks and radiometric conventions, how does imagery-d
> decide whether a requested `ImageView!T` can be produced directly, requires
> explicit transformation, or must be rejected?

M2.5 must preserve the accepted M1 invariant:

    ImageView!T
        =
    one common-grid RasterView!T
        +
    immutable image semantics
        +
    optional same-grid RasterView!ubyte validity

No spelling in this document is a frozen public D API.

## 2. Inputs from M1

M1 established that a processing image is intentionally narrower than an
imagery product.

An imagery product may contain multiple assets/resources, multiple
components/bands, different native sample types, different native grids and
resolutions, masks and quality layers, derived representations, and arbitrary
channel meanings.

An `ImageView!T` instead requires one common logical 2D grid, one materialized
sample type `T`, one ordered set of image channels, immutable image
interpretation and optional same-grid `ubyte` validity.

Therefore:

> product discovery and processing-image construction are separate phases.

## 3. Inputs from M2.1–M2.4

M2.1 separates Source identity, Resource identity, Locator and Revision.

M2.2 defines direct native-grid materialization into retained raster storage
owned by `RasterLease!T`, and rejects implicit conversion/resampling.

M2.3 requires decoded and transformed cache keys to include every semantic
choice that can change pixels.

M2.4 requires production keys to identify semantic results independently from
request priority, viewport generation or subscriber state.

M2.5 defines the missing semantic dimensions.

# Part I — Reference Evidence

## 4. OpenEXR

OpenEXR is a strong counterexample to the idea that one file automatically
means one homogeneous image.

A file may contain arbitrary channel names, per-channel sample types (`HALF`,
`FLOAT`, `UINT`), per-channel x/y sampling rates, multipart images, parts with
different data windows, and regular/deep data.

Therefore one selected group of OpenEXR channels may fail the M1 common-grid or
common-`T` invariant even though all channels are physically stored in one file.

Architectural lesson:

> file membership is not sufficient evidence for direct `ImageView!T`
> compatibility.

## 5. Sentinel-2

Sentinel-2 MSI has 13 spectral bands with native spatial resolutions of 10 m,
20 m and 60 m.

The official product specification assigns four bands to 10 m, six bands to
20 m and three bands to 60 m.

Level-2A products additionally expose resampled representations at several
product resolutions and quality layers such as Scene Classification.

Architectural lesson:

> product-level semantic relationship does not imply common native grid.

A true-colour selection of B2/B3/B4 can be direct at 10 m.

A selection such as B4/B8A/B11 cannot become one common-grid image without an
explicit target-grid and resampling decision.

## 6. xarray

`xarray.Dataset` permits variables with different dtypes and even different
dimensions, while variables using the same named dimension share that
coordinate system.

This is useful conceptual evidence:

    heterogeneous Dataset
        !=
    one homogeneous array

Converting a dataset-like structure into one stacked/common array requires
additional compatibility/alignment decisions.

That is close to the M1 Product -> Image distinction.

## 7. STAC Raster metadata

The STAC Raster extension records raster semantics such as point/area sampling,
bits per sample, spatial resolution, scale, offset and NoData.

This reinforces a core M1/M2.5 distinction:

    encoded/stored samples
        !=
    physical/radiometric values

Applying scale and offset is a semantic transformation, not just metadata
copying.

## 8. GDAL RasterIO

GDAL can perform spatial window selection, sample-type conversion and resampling
within one read call.

This is convenient, but it creates a design hazard.

`imagery-d` must not infer from one backend API that those semantic decisions
are one operation.

M2.5 keeps them explicit even when one adapter can fuse execution.

# Part II — Materialization Target

## 9. A typed image target is explicit

A future product-to-image request needs an explicit target contract.

Conceptually it includes:

    selected product components
    component order
    target logical grid
    target materialized sample type T
    radiometric domain/policy
    validity policy
    explicit resampling policy where required
    explicit conversion policy where required
    image semantic binding

No exact type is frozen.

## 10. Component selection

Component selection identifies which semantic product members will become
processing-image channels or validity inputs.

Selection should be based on stable product semantics/IDs, not merely physical
file position.

Examples include B02/B03/B04, red/green/blue, or custom scientific channels.

## 11. Component order

Order matters for one `ImageView!T`.

These are different image contracts:

    [B04, B03, B02]
    [B02, B03, B04]

even if they refer to the same upstream components.

Therefore ordered component identity participates in materialization/cache key
semantics.

## 12. Target grid

A typed ImageView needs one target grid.

The target grid conceptually includes enough identity to answer pixel
dimensions, logical extent, sampling geometry, resolution, alignment/origin,
and coordinate/grid identity supplied by the higher geospatial/product model.

M2.5 does not define CRS or geodesy APIs.

It only requires an unambiguous grid identity for compatibility and cache keys.

## 13. Target sample type

All primary planes in `ImageView!T` use the same materialized D sample type `T`.

Therefore selected source components with differing native types require one
of:

    explicit conversion
    compatible direct decode to common T
    rejection

No implicit "best" common type is selected by the core.

## 14. Radiometric domain

A target should distinguish at least conceptually:

    stored/raw domain
    physical/scaled domain

Example:

    stored:
        uint16 DN

    physical:
        reflectance = scale * DN + offset

Applying scale/offset changes values and often changes appropriate sample type.

This choice is materialization semantics.

## 15. Presentation is separate

False colour, tone mapping, gamma, histogram stretch and display rendering are
not automatically part of product-to-processing-image materialization.

A product component's intrinsic identity remains unchanged when later bound to
a display colour role.

# Part III — Compatibility Analysis

## 16. Compatibility analysis precedes execution

Before source access or large allocation, M2.5 should classify the selected
components against the requested typed image target.

Conceptually:

    selection
        ->
    inspect component descriptors
        ->
    compatibility analysis
        ->
    direct or explicit transform plan
        ->
    materialization

This prevents backend convenience from silently deciding semantics.

## 17. Compatibility classes

A useful initial classification is:

    direct
    type-conversion-required
    grid-transform-required
    type-and-grid-transform-required
    semantic-normalization-required
    unsupported

The exact enum/type remains open.

## 18. Direct compatibility

Direct materialization is possible when all selected primary components already
agree on target grid, extent/alignment, target sample type or exact decoder
output contract, channel sampling, requested radiometric domain and relevant
interpretation.

No resampling or sample conversion is required.

## 19. Type-only incompatibility

Example:

    channel A native uint16
    channel B native float32
    target ImageView!float

Grid is already common.

Result:

    explicit type conversion required

The caller/materialization policy must authorize the conversion.

## 20. Grid-only incompatibility

Example:

    Sentinel-2 B04: 10 m
    Sentinel-2 B8A: 20 m
    target T already compatible

Result:

    explicit target grid selection
    +
    explicit resampling policy

No automatic "highest resolution wins" rule.

## 21. Type and grid incompatibility

Example:

    component A: uint16 at grid A
    component B: float32 at grid B
    target: float at grid C

Result:

    explicit conversion
    +
    explicit grid transform

Execution may fuse these operations, but the semantic plan keeps them separate.

## 22. Semantic-normalization incompatibility

A component can be spatially and numerically compatible but still require a
semantic mapping.

Example:

    categorical Scene Classification Layer
        ->
    binary validity mask

This is not merely sample conversion.

It needs an explicit class-to-validity policy.

## 23. Unsupported compatibility

Examples include deep OpenEXR channel structure when flat `ImageView!T` is
requested, variable-length per-pixel samples, unknown grid relation with no
authorized transformation, required categorical mapping unavailable, or
unsupported component semantics.

Failure should identify the incompatible dimension rather than reporting a
generic decode error.

# Part IV — Grid Compatibility

## 24. Grid equality must be semantic

Equal width/height alone does not prove grid compatibility.

Two rasters can have identical dimensions but different resolution, origin,
alignment, sampling convention or geographic placement.

M2.5 requires semantic grid identity/equality supplied by the product/grid
layer.

## 25. Point versus area sampling

STAC Raster explicitly distinguishes point and area sampling.

That distinction can matter during resampling and alignment.

M2.5 should not silently treat both as identical grids merely because pixel
centres appear similar.

## 26. Native grid selection

If all selected components share one native grid, that grid is the natural
direct target.

This should require no resampling.

## 27. Mixed native grids

When selected components use different native grids, a target must be selected
explicitly.

Possible target sources include one selected component's native grid, a
product-supplied standardized/resampled grid, or an explicitly caller-supplied
target grid.

The core must not choose based solely on finest resolution.

## 28. Provider-resampled representations

Some products expose multiple already-resampled versions.

Sentinel-2 Level-2A is representative.

These are distinct product/resource representations with their own provenance.

Using a provider-resampled 20 m or 60 m representation is not the same
operation as locally resampling the original native representation, even if the
nominal target resolution matches.

Therefore representation choice is part of upstream snapshot/materialization
identity.

## 29. Source footprint for resampling

Cross-grid output region R on target grid does not usually map to an equal
integer source region.

The transform must derive:

    target output region
        ->
    mathematical source footprint
        ->
    resampling-kernel support / halo
        ->
    valid source input region
        ->
    M2.2 materialization

This is operation dependency.

It remains separate from source/provider tile geometry.

## 30. Resampling kernel participates in semantics

Different resamplers can produce different pixels.

Examples:

    nearest
    bilinear
    cubic
    Lanczos
    area/average
    mode

Therefore the resampler participates in production key, transformed cache key
and provenance.

## 31. Component semantics constrain resampling

A generic "one resampler for every channel" rule is unsafe.

Continuous reflectance may support bilinear/cubic/area-like policies.

Categorical classification generally needs nearest/mode-like semantics rather
than numeric interpolation.

Binary validity may need conservative semantic rules.

Alpha may interact with alpha association and colour-space assumptions.

Therefore resampling policy can be component-role aware.

## 32. One ImageView requires common final grid

Whatever source-specific transformations are used, final primary channels must
share one exact processing grid before `ImageView!T` publication.

Validity must also share that final grid.

# Part V — Sample-Type Conversion

## 33. Conversion is explicit

A target `T` must not be inferred silently from heterogeneous inputs.

A request may state:

    target T = float

and authorize specific conversions.

## 34. Conversion categories

Potential distinctions include:

    exact widening
    narrowing
    signedness change
    integer -> float
    float -> integer
    quantizing conversion
    saturating/clamping conversion

M2.5 does not yet freeze an enum.

Not all conversions have equal correctness implications.

## 35. Widening does not remove semantic choice

Even a mathematically lossless widening still changes memory cost and cache
identity.

Target type remains part of the explicit materialization contract.

## 36. Narrowing

Narrowing requires explicit overflow/rounding policy.

Never rely on backend language/library default casts as the stable image
contract.

## 37. Floating-point conversion

Integer DN -> float is common.

But conversion alone does not imply scale/offset application.

These remain distinct:

    uint16 DN -> float(DN)

versus:

    uint16 DN -> float physical reflectance

## 38. Physical-value materialization

If scale/offset is explicitly applied:

    physical = stored * scale + offset

the output sample domain changes.

For many remote-sensing products a floating-point target becomes natural.

The exact target type remains caller/policy choice.

## 39. No implicit clipping/normalization

Applying physical scale/offset must not silently add clamp-to-0..1, histogram
stretch, gamma or min/max normalization.

Those are separate operations/presentation decisions.

# Part VI — NoData, Missing Data and Validity

## 40. NoData metadata is not validity by itself

M1 distinguishes:

    alpha
    validity
    NoData metadata

M2.5 preserves that distinction.

A NoData marker may inform validity generation, but does not automatically mean
a `RasterView!ubyte` validity plane must be materialized.

## 41. Validity policies

Conceptually a materialization request may choose:

    preserve NoData metadata only
    generate validity from NoData
    use explicit mask component
    derive validity from quality/classification mapping
    combine several validity sources

Each policy can change output semantics.

Therefore it participates in materialization identity.

## 42. Explicit mask component

If a product provides a binary mask already on the target grid, it can be a
direct validity source after explicit semantic confirmation.

A mask being present does not automatically mean it expresses validity.

It may instead mean cloud, saturation, water, user mask or classification.

## 43. Classification-to-validity mapping

Example:

    Sentinel-2 Scene Classification
        classes:
            vegetation
            water
            cloud
            cloud shadow
            snow
            ...

A processing request may decide which classes count as valid.

That mapping is explicit policy.

Different mappings produce different validity images and therefore different
production/cache identities.

## 44. Validity resampling

When validity/mask input uses another grid, its grid transform needs
validity-specific semantics.

A naïve bilinear interpolation of validity bytes is generally meaningless.

## 45. Validity combination

If several masks contribute, the combination operator is semantic.

M2.5 should not invent one universal implicit rule.

# Part VII — OpenEXR Pressure Cases

## 46. Same-grid same-type channels

OpenEXR channels:

    R HALF sampling 1x1
    G HALF sampling 1x1
    B HALF sampling 1x1

Target:

    ImageView!half

Result:

**DIRECT COMPATIBILITY** if data window/grid are common.

## 47. Different channel sample types

OpenEXR channels:

    color HALF
    depth FLOAT

Target:

    one ImageView!float

Result:

**TYPE CONVERSION REQUIRED** for HALF color channels if selected together.

Alternatively materialize separate typed images.

## 48. Subsampled channels

OpenEXR luminance/chroma can use different x/y sampling rates.

Target:

    common-grid multi-channel ImageView

Result:

**GRID TRANSFORM / UPSAMPLING REQUIRED** for subsampled channels.

Same file does not make this direct.

## 49. Multipart different data windows

Parts may have different data windows/layouts.

Result:

**NOT DIRECTLY COMMON-GRID** until target grid/coverage relation is explicitly
defined.

## 50. Deep data

Deep OpenEXR stores variable-length samples per pixel.

Result:

**UNSUPPORTED by ordinary flat ImageView!T** unless a separate flattening
operation is explicitly defined.

This is representation incompatibility, not a decode failure.

# Part VIII — Sentinel-2 Pressure Cases

## 51. True-colour 10 m

Selection:

    B04
    B03
    B02

All native 10 m.

Assuming aligned product grids:

Result:

**DIRECT GRID COMPATIBILITY.**

Sample/radiometric policy still determines raw versus physical values and `T`.

## 52. Red-edge composite

Selection:

    B05
    B06
    B07

All native 20 m.

Result:

**DIRECT GRID COMPATIBILITY.**

## 53. Mixed 10 m / 20 m

Selection:

    B04 10 m
    B8A 20 m
    B11 20 m

Target:

    10 m

Result:

**EXPLICIT RESAMPLING REQUIRED** for 20 m components.

Target 20 m would instead require resampling B04 or choosing a provider-supplied
20 m representation if available.

Those strategies have different provenance.

## 54. Mixed 10 m / 60 m

Selection includes B02 and B09.

Result:

**EXPLICIT TARGET GRID REQUIRED.**

No automatic finest/coarsest choice.

## 55. Scene Classification as validity

Primary:

    10 m spectral bands

SCL:

    source classification grid at another resolution

Result:

**SEMANTIC NORMALIZATION + GRID TRANSFORM REQUIRED.**

The class mapping and validity resampler are explicit.

## 56. Provider-resampled Level-2A assets

If the product already includes bands resampled to a common 20 m or 60 m
product grid, those can become a direct materialization source.

But the upstream Resource/representation identity differs from locally
resampling a higher-resolution source.

Cache/provenance identity must preserve that distinction.

## 57. Radiometric offset

Sentinel-2 products can require band-dependent offsets/scales to obtain physical
values.

Raw-DN `ImageView!ushort` and physical-reflectance `ImageView!float` are
different materializations.

They must not share a transformed cache key.

# Part IX — Heterogeneous Snapshot Identity

## 58. One output may depend on many Resources

A typed image can combine channels from:

    Resource A revision a
    Resource B revision b
    Resource C revision c

Therefore one materialization cannot always be identified by one Resource
revision.

## 59. Composite upstream snapshot

M2.5 needs a conceptual immutable dependency snapshot:

    Product/Source identity
    selected component identities
    selected concrete Resource representations
    each Resource revision
    selected grid/level
    relevant source interpretation

The exact representation remains open.

## 60. Snapshot ordering

For an ordered multi-channel image, component/dependency ordering matters.

A canonical composite snapshot should preserve ordered selected component
identities or another deterministic mapping from channel index to upstream
component.

## 61. Cross-resource consistency

Some products provide a product version/acquisition identity establishing which
Resources belong together.

Where available, materialization should retain that product snapshot identity.

## 62. No global atomic snapshot assumption

Independent files/services may not support atomic cross-resource versioning.

M2.5 therefore distinguishes:

### Per-resource coherence

Every Resource used in one materialization is internally revision-consistent.

### Product-level coherence

All selected Resources are known to belong to one coherent product snapshot.

The second cannot always be guaranteed.

If unavailable, that limitation should be represented rather than invented.

## 63. Revision change during multi-resource work

If Resource B changes while A/B/C are being materialized, B's attempt must not
silently mix revisions.

The materialization may fail/retry and re-resolve the desired composite
snapshot.

Whether unchanged A/C work can be reused depends on cache identity and policy.

# Part X — Planning Pipeline

## 64. Product-to-image planning stages

M2.6 introduces an explicit three-level planning distinction:

    TargetImageContract!T
        = what result the caller requests

    ResolvedMaterializationPlan
        = which concrete product snapshot and semantic transformations define
          that result

    ExecutionPlan
        = how the current machine/backend/cache produces that result now

A useful conceptual pipeline is:

    product
      |
      v
    select semantic components
      |
      v
    inspect candidate representations/resources
      |
      v
    choose explicit TargetImageContract!T
      |
      v
    resolve concrete representations + Resource revisions
      |
      v
    compatibility analysis
      |
      v
    ResolvedMaterializationPlan
        - ordered selected components
        - composite upstream snapshot
        - target grid and T
        - radiometric semantics
        - conversion semantics
        - resampling semantics
        - validity semantics
        - per-source logical dependencies
      |
      v
    semantic production/cache key
      |
      v
    ExecutionPlan
        - cache-hit strategy
        - fused/unfused backend path
        - source/cache block choices
        - task decomposition
        - memory admission
      |
      v
    M2.2 native materializations
      |
      v
    explicit/fused deterministic transforms
      |
      v
    bind common image semantics
      |
      v
    publish retained typed ImageView!T owner

The resolved semantic plan, not the execution strategy, defines result identity.

## 65. Planning before expensive work

As much compatibility analysis as possible should happen before downloading
large Resources, allocating output buffers or decoding full imagery.

Product/resource metadata can often reveal native dtype, shape, resolution,
channel sampling, scale/offset, NoData, masks and grid mismatch.

This enables early controlled failure.

## 66. Metadata can be incomplete

Some formats require opening/probing before exact compatibility is known.

Therefore semantic resolution can be staged:

    TargetImageContract
        ->
    descriptor-level candidate resolution
        ->
    probe/open
        ->
    ResolvedMaterializationPlan

The semantic target remains unchanged.

Only after the resolved plan is known should the complete transformed
ProductionKey be considered final.

# Part XI — Direct Versus Transform Materialization

## 67. Direct path

A direct path means selected components already share target grid, selected
components can produce target `T` without semantic conversion, requested
radiometric domain matches stored/decoded values, and validity is already
compatible or omitted.

Execution can still involve decompression, source block assembly and cache
reuse.

"Direct" does not mean zero work.

## 68. Transform path

A transform path includes one or more explicit steps:

    type conversion
    scale/offset
    resampling
    mask/classification normalization
    validity combination

These steps must be represented in the materialization contract even when fused
by an optimized backend.

## 69. Fusion

Execution may fuse decode, conversion, scale/offset and resampling into one
efficient backend call.

That is an optimization.

The semantic plan still records every transformation.

## 70. No backend-defined hidden policy

A backend default resampler, default alpha handling or default NoData behavior
must not silently become imagery-d semantics.

# Part XII — Cache and Production Keys

## 71. Native decoded cache remains below target transforms

M2.3 decoded native cache can reuse source-native pixels independently from many
different target requests.

Therefore M2.5 should avoid placing target-grid or target-radiometric parameters
into the native decoded key unless they actually affect native decode.

## 72. Transform/materialization key

A transformed/materialized production key conceptually includes:

    ordered component selection
    composite upstream snapshot
    target grid identity
    target logical coverage
    target sample type T
    radiometric domain / scale-offset policy
    conversion policy
    resampling policy per semantic class/component
    validity-generation policy
    validity-combination policy
    transform implementation/semantic version where needed

This is the strongest current key direction.

## 73. Component ordering in keys

Because channel order changes the meaning of the final image, it must be
included canonically.

## 74. Grid identity in keys

Nominal resolution alone is insufficient.

A target grid key needs enough identity to distinguish different alignments and
coordinate systems.

## 75. Coverage in keys

Transformed results for different logical target regions contain different
pixels and therefore need distinct/canonical coverage identity.

## 76. Conversion policy in keys

If two policies produce identical mathematical values, they may eventually
canonicalize to one semantic identity.

Until proven, explicit policies that can alter values remain part of the key.

## 77. Validity policy in keys

The primary pixel backing could potentially be shared while validity differs.

Therefore a complete materialized-image key may be separable into:

    primary transformed pixel identity
    +
    validity identity
    +
    semantic binding identity

This can improve reuse.

M2.5 does not freeze the decomposition yet.

# Part XIII — Production Lifecycle Interaction

## 78. Product planning occurs before exact production key

A request for an abstract product selection may not yet know the concrete
Resource representations/revisions.

Therefore M2.4 lifecycle conceptually has:

    request intent / TargetImageContract
        ->
    resolve product/source snapshot
        ->
    ResolvedMaterializationPlan
        ->
    final semantic production key
        ->
    cache/in-flight lookup
        ->
    ExecutionPlan

This refines where the key becomes fully known.

Execution details such as cache hit, GDAL fusion, temporary buffers or task
partitioning do not enter the semantic production key when they are guaranteed
to satisfy the same resolved plan.

## 79. Coalescing after resolution

Two abstract requests may resolve to the same final production key.

They should then join one shared production.

## 80. Priority remains outside key

Even though M2.5 adds many semantic dimensions, M2.4 remains valid:

    priority
    viewport generation
    requester identity

do not enter pixel production key.

## 81. Progressive stages

A lower-resolution stage and a native-resolution final image have different
target grids, so they naturally have different M2.5 production keys.

M2.4 can group them as stages of one subscriber refinement sequence.

# Part XIV — Provenance

## 82. Materialization provenance

A final typed image should be traceable to product identity, selected semantic
components, selected concrete source representations, Resource revisions,
target grid, target type, applied scale/offset, resampling policy, validity
derivation and significant transform versions.

Not all provenance belongs inside `ImageView!T`.

A materialization owner/snapshot can retain broader provenance.

## 83. Provenance is not presentation metadata

Rendering choices such as transient contrast stretch need not contaminate core
scientific materialization provenance unless they actually produced cached
derived pixels.

# Part XV — Failure Model

## 84. Compatibility failures

M2.5 should distinguish at least conceptually:

    component not found
    ambiguous component
    incompatible grid
    target grid unspecified
    conversion required but not authorized
    lossy conversion disallowed
    resampling required but not authorized
    no valid resampler for component semantics
    unsupported representation
    invalid validity mapping
    source snapshot incoherent
    transform not representable

These are planning/materialization failures, not generic I/O errors.

## 85. Early failure

Whenever incompatibility can be known from product descriptors, fail before
source decode.

## 86. Runtime failure

Runtime decode/access/allocation failure remains layered underneath the accepted
plan.

Do not reinterpret runtime transport failure as compatibility failure.

# Part XVI — Pressure Cases

## 87. P1 — homogeneous RGB TIFF

One Resource, three uint8 bands, one grid.

Target:

    ImageView!ubyte [R,G,B]

Result:

**DIRECT.**

## 88. P2 — planar float RGB

One Resource, three float planes, one grid.

Result:

**DIRECT** regardless of planar/interleaved physical layout.

raster-d hides layout.

## 89. P3 — OpenEXR HALF RGB + FLOAT Z

Target selects only RGB to `ImageView!half`.

Result:

**DIRECT** for RGB if grid/sampling compatible.

Z remains an unselected product component.

## 90. P4 — OpenEXR RGB + Z in one float image

Target selects R/G/B/Z to `ImageView!float`.

Result:

**EXPLICIT TYPE CONVERSION** for HALF channels.

## 91. P5 — OpenEXR subsampled chroma

Target requests Y/RY/BY common-grid image.

Result:

**GRID TRANSFORM REQUIRED** for subsampled channels.

## 92. P6 — Sentinel-2 10 m RGB

B04/B03/B02.

Result:

**DIRECT GRID**, subject to target radiometric domain/type.

## 93. P7 — Sentinel-2 mixed-resolution composite

B04/B8A/B11.

Result:

**TARGET GRID + RESAMPLING REQUIRED.**

## 94. P8 — raw DN versus physical reflectance

Same Sentinel-2 channels and grid.

Target A:

    ushort raw DN

Target B:

    float physical reflectance

Result:

**DIFFERENT MATERIALIZATION KEYS.**

## 95. P9 — classification to validity

SCL classes mapped to valid/invalid.

Result:

**SEMANTIC NORMALIZATION REQUIRED.**

Mapping participates in key/provenance.

## 96. P10 — mask grid mismatch

Primary 10 m, cloud mask 20 m.

Result:

**EXPLICIT MASK GRID TRANSFORM REQUIRED.**

## 97. P11 — provider-resampled versus local resample

Provider exposes a 20 m version of B04.

Option A:

    use provider 20 m Resource

Option B:

    use native 10 m Resource + local resampler to 20 m

Result:

Both may satisfy the same nominal target grid, but they have **different
upstream provenance and potentially different pixels**.

They must not be assumed cache-equivalent.

## 98. P12 — same size, shifted grid

Two components each 1000 x 1000 but origin/alignment differs by half a pixel.

Result:

**NOT DIRECTLY COMPATIBLE.**

Shape equality is insufficient.

## 99. P13 — two categorical layers

Both same grid/type.

Target wants them as ordinary channels.

Result:

**DIRECT** if ImageView semantics permit custom categorical channels.

No validity conversion is implied.

## 100. P14 — deep EXR

Result:

**UNSUPPORTED for flat ImageView!T** absent an explicit flattening operation.

## 101. P15 — xarray-like heterogeneous product

Variables differ in dtype/dimensions.

Result:

**PRODUCT MODEL FITS; typed ImageView requires explicit selection/alignment/
conversion.**

No pressure to make ImageView itself heterogeneous.

# Part XVII — Responsibility Boundary

## 102. Product layer owns

- semantic component inventory;
- Resource/representation alternatives;
- native grid descriptors;
- native dtype/encoding descriptors;
- scale/offset/NoData metadata;
- component roles;
- product provenance.

## 103. M2.5 planner owns

- ordered component selection;
- target grid selection;
- target `T`;
- compatibility classification;
- explicit conversion plan;
- explicit resampling plan;
- explicit radiometric-domain plan;
- validity derivation/combination plan;
- composite upstream snapshot;
- final transform/materialization identity.

## 104. M2.2 owns

- materializing already-selected source-native logical regions;
- retained raster construction;
- source/revision coherent decode;
- logical-to-resident coverage mapping.

## 105. raster-d owns

- resident raster ownership;
- plane layout;
- RasterLease;
- RasterView;
- ROI;
- generic raster operations;
- generic dependency mechanics if later promoted.

## 106. M2.3 owns

- cache lookup/storage;
- native decoded reuse;
- transformed-result reuse;
- cache budgets/eviction.

## 107. M2.4 owns

- shared in-flight production;
- priority;
- cancellation;
- prefetch;
- admission/backpressure;
- progressive delivery lifecycle.

# Part XVIII — Candidate Invariants

## 108. M2.5 invariants

1. Product heterogeneity is normal and must remain representable.
2. A product is not forced into one common dtype/grid merely for convenience.
3. `ImageView!T` remains homogeneous in sample type and common grid.
4. Component selection is explicit.
5. Component order is explicit and semantically relevant.
6. Direct compatibility requires common final grid without hidden resampling.
7. Equal width/height does not prove grid equality.
8. Mixed native grids require explicit target grid.
9. The core does not automatically choose finest or coarsest resolution.
10. Provider-resampled and locally-resampled representations are distinct
    provenance paths.
11. Target sample type `T` is explicit.
12. Mixed native types do not trigger implicit common-type promotion.
13. Conversion policy is explicit.
14. Scale/offset application is explicit materialization semantics.
15. Raw stored values and physical values are distinct targets.
16. Scale/offset does not imply clipping/stretch/gamma.
17. Resampler choice is semantic and participates in keys.
18. Categorical channels cannot be treated as continuous merely because their
    storage type is numeric.
19. Validity derivation is explicit.
20. NoData metadata does not automatically materialize validity.
21. Classification-to-validity mapping is explicit.
22. Validity grid transforms use validity-specific semantics.
23. Final primary channels share one exact target grid.
24. Final validity shares the same processing grid.
25. One output may depend on multiple Resource revisions.
26. Composite snapshot identity preserves ordered component mapping.
27. Per-resource revision coherence is required.
28. Product-level atomic coherence is represented when available, not invented
    when unavailable.
29. Backend fusion may optimize execution without hiding semantic transforms.
30. Every value-changing transform participates in production/cache identity.
31. Priority/request generation remain outside production identity.
32. Progressive stages with different grids/qualities have different semantic
    production keys.
33. Deep/variable-length representations are not forced into flat ImageView.
34. Compatibility failure is distinct from source/decode failure.
35. ImageView does not become a heterogeneous Dataset-like container.

# Part XIX — Rejected Alternatives

## 109. Product == ImageView

Reject.

It would force heterogeneous product structure into a homogeneous processing
view.

## 110. One file == one image grid/type

Reject.

OpenEXR directly disproves this.

## 111. Automatically promote native dtypes

Reject.

Target type is a semantic/performance decision.

## 112. Automatically choose highest resolution

Reject.

It imposes resampling and memory cost without caller intent.

## 113. Automatically choose lowest resolution

Reject.

It can discard available spatial detail.

## 114. Automatically use first selected component grid

Reject.

Selection order should not silently determine resampling policy.

## 115. Treat shape equality as grid equality

Reject.

Alignment/origin/sampling can differ.

## 116. Apply scale/offset whenever present

Reject as an implicit rule.

Raw-domain processing is a legitimate use case.

## 117. Interpret every mask as validity

Reject.

Masks have domain-specific meanings.

## 118. Bilinear-resample every numeric channel

Reject.

Categorical and validity semantics differ.

## 119. Hide conversion/resampling inside backend adapter

Reject.

Backend execution can fuse operations, but the semantic plan remains explicit.

## 120. Cache by requested band names only

Reject.

Grid, revision, type, transform and validity policy all affect pixels.

## 121. Put all provenance into ImageView

Reject.

Keep ImageView focused on processing interpretation; broader provenance belongs
to retaining materialization/product snapshots.

# Part XX — Open Questions

## 122. Q1 — target-grid descriptor

What existing/new workspace type should identify one processing grid without
duplicating future geospatial/geodesy responsibilities?

M2 should specify required semantics but avoid freezing a parallel CRS stack.

## 123. Q2 — component compatibility metadata

How much can be known from product descriptors before opening Resources?

Need concrete first product adapters.

## 124. Q3 — conversion-policy granularity

Should policy be one whole-image rule, per component, type-pair based or
operation-specific?

Needs implementation evidence.

## 125. Q4 — resampler policy shape

One global resampler is insufficient for mixed semantic classes.

Need a small way to associate resampling policy with continuous/categorical/
validity roles without building a giant policy framework.

## 126. Q5 — radiometric domain naming

Possible conceptual terms:

    stored
    decoded
    physical
    calibrated

Need consistency with remote-sensing conventions and M1 terminology.

## 127. Q6 — semantic binding versus pixel-cache identity

Can the same transformed pixel backing safely support multiple immutable
channel-semantic bindings?

Potentially yes when only metadata differs.

Needs M2.3 cache decomposition review.

## 128. Q7 — product-level snapshot identity

How should a product declare that several Resources form one coherent version?

Use native product IDs/processing baselines where available rather than
inventing global atomicity.

## 129. Q8 — partial component availability

If one of five requested components is missing/unavailable, should any reduced
image be delivered?

Default M2.5 direction is transactional failure for the requested final image.

Progressive/partial semantics require explicit higher-level policy.

## 130. Q9 — target grid selection helpers

Convenience helpers may eventually offer native grid of component X, named
product grid, or explicit target grid.

The core should not silently choose.

## 131. Q10 — transform fusion contract

How can adapters report that they can fuse decode + conversion + resampling
while still producing the exact requested semantic contract?

Needs first concrete backend integration.

# Part XXI — M2.3 and M2.4 Feedback

## 132. New transformed-key dimensions

M2.5 confirms that M2.3 transformed-cache keys need at least:

    ordered component selection
    composite upstream snapshot
    target grid
    target type
    radiometric policy
    resampling policy
    validity policy
    output coverage
    transform semantic/version identity where required

## 133. Native decoded key stays narrower

A native decoded cache entry should not be duplicated merely because later
targets differ in target grid, physical scaling or display composition.

That reuse boundary remains valuable.

## 134. Production-key resolution can be staged

M2.4's shared production model remains sound.

But the complete transformed production key may only become known after
product/component selection, representation resolution and current Resource
revision resolution.

Therefore abstract request intent and final production identity are separate
phases.

## 135. Multi-source dependency

One transformed production can depend on several native decoded productions.

This introduces graph-like execution pressure.

M2.5 does not justify a general workflow DAG yet.

A small internal dependency set is enough conceptually:

    transformed production
        waits for
    required native coverage productions

M2.4 priority/cancellation should propagate to those required children.

# Part XXII — Provisional Decision

## 136. Preferred compatibility pipeline

The strongest current model is:

    ImageryProduct
        |
        v
    ordered semantic component selection
        |
        v
    inspect candidate native descriptors
        |
        v
    explicit TargetImageContract!T
        - target grid
        - ordered components
        - target sample type
        - radiometric domain
        - validity policy
        - conversion policy
        - resampling policy
        |
        v
    resolve concrete source representations/revisions
        |
        v
    compatibility classification
        |
        +-- direct
        +-- type transform
        +-- grid transform
        +-- semantic normalization
        `-- unsupported
        |
        v
    ResolvedMaterializationPlan
        - composite upstream snapshot
        - exact semantic transforms
        - per-source logical dependencies
        |
        +------------------------> semantic ProductionKey / transform-cache key
        |
        v
    ExecutionPlan
        - cache strategy
        - fused/unfused adapter choice
        - source/cache geometry
        - task decomposition
        - memory admission
        |
        v
    M2.2 native materializations
        |
        v
    explicit or fused deterministic transforms
        |
        v
    common-grid typed retained raster(s)
        |
        v
    image-semantic binding
        |
        v
    retaining materialization owner
        |
        v
    borrowed ImageView!T

The semantic plan defines the result.

The execution plan may change with cache state, source capability, machine
resources or adapter optimization without changing result identity.

## 137. Public-surface implication

M2.5 still does not justify final public type names.

What is becoming stable is the semantic requirement that product-to-image
materialization be driven by an explicit target contract and compatibility
analysis.

A future public API can be small if these decisions remain explicit.

## 138. raster-d handback status

M2.5 does not currently require a new raster-d API.

Cross-grid dependency geometry may eventually provide evidence for promotion of
generic dependency/footprint types, but only when the first real resampling
implementation demonstrates the generic need.

## 139. M2.5 status

M2.5 architecture has now passed the M2.6 reference and consumer validation.

The main M2.6 correction is now incorporated:

    TargetImageContract
        ->
    ResolvedMaterializationPlan
        ->
    ExecutionPlan

This preserves semantic production/cache identity while allowing different
cache/backend/fusion strategies to produce the same defined result.

M2.6 also confirms that multi-source execution requires only finite internal
child-production dependencies at this stage, not a public general DAG.

No production product/materialization API should be implemented yet.

M2.5 should remain open until the focused M2 contract experiment validates the
semantic-plan/key/execution-plan separation mechanically.

## 140. M2.6 validation update

The final semantic ProductionKey is derived from the resolved materialization
plan.

Execution choices do not enter that key unless they change the defined pixel or
validity result.

This permits, for example:

    native decode + imagery-d resample

and:

    backend-fused decode + equivalent resample

to share one semantic identity when exact equivalence is part of the adapter
contract.

## 141. References

Primary references used for M2.5:

- OpenEXR Technical Introduction:
  https://openexr.com/en/latest/TechnicalIntroduction.html

- Copernicus Sentinel-2 Product Specification / SentiWiki:
  https://sentiwiki.copernicus.eu/web/s2-products
  https://sentiwiki.copernicus.eu/web/s2-mission

- xarray Dataset overview:
  https://docs.xarray.dev/en/latest/getting-started-guide/quick-overview.html

- xarray Dataset API:
  https://docs.xarray.dev/en/latest/api/dataset.html

- STAC Raster Extension:
  https://github.com/stac-extensions/raster

- STAC Assets:
  https://github.com/radiantearth/stac-spec/blob/master/commons/assets.md

- GDAL RasterIO / Raster API:
  https://gdal.org/en/stable/doxygen/classGDALRasterBand.html
  https://gdal.org/en/stable/tutorials/raster_api_tut.html

Project evidence used:

- M1 ADR 0002
- `docs/research/m1-imagery-product-boundary.md`
- `docs/research/m1-image-view-contract.md`
- `docs/research/m2-source-resource-access-model.md`
- `docs/research/m2-region-materialization-boundary.md`
- `docs/research/m2-cache-architecture.md`
- `docs/research/m2-demand-cancellation-prefetch.md`
