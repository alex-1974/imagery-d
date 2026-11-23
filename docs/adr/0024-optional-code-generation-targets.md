# ADR 0024: optional code-generation targets

Date: 2026-11-23

Status: accepted for experiments; portable consumer default retained

Related: #212, #213, #214; ADR 0023

## Decision

Use separate compile-time builds. DUB's ordinary configuration remains portable
on its target architecture. LDC consumers on compatible x86 machines may build
with `DFLAGS='--mcpu=x86-64-v3'`. This creates an optional binary with an explicit
ISA requirement; it is not a new minimum for imagery-d or its dependencies.
`--mcpu=native` is a host-specific experimental upper bound, not a distributable
configuration. The documented flags are in `dub.sdl`.

There is no runtime CPU dispatch and no mandatory x86 intrinsic dependency.
Portable DMD and LDC, and optional LDC v3, run the independent numerical corpus
in CI. ARM keeps its normal compiler target; this experiment does not establish
ARM throughput or NEON coverage. Two separately built x86 targets cost an extra
reference CI job and require consumers to choose a compatible binary.

This decision precedes any new explicit vector implementation. No new explicit
vector path or `@fastmath` is introduced by this experiment. Existing luminance
stretch code already has LDC-guarded `core.simd` vectors and a DMD scalar path.

## Numerical constraints

The three builds use identical production source and ordinary DUB release
options. Line-table metadata and LLVM vectorisation remarks are enabled for all
three. No blanket fast-math, reassociation or approximate `atan2` is enabled.
Per-target independent oracles check exact operators, full-domain fallbacks,
configured parameters and tile partitions before timing. Output fingerprints
also disclose differences across targets. An ISA experiment is not permission
to change invalid-value, signed-zero, rank or winner-tie semantics.

The gradient and Hessian expose angles; an approximation would need a separately
specified error policy and boundary tests. Ridge and Gabor winners publish bank
angles, so replacing `atan2` cannot accelerate those loops. Strict scalar
fallbacks deliberately retain validation, ordered reductions and early exits.
LLVM's missed remarks alone do not justify removing those safeguards.

## Integer work and remaining candidates

The #213 path carrier checks exact membership in `Float32(code)/255` and runs
byte min/max recurrence, with complete floating fallback. It is not approximate
quantization. Its dispatch and all scratch are included in the benchmarks.

RGB distributions already delegate to raster-d's exact stored-byte histogram.
CLAHE uses integer bins, clipping, excess and cumulative counts. Luminance
stretch uses integer histograms and decoded-byte/encoding lookup tables plus
worker-private counts. Its bin is a luminance quantization, not the raw channel
code; replacing that semantic conversion with raw-byte bins is not equivalent.

The public median operators are 3x3. A 5x5 variant would require a new operator
contract. The existing finite min/max selection network already permits SIMD
over Float32 lanes without changing rank; byte conversion, alphabet checks and
extra scratch must be included before claiming a gain from a byte variant.
No 16-bit specialization or per-lane histogram is claimed by this experiment.

Rolling normalization maintains exact integer valid counts by adding and
subtracting row counts. Repacking the mask to call `popcnt` would add a pass;
it does not replace a repeated full-window count here. Constant division in
CLAHE remains a compile-time constant for the optimizer.

## Evidence

`tools/build-codegen-experiment.sh` builds portable, v3 and native binaries and
validates each against independent references. `tools/qualify-codegen.py` uses
the #212 ABBA protocol: at least 15 accepted whole cycles, full output hashes,
unchanged controls, retained rejected rows and bootstrap intervals. The control
uses the same portable C shared object for every target, validated on 120 cases,
pinned to the measured core with identical preheat. Per-target D controls remain
separate diagnostics. Prepared
worker clocks exclude fixture preparation and frame publication; Hessian uses
the standalone three-scale operation with caller-owned scratch. These are not
end-to-end Engine or frame-rate claims.

The dated benchmark report records every reported missed hot-source loop,
LLVM's reason, and the decision for that loop family. It records conclusive
effects separately from inconclusive/noisy results. Optional target flags may
be useful to a consumer without being safe to promote as a library default.
