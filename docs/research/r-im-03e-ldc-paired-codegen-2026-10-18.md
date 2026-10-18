# R-IM-03e — Paired exact-revision D-vs-D LDC codegen receipt

**Date:** 2026-10-18. **State:** qualified hosted Linux x86-64 **generated-code evidence**, **NO native XPS performance result**, compiler speedup claim or production/admission verdict. Research only, no C++ source or translation.

**Scientific question:** Does the D-native `static if (HasSelection)` specialization eliminate enough repeated mask-branch work to justify a second generated mask-capability family and greater code size? Actual runtime effect is still unknown.

## Exact source and toolchain protocol

Same immutable D sources per compiler:

| Revision | Exact commit | Exact source SHA-256 |
|---|---|---|
| D baseline, runtime `if(hasSelection)` inside shared kernel | `68ddbdefc5b9cfefd95fe8545ba4848fc5736beb` (PR #91) | `8f506544207993e0539dd99ed4552ad4e78b1988a77b7981fc10c4f603571357` |
| D candidate, one entry dispatch into `execute!(T, METHOD, HasSelection)` | `ae36974af9369d7bbdbbecf9b8619d2da52e59be` (PR #93) | `6fad67adffc0acdf60f64781951a6569d759bf99fc6c9efe23927bd97926c057` |

Source paths are identical in both snapshots: `experiments/r_im_03a_levels/source/imagery/presentation/levels_integer_research.d`. The same `raster-d` checkout `2f2415851e45001df92ce56dad409f680684ba8d` was symlinked into the expected adjacent dependency path in a **new isolated temp tree**. `git archive` captured both exact SHA revisions; their source hashes were checked after extraction. No copying into or resetting another developer checkout.

Tool script: [`tools/research/compare_r_im_03e_codegen.sh`](../../tools/research/compare_r_im_03e_codegen.sh). A single LDC executable/version per pair, `dub build --build=release --force --verbose` and **unchanged DUB release flags** for both variants. The entire independent 4-method benchmark executable is built but **NOT executed for timing**. `nm --defined-only --print-size --size-sort --demangle=dlang`, `size -A`, `objdump -d --demangle=dlang --no-show-raw-insn`, exact source/executable hashes and full verbose compiler commands are archived in GitHub Actions **30-day** artifacts, not as fabricated source files.

- Hosted Ubuntu **24.04, x86-64**, Linux 6.17.0-1022-azure (not native XPS i7-9750H).
- LDC **1.41.0** pair reports DUB 1.40.0, run [#39114117789](https://github.com/alex-1974/imagery-d/actions/runs/39114117789), job **117636272380**, artifact `r-im-03e-codegen-ldc-1.41.0` (GitHub artifact ID **12132000713**).
- LDC **1.43.0** pair reports DUB 1.42.0, *but the baseline and candidate within that pair use the same DUB version*, same workflow run, job **117636272168**, artifact `r-im-03e-codegen-ldc-1.43.0` (GitHub artifact ID **12131513083**).
- Exact comparisons are **within compiler version only**; do not interpret cross-LDC absolute differences as attributable to the D source.
- The same research head `8a87334012c7e2a767bb6db0a5fd50d71b00db22` was tested by [push run #39114117789](https://github.com/alex-1974/imagery-d/actions/runs/39114117789) **6/6 PASS** and [PR run #39114120697](https://github.com/alex-1974/imagery-d/actions/runs/39114120697) **6/6 PASS**, combining 2 codegen pairs with 4 untouched DMD/LDC consumer correctness jobs.
- A preceding [push run #39114055186](https://github.com/alex-1974/imagery-d/actions/runs/39114055186) was **FAILURE** due to a malformed inserted YAML workflow (source-text replacement unintentionally duplicated original workflow lines). That **workflow-only regression** was repaired in `8a873340...`; neither underlying D source nor generated-code comparator data was changed by that repair. Preserve its failure receipt rather than erasing it.

## Measured section and whole-executable sizes

These are **whole executable** `.text` sizes, not isolated kernel size, and native host performance has **not been measured**.

| Compiler | Whole executable baseline | Candidate | Δ bytes | Δ % |
|---|---:|---:|---:|---:|
| LDC 1.41.0, executable on-disk | 1,318,224 | 1,337,184 | **+18,960** | **+1.44%** |
| LDC 1.41.0, `.text` segment | 444,112 | 463,712 | **+19,600** | **+4.41%** |
| LDC 1.43.0, executable on-disk | 1,420,144 | 1,443,176 | **+23,032** | **+1.62%** |
| LDC 1.43.0, `.text` segment | 450,832 | 469,584 | **+18,752** | **+4.16%** |

**Mechanism evidence:**

- `nm` reports **8** selected `imagery.presentation.levels_integer_research` *defined symbols* in baseline and **16** in specialized candidate with **either** LDC version. The baseline has `execute!(T, METHOD)` for 2 integer sample types × 4 math methods; candidate has 10 emitted `execute!(T, METHOD, HasSelection)` symbols **plus 6 separately emitted public-research-wrapper symbols**. These 16 symbols are a count of selected symbol-table entries **not** a full count of optimized/internal function instantiations, and many functions may be inlined and therefore absent from `nm`.
- In the candidate, the explicit **`execute!(ubyte, 0, false)` and `execute!(ushort, 0, false)`** appear as out-of-line symbols alongside `execute!(T, 0, true)`. For methods 1, 2 and 3, only `execute!(T, METHOD, true)` appear as such symbols; a missing `false` symbol **does not prove** that mask-free code is absent or was never emitted. It can have been inlined into wrappers and/or optimized out of a separate function.
- A representative LDC 1.43 **u16, LUT, original shared** `execute!(ushort, 3)` symbol is **1,326 bytes**. The candidate **u16, LUT, masked** `execute!(ushort, 3, true)` is **1,262 bytes**, **64 bytes smaller** *as a named local routine*. But the candidate also has an independently named `tryLevelsIntegerLutResearch!(ushort)` wrapper of **1,231 bytes**, and its mask-free path may have been inlined into the wrapper. This observation must **not** be misrepresented as an end-to-end 64-byte reduction.
- A representative LDC 1.41 **u16, LUT** symbol changes from 1,340 bytes baseline to 1,258 bytes in the candidate's `HasSelection=true` path (−82 bytes on just this symbol). Again, the whole executable increases.
- Some wrappers are externally callable research functions; a change in which calls were inlined can change total `.text` size. The complete `objdump` artifacts were subsequently audited for the **u16/LUT mask-presence branch** (see below), but no claim is made that alias checks, bounds checks or general preflight work disappear.

## Machine-code audit: 16-bit LUT mask-presence check

After the initial whole-image size audit, the **actual** `objdump` files from the LDC 1.41 and 1.43 Actions ZIPs were downloaded and inspected. This is more specific evidence than source inspection or just counting symbols. The symbol starts/sizes are independently matched to `nm --print-size --demangle=dlang` entries, and backwards branch targets were checked inside the same named function.

| Compiler | Baseline `execute!(ushort, 3)` | Baseline flag test **inside repeated pixel loop** | Backward loop edge crossing flag test | Specialized `tryLevelsIntegerLutResearch!(ushort)` mask branch |
|---|---|---|---|---|
| LDC 1.41.0 | `0x3ad60`, 1,340 B | `0x3b032: cmpb $0x0,0x2c(%rsp)` | `0x3b256: jne 0x3b02e` | `0x3cda5: test %dl,%dl` **before** either pixel loop |
| LDC 1.43.0 | `0x3c1e0`, 1,326 B | `0x3c4ae: cmpb $0x0,0x2c(%rsp)` | `0x3c6e0: jne 0x3c4aa` | `0x3df05: test %dl,%dl` **before** either pixel loop |

The baseline additionally checks the same flag once during preflight (`0x3ae92` in 1.41, `0x3c30b` in 1.43). In both binaries the flag originates from the kernel's runtime mask-presence parameter and is stored at the shown stack offset. In the measured repeated pixel loop, the branch loops back **before** the second mask flag check: **the baseline LDC compiler did NOT entirely hoist the mask-presence test for this u16 LUT path**.

The specialized candidate branches once in its caller based on runtime `hasSelection`, with a call into `execute!(ushort, 3, true)` for the masked path, and its unmasked path is integrated in the caller; the separated masked `execute!(ushort, 3, true)` receives no `hasSelection` bool and cannot recheck its presence. This confirms a **real codegen mechanism** for the D `static if` optimization.

**Critical limits:** this is a targeted **u16/LUT** assembly audit for two LDC versions, **not** a proof for every one of the 8-/16-bit direct pow/sqrt variants or every backend architecture. The branch can be predictable and cheap, while the additional code and dispatch/inlining policy may cost more in the instruction cache. Branch removal, by itself, **does not establish a positive timing result**. No system-dependent absolute performance conclusions are drawn from hosted runners.

## Interpretation and decision

**Supported observation:** Compile-time capability dispatch increases overall output code size by ~**4.2–4.4%** `.text` across both compiler generations; the named function map changes substantially. The compiler's layout and inlining policy are part of the effect. **The assembly audit confirms that the old LDC-generated u16/LUT pixel loop retained a runtime mask-presence test on the repeated path**, while the candidate checks once at entry and directs the masked/unmasked work into separate paths. This is **demonstrated removal of repeated branch work** in the named path, but **not proof of a faster executable** or evidence about every other backend.

**NOT demonstrated:** runtime throughput improvement, binary size as an adequate proxy for instruction-cache pressure, vectorization, fewer retired instructions, safer memory, stronger alias semantics, `@safe`/`@nogc`, SIMD advantage, XPS thermal stability, general gamma accuracy, production worthiness.

**Decision:** keep R-IM-03e **Draft**. The code-size penalty is a **material trade-off** that must be justified by paired D-vs-D consumer-visible runtime timings with the original and new SHAs, both layouts/selection states, small and large regions, and fixed runtime invariants. Without a reproducible substantial gain, **prefer the original simpler D kernel**; do not promote extra compile-time specializations merely because they are available in the language. This is consistent with `.workspace/DLANG_PRACTICES.md` §15.1: source shape is not a performance oracle.

The user's XPS has recorded 100°C CPU readings, repeated thermal-throttle event bursts and significant Firefox/backup background load. **Do not** run another uncontrolled extended native benchmark to 'prove' the static-if result. A qualified next step would be a *short* paired pilot with per-case/interval thermal-throttle deltas, current per-core CPU load, temperature and a stop policy, after cooling and workload readiness are established.

**C++ boundary:** a high-quality independent C++ implementation remains an **external performance target**, never a source model to port into D. That comparison is downstream of this D-against-D trade-off and equivalent numerical, ownership, and source/destination work.

**No production package/API introduced, no `raster-d` or other repo modified, no grandfathered research branches merged/rebased.**
