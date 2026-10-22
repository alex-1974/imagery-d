#!/usr/bin/env python3
"""Source-package release *readiness* checks. Does not version or publish.

The checks run on actual git-archive bytes, not a hand-written file list.
Checks intentionally do not claim that a DUB Registry package is available.
"""
from __future__ import annotations

import io
import pathlib
import re
import subprocess
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
manifest = (ROOT / "dub.sdl").read_text(encoding="utf-8")
license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
required = {
    "dub.sdl",
    "LICENSE",
    "README.md",
    "CHANGELOG.md",
    "source/imagery/package.d",
    "source/imagery/presentation/levels.d",
    "source/imagery/analysis/rgb_histogram.d",
}
excluded = (".github/", ".workspace/", "experiments/", "tests/", "docs/research/", "docs/release/")


def require(flag: bool, message: str) -> None:
    if not flag:
        raise AssertionError("release package preflight: " + message)


def manifest_string(name: str) -> str:
    matches = re.findall(
        r'^' + re.escape(name) + r'\s+"([^"]+)"\s*$',
        manifest, re.MULTILINE
    )
    require(len(matches) == 1, f"exactly one {name} field")
    return matches[0]


require(manifest_string("name") == "imagery-d", "DUB package name")
require(manifest_string("license") == "MIT", "DUB MIT licence metadata")
require(
    manifest_string("homepage") == "https://github.com/alex-1974/imagery-d",
    "package homepage",
)
require(manifest_string("targetType") == "library", "library target")
require("sourcePaths \"source\"" in manifest, "consumer source root")
require(
    re.search(r'^toolchainRequirements\s+frontend=">=2\.111\.0"\s*$',
              manifest, re.MULTILINE) is not None,
    "declared frontend floor must match explicit DMD 2.111 gate",
)
require(
    re.search(r'^dependency\s+"raster-d"\s+version="~>0\.3\.0"\s*$',
              manifest, re.MULTILINE) is not None,
    "release raster-d 0.3.x dependency (do not pin local path)",
)
require(
    not re.search(r'^dflags\b.*(?:-preview|preview=)',
                  manifest, re.MULTILINE),
    "preview semantics must never be forced on all consumers",
)
require(
    "MIT License" in license_text
    and "Permission is hereby granted" in license_text,
    "committed MIT license text",
)
archive = subprocess.check_output(
    ["git", "archive", "--format=tar", "HEAD"], cwd=ROOT
)
with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tf:
    filenames = {member.name.lstrip("./") for member in tf.getmembers()
                 if member.isfile()}
    archive_license = tf.extractfile("LICENSE")
    require(archive_license is not None, "archive LICENSE present")
    license_bytes = archive_license.read()
require(required <= filenames,
        "missing required consumer source/metadata: "
        + ", ".join(sorted(required - filenames)))
require(not any(n.startswith(excluded) for n in filenames),
        "research, CI or test source unexpectedly shipped")
require(license_bytes == (ROOT / "LICENSE").read_bytes(),
        "archive MIT bytes differ from tracked source")
require(
    not any(n.endswith(("dub.selections.json", "dub.json.lock"))
            for n in filenames),
    "workspace/local dependency resolution lock unexpectedly shipped",
)
print("M3_RELEASE_PACKAGE_PREFLIGHT=PASS; actual git archive, MIT, "
      "DUB metadata, frontend declaration, filtered consumer sources")
