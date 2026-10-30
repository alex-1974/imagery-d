# RGB luminance stretch — function-target AVX2 experiment

**Status:** rejected; local diagnostic evidence only.

- Date: 2026-10-29
- Base revision: `9e162988a740ccbf36b4392f9a611acc346f0964`
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host target: x86-64, LDC default CPU `skylake`; host advertises AVX2
- Workload: `tests/perf_consumer --fullhd-only`, 1920 × 1080, 12 complete owned-result calls per timed batch, seven replicates after two warmups

## Question and method

The current Release profile attributes about 78% of sampled cycles to the
transform pass. Since the default-target eight-lane `Vector!(float[8])` path
uses XMM-width instructions, this experiment added LDC's function-level
`@target("arch=haswell")` to the private transform helper only. The consumer
was rebuilt at the normal generic package target, so this tested the codegen
benefit without globally enabling AVX2 across dependencies. A separate probe
confirmed the targeted helper emits YMM instructions while its generic helper
remains XMM-compatible.

The consumer's independent image oracle passed on the targeted build. Paired
Full-HD runs showed no repeatable improvement:

| Build | Unmasked median call | Masked median call |
|---|---:|---:|
| Generic target, initial profile run | 22.94 ms | 22.56 ms |
| Function-target AVX2 | 22.77 ms | 22.55 ms |
| Generic target, rebuilt run | 24.15–27.21 ms | 24.91–24.91 ms |

The profile and system load shifted between sessions, so small differences
are not attributable to AVX2. `perf stat` also reported essentially identical
instruction totals (about 57.84 billion per consumer invocation) and cycle
counts between targeted and generic builds (roughly 21.2 billion). The AVX2
attribute is therefore rejected; no product code change remains from it.

## Follow-up candidate

The transform's RGB8 decode currently performs three table lookups per pixel
and scalar lane packing. LDC's `ldc.gccbuiltins_x86` declares the AVX2
`__builtin_ia32_gatherd_ps256` intrinsic, so a targeted decode-gather kernel
is technically available. It still needs a correct AVX2 runtime dispatch and
a generic fallback. The installed `core.cpuid` implementation keeps its CPU
feature struct and accessor private, so imagery cannot rely on that internal
API directly. Any gather candidate must first provide a supported feature
check (or a small, audited CPUID/XGETBV helper), then pass the independent
pixel oracle and paired complete-API measurements. AVX2 remains only a
candidate for that narrower lookup experiment, not an established speedup.
