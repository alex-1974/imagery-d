# v0.4.0 API audit and freeze checklist

**Status: technical audit accepted for the pre-1.0 candidate.** The maintainer
waived the independent readability review before 1.0 on 2026-11-24; the
[recorded policy](REVIEW-POLICY.json) preserves that exception. The annotated
`freeze/api-0.4.0` checkpoint records this candidate after the audit.

The source API is identical to feature baseline
`2495c16c1fc9ed4ab1c3fc383989eba0d01c04dc`. Release hardening changes CI,
packaging verification and release documentation, not production signatures,
algorithms, attributes or dependency ranges.

## Technical evidence available for review

| Contract | Evidence and limit |
| --- | --- |
| Supported imports and exports | [Complete author inventory](../public-api-review-2026-11-24.md): all 47 source modules are examined by the compiler-JSON/rendered-symbol gate; 1,242 owned public declarations and 21 explicitly routed upstream writer names. Counting symbols does not establish that every export should be frozen. |
| Parameters, defaults, results and errors | The author review covers units, `.init`, output rollback/reset and operation-specific exceptions; source Ddoc is authoritative. No universal no-throw or preserved-output convention is claimed. |
| Instantiation and attributes | Positive/negative API probes run with DIP1000; supported named arguments, scoped borrows and selected `@safe nothrow @nogc` entry points are instantiated. This is evidence for the named probes, not every possible consumer instantiation or universal CTFE capability. |
| ROI-copy migration | [ADR 0027](../adr/0027-validated-roi-copy-and-channel-selection.md): the old uninstantiable pointer overload is explicitly disabled/deprecated; the supported overload takes a validated plane window. Four scalar types, signed layouts and rollback are exercised in 64 external consumer cases. |
| Channel/mask behavior | The same ADR and 192 external cases cover selected channels, zero masks, nonfinite payloads, signed zero and retained prior output. |
| Numerical and resource contracts | Independent feature/component/region/mosaic references, portable/v3 checks, compiler matrix and warm allocation/resource gates; dated performance receipts retain their exact source/compiler/host and scope. |
| External use and packaging | All six compilers pass default/no-io source-archive consumers and released-dependency builds at the previous candidate. The final hardening head must pass again; installed workspace copies do not qualify the clean dependency gate. |
| Documentation | All 1,242 declarations and 76 documented examples are covered by source/rendered-page gates. Independent readability review is waived for pre-1.0, not reported as performed. |

## Pre-1.0 exception and final checkpoint

Issue [#220](https://github.com/alex-1974/imagery-d/issues/220) requires:

> Each rewritten comment is read once by someone who does not know the code.

On 2026-11-24 the maintainer explicitly instructed: "Die Durchsicht übergehen
wir pre-1.0". The technical author audit, executable examples, numerical/API
probes and source/rendered-page checks provide the pre-1.0 release basis.
The unfamiliar-reader review remains tracked by #220 for 1.0. It is neither
performed nor closed as completed by this exception. At and after 1.0 the
publication guard requires the completed review again.

Root/direct exports and supported calling forms remain as documented in the
author report and ADR 0027; production source is byte-identical to the qualified
feature baseline. Record this state with an annotated `freeze/api-0.4.0`
checkpoint and complete the final-head gates. It freezes this candidate, not future
pre-1.0 minor releases. An API correction afterward requires an explicit
reopened audit and a new immutable checkpoint, never moving the old tag.

This checklist does not claim deployed Dunia acceptance or a general feature
scheduler. The exclusions in [the release plan](PLAN-0.4.0.md) still apply.
