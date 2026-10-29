# RGB luminance stretch — normalized table encoder experiment

**Status:** paired local candidate evidence; not a portable performance claim.

- Date: 2026-10-28
- Base revision: `9dfd3c685ee50eccf646f5975b24fbcf2a95bd29`
- Compiler: LDC 1.42.0 (D frontend 2.112.1, LLVM 19.1.7)
- DUB: 1.40.0
- Dependencies: raster-d 0.5.5, color-d 0.3.0
- Host: Linux x86-64, Intel Core i7-9750H; CPU 0 pinned, `powersave`
- Build: `tests/perf_consumer`, Release, `--fullhd-only`

## Change

The four-pixel LDC kernel already clips RGB to `[0,1]` when `Clip=true`, and
rejects out-of-gamut values before encoding when `Clip=false`. It therefore
knows that all three output channels are normalized before sRGB encoding. The
general encoder still checked the lower and upper bounds for every channel.

The LDC four-pixel kernel now uses a specialized normalized encoder without
those checks. The per-call table includes a duplicate final entry, so exact
`1.0` can use the same interpolation formula and still access `index + 1`
safely. The existing range-checking encoder remains in the scalar tail. DMD
continues using its scalar path; the extra table entry duplicates the same
endpoint value and does not change its output.

## Measurement

Baseline and candidate binaries were built from the same source revision;
only the normalized encoder and extra endpoint differed. Runs were pinned to
CPU 0 and alternated baseline, candidate, candidate, baseline. Every process
used two warm-up batches and seven timed batches of 12 complete owned-result
calls. The machine was not frequency-locked.

| Workload | Baseline mean of 2 run medians | Candidate mean of 2 run medians | Latency reduction |
|---|---:|---:|---:|
| 1080p, no mask | 63.252 ms | 51.275 ms | 18.9% |
| 1080p, mask | 66.590 ms | 50.601 ms | 24.0% |

Raw unmasked medians were 62.243/64.261 ms baseline and 46.396/56.153 ms
candidate. Masked medians were 66.839/66.341 ms baseline and 54.761/46.441 ms
candidate. Process-to-process spread remains visible, but both candidate
results were below both baseline results in each workload. A preceding single
run measured 54.9/58.2 ms baseline and 45.8/46.9 ms candidate, in the same
direction.

The optimization does not reach serial 30 fps: its measured 1080p latency is
about 50–51 ms and the target budget is 33.3 ms. Treat these results as local
evidence for retaining the candidate, not a cross-machine guarantee.

## Validation and generated code

DMD 2.111.0 and LDC 1.42.0 Release unit tests passed. The independent
`verify_m4_luminance_stretch.py` oracle passed on both compilers: 24
serial/parallel cases, maximum one-byte error, four rejected requests, masks,
and constant-bin identity.

LDC Release disassembly has no call to the normalized encoder or the
four-pixel helper in the hot path. The only three calls to the general encoder
are in the scalar remainder loop. This confirms that the specialized lookup
formula is inlined and that range checks are absent from the four-pixel path.

## Next limit

The serial operation still misses 30 fps. This change removes the per-channel
range checks and lookup-helper calls, but table loads/interpolation, RGB table
decoding, luminance mapping, and division remain. The next experiment should
measure those operations separately without using the inconsistent staged
pass-attribution mode as a percentage breakdown. Any more complex SIMD or
lookup fusion should retain a portable fallback and pass the complete-API
paired benchmark plus the independent image oracle.
