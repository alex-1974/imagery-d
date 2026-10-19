# A usable Levels image consumer (P6 PPM)

This is an **ordinary executable**, not a test-only synthetic pixel loop. It accepts
an uncompressed 8-bit RGB P6 image, calls the existing **D** research Levels operation
over real `raster-d` input and output leases, and writes a new P6 image.

It deliberately lives **outside** the future `imagery-d` production package:
decoding, file paths, PPM format details and CLI presentation are a caller's job,
not part of the generic image-algorithm API.

## Usage

From the existing imagery-d research branch and with `raster-d` checked out in
the adjacent workspace as required by the research DUB library:

```bash
dub build --root=experiments/r_im_03a_levels/photo_cli --compiler=ldc2 --build=release
EXE=experiments/r_im_03a_levels/photo_cli/m3-levels-ppm-consumer
"$EXE" original.ppm adjusted.ppm 0.1 0.9 2.0 0.05 0.95
```

The five numbers are **input-black, input-white, gamma, output-black, output-white**.
Gamma 1.0 with `0 1 1 0 1` is an identity transform for all 8-bit inputs.
Results are the research kernel's normalized `float` outputs converted by
explicit clip-to-[0,1] and half-up rounding to P6 bytes.

**Narrow input policy:** P6, max value 255, RGB only, dimensions 1…2048 each,
at most 16 MiB input. Comments in the ASCII header are allowed, and the binary
pixel payload starts immediately after the maxval delimiter; a leading pixel
byte equal to newline is **not** treated as header whitespace. Existing outputs
are not overwritten; the entire output is prepared in memory before saving.

**Numerical meaning:** Levels is applied independently to the **caller-declared
encoded RGB channels**; the sample performs **no** sRGB decode/linear-light
transform, ICC-profile interpretation, premultiplied-alpha adjustment, or
colour-managed photo editing. It supports no alpha, graded mask or extra
channels in this particular CLI; those capabilities remain research-kernel
contracts, not an unannounced CLI guarantee. Output should not be represented
as a generally colour-accurate photographic grade.

**Status:** research consumer / functional interface probe. Not a public
`imagery-d` API, no production `dub.sdl` or `source/imagery`, no accepted
M3 promotion ADR, and no claim that a checked-in demonstration constitutes
independent adoption by a downstream application. The already documented M3
three-channel display-mapping candidate remains selected for qualification;
this CLI does not silently supersede that decision. It tests a distinct,
plain-image photo-editing use case and can inform a later explicit M3 choice.

**Owned-result boundary:** The CLI uses
`imagery.presentation.levels_owned_research.tryLevelsOwnedResearch` rather
than exposing a caller-owned writable destination directly. The wrapper
allocates/imports a **new** ROI-sized interleaved float `raster-d` lease,
runs the unchanged Levels pixel kernel on that independent backing, and
assigns it to the caller **only after success**. On a returned error,
a previously published owner remains unchanged. This avoids requiring the
caller to prove physical source/output non-aliasing. The source raster,
destination raster and original PPM bytes are distinct resources.

The **output pixel payload** is exactly
`width * height * sourceChannels * float.sizeof` bytes in this research
form; additional raster backing/metadata ownership, GC metadata and the
input/output PPM buffers are separate and **not** included in that figure.
Allocation and system exceptions remain possible; this probe makes no
`@safe`/`@nogc`/`nothrow` guarantee. Invalid Levels parameters cause
no output file creation; failed raster processing never publishes its
partial result. This is **not** a general-purpose encoder or an atomic
filesystem publishing API.

The intended minimal consumer-facing decision is **one** operation yielding
an owned result, **not** parallel public `Into` and owned operations without
a compelling real consumer use case. Public symbol names and output formats
remain provisional until the M3 admission review.

Compiler test: CI builds the executable with DMD and LDC, tests an identity
image and a separate Python `sqrt`/half-up oracle, and checks fail-before-file
behavior on invalid parameters. Timings are **not** a benchmark.
