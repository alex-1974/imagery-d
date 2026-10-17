# R-IM-03b — First native XPS integer Levels LUT-vs-direct result

**Run:** 2026-10-17 18:17:41 UTC (20:17:41 Europe/Vienna). **Evidence level: native, single host/run, exploratory benchmark—not release-performance or C++ parity admission.**

**Source file:** user-supplied `benchmark.log` in imagery-d research conversation. Original complete file: **3,929 bytes; SHA-256 `77e96b7c64cebd5adb4c6b0ca1f37f8757f224fc774e46d8d8c25a8eb027e5b7`**. The eight unchanged machine-result rows are reproduced below. Do not confuse this source log with new results produced by a hosted runner.

## Provenance and verification

| Field | Observed |
|---|---|
| host | `xps-15` |
| CPU | Intel Core i7-9750H @ 2.60 GHz |
| OS | Linux `6.17.0-22-generic` x86_64, Ubuntu |
| recorded governor | `powersave` |
| imagery-d Git SHA | `d7482ddbf6d0fcdb7e06851d1c7958cc052922c8` |
| imagery Git branch/status | detached HEAD and clean working tree in a separate benchmark clone |
| raster-d pinned SHA | `2f2415851e45001df92ce56dad409f680684ba8d` (v0.2.0) |
| compiler | **LDC 1.42.0**, DMD frontend 2.112.1, LLVM 19.1.7; default target x86_64, host CPU skylake |
| DUB | 1.40.0 |
| build | DUB `release`; compile/link logs confirm independent research library, benchmark executable and raster-d |
| benchmark invocation | `1024 7 ldc2` = 1024 × 1024 RGBA pixels, seven paired rounds per configuration |
| layouts | planar vs interleaved source; destination opposite layout |
| selection | either no mask or three-level 0/128/255 editing selection mask |
| selected channels | 3 of 4 RGBA channels; channel 3 copied unchanged |
| numerical settings | input black 0.1, white 0.9; gamma 2; output black 0.05, white 0.95 |
| timing | prepare LUT separately, one full-output direct-vs-LUT correctness check/warm-up, alternate 7 pairs, median per method, microseconds recorded |
| allocation scope | same already-allocated raster-d source, two outputs and mask reused; table prepared outside timed loop |
| verification scope | direct and LUT outputs compared for every output pixel/channel in the warm-up, then numerical checksums emitted |

**Source-code audit:** The `ushort` pixels are generated as `cast(ushort)(257 * ((31*x+17*y+13*channel) % 256))` (benchmark `bench/source/app.d`). **Only 256 distinct `ushort` input codes are visited**, despite the 65,536-entry LUT. This under-represents true 16-bit image entropy/locality. The separate correctness consumer *does* enumerate all 65,536 input codes but that is **not** equivalent to performance coverage.

## Source machine-result rows (unaltered)

```csv
RIM03B_FIELDS,type,width,height,layout,mask,rounds,prep_us,direct_median_us,lut_median_us,break_even_reuses,retained_lut_payload_bytes,checksum
RIM03B_CSV,ubyte,1024,1024,planar,no-mask,7,38,236431,13910,0.00017077,2048,630706176
RIM03B_CSV,ushort,1024,1024,planar,no-mask,7,4732,229429,13772,0.0219423,524288,162081902592
RIM03B_CSV,ubyte,1024,1024,planar,mask,7,22,164538,15815,0.000147926,2048,582815702
RIM03B_CSV,ushort,1024,1024,planar,mask,7,4674,158672,14489,0.0324171,524288,149775479427
RIM03B_CSV,ubyte,1024,1024,interleaved,no-mask,7,21,226385,13390,9.85939e-05,2048,630706176
RIM03B_CSV,ushort,1024,1024,interleaved,no-mask,7,4507,227419,13336,0.0210526,524288,162081902592
RIM03B_CSV,ubyte,1024,1024,interleaved,mask,7,21,158018,14131,0.000145948,2048,582815702
RIM03B_CSV,ushort,1024,1024,interleaved,mask,7,5065,160213,14409,0.0347384,524288,149775479427
```

## Derived comparison (calculated from those median microseconds)

