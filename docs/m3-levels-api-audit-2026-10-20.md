# M3 Levels — public API audit (Draft PR #97)

> **Later admission decision (2026-10-20):** This is a dated,
> historically preserved **pre-admission** qualification inventory.
> ADR 0006 subsequently accepted the narrow Levels source API for
> `develop`, without an API/ABI freeze, release tag or registry publication.
> Original checkpoints and unsuccessful attempts remain as evidence.


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
- Public `enum LevelsError`; `LevelsError.init == notAttempted`,
  deliberately **not success**. `notAttempted` is never emitted by a call.
  The status must be checked for `none`; returned failure preserves the
  existing output owner.
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
  `Error`: **the public entry points are now @safe through one narrowly
  reviewed @trusted malloc/adoption boundary; no @nogc, nothrow or
  exception-safe publication claim is made**.
  Normal returned errors preserve `published`; failure during arbitrary
  exceptions is not qualified.
- Removed the impossible public `invalidDestination` diagnostic during
  this Draft API audit. Caller destinations are not accepted; failure to
  construct a usable *internal* output maps to `allocationFailure`.
  A compile-negative consumer gate prevents accidental re-export.

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

1. **Error/status decision completed for this Draft candidate:** the
   default enum state is `notAttempted`, not a silent success; the impossible
   caller-destination error was removed. Recheck exact-head DMD/LDC and
   consumer compile gates after this API change. No ABI freeze exists.
2. **Safe-boundary decision completed for this Draft candidate:** the
   two public calls are `@safe` and only the private malloc/adoption
   adapter is `@trusted`, with a stated proof. Runtime resource exhaustion
   and fatal OOM/`Error` unwinding remain explicitly outside promised
   returned-error guarantees. Independent release review remains necessary.
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

## Initial D safety restriction — 2026-10-20 (superseded below)

At this initial checkpoint both `tryLevelsOwned` overloads were **explicitly `@system`**. The implementation used C `malloc/free` and the `@system` public raster-d
malloc-resource adoption API, so a safe claim was **not** justified by
ordinary consumer success. At that time a compile-negative contract proved
an `@safe` caller could not invoke it. That temporary safety restriction
was **superseded by the audited minimal trust boundary below**; the old
compiler-failure evidence remains in commit history.

## Measured Gamma=2 kernel performance qualification — 2026-10-20

[Paired evidence](performance/m3-levels-paired-2026-10-20.md) runs a
bounded `raster-d`-owned, 4-channel masked Levels operation in LDC 1.43
Release. The optimized gamma-2 candidate, generic `pow(t,1/gamma)`
reference and equivalent direct `sqrt(t)` reference each allocate their
own interleaved `RasterLease!float`, sample the same retained input and
selection and perform the same complete ROI output writes. Full output
pixel comparisons agree within the documented epsilon (observed maximum
absolute error **0** on this fixture). Each run uses one selected CPU
affinity, two warmups, seven rotating-order paired iterations, and medians.

On separate push and PR hosted runners, candidate/pow reference median
ratios are **0.120–0.128**, corresponding to roughly **7.8–8.3x lower**
execution time on this specific optimized gamma-2 workload.
Candidate/sqrt reference is **1.38–1.46**. The speedup is supported as
**directional, same-run kernel evidence**; it is not a C++ parity claim,
full HDR parameter-domain benchmark, constant-clock comparison or
whole-process memory budget. Non-gamma-2 paths continue using `pow`;
gamma 4 fallback has a separate numerical regression. Full public API
admission remains **DEFERRED**.

## Independent 90-digit Decimal correctness gate — 2026-10-20

An ordinary DUB consumer now emits exact binary32 result bits for
**624 deterministic u8/u16/f32 scalar cases** spanning ordinary and
extreme finite thresholds, gamma values, full/partial/zero selection,
and selected/unselected channels. A separate Python `decimal` high-precision
reference computes the expected image operation without importing imagery-d
math or implementation code. Results are compared by ordered binary32
ULP distance, not an absolute epsilon alone.

