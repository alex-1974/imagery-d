# R-IM-03e — D-native Levels execution, not a C++ translation

> **Paired LDC codegen update (2026-10-18):** Exact baseline-vs-candidate Release builds under LDC 1.41 and 1.43 [show an additional 19,600 / 18,752 bytes of whole-executable `.text` (+4.41% / +4.16%)](r-im-03e-ldc-paired-codegen-2026-10-18.md). 8 relevant defined symbols in the baseline versus 16 in the specialized build; the mask-free path is compiled in the D source but real speed benefit is **not measured**. Inspect inlining/branch behavior and paired D-vs-D native runtime before accepting this specialization. Original directions below describe the pre-result plan and remain research gates.

**Date:** 2026-10-18. **Status:** implementation **research only**, first controlled hypothesis. **Parent:** R-IM-03d [Draft PR #91](https://github.com/alex-1974/imagery-d/pull/91) at **`68ddbdefc5b9cfefd95fe8545ba4848fc5736beb`**, which itself stacks on R-IM-03c [Draft PR #89](https://github.com/alex-1974/imagery-d/pull/89), R-IM-03b [Draft PR #87](https://github.com/alex-1974/imagery-d/pull/87). This topic intentionally **does not** move or merge any grandfathered branch or other library.

## Engineering direction

**Do not rebuild, transliterate or mechanically port C++ internals into D.** First create the best coherent implementation that respects imagery-d's semantics and exploits what D can provide. A high-quality existing C++ implementation may later supply an **independent performance target/oracle**, not a code-layout recipe or source to copy. Under workspace `QUALITY_GATES.md` §7 and `DLANG_PRACTICES.md` §15, do not change validation, numerical precision, allocation, error cases or bounds checks to make D artificially look faster.

The useful D-native mechanisms to study in the existing actual code, in order:

1. **Compile-time capability specialization** using ordinary templates, enum parameters and `static if` for semantic facts known once per invocation; no generated strings or extra public API variants.
2. **Typed `raster-d` `RasterView!T` / `WritableRasterView!T` / retained `RasterLease!T`**, with `scope`-based borrowing and independent owned destination. No unchecked pointer dereference or hard-coded planar-only loop to evade view semantics.
3. **Prepared immutable lookup state** for the repeated transform case; retain a straightforward direct operation for one-off use. Count all **512 KiB u16 payload**, transient preparation allocation, setup time and break-even; never claim `@nogc` on an allocating prepare.
4. **Language attributes and ownership gates** such as `@safe`, `nothrow`, `@nogc`, `pure` only where actual dependent APIs, type lifetimes, and compiler probes justify them. The original research code **has not yet demonstrated** a global `@safe/@nogc` production operation; do not assert it.
5. **LDC native optimizer/codegen** with production-relevant bounds and safety settings; review auto-vectorization only after profiling and never introduce manual SIMD, `@trusted` escapes, scatter-pointers, backend forks, `-ffast-math`, or API source-shape duplication without measured cause. DMD remains the correctness development compiler, LDC the primary optimized release compiler.

**Critical cross-library ownership:** raster layout/strides and memory guarantees remain in `raster-d`. Colour transfer, gamma/working-space interpretation and compositing correctness cannot silently be solved by a numerical LUT, and spectral meaning/NoData/alpha remain independent image semantics (M1 accepted ADR). Avoid introducing a production `source/imagery` surface or root DUB package while M3 consumer, publish-on-success/alias, real image and performance gates remain open.

## First R-IM-03e experiment: a real compile-time capability

The previous R-IM-03c/D source contains:

```d
// Original branch: hasSelection is a bool read inside every pixel.
if (hasSelection) {
    if (!selection.trySample(0, x, y, m))
        return ResearchLevelsError.sampleFailure;
    strength = cast(double)m / 255.0;
}
```

The new, **single shared D kernel** specializes its capability:

```d
private ResearchLevelsError execute(T, int METHOD, bool HasSelection)(...)
{
    // existing semantic preflight, with HasSelection as a known capability
    // ...
    double strength = 1.0;
    static if (HasSelection) {
        // existing checked mask sampling and opacity conversion
    }
    // existing loop, typed source/destination, LUT or math selected by METHOD
}
```

Each existing research wrapper performs a **single runtime mask-presence dispatch before entering the ROI loop**, selecting `execute!(T, METHOD, true)` or `execute!(T, METHOD, false)`. `METHOD` was *already* a D template parameter for Phobos, LLVM, gamma2 sqrt or prepared LUT; `T` was *already* `ubyte`/`ushort`. All computation remains in **one source function**, not duplicate planar/pointer/C++ variants.

**Hypothesis only:** Removing the per-pixel runtime `hasSelection` path in the mask-free instantiation may permit better LDC optimization and eliminate redundant mask handling from that instantiated code. **The old compiler could already have hoisted/predicated the branch**, so there is *no performance gain claim* without actual optimized codegen and fair timed tests. The extra template instantiation/compile time and code-size cost must also be assessed. This is a meaningful semantic capability (`no selection mask` vs `graded selection mask`), not a micro-template for incidental layout flags.

### Invariants deliberately retained

- **Unchanged research callable signatures** `tryLevelsIntegerDirectResearch`, `tryLevelsIntegerLutResearch`, `tryLevelsIntegerLlvmPowResearch`, `tryLevelsIntegerSqrt2Research`; no public API admission.
- **Unchanged preflight** on source dimensions, ROI, selected-band length, gamma, destination dimensions, optional mask grid and negative-before-write rejection.
- **Unchanged per-pixel semantics**: input code -> normalized double -> clipped mapped result -> optional 0/128/255 selection blend -> **single half-up output quantization**. Unselected channel/alpha passthrough remains exact. No hidden colour conversion.
- No change to mathematical method, LUT preparation/immutability, source and result raster leases, memory model, physical alias policy or late-failure behavior. **The research code still does not guarantee non-aliasing or transactional output publication**.
- No forced unroll, unchecked cast/pointer, `@trusted`, x86 instruction, CPU governor, no safety/performance weakening.

## Independent correctness gate

New focused CI runs the **existing independent DUB Levels consumer** under **DMD 2.111.0/2.113.0 and LDC 1.41.0/1.43.0**, in **Debug and Release**, pinned to raster-d exact commit `2f2415851e45001df92ce56dad409f680684ba8d`. The pre-existing consumer already qualifies:

- 8-bit and 16-bit types, 1 and 4 bands, planar and interleaved, masked/unmasked, gamma 1 and 2.
- ROI whole image vs four subregions; 32 case matrix, 160 ROI comparisons, unselected channels and alpha, 0/128/255 selection opacity.
- All 256 + 65536 integer sample codes; independent mathematical oracle, exact direct/LUT agreement under tested profiles, <=1 integer code for optimized LLVM/sqrt, half-way rounding cases.
- Negative ROI/mask/destination/gamma/reprepare cases and no-write-on-preflight-reject.
- Small case-order canary for `forward/reverse/target-first/target-only/control-only` under LDC 1.43, with separate masked and unmasked case identifiers.

The existing consumer tests do **not** prove alias safety, complete numerical equivalence for arbitrary gamma, constrained non-GC API attributes, overlapping-source correctness or optimized throughput. Hosted CI timings **are not** XPS release performance evidence.

## Next fair **D-against-D** and external comparison gates

1. **Correctness first:** if CI fails, keep failure evidence and repair the D implementation within the research branch; do not relax negative tests.
2. **Inspect LDC codegen / binary size / compilation time** of the baseline R-IM-03d single generic runtime-flag kernel and the R-IM-03e static-capability kernel. Look specifically for mask-path elimination and unnecessary loop checks; count the additional instantiations, assembly / LLVM IR changes and evidence of optimizer already hoisting the flag.
3. **Paired native D-vs-D timings** on equivalent source/output owners, layouts, ROIs, masks, gamma and LUT reuse. Fix compiler flags, warmups and actual baseline SHAs, rotate methods/process order, retain raw distributions. Include masking and no-mask scenarios; D variant must not win by doing less user-visible work.
4. **System prerequisite:** XPS reached 100 °C during R-IM-03c/d; prior live backup and Firefox loads, 30,819 throttle transitions in an unobserved 26-minute interval, and high occupied swap were separately recorded. A quiet 15-second window with 0 new throttling is not a stable-under-load clearance. Complete cooling/airflow review and capture **time-correlated** throttle-counter/frequency/thermal state during only **short, stop-on-critical, controlled** pilot runs. No further long XPS stress just to qualify a small source change.
5. **External comparator later:** a known independent high-quality C++ image-processing library used **as shipped** (or independently specified algorithmic reference when necessary), with carefully documented semantic mismatches; **never translated into D**. Since equivalent validation, opacity, ROI, precision, owner publication and allocation may differ, no end-to-end D-vs-C++ rank is fair until work-equivalence is shown. Clang builds and more D variants should not be added automatically without independent evidence.
6. Only after consumer and owner/alias/publication, domain/colour and multi-size benchmarks are qualified consider the minimal production Levels vertical slice. Keep **research code out of release**.

**Disposition:** R-IM-03e tests a specific compile-time capability on the established single D kernel. It does not prove LLVM vectorization, cache efficiency, throughput benefit or overall release readiness.
