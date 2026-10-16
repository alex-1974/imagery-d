# M3 RGBA — independent ThinLTO XPS audit (2026-10-16)

**Disposition: THINLTO DOES NOT REMOVE THE HOTLOOP ACCESSOR CALLS; extracted B producer remains PERFORMANCE BLOCKED.**
Research-only, Design #75, Draft PR #73. No public API acceptance, merge,
release, new raster-d/color-d requirement, or universal speed claim.

## Original immutable evidence

The user's uploaded original export
`m3-owned-library-thinlto-20261016T140156Z.tar.gz`
has archive SHA-256:

`85233a2ead2623bd68f4b55664b37046e93cf242af6eced188961e55406a6bce`

Its original environment records:

- Measured imagery-d **`430cbe01cd34e21a8dd5bc5d5423f2cd7e82d15d`**,
  branch `research/m3-rgba-layer-compositing`.
- LDC **1.43.0**, Release, library **and** consumer compiled
  `-flto=thin`, linker `--linker=lld`. The **actual archived
  `build.log`** contains three LDC commands with `-flto=thin`
  (library, consumer, link), and `--linker=lld`; this is not just
  a user-declared build label.
- Native XPS-15, Intel i7-9750H, Linux 6.17.0-22-generic,
  DUB 1.42.0, originally completed 2026-10-16 around 14:02 UTC.
- Pinned raster-d v0.2.0 SHA
  `2f2415851e45001df92ce56dad409f680684ba8d`;
  pinned color-d v0.2.0 SHA
  `3359f08f4e83941ac1a8451cadefb146b5736019`.
- Exact original measured executable
  `m3-owned-library-consumer` **1,643,560 bytes**,
  SHA-256 `689f6d10ff8a49a87640c19ab446a95797f32f16a4c982d57f89f5c76ee90cd9`.
  These are verified **inside** the original SHA manifest.

For descriptive comparison, the earlier **NON-LTO** original export
`m3-owned-library-20261016T133936Z.tar.gz`
has archive SHA-256
`44cfda04de1c9be34ee5bf5ce89caaa9b5925c1095c692cb6f56b2f1c277097b`,
measured repository source
`fceb413fdf8fc26734309e60896d41a4407f672c`,
and measured executable SHA-256
`4e8cd4ddf5d82162f6bd30f1dc5f31b3a19c86b9229f29787a633caa04a72afe`,
1,716,432 bytes. Source commits and sessions differ;
do NOT call the two-build values directly paired.

## Independently verified full results

A fresh Python replay reads each archive with `tarfile`,
`hashlib`, `csv`, and `statistics`, without executing the
original executable or importing bundled analyzer logic:

- ThinLTO **44/44** original SHA-256 manifest members, including
  `CODEGEN_CALLS.json` and actual executable: PASS.
- NON-LTO **43/43** original manifest members: PASS.
- Each run **40/40** defined source meaning/pattern/layout/ROI cases,
  **840/840** raw positive full-owned timed records
  (7 rounds × 3 rotated stages per case; 24 iterations).
- Reproduced **40/40** complete **21-field** summary CSV rows
  **exactly** at six decimal places, independently for each
  archive. All **20** cross-layout checksum groups agree, 40
  stderr files empty, all observed per-thread GC byte deltas 0.
  These are NOT absolute native-allocation or RSS guarantees.
- Independently verified the ThinLTO codegen JSON's ELF SHA/length.
  **Read-only `nm` and `objdump`** of that exact original
  ThinLTO ELF likewise confirm retained static calls in the
  extracted packing loop at addresses 0x114910,
  0x11493c, 0x11495f, 0x114982
  (four `RasterView!ubyte.trySample`) and
  0x1149a7 (one `WritableRasterView!SRgba8.trySetSample`).
  The private optimized packing loop contains none of these
  accessor call sites. Thus ThinLTO genuinely built/linked,
  **but did not achieve the hypothesized cross-module inlining**.

