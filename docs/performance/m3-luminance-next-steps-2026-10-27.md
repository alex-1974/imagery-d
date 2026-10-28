# RGB luminance stretch — next optimization investigation

**Status:** local diagnostic evidence; this is not a portable performance claim.

- Date: 2026-10-27
- Base revision: `2755d092afc603fa658cad2246a66cd30363e7c1`
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- DUB: 1.40.0
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Linux x86-64, Intel Core i7-9750H; CPU 0 pinned, `powersave`
- Method: release perf consumer, 1920 × 1080 RGB8, two process runs per
  variant, each with two warmups and seven timed 12-call batches. The source
  was compiled twice from the same revision, changing only the LDC inline
  pragma on the four-pixel transform helper.

## Implemented: inline the LDC four-pixel helper

LDC Release retained a call from the per-pixel loop to
`transformFourPixels`. Its body processes four pixels, so the call happened
once for every four pixels. The implementation now forces this private helper
inline only for LDC. DMD and the generic scalar tail are unchanged.

| Workload | No pragma, mean of 2 run medians | Inline, mean of 2 run medians | Latency change |
|---|---:|---:|---:|
| 1080p, no mask | 56.328 ms | 52.370 ms | −7.0% |
| 1080p, mask | 58.500 ms | 52.850 ms | −9.7% |

The per-process pairs were 55.687/56.970 ms versus 52.829/51.911 ms
unmasked, and 58.746/58.253 ms versus 53.484/52.215 ms masked. The masked
and unmasked runs were interleaved. The resulting 52–53 ms still misses the
33.3 ms serial 30-fps budget. Treat the size of the gain as host-specific;
the host was not frequency-locked.

The assembly confirms that `transformFourPixels` disappears as a callable
symbol in the LDC candidate. Calls to `encodeSrgbFromTable` remain in the hot
path, so this change removes one level of call overhead but does not make the
channel lookups or output encoding vector operations. This is the next
measurement target. The D `pragma(inline, true)` contract is implementation
defined in cases where a function cannot be inlined, so the pragma stays
confined to the small private helper and the LDC build matrix must keep
checking it.

## Pass attribution and remaining costs

A fresh legacy `--pass-attribution` diagnostic in the same session reported
37.2 ms for the masked histogram, 186.9 ms for the transform, and 183.5 ms for
the complete operation. Its separate staged diagnostics measured 71.2 ms for
decode/luminance/scale and 84.0 ms for table encode/output writes. Those pass
times were internally inconsistent and are not a valid cost breakdown. The
direct instrumentation follow-up measured the actual histogram and transform
inside the owned-result call; see
[direct phase attribution](m3-luminance-direct-phase-attribution-2026-10-28.md).

A later candidate-only full-API run measured 64.8 ms unmasked and 107.7 ms
masked. At that time another workspace process (`png-bench-ldc2`) was using a
full CPU across the same allowed CPU set. Discard those values; they are direct
evidence that cross-workspace load contaminated this session's diagnostics.
The paired inline comparison above remains a local lead, not release evidence.

The latest transform probe counted the sRGB table work and found two dynamic
bounds checks per output channel. The LDC-only pointer lookup removed those
checks while retaining the existing range and table-size invariants. It passed
the independent byte oracle and reduced complete-call counters and latency in
both process orders; see the
[counter-backed result](m3-luminance-transform-codegen-2026-10-28.md).

The normalized LDC encoder experiment was carried out on 2026-10-28; see the
[follow-up measurement](m3-luminance-normalized-encoder-2026-10-28.md).

The follow-up vector-reciprocal experiment was rejected after paired complete
operation runs; see the
[measurement and result](m3-luminance-reciprocal-scale-2026-10-28.md).

The eight-pixel LDC kernel was then measured against the four-pixel baseline;
see the [paired result](m3-luminance-eight-pixel-kernel-2026-10-28.md).

The default-target eight-lane path is emitted as scalar XMM operations and
indexed color-table loads. A scalar-unrolled alternative passed the image
oracle but was slower in the reversed-order complete-call comparison and was
discarded. The bounds-check change was retained, then superseded by a dense
direct sRGB lookup in the LDC vector path. An ABBA full-owned-call comparison
reduced serial latency by about 22% and brought both masked and unmasked 1080p
medians to about 25 ms; see the
[direct-lookup measurement](m3-luminance-direct-srgb-lookup-2026-10-28.md).

## AVX2 assessment

The i7-9750H supports AVX2, and an isolated LDC `Vector!(float[8])` probe
produced YMM instructions with `-mcpu=skylake`; a default x86-64 build lowered
the same operation to two XMM operations. This proves the compiler can emit
the wider operation, not that the image kernel benefits from it. The tested
production path uses eight-pixel groups followed by four-pixel groups and a
scalar tail, and compiling the whole
consumer for Skylake also changes code throughout every dependency. Full-API
runs during this investigation varied by more than 20% between process
medians, with the target-specific binary not consistently faster. There is
therefore no performance evidence to ship AVX2 or to make it the package's
default target.

The D vector specification explicitly says vector support depends on the
compiler target and that the compiler does not insert CPU-feature runtime
checks. A portable wider-kernel follow-up needs an explicit runtime dispatch
and a tested fallback, plus a paired complete-API win. LLVM's vectorizer
documentation also notes that gather/scatter vectorization can be rejected by
its cost model, which is relevant because this kernel performs indexed color
table lookups. Sources: [D vector extensions](https://dlang.org/spec/simd.html),
[LLVM auto-vectorization](https://llvm.org/docs/Vectorizers.html), and
[D inline pragma](https://dlang.org/spec/pragma.html).
