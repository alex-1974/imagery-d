#!/usr/bin/env python3
"""Build stable/versioned Pages from checksummed published Ddoc assets."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from release_artifacts import extract_archive, verify_checksum


def gh_json(route):
    return json.loads(subprocess.check_output(["gh", "api", route], text=True))


def build(repository: str, version: str, output: Path) -> None:
    if not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        raise ValueError("expected an exact version tag")
    latest = gh_json(f"repos/{repository}/releases/latest")
    if latest["tag_name"] != version:
        raise ValueError("refusing to replace stable docs with a non-latest release")
    releases = gh_json(f"repos/{repository}/releases?per_page=100")
    if len(releases) == 100:
        raise ValueError("collect paginated releases before rebuilding the versioned site")
    if output.exists():
        raise ValueError("documentation output must be a fresh directory")
    output.mkdir(parents=True)
    versions = []
    with tempfile.TemporaryDirectory(prefix="imagery-released-docs-") as directory:
        scratch = Path(directory)
        current = None
        for release in releases:
            tag = release["tag_name"]
            if (release.get("draft") or release.get("prerelease") or
                    not re.fullmatch(r"v\d+\.\d+\.\d+", tag)):
                continue
            archive = f"imagery-d-{tag}-ddox.tar.gz"
            names = {asset["name"] for asset in release["assets"]}
            manifests = [name for name in (f"imagery-d-{tag}.sha256",
                                          f"imagery-d-{tag}-ddox.sha256") if name in names]
            if archive not in names:
                continue
            if len(manifests) != 1:
                raise ValueError("versioned Ddoc needs one checksum asset: " + tag)
            target = scratch / tag
            subprocess.run(["gh", "release", "download", tag, "--repo", repository,
                            "--pattern", archive, "--pattern", manifests[0],
                            "--dir", str(target)], check=True)
            verify_checksum(target / archive, target / manifests[0])
            html = target / "html"
            extract_archive(target / archive, html)
            if not (html / "index.html").is_file():
                raise ValueError("released Ddoc has no root index: " + tag)
            shutil.copytree(html, output / tag)
            versions.append(tag)
            if tag == version:
                current = html
        if current is None:
            raise ValueError("latest release has no verified documentation asset")
        # Version folders retain the exact released bytes. Only the stable
        # root index receives a navigation link to its immutable version.
        shutil.copytree(current, output, dirs_exist_ok=True)
        index = output / "index.html"
        text = index.read_text()
        if "</body>" not in text:
            raise ValueError("Ddoc root index has no closing body")
        index.write_text(text.replace("</body>",
                         f'<p><a href="{version}/index.html">Versioned reference: {version}</a></p>\n</body>', 1))
    versions.sort(key=lambda tag: tuple(map(int, tag[1:].split("."))), reverse=True)
    (output / "versions.json").write_text(json.dumps({"stable": version, "versions": versions}, indent=2) + "\n")
    print("RELEASE_DOCS_SITE=PASS; stable=" + version + "; versions=" + ",".join(versions))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.repository, args.version, args.output)