### Within-run paired whole-owned speed

For each case, the ratio is the median of seven same-round
`owned_extracted_library / owned_fused_checked` full-owned
durations. Each cohort median is over ten case medians
(two source layouts × five square ROIs). Paired absolute
deltas are calculated per case, then per cohort.

| Input meaning / alpha | NON-LTO library/private | ThinLTO library/private | NON-LTO added ns/px | ThinLTO added ns/px | ThinLTO cases >1.05 |
|---|---:|---:|---:|---:|---:|
| Encoded straight / mixed | 1.091856 | **1.071454** | +7.747 | **+6.228** | 10/10 |
| Encoded straight / transparent | 1.309864 | **1.258855** | +7.723 | **+6.300** | 10/10 |
| Linear PM / mixed | 1.087715 | **1.066716** | +7.814 | **+6.270** | 9/10 |
| Linear PM / transparent | 1.234185 | **1.193174** | +7.648 | **+6.280** | 10/10 |

**39/40 ThinLTO** case medians breach the registered +5%
*investigation* threshold. ThinLTO ratio range across the
40 cases: **1.044920–1.356589**. The lower observed extra
~6.3 ns/pixel is encouraging but not acceptance.

Binary-size observation: Non-LTO 1,716,432 B vs ThinLTO 1,643,560 B
(**−4.25%**). ELF `.text` (read-only `readelf`)
681,440 B vs 676,872 B (**−0.67%**). These sizes refer
to different full builds, not isolated one-function costs.

**Science limit:** The two builds are sequential separate
sessions on different source commits
(`fceb413...` vs `430cbe...`). Each build's three
timing stages **are** internally same-round paired, but
the cross-build differences are descriptive, not an
unconfounded A/B causal estimate.

## GitHub CI discrepancy at measured commit

At exact measured source **`430cbe01...`**, four of the
five GitHub workflows completed SUCCESS. The fifth,
`M3 decoded RGBA source-over consumer`, completed
**FAILURE**, because its **LDC 1.43.0** job exited
immediately at the start of the step
`LDC 1.43 pinned ThinLTO library and archive smoke`:
the script first checks `command -v ld.lld`,
which was unavailable on that runner. The DMD 2.112.1 /
2.113.0 and LDC 1.42.0 RGBA consumer jobs passed.
The ThinLTO-specific CI fault matrix therefore was
**not** reached on this runner. The measured XPS with
matching installed `lld` completed its native full run;
that local evidence does NOT retroactively turn the
GitHub CI gate green.

A narrowly scoped CI-only follow-up after this
measured source provisions signed LLVM **22**
`lld-22` (consistent with LDC 1.43's LLVM 22
prebuilt packages) **only for the LDC 1.43 research job**,
without altering the host default system linker or any
other workspace repository. That follow-up's CI result
must be checked independently; this record does NOT
assert it passed.

## Decision / next discriminating experiment

**RESEARCH ADAPT / PERFORMANCE BLOCKED.** The
non-LTO performance problem is reproduced even under
genuine ThinLTO. Do **not** promote this separate
owned B implementation to the production package.
Keep the accepted output ownership semantics and
native failure invariants, but test a narrowly
scoped **raster-view accessor/POD packing specialization**
that preserves public released raster-d read/write
contracts and does not introduce raw-pointer bypasses,
custom refcounts, cache owners or new public APIs.
A valid alternative must independently prove
compiler/runtime safety, exact RGBA byte parity,
early PM rejection, real native fault handling,
and matched whole-owned end-to-end performance.

The historical original XPS evidence and grandfathered
Draft PR #73 remain unmodified. No API freeze,
merge or release.

Machine-readable reviewer artefacts (conversation uploads):
`m3_rgba_thinlto_20261016_independent_metrics.json`,
`m3_rgba_thinlto_20261016_independent_40_cases.csv`,
`audit_m3_thinlto_20261016.py`,
and the Markdown audit.