The first run detected a real cancellation bug: finite input
`-float.max`, Levels `(-2, 2, 4, 0.05, 0.95)` and full selection
returned **0** where the correctly rounded output is about **0.05**.
Commit `bc74e016` now publishes the already computed `mapped` value
when selection weight is exactly one, bypassing the destructive
`original + (mapped-original)` expression. A permanent ordinary D
consumer regression exercises both public overloads and zero-strength
pass-through at this extreme. The differential oracle on fixed commit
`bc74e016` [CI #39383796013](https://github.com/alex-1974/imagery-d/actions/runs/39383796013)
reported **624/624 passed, observed maximum 1 float32 ULP** on DMD;
other supported build jobs are qualified independently in the final
exact-head CI. This **does not promise** global <=1 ULP accuracy, bitwise
NaN preservation or complete HDR/colour policy. The approximate shortcuts
in the *reference only* for gamma outside 1e-12..1e12 are constrained to
the generated fixture domain; wider cases require separate qualification.

### Exception-path disposition

The pinned `raster-d` owned-import API differentiates pre-commit retained
ownership, successful transfer, and post-commit release; its move-only
`OwnedByteResource` has deterministic nothrow release. The Levels candidate
therefore relies on existing raster-d lifetime machinery; it does not
invent a new owner. On **returned** error, publication is unchanged;
errors and exceptions before owner assignment are outside the last
publication statement. That observation does **not** prove arbitrary
OOM-`Error` unwinding, allocator-fault behavior, post-commit construction
exception safety, or an `@safe` boundary **at that checkpoint**. The
subsequent narrowly justified adapter qualifies the `@safe` property,
but still does not catch/misclassify OOM as normal `allocationFailure`.


## Explicit pre-freeze public error cleanup — 2026-10-20

This is a deliberate **source/API contract change before any freeze**:
`LevelsError.init` is now `notAttempted` rather than `none` so a
uninitialized error variable cannot silently appear successful. Only an
explicitly returned `LevelsError.none` denotes successful publication.
The eight-argument private helper's destination-shape invariant is an
internal result-construction defect, not public caller misuse: the public
`invalidDestination` enum member was removed and that failure is mapped
to `allocationFailure`. No call can return `notAttempted`. Both public
signatures and named-argument names remain unchanged; the later audited
`@safe` transition intentionally replaces the temporary `@system` attribute.
Positive and negative consumer compile probes plus DUB regression enforce
these choices on both DMD and LDC. The enum is not frozen or published;
its numeric discriminants are **not** an external binary-stability promise.


## Qualified minimal native ownership boundary — 2026-10-20

**Accepted for the Draft candidate:** the two public `tryLevelsOwned`
overloads are now **`@safe`** on both DMD 2.113 and LDC 1.43, Debug and
Release. All non-native pixel, validation, ROI, checked-budget and output
publication helpers were declared `@safe`; D's safety checking governs
them. One single **private `@trusted nothrow @nogc`** adapter
(`tryCreateOwnedMallocBytes`) covers only the raw C pointer claim.

**Concrete proof obligation:** `bytes` is nonzero and bounded before this
adapter is called. The adapter accepts an empty `OwnedByteResource`, obtains
a byte region of exactly the requested length from libc `malloc(bytes)`,
checks for null, and immediately attempts `raster-d`'s
`tryAdoptMallocResource` on the *same pointer and byte length*. Its
`free` fallback applies only if the token has not accepted ownership;
on adoption success the raw pointer is never exposed again and the
move-only token is the sole release owner. The established `raster-d`
import consumes or releases the token according to its public disposition
contract. There is no raw pointer arithmetic, fabricated input memory,
extra alias, unchecked write or new owner implementation in the trusted
adapter. Borrowed caller input and optional selection mask are read through
`raster-d`'s checked views; the result is published only on success.

**Compiler evidence:** an ordinary consumer now compiles both unmasked
`ubyte` and masked `float` calls **inside genuine `@safe` functions**,
under `-preview=dip1000 -c`, while an escaping owner borrow, unsupported
source type, unpublished Into operation and impossible removed status remain
negative compile contracts. [Push CI #39385172643](https://github.com/alex-1974/imagery-d/actions/runs/39385172643),
[PR CI #39385178981](https://github.com/alex-1974/imagery-d/actions/runs/39385178981),
and [Fast CI #39385179114](https://github.com/alex-1974/imagery-d/actions/runs/39385179114)
all completed SUCCESS on `942a9a05a807893c8d3116893aa96f0c8659fc85`.
The 624-case independent Decimal oracle, independent ordinary DUB consumer,
DDox, P6 and paired LDC performance checks remain green.

**Limits of the claim:** `@safe` is *not* `nothrow`, `@nogc`, lock-free
thread safety or a peak-memory bound. Throwing GC descriptor allocation,
error unwinding and OOM `Error` do not become normal returned statuses.
The contract is that **all normally returned failures** preserve the
prior published lease, with no promise of successful cleanup after a
fatal runtime Error. Concurrent mutation of a retained source/lease and
external non-atomic reference-count races remain a caller responsibility.
The exact call signatures and result payload budget are unchanged.

The formal API admission gate is still **DEFERRED** until the remaining
release-level review (including external consumption, precision-domain
selection and package readiness); no API freeze or merge has occurred.
