# M3.2.5 — Borrow-only versus immutable GC metadata snapshots

**Status:** Research experiment; **not** a public API, allocator decision or
production admission.

## Scope

This experiment uses exactly the existing `imagery-d` research contracts
from M1.5, M3.2.2, M3.2.3 and M3.2.4. It exercises two alternative
**metadata lifetimes** above identical `raster-d` pixel/validity leases:

| Property | Caller-borrowed | GC snapshot via `.idup` |
| --- | --- | --- |
| Intrinsic metadata source | Caller-owned `const(IntrinsicChannel)[]` | Owner-owned `immutable(IntrinsicChannel)[]` |
| M1 channel identities | Caller-owned descriptor slice | Second `immutable` copy |
| Explicit full-array copies during binding | **0** | **2** `.idup` copies during owner creation |
| Metadata borrow/ROI copies | 0 | 0 |
| Caller changes reflected? | **Yes:** `const` does not freeze backing | **No:** immutable snapshot copies descriptor values |
| Owner-controlled reclamation | Caller controls original backing; view is scoped | No deterministic GC release guarantee |
| Pixel/validity resources | Existing `RasterLease` borrows | Same `RasterLease` backing retained again |

The count of `0` and `2` refers **only to explicit full-array
snapshot copy operations** in the compared imagery metadata APIs. It is
not a measurement of all GC, compiler, `raster-d` or test-harness allocations.
Also, `.idup` copies struct descriptors, not necessarily all bytes
referenced by the D `string` fields inside them.

The caller-borrowed case requires the input descriptor storage to live
as long as the view and to remain semantically stable while in use.
`const` limits mutation *through* that view, but does not guarantee
immutability of mutable data held elsewhere.

## Tests

- 1, 3, 4, 17, 64 and 256-channel synthetic common-grid images;
- planar with validity and interleaved without validity;
- explicit scale/offset applied to three chosen channels for n ≥ 3;
- pixel results compared bit-exactly against each other and against a
  synthetic independent exact binary-fraction oracle;
- ROI metadata aliases the original caller array or retained snapshot
  without additional copies;
- caller mutation remains visible through the borrowed `const` slice;
  the `immutable` snapshot is isolated;
- metadata cardinality and identity failures;
- one compiler-negative `@safe` DIP1000 stack-metadata escape.
  The existing M1.5/M3.2.3/M3.2.4 lifetime experiment suites are not
  replaced by this narrower probe.

## Timings: advisory only

The optional `--benchmark` mode reports elapsed-time observations on
`3 / 64 / 256` channels, with variable iteration counts:

```text
metric,channels,iterations,elapsed_us,checksum
borrow_bind,...
snapshot_create,...
borrow_roi,...
snapshot_roi,...
```

The measured operations are intentionally distinct: `borrow_bind`
validates a borrowed metadata view; `snapshot_create` validates and
creates two immutable array snapshots; `borrow_roi` and `snapshot_roi`
derive an ROI from pre-existing composite views.

**These are not equivalent full-image acquisition paths** and the numbers
must not be interpreted as a single apples-to-apples image-decode
throughput comparison. They isolate *some* control-plane overhead.
A retained snapshot can be amortized over many image operations, whereas
a caller borrow requires lifetime discipline elsewhere.

The current compound `tryRoi` calls the validated composite-view factory
again, which walks channel IDs. Thus a compound imagery ROI can incur
**O(channel count) semantic revalidation**, even though the underlying
`raster-d` ROI is O(1) and performs no pixel copy. M3.2.5 must
characterize this cost before proposing a fast validated ROI path.

Cloud CI timing samples depend on hosted-runner scheduling and are
**not** production performance gates or XPS reproducibility evidence.
No full-process peak RSS, GC allocations, or deterministic metadata
release timing is claimed.

## Run

From `libs/imagery-d`:

```bash
bash experiments/m3_2_borrow_snapshot/tools/run.sh
```

To run only one toolchain and an advisory LDC benchmark:

```bash
COMPILERS=ldc2 RUN_BENCHMARK=1 \
  bash experiments/m3_2_borrow_snapshot/tools/run.sh
```

The tracked targeted CI matrix covers DMD 2.111.0/2.113.0 and LDC
1.41.0/1.43.0 against `raster-d` v0.2.0. There are no
pass/fail performance thresholds.

## Decision gate

Retain the simplest safe, caller-borrowed metadata path as the initial
reference. Admit a snapshot only for a concrete consumer that needs
independent metadata lifetime or mutation isolation. Do not implement
a new deterministic allocator, public image owner, or GC avoidance
mechanism without stronger lifetime, allocation, numerical, and
large-image performance evidence.

See the preceding [cross-repository ownership/lifetime audit](
../../docs/research/m3-2-cross-repository-lifetime-audit.md),
[issue #32](https://github.com/alex-1974/imagery-d/issues/32).
