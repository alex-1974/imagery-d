# Repository Engineering Context

This repository is part of the d-geospatial workspace.

Before changing architecture, public API, numerical behavior, tests, CI,
release configuration, repository structure, or toolchain work, read the
relevant canonical workspace documents under `.workspace/`.

Canonical workspace documents:

- `.workspace/README.md`
- `.workspace/ROADMAP.md`
- `.workspace/DESIGN_PRINCIPLES.md`
- `.workspace/DLANG_PRACTICES.md`
- `.workspace/RESEARCH.md`
- `.workspace/QUALITY_GATES.md`
- `.workspace/GIT_GITHUB_WORKFLOW.md`
- `.workspace/REPOSITORY_STANDARD.md`
- `.workspace/TOOLCHAIN_ISSUES.md`

Repository-specific documents may specialize these rules where the repository
requires it. They must not silently contradict workspace-wide rules.

If a necessary exception exists, document the exception and its rationale
explicitly.

When `.workspace/` is unavailable (for example in a standalone clone), do not
invent workspace policy. Follow the tracked repository documentation and note
that workspace context was unavailable.
