#!/usr/bin/env python3
"""Source-package release *readiness* checks. Does not version or publish.

The checks run on actual git-archive bytes, not a hand-written file list.
Checks intentionally do not claim that a DUB Registry package is available.
"""
from __future__ import annotations

import io
import os
import pathlib
import posixpath
import re
import subprocess
import tarfile
from urllib.parse import unquote, urlsplit

ROOT = pathlib.Path(__file__).resolve().parent.parent
manifest = (ROOT / "dub.sdl").read_text(encoding="utf-8")
license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
required = {
    "dub.sdl",
    "LICENSE",
    "README.md",
    "CHANGELOG.md",
    "docs/README.md",
    "docs/tutorial/levels.md",
    "docs/how-to/install.md",
    "docs/how-to/choose-an-api.md",
    "docs/how-to/image-io.md",
    "docs/how-to/features.md",
    "docs/concepts/image-data.md",
    "docs/glossary.md",
    "docs/accuracy-and-validation.md",
    "source/imagery/package.d",
    "source/imagery/presentation/levels.d",
    "source/imagery/presentation/luminance_stretch.d",
    "source/imagery/analysis/rgb_histogram.d",
}
excluded = (".github/", ".workspace/", "experiments/", "tests/",
            "docs/research/", "docs/release/", "docs/benchmarks/", "docs/qualification/",
            "docs/m3-", "docs/m6-feature-region-slice.md", "docs/public-api-review-")


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
    re.search(r'^dependency\s+"raster-d"\s+version="~>0\.5\.5"\s*$',
              manifest, re.MULTILINE) is not None,
    "release raster-d 0.5.x dependency (do not pin local path)",
)
require(
    re.search(r'^dependency\s+"color-d"\s+version="~>0\.4\.0"\s*$',
              manifest, re.MULTILINE) is not None,
    "released color-d 0.4.x dependency for color conversions",
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
archive_ref = os.environ.get("GIT_ARCHIVE_REF", "HEAD")
archive = subprocess.check_output(
    ["git", "archive", "--format=tar", archive_ref], cwd=ROOT
)
with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tf:
    filenames = {member.name.lstrip("./") for member in tf.getmembers()
                 if member.isfile()}
    archive_license = tf.extractfile("LICENSE")
    require(archive_license is not None, "archive LICENSE present")
    license_bytes = archive_license.read()
    # Check the documents actually shipped, so export-ignore changes cannot
    # silently strand a guide's local links. Code examples are not Markdown.
    documents = [n for n in filenames if n.endswith(".md")
                 and (n in {"README.md", "CONTRIBUTING.md"} or n.startswith("docs/"))]
    for name in sorted(documents):
        text = tf.extractfile(name).read().decode("utf-8")
        text = re.sub(r"^```[^\n]*\n.*?^```[ \t]*$", "", text,
                      flags=re.MULTILINE | re.DOTALL)
        for target in re.findall(r"\]\(([^)]+)\)", text):
            link = urlsplit(target)
            if link.scheme or link.netloc or not link.path:
                continue
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name),
                                                       unquote(link.path)))
            require(resolved in filenames or any(n.startswith(resolved.rstrip("/") + "/")
                                                 for n in filenames),
                    f"shipped document {name} links to missing {target}")
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
