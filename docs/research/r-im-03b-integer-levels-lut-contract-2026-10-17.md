# R-IM-03b — Integer Levels quantization, prepared LUT and native performance qualification plan

**Research date:** 2026-10-17  
**Status:** research implementation and independent consumer; **native XPS measurement and performance claim not yet available**.  
**Branch:** `research/r-im-03b-levels-integer-lut`, stacked on `research/r-im-03a-general-levels-consumer` / [Draft PR #85](https://github.com/alex-1974/imagery-d/pull/85). Generic-image processing direction under [design Draft #84](https://github.com/alex-1974/imagery-d/pull/84).  
**No production root `dub.sdl` or `source/imagery/**`, no public signature, accepted ADR or change to sibling repositories, and no changes to grandfathered [RGBA Draft #73](https://github.com/alex-1974/imagery-d/pull/73).

## 1. Question and responsibility

A GIMP/Photoshop-like Levels operation must work on ordinary **grayscale or RGBA image buffers**, not STAC/Sentinel/CRS/sensor information. Compare two general-purpose integer-output implementation methods with **identical numeric semantics**:

1. **Direct**: compute normalized levels with `pow(t,1/gamma)` for each selected sample and quantize output.
2. **Prepared LUT**: evaluate exactly the same full-precision scalar map once per possible integer code; reuse an **immutable double table** across one or more image operations, then apply selection opacity and quantize.

Do **not** infer that the LUT is faster until controlled native timings prove setup-amortized benefit. A generic lookup table is a research implementation strategy, not automatically a required public API type.

`raster-d` owns real sample layouts, views, leases and physical memory; `imagery-d` owns the explicitly image-oriented Levels and selection-opacity semantics. No code or dependencies on `color-d` are assumed: colour-management and premultiplied alpha are not solved here.

## 2. Numeric contract — bounded integer samples only

Accept **`ubyte` (0–255) and `ushort` (0–65535)** source samples and destination samples of the **same type**; one or more source planes in any valid raster-d layout. The consumer supplies channel selection (e.g., RGBA RGB selected, alpha unselected), a checked source ROI, optional matching full-source-extent `ubyte` *editing-selection* coverage mask, and numeric Levels parameters.

For input code `c`, integer maximum `M`, input black `b`, white `w`, gamma `g`, output black `lo`, white `hi`, coverage byte `mask`:

```text
v      = double(c) / M
t      = clamp((v - b)/(w-b), 0, 1)
mapped = lo + pow(t,1/g) * (hi-lo)
alpha  = mask/255 (or exactly 1 if selection is absent)
mixed  = v + alpha * (mapped - v)
output = uint(clamp(mixed,0,1)*M + 0.5)  # nonnegative round-half-up
```

The output is saturated in the destination's integer domain. `gamma > 0`; all parameter fields, `1/gamma` and input span must be finite; `b < w`, `0 <= lo <= hi <= 1`. Float input/NaN/Inf processing still belongs to the separate **R-IM-03a** float-output study, *not* this integer-output kernel.

- **Unselected channels** and pixels with selection strength 0 are **copied by code without any conversion**; this matters for the alpha channel or a region outside an editing selection.
- A partial selection mixes **unquantized** mapped and original normalized values, then rounds **once**. A lookup of *already rounded output codes* followed by interpolation would silently double-round some values; **that is not this experiment**.
- A prepared LUT stores `double` mapped values, not `ubyte`/`ushort` quantized results; consequently **the lookup variant uses exactly the direct path's post-map alpha and quantization semantics**.
- The integer levels interpretation is **scalar**: there is no guessed gamma-encoded RGB conversion, perceptual lightness transformation or safe premultiplied-alpha handling. The consumer chooses correct channels/data representation. Library computation must still be numerically correct for its defined scalar domain.
- On successful full ROI execution output channels and region-local coordinates match the source channel order and requested ROI. No global/world coordinates or source-provenance requirements exist.

**Preflight** checks source, ROI, channel selection count, finite/nondegenerate parameters, mask shape, output extent/plane count and LUT prepared state *before writing any output*. A rejected `ref` table preparation leaves the **previous prepared table unchanged**. A source sample/write failure **after** the pixel loop begins may leave a partial caller-owned destination and is **not** rolled back.

### Known ownership/API blockers

The research caller-provided writable output and source could physically alias, or overlap by shifted views. `@safe`/DIP1000 syntax alone would **not** establish physical noalias or uniqueness. All independent test owners are deliberately **disjoint**. Before first public API choose between:

- a validated disjoint destination capability + explicit allowed in-place cases, with complete failure contract; or
- an **owned, publish-only-after-success** result retaining its `raster-d RasterLease!T`, with validated allocation, error and old-result preservation, including native-fault behavior.

Neither public form is admitted, and no claim of `@safe`, `@nogc`, `nothrow`, process RSS bound or no-allocation is made from this research.

## 3. Prepared table lifecycle and memory

`ResearchLevelsTable!T.prepare(params, ref table)` builds a complete table of **`M+1` binary64 mapped values**, then snapshots it using `.idup` into an **immutable array**. A failed numeric-parameter validation does not modify the old table. A newly prepared table does not rewrite an already retained table instance.

| Integer type | Entries | Retained numeric LUT payload (excluding headers/GC metadata) | Approx. temporary + immutable payload during build |
|---|---:|---:|---:|
| `ubyte` | 256 | 2,048 bytes | 4,096 bytes |
| `ushort` | 65,536 | 524,288 bytes | 1,048,576 bytes |

The second column of bytes is an **accounted numeric array payload**, **not** measured peak RSS or proof of GC reclamation timing. The source and output buffers, selection mask, source leases and any simultaneously retained old LUT generations add their own residency.

Table preparation is not free. `ushort` invokes 65,536 scalar `pow` evaluations even when only a few pixels will be processed. A table is justified only when a real editing workflow reuses the same adjustment parameters enough to pay this cost.

Reference [OpenImageIO `contrast_remap`](https://openimageio.readthedocs.io/en/stable/imagebufalgo.html) may extrapolate outside source range; our Levels deliberately clamps. A semantically equal C++ baseline must implement **this formula**, not compare against an unrelated contrast/sigmoid transform.

**Workspace toolchain note:** [TOOLCHAIN_ISSUES.md TC-0006](../../../.workspace/TOOLCHAIN_ISSUES.md) reports a DMD/LDC Phobos `pow` hot-path cost and an LDC `llvm_pow` experiment in colour processing. This direct-vs-LUT experiment initially uses plain Phobos `pow` in both scalar/preparation methods. **Any claimed general performance advantage must later separate `pow`-backend effects from LUT effects**, preferably with a semantically equal Clang reference and independent numerical oracle.

## 4. Independent consumer correctness and regression matrix

Module: `experiments/r_im_03a_levels/source/imagery/presentation/levels_integer_research.d`. Separate DUB app: `experiments/r_im_03a_levels/smoke/source/integer_consumer.d`, invoked alongside unchanged original R-IM-03a tests.

**Cross-product:** 2 integer sample types × 2 channel counts (grayscale 1 and RGBA 4) × 2 raster layouts × 2 optional graded-selection mask states × 2 gamma settings (1,2) = **32 cases**.

For each case, independent actual raster-d source, mask, direct destination and LUT destination owners are initialized; 1 whole 8×6 output and 4 nonoverlapping 4×3 outputs are checked, for **160 ROI pairs** (320 output raster results). All channel codes in the independent consumer oracle are computed from a deterministic fixture, with separate `sqrt` for `gamma=2` rather than calling the kernel `pow`.

- Every selected code is compared with a fixture-derived integer rounding oracle (allowing ≤1 output code for independent transcendental/near-halfway rounding differences), while **direct output and LUT output must match **exactly** at all tested pixels**.
- Whole versus partitioned outputs match exactly, including all RGBA channel codes and selection opacity 0, 128 and 255.
- Gamma=1 and gamma=2 ensure linear and nonlinear correction. Alpha-channel pass-through and selection-opacity-zero pass-through must be **bit-exact**.
- Deliberately invalid ROI, NaN gamma, invalid source selection mask, wrong output dimensions or unprepared LUT must reject before changing any initialized output sentinel.
- Preparing a new LUT generation does not mutate the retained old LUT. Invalid parameters cannot destroy existing valid prepared state.
- **Complete integer-domain equality check**: one 256-code `ubyte` and one 65,536-code `ushort` single-channel ROI, direct versus LUT for every possible stored input code. These tests expose lookup indexing/normalization omissions that tiny synthetic images cannot.
- Explicit tie probes check that output half-code boundaries use nonnegative **round-half-up** in both execution methods rather than truncation or ties-to-even.

The earlier R-IM-03a float-output consumer remains an independently built executable module with **48 cases/240 ROI images** in the same separate DUB app, guarding backward research compatibility.

These tests **do not** prove DUB public package integration, real GIMP/Photoshop colour parity or optimized XPS performance.

## 5. Native benchmark harness — executable, results unmeasured

An optional **independent DUB research benchmark** is provided:

```bash
# Run on the real XPS with sibling raster-d checked out at pinned state:
bash tools/research/bench_r_im_03b_levels_xps.sh "$PWD" 1024 7 ldc2
```

It runs `experiments/r_im_03a_levels/bench/source/app.d` in **LDC Release**, measuring 4-channel `ubyte`/`ushort`, planar/interleaved and with/without a 0/128/255 selection mask:

- **LUT prepare time**, separately timed;
- one whole-image **numerical equivalence/warmup** for both methods, **outside** timing;
- **paired, alternating** direct and LUT repeated complete operations with reused raster-d source/destination owners, no resizing/allocation of results in the hot path;
- median per-operation runtime for each variant (microseconds);
- rough **break-even reuse count** = preparation time / (median_direct - median_LUT), or `-1` if LUT is no faster;
- retained LUT *numeric payload* and a full-output checksum, plus OS/CPU/compiler/Git/raster commit/governor metadata in invoking script.

This benchmark includes raster-d `trySample`/`trySetSample` costs for **both** variants. It is **not** an optimized hand-vectorized/contiguous image kernel and should not be compared directly with a raw-pointer C++ loop as though semantics were equivalent. Optimization choices should follow codegen and timings.

**CI builds the benchmark executable but does not use GitHub-hosted runner timings as native XPS evidence.** No measured median, ratio, allocation count, C++ comparison or break-even estimate is reported in this document as of the current research source. Do not fabricate them.

## 6. Remaining admission gates

1. **Real consumer:** demonstrate Levels in a non-test image editor/graphics application with concrete ownership and colour semantics.
2. **Ownership:** resolve disjoint output vs transactional owned result, with physical overlap tests, last-owner lifetime, failure injection and DIP1000 negative probes.
3. **Colour:** explicitly specify encoded/scalar versus scene-linear operations and premultiplied alpha; use existing `color-d` semantics when necessary, never embed second colour engine.
4. **Performance:** execute native paired benchmark on XPS with pinned compiler, governor/affinity, several data sizes/repetitions; compare low-level D fast paths and semantically equivalent C++ with raw results and memory observations.
5. **API:** only after numerical, memory, benchmark and genuine-consumer evidence, decide operation package/function shape in a new ADR; do not elevate `ResearchLevelsTable` or `Into` from experiment by convention.
6. **No source-format scope creep:** no imageio codecs or satellite/EO metadata gate in ordinary Levels processing.

**Disposition:** retain qualified research and targeted CI, keep Draft PRs open until explicit promotion decision, no writes to sibling repositories, no history rewrite or wholesale Research merge.
