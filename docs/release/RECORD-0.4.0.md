# imagery-d v0.4.0 publication record

Published on 2026-11-24 at 20:59:09 UTC as a
[GitHub source release](https://github.com/alex-1974/imagery-d/releases/tag/v0.4.0).
Remote assets and Pages were checked again on 2026-11-25.
Imagery-d has not been registered on DUB.

## Immutable source identity

| Item | Commit or object |
| --- | --- |
| Feature checkpoint `freeze/feature-0.4.0` | `2495c16c1fc9ed4ab1c3fc383989eba0d01c04dc` |
| API checkpoint `freeze/api-0.4.0` and qualified release head | `45a65f12e17d678db7c93f2939aab8077fb17e64` |
| Main promotion [PR #227](https://github.com/alex-1974/imagery-d/pull/227) | `af469f656c498ec3dbc8e7ace3c530f77eecad72` |
| Annotated `v0.4.0` tag object | `d248d11faac5ebfdf0258b4c29973fc28eb3ab34` |

The remote tag peels to the main promotion commit. The merge preserves the
qualified release tree. The configured signing agent refused the actual signing
attempt; the final tag is annotated and unsigned, with that reason recorded in
its annotation. No existing tag was moved.

## Qualification and publication

The published evidence JSON records seven passing workflows on the exact
qualified head, including all twelve compiler/configuration cells, API and
numerical references, Ddoc/consumers and publication contracts. The resolved
dependency graph is retained in that evidence and the qualification snapshot.

- [Publication workflow](https://github.com/alex-1974/imagery-d/actions/runs/45486042146):
  success on the promoted main commit. Source, Ddoc, evidence and checksum
  assets were uploaded, downloaded and verified; downloaded source consumers
  passed in default and no-I/O configurations.
- [Pages workflow](https://github.com/alex-1974/imagery-d/actions/runs/45577308429):
  success on the same commit, publishing verified released Ddoc assets.
- HTTP 200 on the [stable reference](https://alex-1974.github.io/imagery-d/),
  [v0.4.0](https://alex-1974.github.io/imagery-d/v0.4.0/),
  [retained v0.2.0](https://alex-1974.github.io/imagery-d/v0.2.0/)
  and [version index](https://alex-1974.github.io/imagery-d/versions.json).
  The index identifies `v0.4.0` as stable and retains both released versions.

Downloaded files match the published SHA-256 manifest:

| Asset | SHA-256 |
| --- | --- |
| `imagery-d-v0.4.0-source.tar.gz` | `dc0d15360c12b3e1a82264872cf7a099a5734e33d45edfbd11987076456cebcf` |
| `imagery-d-v0.4.0-ddox.tar.gz` | `829061c695d496ccdd54f45e303ec2def663d5d5b21202ea6ca8b15cc3a7ab46` |
| `imagery-d-v0.4.0-evidence.json` | `081de95b765640b84db342aba0359fb603844b75694a7f42ec8f1fe249c06887` |

## Review policy and scope

The maintainer explicitly waived the independent readability review before
1.0.0: “Die Durchsicht übergehen wir pre-1.0”. The versioned
`REVIEW-POLICY.json` and published evidence record `waived-pre-1.0`; they retain
the actual open state of #220. That review remains in the v1.0.0 milestone and
was not represented as completed.

The 60-fps qualification remains limited to named resident display workloads.
Decoder handoff, deployed consumer integration, manually annotated scenes and
separate accounting research retain their own acceptance issues. Later
documentation revisions on develop do not modify this release's tag or assets.
