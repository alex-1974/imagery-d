# M3 Levels — public API audit (Draft PR #97)

**Audit date:** 2026-10-20  
**Reference base:** `develop` `f47c0ca521b89b526d6e943335bca57b773e08ef`  
**Status:** **QUALIFICATION IN PROGRESS — API admission DEFERRED**, not an
API freeze, published API or release; see priority-only ADR 0004 (Draft #96).

This is an evidence inventory of the **isolated production candidate**, not
a retrospective rewrite of R-IM-03a research or historic M3 choices.

## Supported candidate import and public symbols

- `dub.sdl` package `imagery-d`, module `imagery.presentation.levels`,
  curated package import `imagery`.
- Public `struct Levels` with five double fields; `Levels.init`
  contains NaN and is **invalid**.
- Public `enum LevelsError`; `LevelsError.init == none`. The status
  must be checked; returned failure preserves the existing output owner.
- `tryLevelsOwned!T`, `T in {ubyte, ushort, float}`, two shapes:
  unmasked `(pixels, roi, affected, settings, maxResultBytes, ref published)`
  and masked `(pixels, roi, affected, settings, selection, maxResultBytes,
  ref published)`. Parameter names and UFCS form are compile-probed.
- The old caller-writable `Into` research function is **private**, not an
  exported production surface. Compilation probes ensure it cannot be imported.

## Mathematical contract and audit fix

For a finite input channel sample (u8/255, u16/65535 or direct float),
clamp `(v - inputBlack)/(inputWhite-inputBlack)` to [0,1], apply
`pow(t, 1/gamma)` and the chosen output range; a byte edit mask multiplies
the strength by `byte/255`. Unselected channels are numerically passed through.
NaN and signed infinities in float inputs are passed through by classification
and value; **bit-for-bit NaN payload/sign preservation is not promised**.
No physical/scientific meaning, colour transfer, ICC, sRGB, alpha association,
NoData/validity semantics or hidden integer output quantization.

The review found that finite threshold endpoints can overflow on subtraction.
Commit `54ebd41` introduced a half-scaled equivalent normalization for this
case; independent tests verify `[-double.max,+double.max]` at zero gives
`0.5` (gamma 1) and approximately `sqrt(0.5)` (gamma 2), plus tiny/huge
positive gamma, NaN/infinities, disabled channels and output preservation.

**Accuracy limit:** This is representative regression coverage, **not** a
full-domain ULP/error-envelope guarantee, bit-preserving NaN contract,
colour-managed HDR operation or external Photoshop/GIMP equivalence.

## Output, failure and resource contracts

- A fresh `raster-d`-owned **interleaved float raster** sized exactly to the
  ROI, identical source channel count. The source and mask are borrowed.
  Output is published only after complete success; late returned read/write
  errors drop the unpublished owner. An old output may coexist transiently.
- A self-owner case (same retained `RasterLease!float` as source and
  replacement result) is tested: copying the original lease retains the old
  backing, mutation of the old backing does not affect the new result.
  This does **not** grant a general borrowed-view escape or concurrently
  mutation-safe API; `raster-d` lease refcounts are not atomic.
- The required `maxResultBytes` caps only the NEW float **pixel payload**.
  Input/old result, control metadata, allocator/GC and I/O are excluded.
  Validity, overflow and signed-stride checks precede output allocation.
  Too-short (including zero) fails; exactly equal passes.
- `allocationFailure` covers detected overflow, returned malloc and raster
  adoption/import failures. D allocation may still throw or raise an OOM
  `Error`: **no @safe, @nogc, nothrow or exception-safe publication claim**.
  Normal returned errors preserve `published`; failure during arbitrary
  exceptions is not qualified.
- `invalidDestination` is an internal destination-shape diagnostic and is
  currently not expected from valid public caller inputs. Decide whether to
  keep this enumerator in the public status set **before any API freeze**.

## Compiler, consumer and documentation gates

The ordinary external DUB consumer exercises 48 scalar/mask/layout cases,
240 complete ROI outputs, independent sqrt oracle, checked ROI and output
budgets, single-pixel numeric boundaries and self-owner replacement.
The actual P6 CLI separately verifies byte-exact identity, independent
Python gamma2 oracle, invalid settings and no-overwrite behaviour.
It remains an in-repository application, **not external adoption**.

The compile-only gate uses DMD/LDC with `-preview=dip1000 -c` and the
actual DUB-resolved import graph. A valid local borrow must compile; a
dangling local-owner view, unsupported double input and public `Into`
import must each be rejected. These checks prove compiler-enforced
borrowing for the tested `raster-d` owner boundary and candidate type/import
constraints, **not every possible user alias or lifetime interaction**.
Named argument and UFCS positive probes are included.

Package CI builds the normal `imagery` import on DMD 2.113 and LDC 1.43
Debug + Release and fast DMD 2.111/LDC 1.41. DDox is rendered to actual
HTML and source archive export-ignore excludes tests/research; no production
release artifact is published.

## Remaining admission requirements

1. **Final public error/status review**, including treatment of the
   unreachable `invalidDestination` code and documented overload names.
2. **Exception/lifetime qualification** beyond ordinary returned failures.
   Explicitly choose a release-level @safe/system boundary; the current
   candidate claims no @safe property and uses a small C malloc adoption path.
3. **Numerical error-envelope decision** for extreme float/HDR values and
   negative/denormal/NaN payload behaviour. Existing regression tolerances do
   not establish a broad precision standard.
4. **Reproducible paired performance verdict** using comparable work with
   a fixed CPU/compiler/frequency and controlled ordering. The current hosted
   LDC Release P6 times vary materially between runners and are only smoke
   receipts; no XPS thermal stress test was performed.
5. **Explicit public API admission verdict** (Accepted/Rejected/Deferred)
   before merging #97 into `develop`. ADR 0004 accepted the *priority*,
   not any signature or release. Keep #97 Draft until then.

No merges, tags, package releases, sibling repository modifications or
research-branch history changes are implied by this report.
