# v0.4.0 API audit and freeze checklist

**Status: technical evidence prepared; independent review #220 and final API
freeze remain open.** No `freeze/api-0.4.0` checkpoint exists yet.

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
| Documentation | All 1,242 declarations and 76 documented examples are covered by the existing source/rendered-page gates. Automated coverage and the author's review do not replace #220. |

## Independent review and final checkpoint

Issue [#220](https://github.com/alex-1974/imagery-d/issues/220) requires:

> Each rewritten comment is read once by someone who does not know the code.

The reviewer records the six-question readability checklist in the promotion
PR: clear style, purpose/use, parameters, result, consumer focus and ability to
understand the contract without the implementation. The full author report,
source Ddoc and generated reference are available for that review. Do not
close the issue on the basis of automated checks or another author pass.

After that review and any corrections, reconcile root/direct exports and the
supported calling forms with the report, rerun the affected gates, then create
an annotated `freeze/api-0.4.0` checkpoint. It freezes this candidate, not future
pre-1.0 minor releases. An API correction afterward requires an explicit
reopened audit and a new immutable checkpoint, never moving the old tag.

This checklist does not claim deployed Dunia acceptance or a general feature
scheduler. The exclusions in [the release plan](PLAN-0.4.0.md) still apply.
