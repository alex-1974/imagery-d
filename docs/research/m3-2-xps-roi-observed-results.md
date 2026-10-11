# M3.2.7 — XPS ROI measurements: source, lifetime and provenance audit

**Status:** XPS measurement and compiler evidence **VERIFIED for the supplied local state**;
released `raster-d v0.2.0` dependency equivalence and production performance
**NOT YET QUALIFIED**. No public API or release admission.

**Evidence date:** 2026-10-11 (UTC run timestamp `20261011T114836Z`).  
**Research PR:** [#37](https://github.com/alex-1974/imagery-d/pull/37)  
**Source commit actually measured:** [`0785fb7e37d4277fa0882ef212d20c29b6ec6bdf`](https://github.com/alex-1974/imagery-d/commit/0785fb7e37d4277fa0882ef212d20c29b6ec6bdf)  
**Worktree at measurement:** `imagery-d` clean (`imagery_dirty=0`); branch `research/m3-2-xps-roi-qualification`.  
**Host/compiler:** Dell XPS 15, Intel Core i7-9750H (6 cores/12 threads),
Ubuntu Linux x86-64, LDC **1.41.0** (DMD 2.111.0 frontend, LLVM 19.1.7),
DUB 1.40.0, release build. CPU `intel_pstate` with `powersave` governor;
OS-default affinity.

## 1. Evidence inventory and binary identity

The operator supplied the original files `roi-raw.csv`,
`environment.txt`, `correctness.log`, `binary.sha256`,
`timed-binary.sha256`, plus `relevant-symbols.txt` and
`disassembly.txt.gz` reviewed separately.

| Evidence | Recorded SHA-256 (file bytes) |
| --- | --- |
| `roi-raw.csv` | `ae741cfd66b07fe4bb989b2dfa8f7908503830d07dcb9ec2c8d4afa0a4c1d890` |
| `environment.txt` | `d04bd7b067eb09190b65c7322cd383df297202394eaf81a6c71f67938652456d` |
| `correctness.log` | `21a897f288fd410435648905089c1465c92c46b03d9f232ac247ef78f27ab8b9` |
| `binary.sha256` / `timed-binary.sha256` | Same manifest content, file hash `8958d661c4b9ce60b3d378871ba2a298fe8370e341260c1fce7a68f26c0fbfaa` |
| `relevant-symbols.txt` | `49e8be0736798e18cc045b06bf5718412ebb7f4c7c6365626abaa057a4c0bd05` |
| `disassembly.txt.gz` | `7e2f9d8db888d28db84db17138c0c645f8a23c789d6788e4a3f8492935110536` |

**Both binary manifests report the same executable SHA-256**:
`3a9e84273b358310ec363ee23ba331072eb0c9c92df9725ac9c01f77a65d37ef`.
Thus the runner recorded unchanged executable content between its
preflight and timed stages. The executable bytes were **not uploaded**;
this check compares the two recorded fingerprints and cannot independently
re-hash the actual binary or cryptographically bind the separately supplied
disassembly to those bytes.

Large raw evidence remains outside Git in accordance with workspace
quality/evidence retention rules. The hashes above permit identifying
the analyzed operator-supplied files without committing them.

## 2. Correctness, security and negative lifetime gates

The uploaded `correctness.log` verifies the **same local `ldc2` toolchain**
ran M3.2.6 positive functional tests in debug **PASS** and release **PASS**.
The six expected failures were separately emitted as real compiler errors:

- forbidden primary lease lifetime escape — rejected;
- forbidden validity lease lifetime escape — rejected;
- local immutable metadata escape — rejected;
- nested ROI escape — rejected;
- attempting the immutable fast factory with mutable-`const` metadata — rejected;
- outside-module construction of the validated capability without its
  private constructor — rejected.

This complements the previously successful GitHub DMD 2.111/2.113 and
LDC 1.41/1.43 matrix against the pinned released dependency. It does **not**
mean every compiler version was run on the XPS.

## 3. Complete paired timing corpus

The raw CSV contains **1,125 timing rows**, with five processes
× 15 rounds × five channel counts × three ROI modes.
All **375/375** paired cycles have one of each mode, all three distinct
slots, identical 50,000-iteration counts, and matching nonzero checksums.
All 375 paired comparisons measured the validated imagery ROI faster than
the revalidating imagery ROI. The paired runs are repeated measures,
**not** 375 independent host reboots.

**Median elapsed nanoseconds per ROI call** (75 samples per mode and
channel count). Speed ratio = median of the **paired** old/new ratios,
not a ratio of independent marginal medians.

| Channels | Direct `raster-d` | Revalidated image | Validated immutable image | Paired speed ratio | Median saved |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | 8.72 ns | 26.79 ns | 21.42 ns | 1.255× | 5.448 ns |
| 17 | 8.97 ns | 31.83 ns | 21.65 ns | 1.471× | 10.176 ns |
| 64 | 8.94 ns | 49.59 ns | 21.77 ns | 2.269× | 27.674 ns |
| 256 | 9.00 ns | 121.63 ns | 21.97 ns | 5.492× | 99.212 ns |
| 1024 | 8.69 ns | 605.10 ns | 21.22 ns | 28.640× | 583.688 ns |

At 1,024 channels, the five separate process-median speed ratios were
approximately **28.965×, 28.726×, 28.628×, 28.624×, 27.940×**.
At 64 channels, process 0 was notably slower in the revalidating path,
indicating some host/runtime drift. Complete paired distributions and
the raw CSV should be retained as operator evidence rather than
replacing them with the best single result.

The direct raster reference intentionally omits image-semantic validation;
it is a control for basic ROI work, not an identical semantic contract.
No image pixels are read inside the timed loops. Synthetic pixel
correctness, planar/interleaved and validity handling were verified in
the separate M3.2.6 functional tests.

## 4. Codegen correlation, not full binary attestation

The separately supplied x86-64 disassembly has three distinct
noinline benchmark wrappers (`rasterControl`, `conservativeControl`,
`validatedControl`). The conservative compound ROI contains a
backward per-channel semantic-ID comparison loop near addresses
`0x26400–0x26413`. The validated immutable ROI lacks that repeated
identity scan while retaining ROI/validity bounds checks.

The mechanism and the observed channel-count dependence are consistent:
old ROI latency rises with channel count; the immutable validated
candidate stays near 21–22 ns/call over the measured range.
No claim is made that *all* compiler optimizations or timing confounders
are excluded. Without the executable bytes and a cryptographic
disassembly manifest, the association is based on matching operator
file provenance and source context, not a byte-level attestation.

## 5. Dependency discrepancy: do not silently normalize

The XPS manifest identifies:

- local `raster-d` HEAD `1ea67cb6ffb2c887f78d160249a293ad74ba5cda`;
- local tag `v0.2.0` commit `2f2415851e45001df92ce56dad409f680684ba8d`;
- `raster_dirty=17` (`git status --porcelain | wc -l`);
- `raster_dependency_not_pinned=true`.

The local HEAD is **38 commits behind** the tag (an ancestor, not a
newer release). A read-only GitHub comparison of those two **tracked
published commits** found changes in documentation and comments.
All nine tracked source files changed between those refs, including
`source/raster/view.d`, compare equal after stripping comments and
whitespace in a source-text comparison. Therefore no differing D code
was found in those nine changed tracked source files.

**Follow-up worktree inspection received from the operator:**
`git status --short` contains exactly 17 `??` entries:
16 untracked executable-like artifacts under `benchmark/` and one
untracked `experiments/` directory. Both
`git diff --name-only` and `git diff --cached --name-only`
return **no paths**. Consequently no tracked `raster-d` sources,
DUB configuration, or other tracked files are locally edited or staged.
The untracked `experiments/` directory's contents were **not**
individually inspected; no stronger claim about its contents is made.

The independently fetched `raster-d` DUB manifest at the recorded
HEAD declares `sourcePaths "source"`. The observed untracked
`benchmark/` and `experiments/` paths lie **outside** that standard
library compilation source path. Thus there is **no observed local
tracked-source modification** and no indication that those untracked
artifacts were included in this ordinary DUB library build.

**Scope of resolution:** the original `raster_dirty=17` flag is
explained by untracked benchmark/research artifacts, not modified
version-controlled code. The ROI measurements' *local source-state
provenance issue* is resolved to that extent.

**What remains:** the dependency commit was still not the exact
`raster-d v0.2.0` tag, so this does **not** retroactively become a
pinned-tag benchmark. The comments-only tracked diff strengthens
source-level comparability but does not establish byte-identical
released binary artefacts. If pinning is required for promotion,
repeat against a separate clean `v0.2.0` checkout, preserving the
active sibling repository and its untracked experiments in place.

## 6. Decision and next gates

**Supported:** verified local XPS compiler/lifetime gates, matching
recorded executable hashes, complete paired control-plane timing
distribution, positive codegen mechanism evidence, and a substantial
measured ROI-construction advantage of the immutable validated variant.

**Not admitted:** a final `imagery-d` public `ImageView`/owner API,
an absolute release-performance threshold, a whole-image mapping or
decoder speedup, or performance parity against an unchanged pinned
`raster-d v0.2.0` baseline.

Required before admission:

1. **RESOLVED for tracked source:** operator status/diff output
   confirms only untracked `benchmark/` artefacts and `experiments/`,
   with no tracked or staged modifications. The DUB source path is `source`;
   the untracked directory contents were not individually inspected.
2. **STILL OPEN for strict release pinning:** if performance
   comparability to the release tag is required, repeat the benchmark
   with a separate, clean `v0.2.0` dependency (without touching the
   current local raster research worktree).
3. Measure explicit immutable-metadata preparation and its
   amortization/break-even reuse count; compare realistic consumer
   operations in which ROI time is only one component.
4. Retain compiler/lifetime gates and a codegen control at the exact
   candidate source revision for any public promotion.

**Verdict:** strong **observed XPS ROI microbenchmark evidence** with
the local dirty-worktree concern explained and no versioned-source
modifications observed. Strict **`raster-d v0.2.0` commit pinning,
consumer-level benefit and public API promotion remain OPEN**. Preserve
this research on PR #37 rather than merging stacked experimental
history wholesale into `develop`.
