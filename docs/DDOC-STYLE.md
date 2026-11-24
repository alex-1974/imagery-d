# Writing public API documentation

Public Ddoc is the reference for callers. Read the implementation and its tests
before changing a contract. The same rules apply to root re-exports, supported
direct module imports, public members and enum values.

Start with what the caller can do and when the operation is useful. Then state
its input domain, units, ownership, lifetime and failure behavior. Put numerical
and lifetime requirements before implementation notes. Keep essential safety
rules even when their explanation needs technical language.

For a callable, use `Params:` for each argument (including units, ranges and
whether it is read, written or retained), `Returns:` for a non-void result, and
`Throws:` for exceptions that can escape. Explain a void operation's effects in
the prose. Template arguments belong in `Params:` when they affect usage.
Do not advertise `nothrow`, `@nogc`, CTFE or deep lifetime enforcement unless the
signature and the corresponding probes establish the claim.

For a type, explain what `.init` means. In D, an uninitialized floating-point
field is NaN, not zero. For an error enum, distinguish its default member from
successful execution. Document numeric result validity separately from request
success and from orientation validity.

There is no library-wide `try` failure convention. Document each function:

- `out` parameters are reset to `.init` on entry; they cannot preserve a previous
  value. Failure can still leave subsequently assigned fields changed.
- A `ref` output is preserved on failure only when the implementation guarantees
  that. Working buffers can change even when a result remains unchanged.
- A status-returning function can allocate or propagate callback exceptions
  unless its signature and implementation establish otherwise.

Use short, concrete sentences. Introduce names such as working memory, revision,
validity and borrowed view where they first matter. Use the actual parameter
name in `Params:`; an existing parameter named `published` is still part of the
API. Describe it as the output parameter in prose. Reserve implementation history
and milestone names for ADRs or evidence reports. Words such as *candidate* can
be necessary domain terms; a global word blacklist cannot establish doc quality.

## Example of a useful contract

Before: “Noncopyable serial search retaining an independent float64 cost copy.”

After: “Find a minimum-cost route through an image cost grid. `prepare` copies
costs; later searches reuse working storage. Each edge costs its geometric
length multiplied by the arithmetic mean of its endpoint costs. NaN and positive
infinity block a cell; negative costs are rejected.”

The fuller comment then documents connectivity, step units, search windows,
failure state and a small executable route example.

## Executable examples

Prefer documented unittests using only supported public symbols. Show typical
use before error handling. Attach an example to each meaningful public type or
callable family; methods/accessors covered by that example do not need redundant
copies. Aliases link to the canonical operation and share its example. This
follows the workspace repository standard rather than mechanically duplicating
an example for every trivial member.

Compile and run examples with DMD and LDC. Inspect the generated HTML as well:
comments and examples can compile yet attach to the wrong declaration. Keep the
Ddoc immediately before the declaration and the example after that declaration.
Put each documented enum value or field on a separate line; a trailing Ddoc can
attach to the previous declaration.

## Review and automated checks

Run `bash tools/build-docs.sh`. It compiles every source module to unfiltered
JSON, audits public declarations before filtering, then audits the rendered pages.
The coverage report lists declarations and documented examples per module. A
coverage pass establishes presence, not semantic accuracy or readability.

Review every public family with these questions:

1. Is its purpose and intended use clear?
2. Are inputs, units, ranges and source encoding explained?
3. Are outputs, validity and failure states explicit?
4. Are ownership, aliasing, lifetime and allocation constraints clear?
5. Are numerical details separated from implementation history?
6. Can a caller use it from its documented import without reading private code?

Record the reviewed surface, exceptions and validation in the PR and audit
report. Do not call an automated check or an author’s own review an independent
consumer review. Handle newly found behavior defects separately; documentation
must describe the implemented behavior without silently changing it.
