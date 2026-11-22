# Resident display preparation

`imagery.mosaic.multiresolution` now has a direct path for one declared straight
encoded-sRGB RGBA8 source:

- Nearest sampling, including fractional scale ratios.
- Bilinear or area filtering when the selected source grid equals the target
  grid. These reduce exactly to single-sample identity filtering.

The path visits only provider tiles containing selected samples and writes the
output block while their validated raster-d planes are borrowed. It does not
copy a large source rectangle into an LRU slot, perform unnecessary color
round-trips or validate five destination views for each output pixel.
Zero policy weights avoid reads. NoData/missing tiles, alpha, canonical zero RGB
at alpha zero, cancellation and resource limits retain their explicit meanings.
This is an exact specialization, not a lower-precision resampling mode.

Fractional bilinear/area and multiple-source mixtures retain the general
linear-premultiplied implementation. There is no unconditional 60-fps promise
for them, decoding, arbitrary warps or an entire GUI/GPU upload pipeline.

## Owned output and borrowed display

`tryAssembleMosaicOwned` continues to allocate an independent owned frame and
preserves previously published owners/aliases on every failure. Writable
capability in raster-d explicitly does **not** imply uniqueness; existing owned
frames are never silently recycled.

For synchronous presentation, use a noncopyable `MosaicDisplayWorkspace` and
`tryVisit`. The callback receives only scoped read-only RGBA/validity views and
`MosaicDisplayInfo`, which contains no pixel owners. Upload or explicitly copy
pixels before returning. Metadata may be retained. The workspace keeps its
private output allocation for subsequent equal-sized views, always rereads
source pixels and reuses metadata only when recorded source facts match.

Its active owner is moved into a private local across source and consumer
callbacks. Resetting a public workspace value cannot free those active pixels.
Normal recursive calls are rejected. Use serially and do not move/reset the
workspace during an active operation. No callback runs on an incomplete frame.
A false/throwing consumer reports readFailure/callbackException; the caller
controls its own external presentation side effects.

`MosaicMetrics.resultBytes` remains the logical five-byte-per-pixel output.
`allocatedOutputBytes` reports new pixel payload; a warm matching display buffer
reports zero. This does not promise an allocation-free operation: scratch uses
C allocation and small runtime/closure bookkeeping may allocate GC bytes.
`reusedOutput` records the private-buffer case. The complete operation has no
@nogc/nothrow annotation. Old owned frame users keep the independent API.

## Budget and measured target

A 512² direct request uses 153,768 bytes of work payload and 1,310,720 bytes of
output. The generic 16-source bound remains 6,029,952 work bytes, below 8 MiB.
Only the direct path uses the additional block-output buffer; the general path
retains its original store strategy after a bulk-output trial regressed it.
Provider decode/cache storage, owner/allocator metadata and consumer upload
memory are separate. A private display workspace retains one output backing
until destruction or a later differently-sized successful allocation.

The qualified workload is a moving 512² viewport over a resident decoded
overview cache, on the recorded CPU/compiler. Four modes are checked: nearest
at the selected overview grid, nearest with a fractional ratio, bilinear identity
and area identity. Properly prepared overviews are important; a missing overview
does not make expensive multi-tap reduction equivalent to identity filtering.

The regression target is **p95 CPU assembly <=16.67 ms**, with five warm-ups and
101 measured frames per mode. Maxima are reported too; this is a throughput
qualification, not an OS hard-real-time guarantee. PNG decode/cache preparation
and consumer copying/GPU upload are outside that clock. `tools/verify-display.py`
independently checks final frame bytes/validity with Pillow/NumPy, including
moving origins, masks, transparency and owned-versus-borrowed results.

See the [receipt and raw rounds](benchmarks/slic-graph-display-2026-11-22.md).
The prepared buffer removes repeated output allocation, but overlapping timing
distributions do not justify a universal latency-speedup claim. Applications
still own decoded-cache limits, scheduling and refinement policy.
