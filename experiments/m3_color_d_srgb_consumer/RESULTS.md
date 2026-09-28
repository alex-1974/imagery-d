# M3 color-d sRGB consumer experiment — Results

Status: **PASS — consumer boundary validated; production admission deferred**

## Validated state

Final focused validation run:

- GitHub Actions run: `36435339820`
- validated imagery-d experiment source: `3ead4239861da0da384936f035fa7b7e96cb14d6`
- color-d: `65aa8fd53d52c2d9436ba1fdf3917ef48efd3f74` from `develop`
- raster-d: `c2e5932c1b2c0402832ac210411119f373f8cd30` from `main`
- DMD: 2.113.0, debug correctness build
- LDC: 1.43.0 / DMD frontend 2.113.0 / LLVM 22.1.8, release build
- runner: GitHub-hosted Ubuntu 24.04 x86-64

The focused matrix passed under both compilers.

## Consumer call shape

The experiment uses the public color-d root import and public value API:

```d
const linear =
    SRgb!T(
        red,
        green,
        blue
    ).toLinear;
```

and the explicit reverse:

```d
const encoded =
    LinearSRgb!T(
        red,
        green,
        blue
    ).toSRgb;
```

No color-d source change, adapter, internal import, allocation hook, image type,
or raster-specific API was needed.

## Semantic boundary result

PASS.

The experiment keeps responsibilities separated as intended.

imagery-d research code owns:

- explicit ordered RGB-plane binding;
- encoded-versus-linear image interpretation;
- region iteration;
- output interpretation;
- rejection of invalid image bindings.

raster-d owns:

- planar/interleaved physical layout;
- retained storage and lifetime;
- ROI;
- read and writable views;
- caller-owned destination storage.

color-d owns:

- `SRgb!T` and `LinearSRgb!T` value semantics;
- encoded-to-linear sRGB transfer;
- linear-to-encoded sRGB transfer;
- extended mathematical value behavior.

No RGB interpretation is inferred from channel count, names, or physical
interleaving.

The experiment does not reinterpret alpha, validity masks, or NoData. They
remain separate image-domain concepts. Premultiplied colour is not silently
accepted as straight encoded sRGB.

## Numerical oracle

The test driver contains an independent local sRGB transfer implementation in
D `real` precision. It is not a color-d round trip.

The finite corpus includes:

- negative extended values;
- the encoded transfer boundary;
- values below and above the boundary;
- zero and negative zero;
- ordinary mid-range values;
- one;
- values greater than one.

The public color-d scalar API is also exercised separately with NaN and positive
and negative infinity. Signed negative zero remains negative zero through the
linear branch.

Observed maximum absolute errors were identical in the DMD and LDC focused
runs:

| scalar | layout | decode max abs error | encode max abs error |
| --- | --- | ---: | ---: |
| `float` | planar | 1.656702637e-06 | 2.863535858e-07 |
| `float` | pixel-interleaved | 1.656702637e-06 | 2.863535858e-07 |
| `double` | planar | 1.395585036e-15 | 2.411265632e-16 |

The experiment uses a measured-value regression guard derived from scalar
epsilon and reference magnitude rather than an image-domain tolerance:

```text
64 * T.epsilon * max(1, abs(reference))
```

This is an experiment regression guard, not a new public color-d accuracy
contract.

## Region equivalence

PASS.

For the same scalar evaluation path:

```text
whole-region result
    ==
the same pixels processed through four uneven ROI partitions
```

The comparison is exact, component by component.

No halo is required because the operation is pointwise.

## Storage-layout independence

PASS.

The same semantic RGB image was materialized as:

- three planar float planes;
- one pixel-interleaved float allocation described as three logical planes.

Both source images compare exactly by semantic sample.

After color-d-backed decode, both destination images also compare exactly by
semantic sample.

Therefore this consumer operation depends on raster semantics, not physical
RGB layout.

## Allocation and memory behavior

The transfer kernels are declared:

```d
@safe nothrow @nogc
```

and compile under both selected compilers.

Source and destination raster storage are allocated before the transfer.
The operation writes directly into caller-owned `WritableRasterView!T`
storage.

The kernel creates only scalar color values on the stack. It performs:

- no per-pixel heap allocation;
- no hidden whole-image temporary;
- no scheduler creation;
- no color-d-owned storage.

Working memory therefore remains bounded by the already-materialized source and
destination regions plus constant scalar state.

## LDC release performance characterization

The final LDC release run also measured a 512 x 512 float image for five warmed
rounds.

This is a shared GitHub-hosted runner measurement. It is characterization
evidence, not a stable performance gate.

| layout | raster read/write identity | raster + color-d decode |
| --- | ---: | ---: |
| planar | 4.466 ns/pixel | 20.282 ns/pixel |
| pixel-interleaved | 4.518 ns/pixel | 20.393 ns/pixel |

The identity path uses the same public raster read/write access pattern without
the color transfer. It provides a practical estimate of iteration/layout cost.

The result shows no material planar-versus-interleaved cliff in this workload.
Most additional time belongs to the actual nonlinear sRGB mathematics rather
than a different image-layout path.

These numbers must not be treated as machine-independent throughput claims.

## Release-build test-harness finding

During validation, an apparent LDC release-only segmentation fault was reduced
and shown **not** to be a color-d, raster-d, or LDC defect.

The experiment initially placed operations with required side effects inside
runtime `assert(...)` expressions.

D release builds remove those assertions, including the expressions inside
them. Resource initialization and sample writes were therefore skipped, and
later code accessed uninitialized test state.

The driver was corrected to use an explicit runtime `require` helper for test
preconditions and to keep side effects outside language assertions.

After the correction:

- DMD 2.113 debug passed;
- LDC 1.43 debug passed;
- LDC 1.43 release passed;
- temporary LDC `-O0`, `-O1`, `-O2`, and `-O` controls all passed.

This is a test-harness lesson, not a product workaround.

## color-d API friction

**No actionable color-d API friction was demonstrated.**

The current public surface was sufficient for this consumer:

- root import works;
- encoded and linear-light types make the semantic transition visible;
- UFCS call shape is compact;
- float and double are available;
- extended values are not implicitly clipped;
- the scalar conversion is `@safe pure nothrow @nogc`;
- CTFE of the scalar primitive works from the consumer;
- imagery/raster responsibilities do not leak into color-d.

No color-d API change is requested from this experiment.

## raster-d capability result

No missing raster-d capability was demonstrated for this slice.

Existing public retained import, read-only view, writable view, sample access,
and ROI operations were sufficient.

The experiment deliberately does not claim these checked scalar accessors are
the eventual fastest imagery execution adapter. That is a separate performance
architecture question.

## M3 production-admission decision

**Do not admit a production imagery-d package solely from this experiment.**

The operation is useful and the library boundary is validated, but the current
implementation is intentionally a thin research composition over public
raster-d and color-d primitives.

Promoting it immediately would force provisional public names and metadata
shapes for RGB binding and image encoding even though the accepted M1
architecture deliberately left those names unfrozen.

The experiment therefore achieves two things without overpromoting API:

1. it validates the real imagery-d -> color-d consumer boundary;
2. it supplies evidence for the eventual M3 production slice.

A later production-admission step should select the smallest image-semantic
surface whose value is greater than merely wrapping one color-d scalar
operation.

## Conclusion

The real consumer test supports the current color-d design.

A separate workspace repository can perform a non-trivial region-based image
operation using the public color-d API while preserving:

- explicit semantics;
- layout independence;
- ROI equivalence;
- extended values;
- allocation-free hot-path execution;
- clear library ownership boundaries.

For this consumer path, no color-d API correction is required.
