# M3.2.4 — Variable-length immutable channel metadata results

**Status:** Focused synthetic contract **PASS**; production admission **deferred**.  
**Date:** 2026-10-11  
**Repository:** `alex-1974/imagery-d`  
**Branch:** `research/m3-2-dynamic-metadata`  
**Validated implementation/test commit:** `823882bf29f3640ab61ef82dbd7e397e7e31748a`  
**CI:** [Run 38133337504](https://github.com/alex-1974/imagery-d/actions/runs/38133337504), **four successful jobs**  
**Environment:** GitHub-hosted Ubuntu 24.04 x86-64, released `raster-d` tag `v0.2.0`

## 1. Compiler matrix

| Compiler | Synthetic debug | Synthetic release | Owner escape rejected | ROI escape rejected | GC metadata escape compiled |
| --- | --- | --- | --- | --- | --- |
| DMD 2.111.0 | PASS | PASS | PASS | PASS | PASS |
| DMD 2.113.0 | PASS | PASS | PASS | PASS | PASS |
| LDC 1.41.0 | PASS | PASS | PASS | PASS | PASS |
| LDC 1.43.0 | PASS | PASS | PASS | PASS | PASS |

Each job log confirms **two** successful `M3.2.4 PASS` positive
executions, **two** scope/lifetime rejected negative configurations, and
**one** separate positive compilation of the GC-backed metadata slice
escape example. Negative acceptance checks require a borrow-escape
diagnostic in this experiment's source, not an unrelated compiler error.

This is the first `imagery-d` synthetic variable-channel owner qualification,
not a declared minimum compiler floor for an eventual public package.

## 2. Scope tested

- Variable intrinsic metadata cardinality **0, 1, 3, 4, 17, 64**.
- Two separately allocated immutable metadata snapshots: identity
  descriptors and intrinsic descriptors with source labels,
  quantity labels and calibration fields.
- Explicit cardinality and semantic-ID matching **before publication**.
- Caller mutates the original descriptor arrays after snapshot;
  owner metadata retains the original values.
- Noncopyable retained owner explicitly **moved before borrowing**;
  transferred metadata remains accessible, moved-from object is inert.
- Typed resident input `RasterLease!float` with planar and
  pixel-interleaved `raster-d` layouts.
- Optional `RasterLease!ubyte` validity (one invalid pixel) and
  fully mask-free input.
- Borrowed M1.5/M3.2.3 composite with correct metadata count;
  ROI shares the *same* intrinsic backing pointer.
- For three or more channels, explicitly select last three distinct
  channels into a caller-owned output, using the M3.2.2 **explicit**
  physical-value interpretation. Whole-region equals four uneven
  ROI partitions exactly, and an independent synthetic value formula
  serves as the exact oracle.
- Reject mismatched metadata counts and semantic IDs.

The zero-channel case qualifies an **empty metadata snapshot**, not a
usable pixel-processing image. Nonzero inputs include one channel
without an RGB interpretation; no colour binding is inferred from
plane count, names or physical layout.

## 3. Essential GC lifetime result

An initially proposed compile-negative case expected returning
`owner.intrinsic` from a stack-local dynamic owner to be rejected.
**The compiler accepted the code on DMD/LDC.**

This is a real design distinction: `immutable` slices created with
`.idup` are GC-backed. Returning such a slice retains the GC allocation
safely beyond the lexical owner. It does **not** prove an unsafe borrow,
and must not be counted as a negative-lifetime PASS.

The test was corrected to require:

1. **A positive compilation** for the independent GC metadata slice
   return, documenting that metadata can outlive its original owner.
2. **A negative compilation** when an entire borrowed image escapes
   a local owner retaining a `RasterLease`.
3. **A negative compilation** when an ROI derived from that local
   borrowed image escapes its scope.

All three conditions passed on all four toolchains. The stricter
transitive M1.5 and M3.2.3 borrow tests remain intact in their
original experiments.

**Implication:** The prototype is memory-safe but cannot promise
strict owner-controlled metadata reclamation. This is a known
GC-residency and control-contract limitation, **not** a reason to
introduce `@trusted` to circumvent the borrow rules.

## 4. Allocation and residency interpretation

Metadata creation performs `identities.idup` and `intrinsic.idup`
once per successful owner construction. The raster and optional
validity resources are retained through existing `raster-d` leases.
Borrowing and ROI use their existing `@safe nothrow @nogc` paths
and share the immutable metadata slices without cloning.

The test harness itself additionally allocates temporary caller
metadata arrays, per-plane `PlaneByteLayout` arrays, and source and
destination raster buffers. These allocations are outside the
actual metadata borrow and image operation; they have **not** been
instrumented as an allocation-count or RSS benchmark.

For the maximum 64-channel 5 x 3 float fixture, source raw sample
payload is `64 * 5 * 3 * 4 = 3,840` bytes. Each of the two
3-plane outputs has `3 * 5 * 3 * 4 = 180` bytes and the optional
one-plane validity buffer is 15 bytes. These calculated payloads
exclude metadata payload, GC bookkeeping, raster lease control
structures, allocator overhead and executable RSS. No performance
claim follows from these figures.

## 5. Unresolved production decisions

1. The `.idup` GC snapshot is only a candidate baseline; compare
   deterministic/caller-controlled allocation strategies before
   choosing a production metadata owner.
2. Qualify ownership transfer, failure atomicity and release behavior
   with arbitrary-size metadata under the selected allocator, rather
   than assuming the GC evidence transfers unchanged.
3. General `immutable` metadata fields and variable source labels
   need provenance and memory-budget contracts. The current source
   names are D immutable strings; no borrowed byte buffers from
   foreign decoders were involved.
4. M1.5/M3.2.2/M3.2.3 contracts remain experimental and their public
   API shapes are not frozen. No general `ImageLease` is admitted.
5. No actual codec, georeference, heterogeneous channel sampling,
   alpha/NoData model or M2 Source/Resource/revision pipeline was tested.
6. Large-image throughput, allocation instrumentation, incremental
   metadata update cost, and comparison with direct `raster-d`
   processing remain open. Arbitrary floating-point radiometry still
   needs an independent numerical accuracy corpus.

**Decision:** Keep M3.2.4 as reviewed experimental evidence on
[PR #31](https://github.com/alex-1974/imagery-d/pull/31), stacked above
[M3.2.3 PR #29](https://github.com/alex-1974/imagery-d/pull/29).
The next responsible step is an allocation/lifetime comparison of
GC snapshots against a deterministic bounded owner with explicit
move and release semantics — not a public API freeze.

Tracking: [Issue #30](https://github.com/alex-1974/imagery-d/issues/30).
