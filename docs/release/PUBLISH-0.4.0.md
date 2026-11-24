# v0.4.0 controlled source publication

**Prepared procedure, not publication approval.** Keep promotion PR #227
draft while independent review #220, the final API audit/freeze or a required
exact-head workflow remains incomplete. See [the audit](API-AUDIT-0.4.0.md)
and [readiness record](READINESS-0.4.0.md).

## Before promotion

1. Complete #220's independent review, record its checklist and close it as
   completed only after acceptance. Reconcile the supported public surface
   and finalize the changelog from `Unreleased — v0.4.0 candidate` to a single
   `v0.4.0` section. Review versioned notes and the compatibility/migration text.
2. Record the final API checkpoint as an annotated `freeze/api-0.4.0` tag on
   the audited release-line state. Verify it descends from the existing feature
   checkpoint. No feature/API checkpoint publishes a package or documentation.
3. Finish all seven promotion workflows on the exact final head: CI,
   architecture Release Gate, feature references/resources, M3 consumer/DDOX,
   release readiness, the clean twelve-cell release qualification, and release
   publication contracts. A newer failed/pending run cannot be replaced with
   an older green run. Preserve source/performance and clean-dependency evidence.
4. Inspect the real source archive and expected assets. The publication
   contract tests run without GitHub writes; they do not test an actual tag,
   GitHub Release or Pages deployment. Confirm a successful cold compiler
   installation and subsequent verified cache hit in hosted logs.

## Deliberate release decision

Only after acceptance and the release decision, merge the promotion PR to
`main` with a **regular merge**, guarded by the approved head SHA. Verify the
merge has that head as its second parent and an identical tree. Associate the
new main commit immediately with the annotated, preferably signed `v0.4.0`
tag. The feature/API tags must remain ancestors of the release.

The version tag triggers `publish-v0.4.0.yml`. Its preflight verifies the remote
annotated tags through independent refs (checkout may peel its local tag),
exact main identity, regular promotion, tree equality, finalized notes and
changelog, completed #220 and the latest successful workflows on the qualified
head. It rechecks these conditions immediately before creating a release draft.

The workflow builds these assets from the qualified tagged state:

- `imagery-d-v0.4.0-source.tar.gz`: filtered source archive with versioned prefix;
- `imagery-d-v0.4.0-ddox.tar.gz`: complete generated reference;
- `imagery-d-v0.4.0-evidence.json`: promotion, review and exact-head workflow receipt;
- `imagery-d-v0.4.0.sha256`: SHA-256 for all three payloads.

The draft assets are downloaded, checksum-verified and consumed from an
unmodified source archive in a separate default/no-io DUB project. Only then
does the workflow publish the draft. A failed post-upload check leaves an
unpublished draft for investigation. A targeted retry may resume it only when
its notes, asset list and bytes match the approved artifact. No published
release or inconsistent draft is overwritten.

## Stable and versioned API documentation

After successful publication, `pages.yml` downloads verified published Ddoc
assets. It does not rebuild a moving develop/main snapshot. The latest release
becomes the stable root; `/v0.4.0/` retains the exact released documentation.
Older versions with published Ddoc/checksum assets (including v0.2.0) are
reconstructed in their own version folders without changing their bytes.
An older release cannot replace the current stable documentation. Optional
manual dispatch requires an exact already-published latest version.

## Post-publication acceptance

Verify the peeled remote tag, GitHub Release commit/assets, downloaded
checksums, clean source consumer, reachable Pages root/version paths and
retained older references. Record actual URLs and receipts in the release
record; an unexecuted workflow is not evidence of publication success.
Propagate release-only changes to develop. No imagery-d DUB registration is
performed by this procedure.
