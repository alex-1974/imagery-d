# M3 color-d sRGB consumer experiment

This is the first concrete imagery-d to color-d consumer slice.

It tests one intentionally narrow image operation:

    explicit image RGB binding
        -> RasterView region iteration
        -> color-d SRgb!T
        -> toLinear
        -> LinearSRgb!T
        -> caller-owned WritableRasterView

and the explicit reverse transfer.

## Purpose

The goal is not merely to prove that importing color-d compiles.

The experiment asks whether a real image-domain consumer can use the public
color-d API while preserving the accepted library boundaries:

- imagery-d owns channel identity and RGB component binding;
- raster-d owns storage layout, ROI, lifetime and write capability;
- color-d owns encoded/linear-light sRGB mathematics.

The operation must require no hidden whole-image temporary, no per-pixel heap
allocation, no channel-count inference, no implicit clipping, and no image
metadata in color-d.

## Coverage

The driver currently exercises:

- float as the primary computational path;
- double as a secondary correctness path;
- planar RGB;
- pixel-interleaved RGB;
- identical semantic input represented through both layouts;
- whole-region versus uneven ROI partition execution;
- an independent local real-precision sRGB transfer oracle;
- explicit reverse linear-to-encoded transfer;
- extended negative and greater-than-one finite values;
- NaN, infinities and signed zero through the public color-d primitive;
- rejection of wrong encoding metadata and duplicate RGB plane binding;
- consumer-side CTFE of the scalar color-d primitive.

The region kernels themselves are declared @safe nothrow @nogc. Input and
destination rasters are allocated before the transform.

## Strong laws

For one compiler/run and scalar type:

    whole-region output
        ==
    the same pixels processed through arbitrary ROI partitions

and:

    planar semantic output
        ==
    interleaved semantic output

The comparison is exact because the operation is pointwise and evaluates the
same scalar color-d transfer for each semantic pixel.

## Numerical oracle

The driver contains a separate local implementation of the sRGB transfer
equations in D real precision.

It records maximum observed absolute error for decode and encode. The current
pre-measurement assertion budget is tied to machine epsilon and result scale,
rather than an arbitrary image tolerance:

    64 * T.epsilon * max(1, abs(reference))

The observed errors should be recorded in RESULTS.md after execution.

## Run

From the workspace checkout:

    cd libs/imagery-d/experiments/m3_color_d_srgb_consumer

    dub run --compiler=dmd-2.113.0 --force
    dub run --compiler=ldc-1.43.0 --build=release --force

The experiment uses sibling path dependencies on raster-d and color-d so it
exercises the actual workspace repositories rather than copied source.

No production imagery-d API is admitted by this experiment alone.
