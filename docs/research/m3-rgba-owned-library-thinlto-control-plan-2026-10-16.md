# M3 RGBA — bounded LDC ThinLTO cross-library control

**Date:** 2026-10-16. **Status: IMPLEMENTED, CI/real XPS not yet qualified.**
Design issue #75 · Draft PR #73 (grandfathered stacked research base).

## Question and negative baseline

Independent XPS evidence for exact imagery-d source commit
`28211cd4fdd367abe8ea318c5f20c523fa5b8cc1`,
[owned-library result](m3-rgba-owned-library-xps-independent-results-2026-10-16.md),
found **39/40** `owned_extracted_library / owned_fused_checked`
case-median ratios above the pre-registered +5% **investigation** trigger.
The cohort medians ranged **1.085019–1.307473**, with
~**7.8 ns/pixel** of additional paired whole-owned cost.

Independent `objdump` of the exact measured 1,716,432-byte native
ELF showed the private producer's packing loop contained inlined
four-channel reads and packed output store, whereas the extracted
library producer contained **four `RasterView.trySample` plus one
`WritableRasterView.trySetSample` direct calls per pixel**.
This is a strong missed-inlining hypothesis, **not** a completed
causal attribution or proof that a static callsite costs exactly
7.8 ns/pixel.

## Single controlled variable

**Keep all source semantics fixed.** Do not edit either producer,
change the canonical PM preflight, use raw pointers or `@trusted`
shortcuts, add another public view/cache API, or change raster-d/color-d.

Compare two **independent DUB builds of exactly the same imagery-d
Git commit**, both pinned to released raster-d/color-d **v0.2.0**:

1. **Baseline:** existing
   `tools/research/run_m3_rgba_owned_library_xps.sh`;
   unchanged `default` DUB configurations and Release LDC1.43.
2. **Candidate:** new
   `tools/research/run_m3_rgba_owned_library_thinlto_xps.sh`;
   compiler options `-flto=thin` on BOTH research library and
   consumer via explicit `subConfiguration`,
   `--linker=lld` on the final executable, and
   `--deep --force --verbose` to rebuild and record dependency
   compiler/link invocations. No LTO flags in default
   research/build/package configurations.

ThinLTO is a **toolchain experiment**, not a workspace-wide or
production default. It may increase compile time or binary size,
fail due to object/linker compatibility, or leave accessor calls
untouched. The CI must report any unsupported flag/linker condition
as **REJECT/DEFER** for this configuration, not silently fall back to
a non-LTO build labeled LTO.

Official DUB documentation permits compiler-specific
`dflags` with `platform="linux-ldc"` and requires
`subConfiguration` to choose an independent dependency
configuration. LDC exposes `-flto=thin` and
`--linker=lld`; confirmed by
https://dub.pm/dub-reference/build_settings/ ,
https://dub.pm/dub-reference/platform_specifications/ ,
https://manpages.debian.org/unstable/ldc/ldc2.1.en.html .
LTO can enable inter-module inlining, but cannot be assumed
effective merely because those flags exist.

## Exact evidence contract

The new ThinLTO XPS runner operates on **immutable `git archive
HEAD` snapshots** in an ignored output directory, with read-only
`raster-d`/`color-d` v0.2.0 archives.
It records source SHA, toolchain, binary, build log, host/CPU
and governor state. The runner **rejects** a build if it does not
observe at least two `-flto=thin` compiler occurrences and the
explicit `--linker=lld` in verbose DUB build output; this is a
smoke guard, **not by itself proof the dependency's LLVM bitcode
was actually linked**. The codegen/ELF and provenance checks
complete that evidence.

The read-only codegen inspection script
`tools/research/inspect_m3_owned_lto_codegen.py`
uses `objdump -Cd --no-show-raw-insn` on the **exact measured
binary** and records:
- binary SHA-256 and length;
- private and extracted producer symbol matches;
- static `call` instruction count per producer body;
- static `trySample` and `trySetSample` call sites.

It was independently trialled on the **prior negative-control
ELF**, SHA-256
`4e8cd4ddf5d82162f6bd30f1dc5f31b3a19c86b9229f29787a633caa04a72afe`,
finding **private 0/0** accessor sites and **extracted 4/1**,
consistent with the earlier manual disassembly.
**A missing function symbol may indicate inlining, elimination,
stripping, or other codegen differences; it is NOT evidence
of zero calls.** These counts describe static calls in the
entire function, not dynamic calls per loop iteration. Inspect
the actual loop when counts change.

