# M3 RGBA — Native XPS comparison of publish-on-success owned output

**Status: research benchmark instrumentation, not a measured performance result.**
Draft PR #73 remains OPEN / DRAFT and stacked on PR #69. Do not merge or promote a production API from this benchmark. The input dependency source trees (`raster-d`, `color-d`) remain read-only at released `v0.2.0`.

## Question

The 2026-10-13 16-case [three-buffer XPS micro ROI experiment](m3-rgba-buffered-micro-xps-2026-10-13.md) measured a different contract: the caller retained the final packed destination while one four-plane scratch and one packed scratch were allocated per invocation. It does **not** measure the newly implemented Candidate B.

The new [consumer-owned-result experiment](m3-rgba-owned-packed-result-contract-probe.md) directly publishes its newly allocated packed scratch as the returned lease after all image color work and repacking succeed. It avoids a third public `copyInto` call. Measure the candidate **as implemented**, within the same independent DUB consumer that passes the 432-scene oracle.

## Three complete *different* allocation/output policies

All paths use one reused 2-KiB exact decode table and runtime opacity 0.37, the same 512² encoded-straight RGBA8 source allocations/layout, matching ROI dimensions, the same color-d source-over math and the same four-plane read/compose path.

| Stage CSV name | Output contract | Native ROI allocation/transfer inside timed call | Peak *incremental ROI pixel payload* |
|---|---|---|---:|
| `prepared_reused_output` | Reuse previously allocated four-plane output | No new ROI buffer. Prepared writes four planes directly. | 0 (caller output already exists, 4N bytes) |
| `owned_allocating_result` | Fresh packed `RasterLease!SRgba8`, published only after success | Four-plane scratch + newly owned packed staging/published buffer; **no final copy**. | 8N bytes |
| `buffered_allocating_final` | Fresh packed output with an additional checked final packed copy | Runs exact `owned_allocating_result` procedure, then allocates another packed destination and invokes public `copyInto`. | 8N bytes at a time in this implementation because four-plane scratch is destroyed before the final destination is allocated; native allocations still total 12N bytes across the call. |

N denotes ROI pixel count; neither native `malloc` activity nor metadata allocation can be inferred from `thread_gc_bytes`. The third path is a **diagnostic allocation-inclusive final-copy control**, *not* the previously measured reused caller-target path. Differences in allocation policy and output representation remain explicit. The 432-scene consumer validates the Candidate B result against its independent four-plane reference separately from timing.

## Measured workload

- Tool: [`tools/research/run_m3_rgba_owned_result_xps.sh`](../../tools/research/run_m3_rgba_owned_result_xps.sh).
- Source: committed `imagery-d` HEAD and `raster-d`/`color-d` v0.2.0 archives extracted into a fresh **imagery-d/data-only** snapshot. No writes to sibling repositories.
- Compiler: LDC 1.43.0 release, with native Dell XPS host CPU/kernel/governor/current-freq snapshots, memory/swap and `/usr/bin/time -v` process summaries recorded. A single sampled frequency does not establish stable frequency or eliminate thermal noise.
- Modes:
  - `--smoke`: backing 192², mixed alpha, planar/interleaved input, ROI 16²/64², two paired rounds × two iterations.
  - default `--micro`: backing 512², mixed and transparent-with-hidden-RGB input, planar/interleaved, ROI sides 16, 32, 64, 128, 256, **20 independent processes/cases**. Each uses seven paired rounds × 24 complete calls/stage.
- Each *stage* batch alternates in rotated order across rounds. Calls within each batch cycle through **four offset ROI origins**: (5,7), (18,23), (41,53), (71,91). This samples repeated spatially moving viewports; it is not a complete production renderer/viewport trace.
- Before timing, the code warms all three paths, and a separate full-pixel verification checks the complete prepared, owned-packed, and extra-final-copy outputs at all four offsets. This verification is repeated after each round. A 64-bit canonical byte checksum for one reference ROI is recorded with every stage row and revalidated after each round. Final materialization/verification and CSV output are **excluded from timed stage batches**.
- Every timed invocation includes Candidate B native allocations, raster import bookkeeping, staging, packing and ownership disposal. Reference state preparation and source/input storage creation are deliberately outside timing. Report the context preparation time independently.

## Evidence and validation

The runner creates one new directory (never overwrites existing evidence) with:

`environment.txt`, `build.log`, individual `*.csv` raw timings, stderr and `*-resource.txt` logs, `CHECKSUMS.sha256`, the derived `OWNED_COMPARISON.csv`, and `snapshot/` source archives.

The derived comparison is produced by [`summarize_m3_rgba_owned_result_xps.py`](../../tools/research/summarize_m3_rgba_owned_result_xps.py), which validates declared matrix, checksums, all round/stage keys, one comma-separated PASS trailer per case, sample counts, and consistent canonical checksums. Ratios are **computed inside the same process/round then summarized with the median**, not by dividing disconnected stage medians:

1. `owned_allocating_result / prepared_reused_output`.
2. `buffered_allocating_final / prepared_reused_output`.
3. `buffered_allocating_final / owned_allocating_result`.

The latter tests the combined cost of **allocating a second final output and copying it**. It is **not** a measurement of pure `copyInto` cost. Each raw stage sample is a batch of 24 complete calls in the full suite; normalize as `elapsed_us * 1000 / (iterations × N)` ns per pixel. Thread-local GC byte deltas are recorded per batch, not confused with native `malloc` bytes.

Negative CSV regression tests cover malformed PASS trailers, duplicate stages, corrupt hashes, changed pixel checksums and layout disagreement. A small pinned native runner is gated on the LDC 1.43.0 GitHub runner; the host CI timing is used as **correctness/provenance smoke only**.

## Running on the XPS

First fast-forward the existing local research branch to the exact PR HEAD after the new CI passes. Preserve all existing untracked DUB artifacts and evidence archives; do **not** clean/reset or overwrite them.

```bash
cd ~/Programmiersprachen/dlang/d-geospatial-workspace/libs/imagery-d
git status --short
git fetch origin research/m3-rgba-layer-compositing
git merge --ff-only origin/research/m3-rgba-layer-compositing
bash tools/research/run_m3_rgba_owned_result_xps.sh --micro
```

The script prints the new output directory. To make a portable archive, use its printed `tar --exclude='./snapshot' ...` command; retain full SHA-256 and raw files. Upload the archive for verification and *then* qualify performance. Do **not** assume an optimization win from the older XPS three-buffer measurements or from hosted CI wall times.

## Gate and limitations

- Actual Candidate B emitted samples must be exact to the existing four-plane prepared reference for *every checked pixel*, not merely aggregate checksums.
- Results are one XPS session unless repeated with controlled temperature/frequency and representative consumer loads. Ratios around 1% are not architectural decision evidence by themselves.
- The native compiler matrix and test suite do not establish transactional guarantees for arbitrary OOM, concurrency or unexpected memory faults; the consumer's native-allocation failure contract remains a research prototype.
- Candidate A, original four-plane input versus a **caller-supplied packed output** physically checked before writes, remains **BLOCKED**. No raster-d API extension or type-erased alias borrowing is created here.
