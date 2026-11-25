# Pixels, regions, masks and ownership

Image operations need a declared meaning for sample values and a clear lifetime
for the storage that holds them. Choose these facts before combining operators.

## Samples and regions

A scalar sample is one numeric measurement. An RGB sample contains declared
color channels. Encoded sRGB bytes and linear-light values are different domains;
an operation's contract states which one it expects. General image operators
do not require satellite, sensor or geographic metadata.

A region of interest (ROI) selects pixels from a larger image. Source coordinates
and coordinates of a newly materialized output need not have the same origin.
For example, the owned Levels output starts at local `(0,0)` and has the requested
ROI width and height. A feature source's `level` is an identifier chosen by the
caller, not a power-of-two scale factor.

A neighborhood operation also reads a border around the pixels it produces.
This border is its **halo**. An execution tile can therefore have a larger read
region than its output core. Give each operation its documented halo and
edge policy; changing the processing partition must not change which image
samples the mathematical operation sees.

## Three kinds of masks

| Kind | Question it answers | Example |
| --- | --- | --- |
| Sample validity | Is this input observation usable? | A missing/NoData pixel is excluded from a measurement |
| Edit selection | How strongly should an adjustment affect this pixel? | A byte mask blends from unchanged at 0 to fully adjusted at 255 |
| Alpha | How does this color contribute during compositing? | An RGBA operation uses declared straight or premultiplied alpha |

A validity mask does not become alpha, and a histogram-estimation selection
does not automatically become an edit mask. Channels are selected explicitly:
leaving an alpha channel untouched is a caller choice, not a channel-name guess.

Request success and result validity also differ. A feature request can complete
while some measurements are invalid. A valid response can have no meaningful
orientation, such as an isotropic structure tensor. Check each flag that the
result contract requires before interpreting its channels.

## Ownership and borrows

The storage/view contracts belong to raster-d; start with the
[RasterLease owner](https://github.com/alex-1974/raster-d/blob/v0.5.5/source/raster/backing.d)
and [RasterView contract](https://github.com/alex-1974/raster-d/blob/v0.5.5/source/raster/view.d).
For imagery calls, keep the input owner alive throughout every borrowed read.
Do not mutate shared input storage while an operation reads it.

An owned imagery result can remain alive after the input decoder or source
buffer is released. A borrowed feature plane or display buffer instead lasts
only for its documented callback or reuse interval. Copy a borrowed result
before keeping it across the next successful preparation/evaluation.

Each operation states what happens to an output parameter on failure. A `ref`
output may preserve an old result when the contract promises that; an `out`
parameter resets on entry. Neither a `try` prefix nor `@safe` implies a
universal no-throw, allocation-free or concurrent-use guarantee.

## Budgets and image identity

Read a budget's unit and accounting boundary. For Levels, `maxResultBytes`
bounds the new float pixel payload; it does not bound the input owner, an older
result, allocator metadata or total process memory. Engine/mosaic budgets
have their own scopes and must not be substituted for that one.

A feature source's identity names the image; its revision changes when samples
or validity change. Its grid identifies alignment, its band identifies the
channel, and its unit describes scalar measurements. Reusing an unchanged
revision after editing pixels can reuse an obsolete cached measurement.
