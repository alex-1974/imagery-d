# M3 RGBA — independently replayed XPS extracted-library performance regression

**2026-10-16 · Design Issue #75 · Draft PR #73 · research-only.**

**Disposition: ADAPT (codegen investigation required).** The independently
linked research B producer is **byte-correct and fault-qualified**, but it is
**NOT performance-qualified** relative to the original private fused
whole-owned producer. The reported local +5% investigation threshold is
crossed in **39/40** cases. No production API admission, public names,
package promotion, merge, release, or general throughput claim.

## Exact original evidence and independent replay

User-supplied archive **`20261016T130848Z.tar.gz`** has archive SHA-256:

`d27ea9378f145da535774628d264bee2c1bcb72d6d79c7959dd74e91dc11ce1c`

The terminal capture in `Eingefügter Text(20261016-131330).txt`
records successful native `--smoke` and `--micro` stages and
`M3 OWNED LIBRARY XPS PASS`. The archive itself includes the
**original executable**, build log, raw CSV, summary, complete pinned
source snapshot, native per-case resource logs, stderr, environment
and source provenance. Independent replay did **not** execute that
supplied binary or rely on the bundled summarizer.

- XPS-15, Intel **Core i7-9750H**, Linux **6.17.0-22-generic**,
  LDC **1.43.0 Release**, DUB **1.42.0**.
- Measured imagery-d **`28211cd4fdd367abe8ea318c5f20c523fa5b8cc1`**.
- Pinned raster-d **v0.2.0**
  `2f2415851e45001df92ce56dad409f680684ba8d`.
- Pinned color-d **v0.2.0**
  `3359f08f4e83941ac1a8451cadefb146b5736019`.
- Original measured `m3-owned-library-consumer`
  size **1,716,432 B**, SHA-256
  `4e8cd4ddf5d82162f6bd30f1dc5f31b3a19c86b9229f29787a633caa04a72afe`.
  The byte identity is independently checked against the **ORIGINAL**
  archived manifest. Note that a single binary size is **not** a
  controlled code-size comparison against earlier different builds.

**Independent strict verification:**

- **43/43 original manifest files** match their SHA-256, including the
  exact original executable. No missing or mismatched entry.
- **40/40** expected micro cases exist: encoded-straight/linear-PM,
  mixed/transparent, source planar/interleaved, five ROI sides 16–256,
  based on 512×512 source fixtures.
- **840/840** positive full-call timings: 40 cases × 7 rounds ×
  **three fully owning stage variants** × 24 iterations, preserving
  exactly the recorded **rotating stage order**. All stages produce,
  publish and retire complete owned packed results inside timed work.
- **40/40** reconstructed **21-column** `LIBRARY_COMPARISON.csv`
  rows match the supplied derived file **exactly at six decimals**
  (without importing its implementation).
- **20/20** canonical output checksum groups match between
  planar/interleaved sources and all within-case rounds/stages.
- **40/40** stderr files empty; all 840 recorded current-thread GC
  byte deltas are zero. This does **not** establish zero native
  allocations, allocator metadata, process RSS or concurrency safety.
- **All five GitHub workflows** for this **exact measured source SHA**
  are **SUCCESS**, including the DMD 2.112.1/2.113.0 and
  LDC 1.42/1.43 RGBA consumer jobs in Debug/Release,
  the independently compiled owner consumer, and its actual
  native malloc/import fault matrix.

This constitutes a complete native research **regression finding**,
not a successful performance admission.

## Whole-owned paired ratios: extracted library versus PRIVATE fused

**Method:** Each case contains seven **same-round**
`owned_extracted_library / owned_fused_checked` timing ratios;
take their median. Each cohort below takes the median of its
**ten case medians**. The 7.8 ns/pixel differences similarly
come from case-specific **paired timing differences**,
not from subtracting independently pooled population medians.

| Input meaning | Alpha pattern | Library/private paired ratio | Relative regression | Median paired library−private ns/pixel | Cases >1.05 |
|---|---|---:|---:|---:|---:|
| Encoded sRGB / straight | mixed | **1.091172** | **+9.12%** | **+7.832** | **10/10** |
| Encoded sRGB / straight | fully transparent | **1.307473** | **+30.75%** | **+7.809** | **10/10** |
| Linear sRGB / premultiplied | mixed | **1.085019** | **+8.50%** | **+7.809** | **9/10** |
| Linear sRGB / premultiplied | fully transparent | **1.243223** | **+24.32%** | **+7.779** | **10/10** |

