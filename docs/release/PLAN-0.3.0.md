# v0.3.0 release plan

v0.3.0 is the next source release candidate after the v0.2.0 RGB analysis and
luminance release.

## Scope

- canonical consumer-facing API facade;
- separate `imagery-d-research` repository for long-form evidence;
- current M3/M4/M5 production source and tests already merged to `develop`;
- no DUB registration (registration remains planned for v1.0.0 unless needed
  earlier).

## Release gates

1. Run the complete required CI matrix on the exact release candidate commit.
2. Run local DMD and LDC unit tests and confirm the public facade imports.
3. Render Ddoc and verify examples use canonical names only.
4. Confirm the consumer archive excludes research and benchmark payloads.
5. Record the final commit, tag, CI URLs and source-archive checksum in a
   versioned release record.

The tag must be created only after all gates pass on the exact candidate.

