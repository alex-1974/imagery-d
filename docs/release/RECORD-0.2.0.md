# v0.2.0 GitHub source release record

**Published:** 2026-10-29. imagery-d remains unregistered on DUB; the
registration decision remains scheduled for v1.0.0 unless needed earlier.

## Identity and qualification

- [Release PR #129](https://github.com/alex-1974/imagery-d/pull/129) merged
  with a regular merge commit after 13 active checks passed on head
  `f23fa62b0a64d1daeac3af238ff9a0935639e21e`. The optional portability
  canary was skipped as designed. Exact-head evidence: [Fast CI](https://github.com/alex-1974/imagery-d/actions/runs/40940259379),
  [M3 consumer and DDox](https://github.com/alex-1974/imagery-d/actions/runs/40940259301),
  [Release Gate](https://github.com/alex-1974/imagery-d/actions/runs/40940259310),
  [Release readiness](https://github.com/alex-1974/imagery-d/actions/runs/40940259903).
- `main` release commit:
  `2861af7499a2fc22b19ffc9d9133a3fd224e9dc7`. Its first parent is the
  previous v0.1.0 `main`; its second parent is the qualified PR head.
- Annotated `v0.2.0` tag object:
  `f3e26f5f47418ff0c9caf53410df296f2b274630`. Its peeled commit equals
  the release commit and current `main` at publication. The tag is unsigned,
  as allowed by `PUBLISH-0.2.0.md`.
- [GitHub Release](https://github.com/alex-1974/imagery-d/releases/tag/v0.2.0)
  has the approved notes and two DDox assets:
  `imagery-d-v0.2.0-ddox.tar.gz` and its `.sha256` file. The release target
  metadata also names the exact release commit.
- DDox tarball SHA-256:
  `3771d1592175d190ccee65c019b99e04c5afeabb9b9a8a1e8f510f59424d3b17`.

## Publication workflow exception

The [tag-triggered publication run](https://github.com/alex-1974/imagery-d/actions/runs/40941078653)
failed before dependency setup or publication. `actions/checkout@v4` fetched
the annotated remote tag and then fetched the peeled commit into its local
`refs/tags/v0.2.0`. The workflow's `git cat-file -t` check therefore saw a
local commit instead of the remote tag object. The remote tag itself was
verified unchanged and annotated; the workflow failure did not identify a
bad release tag or source tree.

The authorized publication was completed manually, from a detached checkout
of the exact `v0.2.0` commit, after checking the tag object's type,
its peeled commit and current remote `main`. The real `git archive` package
preflight passed. DMD rendered DDox from that checkout. A `.sha256` file was
generated for the DDox tarball; both assets were uploaded with the approved
release notes. The downloaded assets passed `sha256sum -c` and matched the
local release build byte for byte.

The already-published tag is immutable. The follow-up change to
`publish-v0.2.0.yml` fetches the remote tag object into a separate ref for
future validation or reuse of the workflow pattern; it does not change the
workflow stored at the published tag. Future version-specific publication
workflows should use the independent-ref check.
