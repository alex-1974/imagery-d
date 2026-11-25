# Contributing to imagery-d

`imagery-d` is an independent D package for general-purpose image
processing. `develop` is the normal integration branch; `main` is
reserved for qualified, tagged releases. Do not force-push protected
branches or merge historical research wholesale.

Before changing public interfaces, release configuration, numerical
contracts, toolchains or CI, read the repository's [AGENTS.md](AGENTS.md),
its own accepted ADRs and, when available inside the workspace,
the **canonical** rules under `.workspace/`. The canonical
`.workspace` directory is not distributed in a standalone checkout.
Do not invent or replace its contents if unavailable.

## Reproducible local checks

Use DMD and LDC for consumer-facing production changes. The current
root package depends on released `raster-d` v0.5.5 and `color-d` v0.4.0.
In a standalone checkout, fetch the published dependencies. An optional
local override must point at the matching released source and must not
become a path dependency in `dub.sdl`:

```sh
dub fetch raster-d@0.5.5
dub fetch color-d@0.4.0
# Optional: dub add-local /path/to/raster-d-at-v0.5.5 0.5.5
dub test --compiler=dmd --force
dub build --compiler=ldc2 --build=release --force
dub run --root=tests/consumer --compiler=ldc2 --build=release --force
bash tools/verify-api-probes.sh
bash tools/verify-archived-consumer.sh release
python3 tools/check-release-package.py
```

The existing `tests/precision_consumer` and its Python
`tools/verify-levels-precision.py` provide a separate numeric
oracle. Full DDox and paired LDC Release consumer runs are automated by
`.github/workflows/m3-levels-candidate.yml`. The release-readiness
workflow separately challenges declared compiler floors and nonblocking
portability canaries.

New feature, bugfix, documentation and CI work normally uses short-lived
branches from `develop` and PRs. A PR should contain a precise
consumer requirement, semantic/failure/ownership contracts, independent
validation when applicable, API/Ddoc examples, and measured optimized
performance evidence when affected. Run all required CI on the **exact**
head intended for a guarded squash merge.

A successful change to `develop` does not authorize a feature/API freeze,
package version, `main` promotion, GitHub Release or DUB Registry
publication. Keep these release decisions separate and traceable.

## Public API documentation

Follow [the Ddoc style guide](docs/DDOC-STYLE.md) for every public surface,
including direct imports and members. Run `bash tools/build-docs.sh` to audit
unfiltered compiler JSON and the actual rendered site. Ddoc examples run in
the normal DMD/LDC unittest suites.

Keep the README short and put each reader task in a tutorial, how-to or concept
page linked from [the documentation index](docs/README.md). Use the
[glossary](docs/glossary.md) for shared terms. Consumer guides and reference
belong in the package; repository-only measurements must use explicit evidence
links so that the filtered source archive has no dangling local links.

Check the complete programs printed in the README, Levels tutorial and feature
guide with `python3 tools/verify-doc-examples.py --compiler=dmd` and again with
`--compiler=ldc2`. The checker extracts the real fenced Markdown programs and
runs them with assertions enabled; do not add an untested duplicate fixture.

Write changelog entries as user-visible changes under `[Unreleased]`, grouped
by Added, Changed, Deprecated, Removed and Fixed as needed. Tagged versions use
`## [x.y.z] - YYYY-MM-DD`; document breaking changes and migration first.

## Workspace and historical context

Inside d-geospatial-workspace, `tools/link-workspace-docs.sh /path/to/workspace`
creates or verifies the ignored canonical hardlinks under `.workspace/`.
Benchmark imagery belongs under an ignored local cache such as `data/`; retain
source definitions, provenance and hashes rather than committing large scenes.
The original repository's generic raster history is retained in raster-d;
ADRs and the research companion document that boundary and its rationale.
