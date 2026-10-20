# v0.1.0 — controlled publication runbook

**Internal publication instructions; not part of the consumer source
archive.** Prerequisite: reviewed release PR to `main` with successful
Linux CI on its exact head; a tag must **never** be created before
the `main` merge is complete.

## Prepublication

1. Confirm `main` hasn't moved unexpectedly and GitHub release
   `v0.1.0` and tag refs do not exist.
2. Review `README.md`, `CHANGELOG.md` and
   `docs/release/NOTES-0.1.0.md` against source/API/manifest.
3. Confirm the release PR's existing Linux DMD/LDC/owned Levels,
   Ddoc, source-archive and clean registry-dependency jobs are green;
   macOS/Windows are explicitly nonblocking.
4. **Merge the release PR using a regular merge commit** so the
   qualification branch's underlying `develop` ancestry remains
   traceable. Do **not** squash, direct-push or force-push `main`.

## Annotated signed release tag (maintainer terminal)

After the merge is confirmed and the main SHA is known:

```sh
git fetch origin main --tags
RELEASE_SHA="$(git rev-parse origin/main)"
git show -s --format='%H %s' "$RELEASE_SHA"
git tag --list v0.1.0
gh release view v0.1.0
```

The last two checks **must report absence** (a nonzero `gh release
view` result is expected). If the release commit isn't the reviewed
merge, investigate before any tag operation.

Prefer a **signed annotated tag** using the maintainer's existing
working Git signing configuration:

```sh
git tag -s v0.1.0 -m 'imagery-d v0.1.0' "$RELEASE_SHA"
git cat-file -t refs/tags/v0.1.0
git rev-parse 'refs/tags/v0.1.0^{commit}'
git push origin refs/tags/v0.1.0
```

The tag object must have type `tag`, and its peeled commit must equal
`RELEASE_SHA`. If signing is not configured, the workspace **permits**
an unsigned **annotated** tag (`git tag -a`); do not use a lightweight
tag. Do **not** move/recreate a published tag after the fact.

The push triggers `.github/workflows/publish-v0.1.0.yml`, which
verifies the tag points to the current main commit, builds rendered
DDox from the tagged source, and publishes the GitHub Release with
approved notes and checksummed API-documentation asset. This workflow
does **not** create the tag or register a DUB package automatically.

## DUB registry

DUB's official publishing instructions require the maintainer to
register `alex-1974/imagery-d` under their account at
https://code.dlang.org/ (if not already registered). SemVer tags are
then picked up during periodic registry scans. This external
registration step requires account login and is not performed by
the GitHub tag workflow.

After indexing, verify on a clean machine or runner:

```sh
dub fetch imagery-d@0.1.0
dub list imagery-d
```

Then compile a real external DUB consumer depending on
`imagery-d ~>0.1.0` with no local checkout or `dub add-local`.

## Completion

Record final release tag, peeled SHA, Github Release URL,
generated docs/checksums, DUB registry URL and clean consumer smoke
in issue #99. Forward-integrate any **release-only** documentation
or packaging changes back to `develop` via an ordinary PR after
release. Do not close issue #99 until those checks are complete.
