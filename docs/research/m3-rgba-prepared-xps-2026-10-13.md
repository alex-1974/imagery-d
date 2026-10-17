# M3 RGBA — Prepared runtime-opacity four-plane XPS qualification

**Measured UTC:** 2026-10-13T19:14:22+00:00 (Europe/Vienna: 21:14:22 CEST).  
**Research-only evidence:** no production API, ABI, release, or general alias guarantee
admitted. **Write scope: imagery-d only**; sibling libraries read-only.

## Evidence, exact source and independent verification

**Uploaded raw archive:** `prepared-20261013T191421Z.tar.gz`.
Compressed archive SHA-256:

```text
b4926b520fa9e0771d1d815c29812cabe9b71d64fa5edbda20d66fd7dba73551
```

The uploaded archive includes the 24 original scenario CSVs,
`STAGE_SUMMARY.csv`, `CHECKSUMS.sha256`, build/environment logs,
per-process resource reports and stderr files. The separately pinned
source snapshots were deliberately excluded from this archive.
All summary medians and case pair ratios were **independently recomputed
from the raw case CSVs**, not accepted merely because the summary
file said they were valid.

| Item | Observed value |
|---|---|
| Machine | `xps-15`, Intel i7-9750H (6 cores/12 threads, x86-64, AVX2), Ubuntu Linux 6.17.0-22-generic |
| **Measured imagery-d source** | `9391c83ad027be70b6e67ce990cf44f550bb8a84`, branch `research/m3-rgba-layer-compositing` |
| **Measured raster-d** | tagged **v0.2.0**, SHA `2f2415851e45001df92ce56dad409f680684ba8d` |
| **Measured color-d** | tagged **v0.2.0**, SHA `3359f08f4e83941ac1a8451cadefb146b5736019` |
| Toolchain | LDC **1.43.0** (frontend DMD 2.113.0, LLVM 22.1.8), DUB 1.42.0 |
| Source/build mode | `pinned-v0.2.0`, `smoke=0`; `git archive` from **committed** imagery HEAD and both tagged sibling commits; LDC release build once, then direct executable invocation under `/usr/bin/time -v` |
| Raw CSV checksums | **24/24** SHA-256 manifest entries PASS |
| Cases | **24/24**: 2 sizes × 3 alpha patterns × 2 four-plane layouts × 2 ROI modes |
| Timed rounds | **108/108**: 512² has 5 rounds per case; 1024×768 has 4 rounds per case; every round comprises **8 stage measurements** |
| Complete timed stage records | **864/864**; derived summary **192** stage medians; all stage columns and per-round sets verified |
| Output oracle | all 24 `HOTPATH-STAGES PASS` markers; all outputs checked pixel-by-pixel against unchanged packed color-d pipeline and both four-plane treatments, before/after every timed round; all 12 corresponding planar/interleaved case-pair canonical checksums identical |
| Runtime allocation | **0** measured `GC.stats().allocatedInCurrentThread` byte deltas for all stage calls (not a native allocation or per-operation RSS audit) |
| Faults/logging | **24/24** stderr files empty; all processes report **0 major page faults** and **0 swaps** |
| Build diagnostics | Only nonfatal `mir-core 1.7.4` `LLVM_version` deprecation warnings, release build/link successful |

The user's *live* imagery working tree was reported dirty, but the
runner used **only the committed imagery HEAD**. Sibling repository
worktrees had pre-existing untracked research work and **were not
switched, cleaned, staged or modified** by this pinned runner.
The live raster-d checkout differed from the measured v0.2.0 release
(`1ea67cb6...` versus `2f241585...`); do not conflate them.

### Exact workload and measurements

This revised 8-stage [stage-attribution consumer](
../../experiments/m3_rgba_layer_compositing/hotpath/source/app.d)
introduces one new full execution stage:

- `fourplane_full`: unchanged original
  `tryCompositeRgbaSourceOver`, straight encoded RGBA8
  input, runtime opacity **0.37**, source and output caller-owned
  `RasterLease!ubyte`, publicly checked four-plane access.
- `prepared_fourplane_full`: the new **scoped**
  `ResearchPreparedRgbaContext`, containing a runtime-created
  `double[256]` encoded-byte sRGB decode table and validated
  runtime opacity **0.37**, passed `ref const` on every call with
  newly borrowed input/output views. Uses the same four-plane raster
  leases, dimensions, layouts and output type as the direct baseline.

Unlike the prior packed-array and `raster.zipTransformInto`
benchmarks, **both full paths here have the same research four-plane
caller-nonoverlap precondition** and classified image error
semantics, including prewrite invalid-PM validation. **Neither
performs the physical alias preflight** of public raster zip;
we cannot transfer that guarantee from unrelated measurements.

The same independent mathematical color-d stages run as additional
diagnostic controls. The stage timings are **not additive**.

Per-process setup and exact output verification occur **outside**
timed hotloops; each timed stage is invoked for **2 complete
ROI iterations**. After every round both complete color paths
are recomputed and checked against the packed and staged color
oracle. This is **differential equivalence for tested successful
fixtures**; it does not re-run the separate 432-scene negative
and numerical corpus, or prove every possible opacity and
exceptional failure during the actual XPS timing.

