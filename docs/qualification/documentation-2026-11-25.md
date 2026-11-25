# Caller documentation revision — 2026-11-25

Author audit for [#228](https://github.com/alex-1974/imagery-d/issues/228).
This is not an independent readability review. The maintainer deferred that
review to v1.0.0 under [#220](https://github.com/alex-1974/imagery-d/issues/220).

## Reviewed surface

- Rewrote all 47 source-module introductions around purpose, entry points and
  input/result choices. Retained numerical and lifetime details in named notes.
- Split 54 grouped declarations into 140 individually documented public fields.
  Kept types, initializers, field order and access unchanged.
- Replaced the long README with a 105-line entry page. Added task navigation,
  installation/configuration, API selection, image I/O and feature guides,
  image-data concepts and a glossary. Reworked the Levels tutorial.
- Checked version, support and dependency facts against the released recipes
  and qualification. The supplied README's unsupported Git-dependency syntax
  was replaced by an actual tagged checkout and sibling path dependency.
- Normalized versioned changelog entries and preserved detailed evidence through
  immutable repository links. Consumer guides ship; benchmark, qualification,
  release and research evidence remain in the repository.

## Verification

Compared DMD 2.113.0 compiler JSON with unmodified v0.4.0 source using each
checkout's corresponding source positions to recover visibility. All 1,242
public declarations match after excluding comments and source locations:
names, order, types, attributes, signatures and reported field offsets are
unchanged. The field-edit script separately checked initializer text.
This is a comparison of these two source states, not a general ABI promise.

`DC=dmd-2.113.0 bash tools/build-docs.sh` passes the unfiltered and rendered
audits: 1,242 owned declarations, 76 documented examples and no missing public
documentation. The 21 upstream writer names retain versioned imageio-d links.

`python3 tools/verify-doc-examples.py` extracts and runs the actual complete D
programs from README, the Levels tutorial and the feature guide. All three
pass with DMD 2.113.0 and LDC 1.43.0 in debug mode, keeping assertions active.
The tutorial demonstrates successful processing and retained output on an
insufficient budget. Its raster-d raw-storage adoption is explicitly `@system`;
the processing function remains `@safe`.

DMD 2.113.0 no-I/O unittests pass in 38 modules. Publication guard tests pass
including both historical and dated changelog headings, duplicate rejection
and invalid dates. Documentation artifact tests and actionlint pass.
The package preflight checks actual archived guides and their local link targets;
CI also runs the Markdown programs with both primary compilers.

The published v0.4.0 tag and assets remain unchanged. These revisions are
post-release documentation for the development line.
