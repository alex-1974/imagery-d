# M3.2.3 — Retained raster and intrinsic metadata lifetime results

**Status:** Focused DMD/LDC lifetime experiment **PASS**; public API admission **deferred**.  
**Date:** 2026-10-11  
**Repository:** `alex-1974/imagery-d`  
**Research branch:** `research/m3-2-retained-metadata-lifetime`  
**Validated implementation + test runner commit:** `5b19b2f4c8719ea1b8361d1a8fac18ecfdd49f18`  
**CI:** [GitHub Actions run 38132576788](https://github.com/alex-1974/imagery-d/actions/runs/38132576788) — four successful jobs  
**Dependency:** `raster-d` tag `v0.2.0`  
**Platform:** GitHub-hosted Ubuntu 24.04 x86-64

## 1. Compiler evidence

| Compiler | Positive debug | Positive release | Intrinsic metadata escape | Primary lease escape | Validity lease escape | Whole-owner escape | ROI escape |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DMD 2.111.0 | PASS | PASS | rejected | rejected | rejected | rejected | rejected |
| DMD 2.113.0 | PASS | PASS | rejected | rejected | rejected | rejected | rejected |
| LDC 1.41.0 | PASS | PASS | rejected | rejected | rejected | rejected | rejected |
| LDC 1.43.0 | PASS | PASS | rejected | rejected | rejected | rejected | rejected |

All four logs have two positive `M3.2.3 PASS` messages and five
expected compile-negative `PASS: rejected negative borrow` messages.
The negative runner checks that the failure contains a scoped
lifetime/reference diagnostic in **this experiment's** contract,
so an unrelated syntax or dependency failure is not accepted as proof.

## 2. Contract qualified

The experiment used the original M1.5 `ImageView!float` and M3.2.2
`IntrinsicChannel` metadata contract without modifying either module.

A bounded, caller-controlled test fixture retains:

- one `RasterLease!float` four-plane raster;
- an optional independent `RasterLease!ubyte` validity raster;
- four **immutable** M1.5 channel identities;
- four **immutable** intrinsic M3.2.2 channel descriptions.

The fixture creates a non-owning `BorrowedSemanticImage` containing
the validated M1.5 view and an intrinsic metadata slice. The borrow
is checked for matching channel count and semantic IDs. An ROI
preserves the same intrinsic metadata backing and narrows only the
raster/validity views. No metadata copy is performed by ROI.

The mapping operation uses the M3.2.2 explicit
`ValueInterpretation.physical` path and **caller-owned** destination.
It does not read encoded files, infer RGB from names, or silently create
validity/alpha/NoData semantics.

## 3. Verified synthetic laws

- **Layouts:** planar and pixel-interleaved views of the same four-plane
  5 × 3 float raster have equivalent semantic results.
- **ROI:** whole processing equals four uneven ROI partitions exactly.
- **Semantics:** explicit output channel order (3,2,1) is independent of
  intrinsic source labels.
- **Value interpretation:** independently constructed exact fixture oracle
  checks `stored * scale + offset` for selected channels; this does not
  establish a general floating-point numerical error budget.
- **Validity:** both masked and mask-free paths pass; the optional byte mask
  is distinct from colour/alpha/NoData.
- **Metadata:** identity and cardinality mismatches are rejected;
  failed image ROI construction is detectable.
- **Lifetime:** the compiler refuses returns escaping local metadata,
  primary/validity resources, the combined owner or an ROI derived from it.

## 4. Useful DIP1000 construction result

During development, a setter-based approach to constructing a
compound borrowed result failed on DMD and LDC with scope/lifetime
errors. Adding `scope` to the local result also failed because the
method receiver could not be treated as non-escaping and a scope-local
could not be returned.

The accepted experimental form instead **directly** returns the aggregate
`BorrowedSemanticImage(image, intrinsic)`, with both factory
arguments explicitly marked `return scope`. This compiled safely
under all four toolchains; five targeted negative builds established
that the return annotations did not permit unsafe stack/reference
escapes.

This is not evidence of a compiler defect, nor a justification for using
`@trusted` to bypass lifetime rules. The failed research commits are
retained on the topic branch as engineering history.

## 5. Resident raw payload accounting

For one 5 × 3 fixture invocation, during the two-output comparison:

| Raw pixel storage | Bytes |
| --- | ---: |
| Four-plane `float` source | 240 |
| Three-plane `float` whole output | 180 |
| Three-plane `float` ROI-partition output | 180 |
| Optional one-plane `ubyte` validity | 0 or 15 |
| **Total without mask** | **600** |
| **Total with mask** | **615** |

These amounts are **calculated raster payloads** for the small fixture.
Metadata fields reside inline in the owning struct. The numbers do not
include lease metadata/control blocks, slice descriptors, allocator
overhead, process RSS or compiler/runtime support. They are not peak
RSS measurements and not throughput benchmarks.

No new memory manager, metadata allocation per ROI, file decoder,
cache or general image-resource scheduler was introduced.

## 6. Limitations and next gates

1. The owner is fixed at **four channels** solely for the experiment.
   Variable-length, immutable metadata storage and its allocation/
   destruction policy require separate research before admission.
2. The retained owner and borrowed carrier type names and fields
   remain provisional; this is not an approved `ImageLease` API.
3. A borrowed view assumes its backing resources and metadata owner
   remain live; a forced resource invalidation or mutation path was
   not introduced to test other ownership implementations.
4. This test does not qualify metadata with arbitrary strings, ICC,
   multi-grid products, heterogeneous sample types, or real decoders.
5. No large-image memory budget or optimized-LDC performance benchmark
   was performed; the wrapper costs versus a direct `raster-d` operation
   remain unmeasured.
6. Arbitrary finite floating-point calibration and non-finite source
   sample policies still require independent numerical evidence.
7. Existing M1.5 lifetime and M3.2.1/M3.2.2 experiments remain separate;
   this run validates the **M3.2.3** composite plus reused operations,
   not a wholesale new baseline for unrelated experiments.

**Decision:** Preserve the experiment and its results as research
evidence on stacked PR #29. Do not yet promote a public
`ImageView`, `ImageLease`, intrinsic metadata owner or production
package. The next defensible step is variable-length owner/lifetime
probes and a numerical/performance admission contract for an actual
image-domain consumer.

Refs: [Issue #28](https://github.com/alex-1974/imagery-d/issues/28),
[PR #29](https://github.com/alex-1974/imagery-d/pull/29), upstream
[M3.2.2 PR #27](https://github.com/alex-1974/imagery-d/pull/27).