Input classes: **mixed** alpha (0,128,255), **opaque**, and **fully
transparent with nonzero hidden RGB**. Four-plane layouts:
**planar and interleaved**. ROI is whole image or a near-full
offset rectangle; it is not a 16²–128² viewport. Exact source
is pinned to commit `9391c83`, not the prior 7-stage run.

## Full four-plane A/B result

For every size × pattern, below are the **medians of the four
individual case medians** (planar/interleaved × whole/partial),
in nanoseconds **per ROI pixel per single call**.
The acceleration factor is the median of the four
**within-case paired-round ratio medians** (direct elapsed time /
prepared elapsed time), not an unpaired aggregate median quotient.

| Image size | Pattern | Direct four-plane ns/px | Prepared four-plane ns/px | Paired throughput ratio |
|---|---|---:|---:|---:|
| **512²** | **mixed** | **213.92** | **110.90** | **1.923×** |
| 512² | opaque | 204.61 | 106.50 | **1.906×** |
| 512² | transparent, hidden RGB | 149.71 | 43.18 | **3.481×** |
| **1024×768** | **mixed** | **199.61** | **103.63** | **1.933×** |
| 1024×768 | opaque | 206.08 | 109.09 | **1.923×** |
| 1024×768 | transparent, hidden RGB | 149.95 | 43.16 | **3.455×** |

Thus, on these **representative mixed-alpha four-plane
consumers**, prepared sRGB8 decoding reduces measured whole
operation time approximately **48%** (and increases throughput
about 92–93%). This result is smaller than the previous
~**2.5× packed raster zip** gain; these are different
executable/pixel-storage/error/alias contracts, **not a
controlled head-to-head comparison**.

For both-alpha-zero inputs, final alpha-zero
canonicalization makes output encoding inexpensive,
so eliminating repeated *input* sRGB decode has
a stronger, domain-specific payoff. **Do not market
3.5× as typical** mixed-alpha behavior.

**All 108/108 individual paired direct-vs-prepared timing
rounds favor prepared.** The full paired-ratio range is
**1.707× to 3.643×** (mixed/opaque and transparent
cases combined); no native clock/thermal-normalized
confidence interval was measured.

### Full-frame mixed-alpha examples

The reported per-pass milliseconds are reconstructed
from paired round medians for a **single full frame**, i.e.
after dividing the round elapsed time by its two iterations.
They exclude one-time context creation.

| Size | Four-plane layout | Direct full frame | Prepared full frame | Paired median ratio |
|---|---|---:|---:|---:|
| 512² | interleaved | **56.41 ms** | **29.15 ms** | **1.941×** |
| 512² | planar | **55.46 ms** | **28.99 ms** | **1.936×** |
| 1024×768 | interleaved | **156.18 ms** | **81.21 ms** | **1.932×** |
| 1024×768 | planar | **163.40 ms** | **84.34 ms** | **1.942×** |

These are **kernel-only single-thread observations**, not
renderer/display frame rates or the cost of loading/uploading
an image.

### Prepared setup cost, reuse and break-even limitations

The full prepared context owns **256 `double` channel
values (2048 numeric payload bytes)** and finite runtime
opacity, plus a ready flag; it does **not** retain raster
views or an image owner.

Measured **one-time preparation** (`prepared_init_us`
in the case PASS trailer): **18 µs median** over all
24 processes, **16–23 µs range**.

It is excluded from the timed per-pixel stage. Within
the measured whole-/near-full-frame workloads it is
small compared with the observed roughly
**100 ns per-pixel** saving. A rough algebraic
division suggests ~**180 pixels** to amortize one
setup on this CPU under the same cost model;
**that is NOT a measured small-ROI crossover**.
Different cache conditions, call overhead, failure
preflight and a new prepared session frequency can
change the economics. Reusing one context for
multiple ROIs matters more than an unqualified
single-image ratio.

Unlike the prior immutable process-global
`zipTransformInto` LUT probe, this value is
**caller-owned**, can carry **arbitrary validated
runtime opacity**, and stores **no borrowed owner
or image view**. These are distinct capability
claims. Physical source/output alias safety has
**not** been added by this change.

## All 24 independently observed case medians

Direct and prepared columns are **ns per ROI pixel and per invocation**,
calculated from raw round medians. Ratio is the **median of
the paired round-level direct/prepared elapsed-time ratios**,
not necessarily the quotient of the two displayed medians.

