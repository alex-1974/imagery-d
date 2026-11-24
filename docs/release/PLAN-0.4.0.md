# v0.4.0 source release plan

## Identity and scope

v0.4.0 is the next pre-1.0 GitHub source release after v0.3.3. It does not
establish v1 source compatibility, a stable ABI or new platform support.
imagery-d DUB registration remains planned for v1.0.0 unless a concrete
consumer need makes earlier registration necessary.

The feature baseline is develop
`2495c16c1fc9ed4ab1c3fc383989eba0d01c04dc`. Cut `release/0.4` from that
commit and retain the annotated `freeze/feature-0.4.0` checkpoint there.
Only stabilization work enters this line: corrections, qualification,
performance investigation, pre-freeze API corrections, documentation,
packaging and CI. Further features belong on develop.

Track acceptance in [#226](https://github.com/alex-1974/imagery-d/issues/226)
and the [v0.4.0 milestone](https://github.com/alex-1974/imagery-d/milestone/8).
The [technical API audit](API-AUDIT-0.4.0.md) identifies what remains before
the final API checkpoint. The pre-1.0 independent-review exception is recorded
in [REVIEW-POLICY.json](REVIEW-POLICY.json). The
[publication procedure](PUBLISH-0.4.0.md) describes the prepared automation.
The [readiness record](READINESS-0.4.0.md) distinguishes inherited evidence
from the final candidate's qualification. [Release notes](NOTES-0.4.0.md)
describe the intended consumer contract.

Included source already integrated at the baseline:

- Scalar and structural features, typed/cooperative requests, shared tiled
  dependencies, full-precision defaults and explicit Float32 delivery.
- Lab D50 color SLIC, component/line extraction and immutable region graphs
  with adjacency, merges and label lineage.
- Explicit overview, quality, validity and bounded registered mosaic APIs;
  imageio component/RGB materialization with owned outputs and rollback.
- Prepared Canny, geometric paths, Gaussian/Hessian/tensor execution and
  bounded scratch/cache reuse, with independent numerical/resource evidence.
- Complete owned public Ddoc coverage and examples; validated-window ROI
  copy and selected-channel/zero-mask brightness corrections (#222/#223).

## Compatibility and support

- Linux x86-64 is the supported release platform. macOS and Windows remain
  best effort; optional smoke tests do not expand this commitment.
- Frontend floor: DMD 2.111.0 / LDC 1.41.0. Qualify DMD 2.111.0, 2.112.1,
  2.113.0 and LDC 1.41.0, 1.42.0, 1.43.0 with DUB 1.40.0, in default and
  no-io configurations.
- Declared dependency ranges remain raster-d `~>0.5.5`, color-d `~>0.4.0`,
  and, for default I/O, imageio-d `~>0.1.1` / transport-d `~>0.2.1`.
  Record the actual resolved transitive releases. A local fix registered
  under a release version is not proof of the published dependency.
- Portable code generation and default Float64 arithmetic remain the
  baseline. Optional x86-64-v3/native measurements do not raise the CPU floor.
- The old pointer-only `copyRoi` spelling is deprecated and disabled because
  it could not be instantiated. Migrate to a validated raster plane window
  inside `withPlane`; see [ADR 0027](../adr/0027-validated-roi-copy-and-channel-selection.md).

The public API audit covers root/direct imports, re-exports, overloads,
named parameters, `.init`, failure state, lifetime, template constraints and
attributes. After the technical audit and the explicit pre-1.0 waiver of #220, record the final
API checkpoint `freeze/api-0.4.0`. This freezes the candidate, not all future
pre-1.0 minor releases. Do not create that checkpoint while the audit is open.

## Claims and exclusions

The resident display-only 60-fps result applies to the named 512-by-512 CPU
workloads and measured host in [the receipt](../benchmarks/slic-graph-display-2026-11-22.md).
It excludes decoding, network access, general filtering and full application
latency. Performance results always retain their compiler, workload, precision
and resource limits; no universal frame rate is promised.

Real Dunia metadata/viewport integration (#145/#146), manually reviewed
multi-tool scene acceptance (#187, aggregate #181), retained-subscriber
accounting research (#74) and workspace-wide compiler rollout (#16) remain
separate. They do not block this bounded general-purpose library release and
must not be described as completed by it. In particular, imageio-d PR #26 is
not a released decoder fix: do not promise the affected real RGB GeoTIFF path
from the released dependency. No scheduler, CRS transformation or semantic
road/building recognition is added.

## Acceptance sequence

1. Establish the feature checkpoint and source/API/performance baseline.
2. Reconcile consumer docs, changelog and compatibility notes. The maintainer
   waived independent readability review #220 for pre-1.0 on 2026-11-24;
   retain its actual deferred state and require it again from 1.0 onward.
3. Audit the supported public surface and make necessary corrections before
   recording the API checkpoint. Requalify any affected numerical, resource
   and performance behavior; preserve independent raw evidence.
4. Run the full release matrix and independent references on the exact
   candidate, including API/DIP1000 negatives, Ddoc pages/examples, ordinary
   consumers, source archive, licence/metadata and clean released dependencies.
   Release-branch checks complement the inherited develop evidence.
5. Prepare a version-specific publication workflow, approved notes, source/API
   archive checksums and stable/versioned documentation. Existing v0.1/v0.2
   publication workflows do not publish v0.4.0. Check tag filtering excludes
   internal `freeze/*` checkpoints.
   The prepared workflow verifies the review disposition (including the explicit
   pre-1.0 waiver) and seven exact-head workflows, builds checksummed artifacts,
   validates downloaded source through a separate consumer before publishing
   its draft, then updates stable/versioned Pages from the verified Ddoc assets.
   These checks are not evidence of an actual publication before execution.
6. Qualify a promotion PR to main on its exact head. Only after the deliberate
   release decision, associate the qualified main commit with an annotated
   (preferably signed) `v0.4.0` tag and publish.
7. Verify the peeled tag, downloaded source/docs/assets and an external
   consumer of the published archive. Propagate release-only fixes to develop.

No v0.4.0 publication is implied by this plan, feature checkpoint or CI run.