| type | source layout | selection | direct median (ms) | LUT median (ms) | direct/LUT |
|---|---|---|---:|---:|---:|
| u8 | planar | none | 236.431 | 13.910 | **17.00×** |
| u16 | planar | none | 229.429 | 13.772 | **16.66×** |
| u8 | planar | 0/128/255 | 164.538 | 15.815 | **10.40×** |
| u16 | planar | 0/128/255 | 158.672 | 14.489 | **10.95×** |
| u8 | interleaved | none | 226.385 | 13.390 | **16.91×** |
| u16 | interleaved | none | 227.419 | 13.336 | **17.05×** |
| u8 | interleaved | 0/128/255 | 158.018 | 14.131 | **11.18×** |
| u16 | interleaved | 0/128/255 | 160.213 | 14.409 | **11.12×** |

**Observed range:** direct/LUT factor **10.40–17.05**. A single 1024×1024 RGBA operation already exceeds LUT setup in this experiment: **u8 21–38 µs**, **u16 4.507–5.065 ms**, while the corresponding full-image direct-minus-LUT median savings are **~144–223 ms**. The benchmark's `break_even_reuses` is (prep / (median_{direct}-median_{LUT})) and lies below 1 for every row. **This calculation is conditional on THIS workload and THIS direct implementation; it cannot establish universal one-shot/LUT preference.**

Both layouts' checksums match for each type/mask setting, consistent with layout-neutral output; the complete warm-up comparison also asserts exact equality direct vs LUT. These are not independent verification of the input fixture's scientific or photo-correction meaning.

## Why this is useful and why it is NOT yet an optimized-engine decision

**Finding:** Prepared unquantized mapping offers a very large improvement over **per-pixel Phobos `std.math.pow`** in this scalar raster-view experiment on the tested XPS. The mask reduces the gap because many selected pixels do no `pow` work when opacity is zero.

**Major confound:** Workspace `.workspace/TOOLCHAIN_ISSUES.md` **TC-0006** identifies Phobos `pow`'s x87 extended-precision call path and an LDC `llvm_pow` alternative in `color-d`. This benchmark compares **an especially costly direct transform** to the prepared lookup. It does **not** show a 10–17× advantage over optimized direct D or semantically equivalent optimized C++. The `pow` path and bounds-checked `RasterView.trySample/trySetSample` layers must be isolated before interpreting a production speed ratio.

**Coverage limits:** only one 1024² image size, one input-code distribution (8-bit source entropy), one fixed gamma, 7 repeated pairs once, no independent reruns, powersave governor, no affinity/frequency/power control, no per-round raw timing retained, no allocation/RSS or source-cache telemetry, no Clang baseline. The LUT memory figures are **retained double-array payload only**, not process peak RSS. `ushort` table build also transiently holds a mutable plus immutable array and needs further allocation qualification. Destination aliases and late-write failures are not addressed by performance data.

## Next evidence gates — prioritized

1. **Fix 16-bit fixture diversity:** benchmark full 16-bit spread (varying low and high bytes) and also realistic photograph-like distributions, retaining original 8-bit-expanded pattern as an explicit separate cohort. Use independent oracle and checksums to compare both direct and LUT.
2. **Rerun with paired raw times** and ≥2–3 independent process repetitions for 256, 1024 and 2048 square inputs and masks/layouts. Record thermal/frequency/affinity/governor and compiler build flags. Retain raw per-round times, medians, dispersion and preparation memory.
3. **Optimize scalar direct mapping** with compiler-appropriate `pow`/intrinsic or a mathematically special-cased gamma=1,2 path, with independently verified rounding at integer half-code boundaries. Do not silently weaken numerical behavior to get speed.
4. **Compare semantically equivalent implementations**, including Clang C++ (same quantization, ROI, channel selection, alpha/mask semantics and full-image checks), and separate direct arithmetic from `raster-d` view/stride/bounds overhead. Do not compare against a naive C++ raw-pointer loop and call it parity.
5. **Investigate ownership and working-set evidence** before public source/destination APIs; this benchmark does not prove alias or late-failure safety.

**Disposition:** strong *native exploratory* reason to continue a prepared-LUT fast path, **not** a public API/performance-freeze decision. Issue #88 remains open and Draft PR #87 remains draft.