| Size | Alpha | Four-plane layout | ROI | Direct ns/px | Prepared ns/px | Paired ratio |
|---|---|---|---|---:|---:|---:|
| 512² | mixed | interleaved | partial | 214.56 | 111.76 | 1.908× |
| 512² | mixed | interleaved | whole | 215.20 | 111.19 | 1.941× |
| 512² | mixed | planar | partial | 213.28 | 109.11 | 1.910× |
| 512² | mixed | planar | whole | 211.57 | 110.60 | 1.936× |
| 512² | opaque | interleaved | partial | 208.04 | 107.63 | 1.909× |
| 512² | opaque | interleaved | whole | 200.81 | 105.36 | 1.904× |
| 512² | opaque | planar | partial | 201.19 | 105.22 | 1.897× |
| 512² | opaque | planar | whole | 218.18 | 112.33 | 1.944× |
| 512² | transparent | interleaved | partial | 147.97 | 41.94 | 3.532× |
| 512² | transparent | interleaved | whole | 150.60 | 42.96 | 3.523× |
| 512² | transparent | planar | partial | 148.82 | 43.40 | 3.439× |
| 512² | transparent | planar | whole | 154.03 | 46.83 | 3.285× |
| 1024×768 | mixed | interleaved | partial | 200.54 | 103.58 | 1.933× |
| 1024×768 | mixed | interleaved | whole | 198.60 | 103.27 | 1.932× |
| 1024×768 | mixed | planar | partial | 198.69 | 103.67 | 1.916× |
| 1024×768 | mixed | planar | whole | 207.78 | 107.24 | 1.942× |
| 1024×768 | opaque | interleaved | partial | 209.63 | 109.04 | 1.927× |
| 1024×768 | opaque | interleaved | whole | 202.52 | 109.15 | 1.898× |
| 1024×768 | opaque | planar | partial | 200.68 | 104.16 | 1.919× |
| 1024×768 | opaque | planar | whole | 211.65 | 111.42 | 1.928× |
| 1024×768 | transparent | interleaved | partial | 154.23 | 42.81 | 3.602× |
| 1024×768 | transparent | interleaved | whole | 149.19 | 43.07 | 3.458× |
| 1024×768 | transparent | planar | partial | 149.09 | 43.25 | 3.452× |
| 1024×768 | transparent | planar | whole | 150.71 | 46.07 | 3.271× |

The partial ROIs cover **249,996 of 262,144 pixels**
at 512² and **764,556 of 786,432 pixels** at 1024×768.
These are near-full, offset regions and do not establish
a small-viewport break-even for the prepared four-plane API.

## Memory/system limitations

- **CPU governor `powersave`** on all 12 logical processors;
  no frequency/time/thermal trace or affinity pinning.
- Recorded host startup `MemAvailable = 4,417,248 kB`,
  `SwapFree = 276 kB` of 4,194,300 kB swap;
  nearly full swap *space* does not imply the
  measured process swapped.
- **All 24** `time -v` processes recorded **zero
  major page faults and zero swaps**.
- Maximum resident set size across whole benchmark
  processes:
  - **51,596–51,816 KiB** at 512²
    (~50.4–50.6 MiB);
  - **147,872–148,264 KiB** at 1024×768
    (~144.4–144.8 MiB).
- **Not** a production working-set estimate:
  the stage harness retains many independent
  prepared color-stage arrays, packed input/output
  arrays and three four-plane RasterLeases in
  addition to D runtime and the 2 KiB table.
  Native per-call scratch maximum is not isolated.
- One real XPS session, no AArch64,
  independent repeat, perf counters,
  CPU frequency normalization or
  adversarial real-scene color distributions.
  Relative paired benefit is robust within
  the run, but do not set an absolute
  runtime regression threshold yet.

## Research disposition and next proof

**Qualified narrow finding:** Caller-owned prepared
sRGB8 LUT + validated runtime opacity **nearly halves**
the measured end-to-end four-plane color execution
time (roughly **1.9× throughput**) on the
tested mixed-alpha workload, **while preserving
the original four-plane research error contract
and its documented caller noalias precondition**.

**Remaining production gates:**

1. **Do not conflate alias contracts.** The
   faster ~2.5× physically alias-checked
   **packed raster zip** callback lacks
   runtime context and per-pixel checked
   error status; the new ~1.9× prepared
   **four-plane** callback supports runtime
   opacity and image error reporting but
   **does not independently prove physical
   noalias**. A production-ready combined
   interface is not demonstrated.
2. Negative/scoped-view lifetime and
   numerical 432-scene independent tests
   live in the existing research consumer.
   Preserve exact-source **four-compiler CI**
   for any later functional/semantic change.
   Native benchmark successful fixtures do
   not prove quantization-failure
   atomicity or alias checks.
3. Study **public-only raster primitives**
   for prewrite physical overlap certification
   and a contextful checked transform
   separately, with clear memory/lifetime/
   error semantics, before considering
   any new raster API or duplication of
   raster internals.
4. Measure real repeated **small scoped ROIs**
   with more than one opacity and
   non-encoded/PM input interpretation,
   logging one-time preparation and
   full-operation cost. The earlier micro-ROI
   zip results are only the narrow
   fixed-opacity packed path.
5. If performance is to be admitted,
   repeat in clock/thermal documented XPS
   sessions, inspect LDC code generation,
   and maintain separate native scratch/GC
   and metadata validation evidence.

**Policy:** Keep `research/m3-rgba-layer-compositing`,
stacked Draft PR #73 **OPEN** on Draft PR #69.
No production API or integration merge; **no
writes to `raster-d`, `color-d` or any other
sibling repository**.
