# ADR 0021 — Exact resident display specialization

**Status:** Implemented and measured, unreleased; PR #205 integration pending.

## Decision

Specialize single-source nearest and exact-grid identity bilinear/area sampling.
Visit only sampled provider tiles, validate planes once and write bounded output
blocks directly. Preserve byte, alpha, validity, quality and failure semantics.
Use the full linear-premultiplied path for other filters/source combinations.

Keep owned output independent. Introduce an explicitly borrowed, noncopyable
display workspace whose private pixel owners never escape. Retain the active
owner locally across foreign callbacks, reject ordinary reentry and publish
only complete scoped views. Metadata can be retained. Buffer reuse is justified
by this private ownership boundary, never by a writable-view uniqueness claim.

## Evidence and target

The [contract](../resident-display.md) and
[receipt](../benchmarks/slic-graph-display-2026-11-22.md) record independent byte
references, real imageio PNG decoding, resident overview cache, moving viewports,
allocation trade-offs, scoped API probes and measured p95/maxima.

The target is p95 <=16.67 ms for the named 512² resident CPU workloads. Decode,
overview generation, GPU upload, multi-source blending and arbitrary fractional
bilinear/area are not represented as having passed that target. No approximate
color quantizer, hidden worker thread or changed NoData policy is introduced.
