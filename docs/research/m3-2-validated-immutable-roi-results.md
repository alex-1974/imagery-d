# M3.2.6 — Validated-once ROI over immutable semantics: results

**Status:** Focused correctness/lifetime and capability construction
qualification **PASS**; production admission **deferred**.  
**Date:** 2026-10-11  
**Repository:** `alex-1974/imagery-d`  
**Branch:** `research/m3-2-validated-immutable-roi`  
**Validated implementation head:** `0a87b2906c1fd2525d407cba1b764bcdc92f1a8a`  
**GitHub Actions:** [run 38135636627](https://github.com/alex-1974/imagery-d/actions/runs/38135636627), **4/4 successful jobs**  
**Earlier exploratory run:** [38135402914](https://github.com/alex-1974/imagery-d/actions/runs/38135402914), pixel/lifetime gates passed but **forge-capability check failed**, intentionally preventing admission  
**Platform:** GitHub-hosted Ubuntu 24.04, x86-64  
**Dependency:** released `raster-d` tag `v0.2.0`

## 1. Evidence matrix

| Compiler | Debug | Release | Primary/validity/metadata/ROI escape | Mutable `const` metadata refused | External validated-marker forgery refused |
| --- | --- | --- | --- | --- | --- |
| DMD 2.111.0 | PASS | PASS | 4/4 rejected | PASS | PASS |
| DMD 2.113.0 | PASS | PASS | 4/4 rejected | PASS | PASS |
| LDC 1.41.0 | PASS | PASS | 4/4 rejected | PASS | PASS |
| LDC 1.43.0 | PASS | PASS | 4/4 rejected | PASS | PASS |

Each compiler job emitted **two** positive semantic test results
(debug/release), **four** expected borrow-escape rejections, an expected
compile error when an ordinary `const(IntrinsicChannel)[]` and
`const(ChannelDescriptor)[]` were passed to the immutable-only factory,
and an expected compile error when outside code tried to fabricate the
validated type without going through its factory.

The negative runner checks the diagnostic's exact experiment source
location and the relevant error class; unrelated DUB/dependency/syntax
failures are not accepted as lifetime proof.

## 2. Semantics and scope established

- Synthetic 3-to-256-channel `float` resident raster data in
  `raster-d RasterLease` storage; layouts planar and pixel-interleaved.
- Optional same-grid independent `ubyte` validity.
- A new **research-only** `ValidatedImmutableImage` factory takes
  truly `immutable(ChannelDescriptor)[]` and
  `immutable(IntrinsicChannel)[]`. It validates descriptor count,
  semantic ID equality, raster plane count and validity region
  **once before publication**.
- On success, its child ROI calls the existing M1.5
  `ImageView.tryRoi` for region/validity checks, shares the identical
  intrinsic metadata slice and **does not rerun the cross-descriptor
  identity loop**.
- Nested and uneven partitioned ROI retain metadata pointer identity.
  Invalid/out-of-bounds regions and default-inert views do not report
  a successfully validated capability.
- Pixel operations using the already existing M3.2.2
  `mapComponentsInto` produce bit-exact output equal to the old
  conservative composite ROI for the same source and caller-owned
  destination. The independent exact oracle is
  `(channel*100 + y*10 + x)*0.5 - 10`; masked invalid pixel has the
  **explicit test-only** zero-output policy.
- Neither the M1.5 original view nor M3.2.3 conservative
  `BorrowedSemanticImage.tryRoi` implementation was modified.
  Mutable caller-backed `const` semantics must continue to use the
  conservative path unless they are first explicitly made immutable.

**Important limitation:** M3.2.2 `mapComponentsInto` independently
revalidates all channel IDs when applying an operation. Therefore
**only the ROI construction path avoids repeated O(channels) intrinsic
validation**. No end-to-end image mapping speedup is claimed.

## 3. A genuine capability-forgery defect found and fixed

The original `ValidatedImmutableImage` had private fields including
a Boolean `verified_` marker, but no user constructor. D's
struct-literal initialization permitted a caller to construct the
aggregate positionally (including the marker), even from outside the
module. The extra whole-source compile-negative forged-capability
probe initially **compiled**, producing a correctly failed CI gate.

The implementation was changed to provide a **private, explicit
D constructor** taking the scoped M1.5 view and immutable metadata.
D does not allow general struct literals when an explicit constructor
exists, and code outside the module cannot call that private
constructor. The factory and ROI method use the private constructor
after the appropriate validation and existing M1 ROI checks.
The source and negative compilation both pass under all four compilers.

This result is retained as a D ownership/capability API lesson:
**private struct fields alone do not establish an unforgeable validation
token**. No `@trusted` escape hatch was introduced.

## 4. ROI complexity and preliminary LDC observations

The conservative composite ROI calls `tryBorrowSemanticImage`
again, looping through `channelCount` semantic IDs after deriving
the M1 raster ROI. The validated-immutable ROI derives only the M1
ROI (whose plane-count and validity-grid checks are constant-time)
and returns the same immutable semantic descriptor slice.

**Mechanism (source-level):**

| Path | Intrinsic metadata comparison per ROI | Pixel copy |
| --- | --- | --- |
| General `BorrowedSemanticImage.tryRoi` | O(channels) | none |
| `ValidatedImmutableImage.tryRoi` | O(1) metadata work; no ID scan | none |

**Advisory elapsed times** on GitHub-hosted Ubuntu 24.04,
LDC 1.43.0 release builds. Each pair is the total measured time over
the stated number of iterations, **not per-call microseconds**.
ROI positions varied; the checksum was consumed and matched.

| Channels | Calls | Old ROI, first / recheck | Immutable ROI, first / recheck |
| --- | ---: | ---: | ---: |
| 3 | 12,000 | 78 / 80 µs | 67 / 68 µs |
| 17 | 12,000 | 175 / 175 µs | 70 / 66 µs |
| 64 | 12,000 | 496 / 513 µs | 68 / 66 µs |
| 256 | 6,000 | 953 / 959 µs | 33 / 33 µs |
| 1024 | 6,000 | 3,745 / 3,722 µs | 33 / 36 µs |

The 1024-channel result supports investigating the proposed mechanism
but **does not establish a production speed ratio**: hosted runner
contention, stopwatch resolution, cache state, compiler hoisting,
inlining, benchmark input symmetry, and lack of controlled XPS
repetitions remain confounders. In particular, checksum equivalence
alone does not prove identical machine-code work or exclusion of
compiler loop transformations.

**No measured memory RSS, metadata allocator count, image decoding
performance, arbitrary ROI corpus, or independent optimized C++
reference** was produced.

## 5. Ownership and admission boundaries

- This is a borrowed view, **not** a new pixel owner: raster and mask
  ownership remain in `RasterLease!T`.
- Immutable metadata is supplied by the caller or an explicitly
  existing snapshot; the new factory performs **no metadata copy**.
- Truly immutable metadata is stricter than read-only `const` backing.
  It cannot be silently obtained from mutable metadata.
- `@safe nothrow @nogc` construction/ROI operates within the
  validated lifetime; expected DIP1000 invalid escape attempts fail.
- Unforgeability is established for ordinary outside-module D code
  under the tested compilers, not for arbitrary `@system` memory
  corruption or malicious `cast` outside safe D.
- Public `ImageView` design, a final metadata owner, radiometric
  error semantics and overall image-domain production admission
  remain **deferred**.

**Next:** controlled XPS benchmark with repeated distributions, an
appropriate `raster-d`-only ROI control, and anti-hoisting/codegen
analysis before deciding whether this specialized capability is worth
a public surface. Keep evidence on the stacked research PR; do not
merge unrelated research history wholesale into `develop`.

Tracking: [issue #34](https://github.com/alex-1974/imagery-d/issues/34),
[PR #35](https://github.com/alex-1974/imagery-d/pull/35).
