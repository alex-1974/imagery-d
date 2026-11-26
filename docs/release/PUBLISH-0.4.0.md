# v0.4.0 controlled source publication

**Prepared procedure, not publication approval.** Keep promotion PR #227
draft while the final API audit/freeze or a required
exact-head workflow remains incomplete. See [the audit](API-AUDIT-0.4.0.md)
and [readiness record](READINESS-0.4.0.md).

## Before promotion

1. Apply the explicit pre-1.0 exception in [REVIEW-POLICY.json](REVIEW-POLICY.json).
   Keep #220 deferred for 1.0; do not represent the waived review as completed.
   At and after 1.0 the completed review remains required. Reconcile the supported public surface
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
   [DEPENDENCIES-0.4.0.json](DEPENDENCIES-0.4.0.json) retains the identical
   resolved versions from all twelve cells of candidate `3557a13`. Every new
   matrix cell and publication build must match this snapshot. If a registry
   update changes resolution, inspect the new graph, update the snapshot
   deliberately and rerun the complete candidate qualification before tagging.
   These are DUB-resolved recipe graphs; optional dependencies may appear even
   for no-io and are not evidence that their code executes in that configuration.
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
changelog, the actual review disposition and the latest successful workflows on the qualified
head. It rechecks these conditions immediately before creating a release draft.

The workflow builds these assets from the qualified tagged state:

- `imagery-d-v0.4.0-source.tar.gz`: filtered source archive with versioned prefix;
- `imagery-d-v0.4.0-ddox.tar.gz`: complete generated reference;
- `imagery-d-v0.4.0-evidence.json`: promotion, review and exact-head workflow receipt;
- `imagery-d-v0.4.0.sha256`: SHA-256 for all three payloads.

The evidence also embeds the validated default/no-io publication dependency
graphs. The separate downloaded-source consumer checks its resolution against
the same baseline; a newer dependency is not silently accepted as qualified.

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

### Static-resource repair

The original v0.2.0 and v0.4.0 Ddoc archives omitted DDox's public CSS,
JavaScript and icon files. Pages supplements only these known historical
versions with the matching pinned DDox 0.16.24 resources and licenses. Every
released file retains its bytes; tags, release assets and their checksums are
unchanged. New Ddoc builds include these resources, and publication rejects
incomplete future archives instead of silently repairing them.

The deployment uses tooling from the workflow ref while API content continues
to come from verified released archives. After a tested deployment fix reaches
develop, rebuild the existing reference with:

```sh
gh workflow run pages.yml --repo alex-1974/imagery-d --ref develop -f version=v0.4.0
```

Verify real CSS/JavaScript/icon responses and a nested reference page after
deployment. An HTTP 200 on the index alone does not establish correct rendering.

## Post-publication acceptance

Verify the peeled remote tag, GitHub Release commit/assets, downloaded
checksums, clean source consumer, reachable Pages root/version paths and
retained older references. Record actual URLs and receipts in the release
record; an unexecuted workflow is not evidence of publication success.
Propagate release-only changes to develop. No imagery-d DUB registration is
performed by this procedure.
