# Verified compiler download cache

## Observed failure

On 2026-11-24, the v0.4.0 checks repeatedly received HTTP 525 while
`setup-dlang` downloaded DMD 2.111.0 / 2.113.0 from downloads.dlang.org.
Examples: [consumer/DDOX](https://github.com/alex-1974/imagery-d/actions/runs/45467764864)
and [readiness](https://github.com/alex-1974/imagery-d/actions/runs/45467764879),
including their targeted second attempts. The failed steps did not run
library tests. The separate [12-cell qualification](https://github.com/alex-1974/imagery-d/actions/runs/45467764901)
passed with the same compiler versions once installation succeeded.
This establishes intermittent distribution failure, not a compiler defect.

## Mitigation

`.github/actions/setup-dlang` wraps the pinned upstream action
`5d239e99bc553874d9362e7e6aeeac9454b6789f`. For exact Linux DMD selectors it
persists the upstream action's installed `dmd/<version>` and `dub/<version>`
tool-cache entries, including the architecture completion markers. Upstream
uses `@actions/tool-cache.find` before downloading and performs GPG
verification when downloading a signed DMD archive. That verification remains
enabled. The cache is saved immediately after successful installation, so a
later library test failure does not discard a verified compiler download.

Cache keys include OS, architecture, exact DMD/DUB versions and the upstream
action commit. There are no partial-key restores, alternate compiler versions,
unverified mirrors or workspace-built compiler uploads. LDC and non-Linux
selectors keep the upstream installation path. DUB stays at 1.40.0.

A cold cache still requires a working official download; this mitigation
does not turn an unavailable initial installation into a passing gate. Retry
only failed setup jobs after another job has populated the identical cache.
Compilation, numerical, API, lifetime, archive and documentation failures
remain blocking and must never be retried away as download errors.

## Qualification and removal

Verify a cold successful installation and a subsequent cache hit in hosted
logs, with the requested compiler/DUB versions and all existing checks intact.
Local YAML checks cannot establish a hosted cache hit. Cache reuse proves no
additional numerical or platform property.

Remove the wrapper or reconsider its cache layout when upstream provides
equivalent persistent caching or changes its installation layout. Bump the
cache namespace when changing verification or installation semantics. No
runtime or compiler-floor workaround exists in the library itself.