The optional `CODEGEN_CALLS.json` is added to the **new
ThinLTO-only manifest**. The strict existing XPS validator
accepts the extra entry **only if** the environment declares
`optimization_mode=thin-lto`, `lto_configuration=thin-lto`
and `linker=lld`. It independently verifies that the JSON's
binary SHA/length refer to the **same** measured executable.
The old non-LTO runner and archives remain under their
original 43-file manifest contract.

## CI and performance gates

**CI first:** DMD2.112.1/2.113.0, LDC1.42/1.43 old default
correctness/native ownership/error tests remain unchanged.
The targeted LDC1.43 Linux job additionally checks script
syntax, validator self-test, `ld.lld`/`objdump` availability,
an immutable eight-case **ThinLTO --smoke** run,
`LIBRARY_COMPARISON.csv`, `CODEGEN_CALLS.json` and SHA-256.

**Native failure gate under LTO, not only under default build:**
The existing four-kind glibc `LD_PRELOAD` interposer and
independently compiled `owned_slice_smoke` consumer are now
also built in the dedicated `native-faults-thin-lto`
DUB configuration. Both research library and
consumer receive `-flto=thin` and the final link selects
`lld`. LDC1.43 release CI must demonstrate first/second
actual pixel `malloc` failures, pre/postcommit public raster
import failures, precisely once released native pixel buffers,
successful retry after fault disarm, invalid last-ROI PM
rejection before first malloc, and no partial publication.
This new LTO-specific gate is **implemented but not yet
reported PASS**. It does not establish druntime `Error`-class
OOM recoverability.

**Only after green exact-head CI:** run baseline and candidate
full `--micro` on the XPS **from the same Git HEAD**,
with fresh unique output directories and untouched sources.
Each has 40 cases × seven rotated rounds × three **complete
owned result** paths × 24 iterations. All pixels are compared
against the independent prepared reference before and after
timing. Exact serialized original evidence is retained.

Compute each case's seven paired
`library / private_fused` whole-call duration ratios, then
cohort medians of the ten case medians. Compare ratio
distributions, absolute ns/pixel, maximum per-case regression,
binary size/`.text` size, GC and accessor-call counts.
Two separately compiled builds are **not interleaved as one
paired experiment**; never call differences between build
configurations `within-round paired`. If changes are close to
noise, qualify a second alternating A/B session.

**Accept as promising** only if the executable really uses
ThinLTO, all byte/fault/lifetime gates remain intact, and
measured linked-library overhead becomes materially closer
to private fused at similar complete-owned cost. Whether
the earlier +5% threshold is met must be *measured* in
each native cohort/case, not inferred from instruction counts.
If ThinLTO does not help, **record a negative result**,
review codegen of the bounded packing loop, and avoid
a permanent consumer-wide toolchain policy change.

## Explicit non-decisions

- No production import paths, API names, `@safe` claims or
  `@nogc` promises are changed.
- No public allocator, cache delivery or raster-d ownership
  capability is introduced.
- The separately linked B producer remains conditional
  and performance-blocked until exact real evidence.
- PR #73 stays open/draft on its grandfathered base;
  no merge, rebase, target change, freeze, release, or
  changes to sibling repositories.

## 2026-10-16 XPS Downloads archive export correction

The original default/ThinLTO XPS runners completed a measurement and
printed a suggested `tar` command using `echo`; they did **not**
execute that command. This was discovered from a native XPS run
`20261016T133936Z`, which completed under measured imagery-d
`fceb413fdf8fc26734309e60896d41a4407f672c` but had no
automatic `~/Downloads` export.

Both research runners now call the same
`tools/research/archive_m3_rgba_owned_xps.sh` helper **after
successful full `--micro` validation**; `--smoke` remains
local-only unless its output directory is passed to the helper
explicitly. The exporter rechecks the original on-disk manifest,
excludes only the redundant `snapshot/` directory, verifies
**every original manifest entry again inside the transport TAR**,
includes the exact measured executable and (for ThinLTO) the
SHA-linked codegen receipt, and atomically hard-links a complete
`m3-owned-library[-thinlto]-<run-directory>.tar.gz` into
`$HOME/Downloads` without overwriting an existing file.
It preserves original CSVs, build logs, source SHA and measurements.

A CI smoke-export test now covers both default and ThinLTO
output types and verifies that overwriting an existing default
transport is rejected. This export change does **not**
rerun or invalidate prior native measurements, and it does
not claim the pending ThinLTO performance hypothesis PASS.
