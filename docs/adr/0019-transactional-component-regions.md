# ADR 0019 — Transactional caller-backed component regions

**Status:** Candidate qualified; broader #186/#187 acceptance remains open.

## Decision

Keep the existing row-streamed union/find engine and direct module boundary.
Qualify fixed-domain canonical IDs, explicit 4/8/seed/single-link policy,
separate observation validity, region measurements and shared-side contacts.
Caller-owned label backing may reside in RAM or a temporary file.

Add a structured operational error model, a checked scratch budget and cooperative
cancellation. The low-level function remains a staging operation. A transactional
entry point stages every output and invokes caller commit only after complete
success, or abort on every other exit, including propagated D Errors. Caller
callbacks own the atomic backing swap; the engine does not pretend to undo
arbitrary externally visible side effects.

Correct principal-axis validity for symmetric footprints using a scale-relative
covariance threshold, and fail overflowing requested statistics explicitly.
Record implementationVersion=2. Preserve canonical IDs for identical source,
extent and policy; crop final labels rather than promising invariant IDs after
changing the connectivity domain.

## Evidence and limits

See the [contract](../component-regions.md) and
[receipt](https://github.com/alex-1974/imagery-d/blob/v0.4.0/docs/benchmarks/component-regions-2026-11-22.md). Independent graph
traversal, SciPy binary labeling, NumPy bulk statistics and maximal-run extraction
agree across block sizes/backings and on a real scene. Compile tests enforce
the @safe named call and direct label-slice non-escape.

Source providers and caller storage remain outside engine payload accounting.
The file-backed fixture exercises windowed I/O on temporary storage; it does
not qualify physical-disk throughput or durable transactions. Single-link cell
segmentation is not color SLIC, and grid runs are not a vector-line fitter.
No API freeze, release or blanket M6 completion follows from this admission.