Across all cases, the median paired extra time is **+7.797
ns/pixel**; the case-specific paired ratio ranges
**1.038154–1.371389**. **39/40** case medians exceed the
preregistered +5% *investigation trigger*. No claim is made
that this threshold predicts exact performance on another host.

**Internal paired old control (same new binary):**

| Meaning / pattern | Private-fused / old | Extracted-library / old |
|---|---:|---:|
| Encoded straight / mixed | 0.999095 | **1.093129** |
| Encoded straight / transparent | 1.000104 | **1.298831** |
| Linear-PM / mixed | 0.994928 | **1.082844** |
| Linear-PM / transparent | 1.030312 | **1.280978** |

The private fused variant broadly reproduces its previous
fast behavior as a same-run internal control, while the
extracted library shows an additional roughly **7.8 ns/pixel**
increment for *every* semantic cohort. Transparent images
therefore have larger percentage regressions because their
original total processing cost is lower.

These paired comparisons are **inside one compiled binary**.
They do not conflate the older `58a122e...`
four-mask XPS run with new cross-commit interleaving.

## Direct machine-code finding from the ORIGINAL release executable

Read-only `nm` + `objdump` examination on the original
unstripped ELF, **without executing untrusted code**, identifies:

- Private `app.tryCompositeOwnedPackedResearch`
  at **0x2c190**, 0x930 bytes. Its inner packed-result
  processing region near **0x2c6b4–0x2c7db** loads
  the four component bytes through directly generated
  address arithmetic and stores the packed 32-bit result
  directly. There are **no `trySample`/`trySetSample`
  function calls in this inner loop**.
- Extracted `imagery.presentation.owned.tryCompositeOwnedRgbaResearch`
  at **0x734d0**, 0x408 bytes. Its inner packing loop
  near **0x7376a–0x7383e** executes **four calls to**
  `RasterView!ubyte.trySample` at
  **0x73790, 0x737bc, 0x737df, 0x73802** and
  **one call to**
  `WritableRasterView!SRgba8.trySetSample`
  at **0x73827** for each packed pixel.
- The LDC optimizer did **not inline these five raster view
  accessor operations** into the new separately compiled
  module's inner loop as it did for the original private
  same-consumer version.

This is concrete code generation evidence consistent with
the roughly constant +7.8 ns/pixel penalty. It does **not**
by itself isolate the exact fraction caused by call overhead,
bounds checks, instruction cache, object layout, or link-time
optimization. Timing plus source-level similarity alone
would **not** prove the root cause; controlled codegen
A/B evidence is the next step.

Do not claim that having a separate library *in principle*
must be slower. Do not bypass raster-d public safety or
view/error contracts using raw pointers or `@trusted`
merely to remove calls. The math/ownership API must remain
independently linkable.

## Bounded next experiment — before considering public admission

1. Keep the original `28211cd4...` source and archived
   binary as **immutable negative performance reference**.
2. Inspect whether LDC 1.43.0 supports a **targeted
   link-time optimization/inlining mode** that acts across
   the DUB library-consumer boundary. Verify the actual
   compiler invocation, dependency build and final link:
   do **not** assume a flag attached only to the final
   executable optimizes separately compiled dependencies.
   If trialling LTO, preserve the full DMD/LDC correctness
   and native fault matrix and record linker/object flags.
3. With a genuinely comparable release binary, check
   whether the five per-pixel calls are eliminated.
   Record `.text` size/instruction-call differences and
   any new allocation/GC changes. Disassembly explains,
   but does not replace, whole-owned timing.
4. Run the **existing unchanged** 40-case
   `--owned-library-bench` XPS protocol in the controlled
   build and compare **same-run paired library/private
   per-case ratios** under the original workload.
   Preserve exact source/flags/binary SHA and original
   independent pixel oracle.
5. If no improvement, isolate the pack stage with a
   **research-only** scoped timing control; do not import
   a second production packer, bypass semantics or
   generalize `raster-d` ownership machinery.

**Hard gate:** Any codegen control that cannot show the
same all-pixel equality, preflight-before-malloc, native
pre/postcommit ownership dispositions and complete-on-publication
is **not** a valid faster replacement.

**Decision:** RESEARCH ADAPT. Candidate-B ownership remains
the conditional conceptual choice from Issue #75, but this
extracted implementation is **performance blocked**.
PR #73 stays OPEN/DRAFT on its grandfathered stacked base.
No public module admission, API freeze, merge or release.
