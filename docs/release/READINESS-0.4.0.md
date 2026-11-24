# v0.4.0 qualification record

## Candidate identity

- Previous publication: [v0.3.3](https://github.com/alex-1974/imagery-d/releases/tag/v0.3.3).
- Feature baseline: `2495c16c1fc9ed4ab1c3fc383989eba0d01c04dc`.
- Stabilization: `release/0.4`; internal checkpoint `freeze/feature-0.4.0`.
- Release tracker: [#226](https://github.com/alex-1974/imagery-d/issues/226).
- Final API checkpoint, promotion commit and release tag: not yet selected.

## Inherited evidence, not final candidate approval

The feature baseline passed all three push workflows:
[CI](https://github.com/alex-1974/imagery-d/actions/runs/45459617810),
[ordinary consumer/Ddoc](https://github.com/alex-1974/imagery-d/actions/runs/45459617392)
and [release readiness](https://github.com/alex-1974/imagery-d/actions/runs/45459617286).
The last includes local dependency substitutions for parts of default I/O;
it is not evidence of an entirely clean released dependency graph.

[The public API review](../public-api-review-2026-11-24.md), followed by
[ADR 0027](../adr/0027-validated-roi-copy-and-channel-selection.md), records
1,242 owned public declarations, 76 documented examples, 64 ROI-copy and 192
channel/mask regression cases. Independent readability review remains #220.

[Engine/performance qualification](../benchmarks/engine-gaussian-2026-11-24.md)
and [its artifact manifest](../benchmarks/engine-gaussian-artifacts-2026-11-24.json)
retain numerical, resource and fixed-target evidence. Those measurements
belong to their recorded source revisions/host; a docs-only change does not
turn them into new measurements. Implementation changes require the affected
gates again. The 60-fps boundary is [resident display only](../benchmarks/slic-graph-display-2026-11-22.md).

## Remaining release gates

| Gate | State / required evidence |
| --- | --- |
| Consumer docs and scope | Prepared for v0.4.0; review with the candidate diff |
| Independent Ddoc readability | Open #220; no automated substitute |
| API audit/final freeze | Pending after review and any contract corrections |
| Six compilers, default/no-io | Require exact candidate run and resolved dependencies |
| Independent references/resources | Require exact candidate workflows; retain timing receipts separately |
| Public API/lifetime probes | Require exact candidate positives/negatives and consumer regressions |
| Ddoc pages/examples | Require exact candidate compiler/renderer gates |
| Clean released default dependencies | Require no path/add-local substitutions, including transitives |
| Actual source archive | Require package inspection, checksum and separate consumer with the unmodified shipped manifest |
| Publication automation/docs | Version-specific workflow and immutable docs/assets still required |
| Main promotion/publication | Pending deliberate release decision after qualification |

Do not close #226 or claim release readiness while a required gate is pending
or failing. Keep #145/#146/#187, #74 and workspace coordination #16 outside
this release's acceptance claims, as specified in [the plan](PLAN-0.4.0.md).
