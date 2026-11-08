# v0.2.0 — controlled GitHub source publication

**Historical runbook.** GitHub v0.2.0 was published. The tag-only workflow
failed during tag verification after checkout replaced its local annotated
tag ref with the peeled commit. Publication was completed manually from the
verified release commit, as recorded in [RECORD-0.2.0.md](RECORD-0.2.0.md).
The prepublication steps below are retained as the original procedure.

1. Confirm that `main` has not moved unexpectedly and that neither tag nor
   GitHub Release `v0.2.0` exists. Check release notes, README, CHANGELOG,
   public Ddoc and source archive against the exact candidate.
2. Merge the reviewed `main` PR using a regular merge commit. Record the
   resulting `main` SHA and immediately create an annotated, preferably
   signed `v0.2.0` tag on that exact commit. Never tag the PR head or a
   prior `develop` commit.
3. Push that tag. The tag-only `publish-v0.2.0.yml` verifies the annotated
   tag and current `main` identity, checks the real package archive,
   renders versioned DDox, and publishes the GitHub Release with checksum.
4. Verify the published release URL, tag peel, attached documentation and
   checksums. Record the exact release commit and CI URLs.

Maintainer-side tag commands after the merge SHA has been verified:

```sh
git fetch origin main --tags
RELEASE_SHA="$(git rev-parse origin/main)"
git show -s --format='%H %s' "$RELEASE_SHA"
git tag --list v0.2.0
gh release view v0.2.0
git tag -s v0.2.0 -m 'imagery-d v0.2.0' "$RELEASE_SHA"
git rev-parse 'refs/tags/v0.2.0^{commit}'
git push origin refs/tags/v0.2.0
```

The tag and release existence checks must report absence before tag
creation; if they do not, stop and investigate. If signing is unavailable,
use an unsigned **annotated** tag (`git tag -a`) with the same verified SHA.
The workflow does not register imagery-d on DUB. Registry registration is
deferred to v1.0.0 unless needed earlier.
